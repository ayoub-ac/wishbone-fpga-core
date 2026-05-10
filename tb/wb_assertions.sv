// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Wishbone B4 protocol assertions (Specification B4 §3).
//
// The properties below are the standard Wishbone B4 invariants every
// master/slave pair must maintain. They are bound on every cycle of
// every test, so a regression that breaks a handshake fails the gate
// instead of producing a confusing functional miscompare.
//
// Properties (8 total):
//
//   p_stb_implies_cyc       STB asserted implies CYC asserted (§3.1.3).
//                           No transfer can be in flight without an
//                           open cycle.
//   p_resp_only_when_cyc    ACK/ERR/RTY only meaningful while CYC=1.
//                           A response signal asserted with CYC=0 is a
//                           protocol violation.
//   p_resp_mutex            At most one of {ACK, ERR, RTY} high in any
//                           cycle (§3.1.4 — the response is a single
//                           termination signal).
//   p_cyc_stable_in_burst   While a beat is outstanding (STB asserted
//                           and the slave has not yet responded) CYC
//                           does not drop. Equivalent to "no abort
//                           mid-beat".
//   p_lock_implies_cyc      LOCK asserted implies CYC asserted (LOCK is
//                           qualified by CYC, B4 §3.2.4).
//   p_stall_implies_cyc     STALL asserted implies CYC asserted (only
//                           meaningful in pipelined mode).
//   p_no_stall_during_idle  When CYC=0, STALL must be 0 (the slave
//                           cannot back-pressure an idle bus).
//   p_resp_after_stb        Each ACK/ERR observed must be preceded by at
//                           least one STB beat in the current cycle.
//                           (Bounded liveness check on the response
//                           pairing.)

module wb_assertions #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter bit          PIPELINED  = 1'b1,
  parameter int unsigned LAT_MAX    = 4096
) (
  input logic                    clk_i,
  input logic                    rst_i,

  input logic [ADDR_WIDTH-1:0]   wb_adr,
  input logic [DATA_WIDTH-1:0]   wb_dat_m2s,
  input logic [DATA_WIDTH-1:0]   wb_dat_s2m,
  input logic                    wb_we,
  input logic [DATA_WIDTH/8-1:0] wb_sel,
  input logic                    wb_stb,
  input logic                    wb_cyc,
  input logic                    wb_lock,
  input logic [2:0]              wb_cti,
  input logic [1:0]              wb_bte,
  input logic                    wb_ack,
  input logic                    wb_err,
  input logic                    wb_rty,
  input logic                    wb_stall
);
`ifndef SYNTHESIS

  // ------------------------------------------------------------------
  // Channel-rule properties.
  // ------------------------------------------------------------------
  property p_stb_implies_cyc;
    @(posedge clk_i) disable iff (rst_i)
      wb_stb |-> wb_cyc;
  endproperty
  a_stb_implies_cyc: assert property (p_stb_implies_cyc)
    else $error("wb: STB asserted with CYC low");

  property p_resp_only_when_cyc;
    @(posedge clk_i) disable iff (rst_i)
      (wb_ack || wb_err || wb_rty) |-> wb_cyc;
  endproperty
  a_resp_only_when_cyc: assert property (p_resp_only_when_cyc)
    else $error("wb: ACK/ERR/RTY asserted with CYC low");

  property p_resp_mutex;
    @(posedge clk_i) disable iff (rst_i)
      $onehot0({wb_ack, wb_err, wb_rty});
  endproperty
  a_resp_mutex: assert property (p_resp_mutex)
    else $error("wb: ACK/ERR/RTY not mutually exclusive");

  // ------------------------------------------------------------------
  // CYC stability while a beat is in flight.
  //
  // Track a "beat outstanding" flag: rises on STB & CYC, falls on a
  // response. While that flag is high, CYC must remain high.
  // ------------------------------------------------------------------
  logic beat_outstanding_q;
  always_ff @(posedge clk_i) begin
    if (rst_i)                                 beat_outstanding_q <= 1'b0;
    else if (wb_ack || wb_err || wb_rty)       beat_outstanding_q <= 1'b0;
    else if (wb_stb && wb_cyc &&
             (PIPELINED ? !wb_stall : 1'b1))   beat_outstanding_q <= 1'b1;
  end

  property p_cyc_stable_in_burst;
    @(posedge clk_i) disable iff (rst_i)
      beat_outstanding_q |-> wb_cyc;
  endproperty
  a_cyc_stable_in_burst: assert property (p_cyc_stable_in_burst)
    else $error("wb: CYC dropped while a beat was outstanding");

  // ------------------------------------------------------------------
  // LOCK / STALL qualification.
  // ------------------------------------------------------------------
  property p_lock_implies_cyc;
    @(posedge clk_i) disable iff (rst_i)
      wb_lock |-> wb_cyc;
  endproperty
  a_lock_implies_cyc: assert property (p_lock_implies_cyc)
    else $error("wb: LOCK asserted with CYC low");

  property p_stall_implies_cyc;
    @(posedge clk_i) disable iff (rst_i)
      (PIPELINED && wb_stall) |-> wb_cyc;
  endproperty
  a_stall_implies_cyc: assert property (p_stall_implies_cyc)
    else $error("wb: STALL asserted with CYC low");

  property p_no_stall_during_idle;
    @(posedge clk_i) disable iff (rst_i)
      !wb_cyc |-> !wb_stall;
  endproperty
  a_no_stall_during_idle: assert property (p_no_stall_during_idle)
    else $error("wb: STALL high while CYC was low");

  // ------------------------------------------------------------------
  // Response pairing: every ACK/ERR/RTY must be preceded by at least
  // one STB beat in this CYC window. Track count of accepted beats and
  // count of received responses; respses cannot lead beats.
  // ------------------------------------------------------------------
  int unsigned beats_accepted_q;
  int unsigned resps_seen_q;
  always_ff @(posedge clk_i) begin
    if (rst_i || !wb_cyc) begin
      beats_accepted_q <= 0;
      resps_seen_q     <= 0;
    end else begin
      if (wb_stb && (PIPELINED ? !wb_stall : 1'b1))
        beats_accepted_q <= beats_accepted_q + 1;
      if (wb_ack || wb_err || wb_rty)
        resps_seen_q <= resps_seen_q + 1;
    end
  end

  property p_resp_after_stb;
    @(posedge clk_i) disable iff (rst_i)
      (wb_ack || wb_err || wb_rty) |-> (beats_accepted_q > resps_seen_q);
  endproperty
  a_resp_after_stb: assert property (p_resp_after_stb)
    else $error("wb: response asserted before any matching beat was accepted");

  // ------------------------------------------------------------------
  // Liveness: a response must arrive within LAT_MAX cycles of an
  // accepted beat. Catches a slave that drops the bus on the floor.
  // ------------------------------------------------------------------
  int unsigned cycles_pending_q;
  always_ff @(posedge clk_i) begin
    if (rst_i || !wb_cyc)                            cycles_pending_q <= 0;
    else if (beats_accepted_q > resps_seen_q)        cycles_pending_q <= cycles_pending_q + 1;
    else                                              cycles_pending_q <= 0;
  end

  property p_no_deadlock;
    @(posedge clk_i) disable iff (rst_i)
      cycles_pending_q < LAT_MAX;
  endproperty
  a_no_deadlock: assert property (p_no_deadlock)
    else $error("wb: a beat hung outstanding for >%0d cycles", LAT_MAX);

`endif // SYNTHESIS
endmodule
