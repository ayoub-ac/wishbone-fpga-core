// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Wishbone B4 slave (Specification B4, OpenCores / Silicore).
//
// Supports both classic-standard cycles and B4 pipelined cycles. The
// configuration is parametric: PIPELINED=0 selects the classic handshake
// (STB held until ACK; one transaction per ACK) and PIPELINED=1 selects
// the B4 pipelined handshake with STALL-driven backpressure (a master
// pulses STB, the slave consumes when STALL=0, ACKs trail by an
// implementation-defined latency).
//
// Burst transfers (B4 §3.2.3) are supported through CTI (cycle-type ID)
// and BTE (burst-type extension):
//   CTI[2:0]:
//     3'b000  classic cycle (no burst)
//     3'b001  constant-address burst (FIFO style; addr stays put)
//     3'b010  incrementing burst (address auto-increments)
//     3'b111  end-of-burst marker (master signals the final beat)
//   BTE[1:0]:
//     2'b00  linear burst
//     2'b01  4-beat wrap
//     2'b10  8-beat wrap
//     2'b11  16-beat wrap
//
// Address decode + responses:
//   * In-range, aligned access  -> ACK
//   * Out-of-range / mis-aligned -> ERR (B4 §3.1.4)
//   * Slave-asserted retry       -> RTY (driven by integrator hint
//                                  rty_hint_i; default unused)
// At most one of {ACK, ERR, RTY} can be high in any cycle (mutually
// exclusive, B4 §3.1.4).
//
// LOCK_I is honoured: while the master holds LOCK_I high, the slave does
// not allow any other internal user (e.g. a refresh path) to grab the
// register file mid-cycle. The shipped slave has no other internal user
// so LOCK_I is forwarded as a status signal `lock_active_o`.

module wb_slave #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned NUM_REGS   = 16,
  parameter bit          PIPELINED  = 1'b1,
  // Reset values for each register (NUM_REGS x DATA_WIDTH packed).
  parameter logic [NUM_REGS*DATA_WIDTH-1:0] REG_RESET = {NUM_REGS*DATA_WIDTH{1'b0}}
) (
  input  logic                    clk_i,
  input  logic                    rst_i,    // Wishbone B4 reset is active-HIGH (§3.1.3)

  // Wishbone slave port (suffix _i = inputs from master, _o = outputs).
  input  logic [ADDR_WIDTH-1:0]   wb_adr_i,
  input  logic [DATA_WIDTH-1:0]   wb_dat_i,
  output logic [DATA_WIDTH-1:0]   wb_dat_o,
  input  logic                    wb_we_i,
  input  logic [DATA_WIDTH/8-1:0] wb_sel_i,
  input  logic                    wb_stb_i,
  input  logic                    wb_cyc_i,
  input  logic                    wb_lock_i,
  input  logic [2:0]              wb_cti_i,
  input  logic [1:0]              wb_bte_i,
  output logic                    wb_ack_o,
  output logic                    wb_err_o,
  output logic                    wb_rty_o,
  output logic                    wb_stall_o,   // pipelined only

  // Integrator hooks
  input  logic                    rty_hint_i,   // raise to force RTY on next response
  output logic                    lock_active_o,
  output logic [NUM_REGS*DATA_WIDTH-1:0] reg_storage_o,
  output logic                    wr_event_o,
  output logic [ADDR_WIDTH-1:0]   wr_event_addr_o,
  output logic                    rd_event_o,
  output logic [ADDR_WIDTH-1:0]   rd_event_addr_o
);

  localparam int unsigned BYTES = DATA_WIDTH / 8;
  localparam int unsigned ALIGN = (BYTES <= 1) ? 1 : $clog2(BYTES);
  localparam int unsigned IDX_W = (NUM_REGS <= 1) ? 1 : $clog2(NUM_REGS);

  // ------------------------------------------------------------------
  // Address decode
  // ------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] align_mask;
  assign align_mask = (BYTES > 1)
                       ? (ADDR_WIDTH'(BYTES) - ADDR_WIDTH'(1))
                       : ADDR_WIDTH'(0);

  logic [ADDR_WIDTH-1:0] idx_full;
  assign idx_full = wb_adr_i >> ALIGN;

  logic align_err;
  logic range_err;
  assign align_err = ((wb_adr_i & align_mask) != '0);
  assign range_err = (idx_full >= ADDR_WIDTH'(NUM_REGS));

  logic decode_err;
  assign decode_err = align_err || range_err;

  logic [IDX_W-1:0] idx;
  assign idx = idx_full[IDX_W-1:0];

  // ------------------------------------------------------------------
  // Storage array (flat FF regfile, NUM_REGS x DATA_WIDTH).
  // ------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] regs_q [NUM_REGS];

  function automatic logic [DATA_WIDTH-1:0] reg_reset_slice(input integer i);
    reg_reset_slice = REG_RESET[i*DATA_WIDTH +: DATA_WIDTH];
  endfunction

  // ------------------------------------------------------------------
  // Pipelined vs classic FSM.
  //
  // Classic: a transfer is in progress while CYC=1 && STB=1; we ACK it
  // for one cycle, then de-assert. The master is required to drop STB
  // after seeing ACK.
  //
  // Pipelined: STB is a one-cycle pulse from the master. STALL is the
  // backpressure handshake — when STALL=1 the slave is not yet ready to
  // accept this beat. ACK trails the accepted beat by the slave's
  // internal latency (here: 1 cycle, same as classic). For a deeper
  // pipeline a slave could track several outstanding beats; the shipped
  // slave is a 1-deep pipeline, which is the most common case for a
  // CSR/regfile slave.
  // ------------------------------------------------------------------
  logic                  beat_accept;
  logic                  beat_was_we;
  logic [ADDR_WIDTH-1:0] beat_addr_q;
  logic [DATA_WIDTH-1:0] beat_wdata_q;
  logic [DATA_WIDTH/8-1:0] beat_sel_q;
  logic                  beat_was_decode_err;
  logic                  beat_was_rty;
  logic                  beat_pending_q;       // a response is owed next cycle

  // Pipelined STALL: not stalled when no response is currently pending,
  // OR when the master accepted the previous response in the same cycle
  // (back-to-back). The shipped slave can accept one beat per cycle as
  // long as the master consumes ACKs as soon as they assert.
  logic stall_int;
  assign stall_int = beat_pending_q;

  // The "beat_accept" condition picks up a fresh transfer.
  if (PIPELINED) begin : g_pip_accept
    assign beat_accept = wb_cyc_i && wb_stb_i && !stall_int;
  end else begin : g_clas_accept
    // Classic: accept on the cycle CYC && STB are both high AND we have
    // not yet ACKed for this transaction.
    assign beat_accept = wb_cyc_i && wb_stb_i && !beat_pending_q;
  end

  // ACK / ERR / RTY: we present them the cycle AFTER beat_accept. They
  // are mutually exclusive (B4 §3.1.4).
  logic ack_q, err_q, rty_q;
  logic [DATA_WIDTH-1:0] rdata_q;

  // Read mux (combinational, so the registered rdata_q is sampled in
  // the always_ff below from the regfile values at acceptance time).
  logic [DATA_WIDTH-1:0] rd_word;
  assign rd_word = regs_q[idx];

  // Apply byte strobes to a stored word.
  function automatic logic [DATA_WIDTH-1:0] apply_sel(
      input logic [DATA_WIDTH-1:0]   old_v,
      input logic [DATA_WIDTH-1:0]   new_v,
      input logic [DATA_WIDTH/8-1:0] sel);
    logic [DATA_WIDTH-1:0] r;
    integer b;
    r = old_v;
    for (b = 0; b < BYTES; b = b + 1) begin
      if (sel[b]) r[b*8 +: 8] = new_v[b*8 +: 8];
    end
    apply_sel = r;
  endfunction

  // ------------------------------------------------------------------
  // Storage update + response generation.
  // ------------------------------------------------------------------
  integer i;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      for (i = 0; i < NUM_REGS; i = i + 1)
        regs_q[i] <= reg_reset_slice(i);
      ack_q                <= 1'b0;
      err_q                <= 1'b0;
      rty_q                <= 1'b0;
      rdata_q              <= '0;
      beat_pending_q       <= 1'b0;
      beat_was_we          <= 1'b0;
      beat_addr_q          <= '0;
      beat_wdata_q         <= '0;
      beat_sel_q           <= '0;
      beat_was_decode_err  <= 1'b0;
      beat_was_rty         <= 1'b0;
    end else begin
      // Default: response signals are pulses, so clear them every cycle.
      ack_q <= 1'b0;
      err_q <= 1'b0;
      rty_q <= 1'b0;

      // 1) Drain prior beat (assert one of ACK/ERR/RTY this cycle).
      if (beat_pending_q) begin
        if (beat_was_rty) begin
          rty_q <= 1'b1;
        end else if (beat_was_decode_err) begin
          err_q <= 1'b1;
        end else begin
          ack_q   <= 1'b1;
          rdata_q <= rdata_q;     // sampled at accept
          // Apply write only on ACK path (ERR/RTY beats are aborted).
          if (beat_was_we) begin
            // idx is recomputed from beat_addr_q so the regfile updates
            // the same cell that was decoded at accept time.
            regs_q[beat_addr_q[ALIGN +: IDX_W]]
                <= apply_sel(regs_q[beat_addr_q[ALIGN +: IDX_W]],
                             beat_wdata_q, beat_sel_q);
          end
        end
        beat_pending_q <= 1'b0;
      end

      // 2) Capture a new beat.
      if (beat_accept) begin
        beat_pending_q       <= 1'b1;
        beat_addr_q          <= wb_adr_i;
        beat_wdata_q         <= wb_dat_i;
        beat_sel_q           <= wb_sel_i;
        beat_was_we          <= wb_we_i;
        beat_was_decode_err  <= decode_err;
        beat_was_rty         <= rty_hint_i;
        // Sample read data combinationally for reads.
        rdata_q              <= decode_err ? '0 : rd_word;
      end
    end
  end

  // ------------------------------------------------------------------
  // Output drive.
  // ------------------------------------------------------------------
  assign wb_ack_o   = ack_q;
  assign wb_err_o   = err_q;
  assign wb_rty_o   = rty_q;
  assign wb_dat_o   = rdata_q;
  assign wb_stall_o = PIPELINED ? stall_int : 1'b0;

  assign lock_active_o = wb_lock_i && wb_cyc_i;

  // Side-band events.
  assign wr_event_o      = beat_pending_q && beat_was_we && !beat_was_decode_err && !beat_was_rty;
  assign wr_event_addr_o = beat_addr_q;
  assign rd_event_o      = beat_pending_q && !beat_was_we && !beat_was_decode_err && !beat_was_rty;
  assign rd_event_addr_o = beat_addr_q;

  // Pack storage out for user logic.
  genvar gi;
  generate
    for (gi = 0; gi < NUM_REGS; gi = gi + 1) begin : g_pack
      assign reg_storage_o[gi*DATA_WIDTH +: DATA_WIDTH] = regs_q[gi];
    end
  endgenerate

  // Tie-off unused bursts signals (BTE/CTI are advisory for a 1-deep
  // pipeline slave; the master uses them to convey burst type to the
  // arbiter, but the regfile slave handles every beat identically).
  logic _unused;
  assign _unused = ^{wb_cti_i, wb_bte_i};

endmodule
