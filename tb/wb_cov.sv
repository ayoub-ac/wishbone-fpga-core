// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Functional coverage for wb_top. Sticky bins recorded across the
// regression so the harness prints a single coverage line at end-of-test.
//
// Bins (10 total):
//   c_read_seen        any read transaction completed
//   c_write_seen       any write transaction completed
//   c_burst_seen       any multi-beat burst (>=2 beats) completed
//   c_single_seen      any single-beat (CTI = 000) transfer completed
//   c_lock_seen        any beat completed while LOCK was high
//   c_classic_mode     PIPELINED == 0 path exercised (CYC asserted with
//                      classic-style STB-held handshake)
//   c_pipelined_mode   PIPELINED == 1 path exercised (STB pulse + STALL)
//   c_resp_ack         ACK observed
//   c_resp_err         ERR observed
//   c_resp_rty         RTY observed

module wb_cov #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter bit          PIPELINED  = 1'b1
) (
  input logic                    clk_i,
  input logic                    rst_i,

  input logic                    wb_we,
  input logic                    wb_stb,
  input logic                    wb_cyc,
  input logic                    wb_lock,
  input logic [2:0]              wb_cti,
  input logic                    wb_ack,
  input logic                    wb_err,
  input logic                    wb_rty,
  input logic                    wb_stall
);

  logic c_read_seen      /*verilator public*/;
  logic c_write_seen     /*verilator public*/;
  logic c_burst_seen     /*verilator public*/;
  logic c_single_seen    /*verilator public*/;
  logic c_lock_seen      /*verilator public*/;
  logic c_classic_mode   /*verilator public*/;
  logic c_pipelined_mode /*verilator public*/;
  logic c_resp_ack       /*verilator public*/;
  logic c_resp_err       /*verilator public*/;
  logic c_resp_rty       /*verilator public*/;

  // Track per-CYC beat count to distinguish bursts from singles.
  int unsigned beats_in_cyc_q;
  logic        cyc_q;
  logic        we_in_cyc_q;
  logic        any_lock_in_cyc_q;
  logic        cti_burst_seen_q;
  logic        stall_seen_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      beats_in_cyc_q     <= 0;
      cyc_q              <= 1'b0;
      we_in_cyc_q        <= 1'b0;
      any_lock_in_cyc_q  <= 1'b0;
      cti_burst_seen_q   <= 1'b0;
      stall_seen_q       <= 1'b0;
    end else begin
      cyc_q <= wb_cyc;

      if (wb_cyc && !cyc_q) begin
        // CYC just rose — open a new transaction window.
        beats_in_cyc_q     <= 0;
        we_in_cyc_q        <= wb_we;
        any_lock_in_cyc_q  <= 1'b0;
        cti_burst_seen_q   <= 1'b0;
        stall_seen_q       <= 1'b0;
      end

      if (wb_cyc) begin
        if (wb_stb && (PIPELINED ? !wb_stall : 1'b1))
          beats_in_cyc_q <= beats_in_cyc_q + 1;
        if (wb_lock) any_lock_in_cyc_q <= 1'b1;
        if (wb_cti == 3'b010 || wb_cti == 3'b001) cti_burst_seen_q <= 1'b1;
        if (wb_stall) stall_seen_q <= 1'b1;
      end

      // Response observations.
      if (wb_ack && wb_cyc) begin
        c_resp_ack <= 1'b1;
        if (we_in_cyc_q) c_write_seen <= 1'b1;
        else             c_read_seen  <= 1'b1;
        if (any_lock_in_cyc_q) c_lock_seen <= 1'b1;

        if (cti_burst_seen_q || beats_in_cyc_q >= 2)
          c_burst_seen <= 1'b1;
        else if (beats_in_cyc_q >= 1)
          c_single_seen <= 1'b1;

        if (PIPELINED && stall_seen_q)
          c_pipelined_mode <= 1'b1;
        if (!PIPELINED)
          c_classic_mode <= 1'b1;
        if (PIPELINED && !stall_seen_q && beats_in_cyc_q >= 1)
          c_pipelined_mode <= 1'b1;     // pipelined run with no stall is still pipelined
      end

      if (wb_err && wb_cyc) c_resp_err <= 1'b1;
      if (wb_rty && wb_cyc) c_resp_rty <= 1'b1;
    end
  end

  initial begin
    c_read_seen      = 1'b0;
    c_write_seen     = 1'b0;
    c_burst_seen     = 1'b0;
    c_single_seen    = 1'b0;
    c_lock_seen      = 1'b0;
    c_classic_mode   = 1'b0;
    c_pipelined_mode = 1'b0;
    c_resp_ack       = 1'b0;
    c_resp_err       = 1'b0;
    c_resp_rty       = 1'b0;
  end

endmodule
