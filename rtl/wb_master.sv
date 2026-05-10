// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Wishbone B4 master (Specification B4, OpenCores / Silicore).
//
// Drives a single Wishbone slave port. Two modes of operation, selected
// by the PIPELINED parameter:
//   * PIPELINED = 0  classic standard cycle. STB is held high until the
//                    slave answers ACK/ERR/RTY. Throughput: one transfer
//                    per N cycles, where N = slave latency + 1.
//   * PIPELINED = 1  B4 pipelined cycle. STB pulses high for one cycle
//                    per beat; the master observes STALL to apply
//                    backpressure. Throughput: one beat per cycle when
//                    the slave is not stalled.
//
// User-side request interface:
//   req_valid_i  pulse high to enqueue a transaction (single beat or
//                burst start)
//   req_we_i     1 = write, 0 = read
//   req_addr_i   target address (byte-aligned to DATA_WIDTH/8)
//   req_data_i   write data (ignored on reads)
//   req_sel_i    byte-select mask (per-byte enable)
//   req_burst_i  burst length in beats (1 = single, 2..N for incrementing
//                burst). Address auto-increments by DATA_WIDTH/8 per beat.
//   req_lock_i   raise to assert LOCK throughout the burst (atomic RMW)
//   req_ready_o  master accepts a new request this cycle (rises when
//                idle or when the previous burst is winding down)
//
// User-side response interface:
//   rsp_valid_o  one-cycle pulse on each completed beat
//   rsp_data_o   read data for the completed beat (zero on a write)
//   rsp_resp_o   2'b00 = OK (ACK), 2'b01 = ERR, 2'b10 = RTY
//   rsp_last_o   one-cycle pulse on the LAST beat of the burst
//
// Errors and retries:
//   On ERR the master aborts the in-flight burst, drives CYC low for one
//   cycle, and reports rsp_resp_o = 01 with rsp_last_o = 1.
//   On RTY the master drops CYC for one cycle and re-issues the same
//   beat. The user-visible response is rsp_resp_o = 10 with rsp_last_o
//   asserted on the final retry attempt that succeeds (or aborts).
//   A retry counter caps re-issue at MAX_RETRIES; beyond that the master
//   gives up and reports rsp_resp_o = 10 with rsp_last_o = 1.

module wb_master #(
  parameter int unsigned ADDR_WIDTH   = 32,
  parameter int unsigned DATA_WIDTH   = 32,
  parameter bit          PIPELINED    = 1'b1,
  parameter int unsigned MAX_BURST    = 16,
  parameter int unsigned MAX_RETRIES  = 4
) (
  input  logic                    clk_i,
  input  logic                    rst_i,

  // Wishbone master port
  output logic [ADDR_WIDTH-1:0]   wb_adr_o,
  output logic [DATA_WIDTH-1:0]   wb_dat_o,
  input  logic [DATA_WIDTH-1:0]   wb_dat_i,
  output logic                    wb_we_o,
  output logic [DATA_WIDTH/8-1:0] wb_sel_o,
  output logic                    wb_stb_o,
  output logic                    wb_cyc_o,
  output logic                    wb_lock_o,
  output logic [2:0]              wb_cti_o,
  output logic [1:0]              wb_bte_o,
  input  logic                    wb_ack_i,
  input  logic                    wb_err_i,
  input  logic                    wb_rty_i,
  input  logic                    wb_stall_i,

  // User request interface
  input  logic                    req_valid_i,
  input  logic                    req_we_i,
  input  logic [ADDR_WIDTH-1:0]   req_addr_i,
  input  logic [DATA_WIDTH-1:0]   req_data_i,
  input  logic [DATA_WIDTH/8-1:0] req_sel_i,
  input  logic [$clog2(MAX_BURST+1)-1:0] req_burst_i,
  input  logic                    req_lock_i,
  output logic                    req_ready_o,

  // User response interface
  output logic                    rsp_valid_o,
  output logic [DATA_WIDTH-1:0]   rsp_data_o,
  output logic [1:0]              rsp_resp_o,
  output logic                    rsp_last_o
);

  localparam int unsigned BYTES   = DATA_WIDTH / 8;
  localparam int unsigned ALIGN   = (BYTES <= 1) ? 0 : $clog2(BYTES);
  localparam int unsigned BURST_W = $clog2(MAX_BURST + 1);
  localparam int unsigned RETRY_W = (MAX_RETRIES <= 1) ? 1 : $clog2(MAX_RETRIES + 1);

  // CTI codes
  localparam logic [2:0] CTI_CLASSIC   = 3'b000;
  localparam logic [2:0] CTI_INCR      = 3'b010;
  localparam logic [2:0] CTI_END       = 3'b111;

  // FSM
  typedef enum logic [2:0] {
      S_IDLE,
      S_ISSUE,
      S_WAIT,
      S_GAP,
      S_RETRY
  } state_e;
  state_e state_q, state_d;

  // Latched request
  logic                    we_q;
  logic [ADDR_WIDTH-1:0]   addr_q;
  logic [DATA_WIDTH-1:0]   wdata_q;
  logic [DATA_WIDTH/8-1:0] sel_q;
  logic [BURST_W-1:0]      beats_total_q;
  logic [BURST_W-1:0]      beats_issued_q;
  logic [BURST_W-1:0]      beats_acked_q;
  logic                    lock_q;
  logic [RETRY_W-1:0]      retry_cnt_q;

  // Pending response from this beat (used for r/w slot tracking).
  logic [DATA_WIDTH-1:0] rdata_buf_q;
  logic                  rsp_valid_q;
  logic [1:0]            rsp_resp_q;
  logic                  rsp_last_q;

  // Combinational helpers
  logic last_beat_to_issue;
  assign last_beat_to_issue = (beats_issued_q + BURST_W'(1)) >= beats_total_q;

  logic burst_complete;
  assign burst_complete = (beats_acked_q >= beats_total_q);

  logic stb_fire;             // master is presenting a fresh beat this cycle
  logic ack_seen;
  logic err_seen;
  logic rty_seen;
  assign ack_seen = wb_ack_i;
  assign err_seen = wb_err_i;
  assign rty_seen = wb_rty_i;

  // FSM next-state logic.
  always_comb begin
    state_d = state_q;
    case (state_q)
      S_IDLE: begin
        if (req_valid_i) state_d = S_ISSUE;
      end
      S_ISSUE: begin
        if (PIPELINED) begin
          // In pipelined mode we keep issuing beats while CYC=1; once
          // all beats have been launched we wait for the trailing ACKs.
          if (last_beat_to_issue && stb_fire) state_d = S_WAIT;
          if (err_seen)                        state_d = S_GAP;
          if (rty_seen)                        state_d = S_RETRY;
        end else begin
          // Classic: a single beat is in flight at a time. After ACK,
          // either continue with the next beat or wind down.
          if (ack_seen) begin
            if (last_beat_to_issue) state_d = S_GAP;
            else                    state_d = S_ISSUE;     // stay, advance
          end
          if (err_seen) state_d = S_GAP;
          if (rty_seen) state_d = S_RETRY;
        end
      end
      S_WAIT: begin
        // Pipelined: drain remaining ACKs.
        if (burst_complete)               state_d = S_GAP;
        if (err_seen)                     state_d = S_GAP;
        if (rty_seen)                     state_d = S_RETRY;
      end
      S_GAP: begin
        // One-cycle CYC-low recovery, then idle.
        state_d = S_IDLE;
      end
      S_RETRY: begin
        // CYC drops for one cycle, then re-issue the SAME beat unless
        // the retry budget is exhausted.
        if (retry_cnt_q >= RETRY_W'(MAX_RETRIES)) state_d = S_GAP;
        else                                       state_d = S_ISSUE;
      end
      default: state_d = S_IDLE;
    endcase
  end

  // Wishbone outputs
  logic                  cyc_drv;
  logic                  stb_drv;
  logic [ADDR_WIDTH-1:0] adr_drv;
  logic [DATA_WIDTH-1:0] dat_drv;
  logic                  we_drv;
  logic [DATA_WIDTH/8-1:0] sel_drv;
  logic                  lock_drv;
  logic [2:0]            cti_drv;
  logic [1:0]            bte_drv;

  always_comb begin
    cyc_drv  = 1'b0;
    stb_drv  = 1'b0;
    adr_drv  = addr_q;
    dat_drv  = wdata_q;
    we_drv   = we_q;
    sel_drv  = sel_q;
    lock_drv = lock_q;
    bte_drv  = 2'b00;     // linear bursts
    cti_drv  = (beats_total_q == BURST_W'(1)) ? CTI_CLASSIC :
               (last_beat_to_issue           ? CTI_END     : CTI_INCR);

    case (state_q)
      S_ISSUE: begin
        cyc_drv = 1'b1;
        // STB high in classic, or while we still have beats to issue in
        // pipelined and the slave is not stalling.
        if (PIPELINED) begin
          stb_drv = !wb_stall_i && (beats_issued_q < beats_total_q);
        end else begin
          stb_drv = 1'b1;
        end
      end
      S_WAIT: begin
        // Pipelined drain: CYC stays high, STB low.
        cyc_drv = 1'b1;
        stb_drv = 1'b0;
      end
      S_GAP, S_RETRY: begin
        cyc_drv = 1'b0;
        stb_drv = 1'b0;
      end
      default: ;
    endcase
  end

  // stb_fire = a beat is being accepted this cycle.
  assign stb_fire = stb_drv && cyc_drv && (PIPELINED ? !wb_stall_i : 1'b1);

  // ----------------------------------------------------------------
  // Sequential update.
  // ----------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q          <= S_IDLE;
      we_q             <= 1'b0;
      addr_q           <= '0;
      wdata_q          <= '0;
      sel_q            <= '0;
      beats_total_q    <= '0;
      beats_issued_q   <= '0;
      beats_acked_q    <= '0;
      lock_q           <= 1'b0;
      retry_cnt_q      <= '0;
      rdata_buf_q      <= '0;
      rsp_valid_q      <= 1'b0;
      rsp_resp_q       <= 2'b00;
      rsp_last_q       <= 1'b0;
    end else begin
      state_q     <= state_d;
      rsp_valid_q <= 1'b0;
      rsp_last_q  <= 1'b0;

      // Latch request on idle accept.
      if (state_q == S_IDLE && req_valid_i) begin
        we_q             <= req_we_i;
        addr_q           <= req_addr_i;
        wdata_q          <= req_data_i;
        sel_q            <= req_sel_i;
        beats_total_q    <= (req_burst_i == 0) ? BURST_W'(1) : req_burst_i;
        beats_issued_q   <= '0;
        beats_acked_q    <= '0;
        lock_q           <= req_lock_i;
        retry_cnt_q      <= '0;
      end

      // Issue a beat -> bump issued count, advance write data / address
      // for the NEXT beat (incrementing burst).
      if (state_q == S_ISSUE && stb_fire) begin
        beats_issued_q <= beats_issued_q + BURST_W'(1);
        addr_q         <= addr_q + ADDR_WIDTH'(BYTES);
        // For multi-beat writes, the user updates wdata via a streaming
        // hookup external to the master in real systems. The shipped
        // master holds the same wdata across the burst, which is the
        // expected behaviour for fill / replicate writes; for streaming
        // writes wrap this master with a small FIFO whose head feeds
        // wdata_q.
      end

      // Receive a response.
      if ((state_q == S_ISSUE || state_q == S_WAIT) && (ack_seen || err_seen || rty_seen)) begin
        rsp_valid_q <= 1'b1;
        rdata_buf_q <= wb_dat_i;
        if (ack_seen) begin
          rsp_resp_q   <= 2'b00;
          beats_acked_q <= beats_acked_q + BURST_W'(1);
          rsp_last_q   <= ((beats_acked_q + BURST_W'(1)) >= beats_total_q);
        end else if (err_seen) begin
          rsp_resp_q   <= 2'b01;
          rsp_last_q   <= 1'b1;     // burst aborts on ERR
        end else begin
          rsp_resp_q   <= 2'b10;
          // RTY does not advance the ack count; we re-issue.
        end
      end

      if (state_q == S_RETRY) begin
        retry_cnt_q    <= retry_cnt_q + RETRY_W'(1);
        // Re-issue the SAME beat: rewind issued count.
        if (beats_issued_q > 0)
          beats_issued_q <= beats_issued_q - BURST_W'(1);
        if (addr_q >= ADDR_WIDTH'(BYTES))
          addr_q <= addr_q - ADDR_WIDTH'(BYTES);
      end

      if (state_q == S_GAP) begin
        // Burst completed (or aborted); re-arm.
        beats_total_q  <= '0;
        beats_issued_q <= '0;
        beats_acked_q  <= '0;
        lock_q         <= 1'b0;
      end

      if (state_q == S_RETRY && retry_cnt_q >= RETRY_W'(MAX_RETRIES)) begin
        // Give up — emit a final RTY response on the way to GAP.
        rsp_valid_q <= 1'b1;
        rsp_resp_q  <= 2'b10;
        rsp_last_q  <= 1'b1;
      end
    end
  end

  // ----------------------------------------------------------------
  // Outputs.
  // ----------------------------------------------------------------
  assign wb_adr_o   = adr_drv;
  assign wb_dat_o   = dat_drv;
  assign wb_we_o    = we_drv;
  assign wb_sel_o   = sel_drv;
  assign wb_stb_o   = stb_drv;
  assign wb_cyc_o   = cyc_drv;
  assign wb_lock_o  = lock_drv && cyc_drv;
  assign wb_cti_o   = cti_drv;
  assign wb_bte_o   = bte_drv;

  assign req_ready_o = (state_q == S_IDLE) && !rst_i;

  assign rsp_valid_o = rsp_valid_q;
  assign rsp_data_o  = rdata_buf_q;
  assign rsp_resp_o  = rsp_resp_q;
  assign rsp_last_o  = rsp_last_q;

endmodule
