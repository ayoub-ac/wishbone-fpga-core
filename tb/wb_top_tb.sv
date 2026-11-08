// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Top-level testbench wrapper for wb_top. Stimulus from tb/sim_main.cpp
// drives the user request / response interface directly; the C++ harness
// does not see the Wishbone wires (they are bound to assertions and
// coverage internally).
//
// PIPELINED is parameterizable here so the same testbench compiles with
// either mode by changing the top-level parameter (or the Makefile flag).

module wb_top_tb #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned NUM_REGS   = 16,
  parameter bit          PIPELINED  = 1'b1,
  parameter int unsigned MAX_BURST  = 16,
  parameter int unsigned MAX_RETRIES = 4
) (
  input  logic                    clk_i,
  input  logic                    rst_i,

  input  logic                    req_valid,
  input  logic                    req_we,
  input  logic [ADDR_WIDTH-1:0]   req_addr,
  input  logic [DATA_WIDTH-1:0]   req_data,
  input  logic [DATA_WIDTH/8-1:0] req_sel,
  input  logic [$clog2(MAX_BURST+1)-1:0] req_burst,
  input  logic                    req_lock,
  output logic                    req_ready,

  output logic                    rsp_valid,
  output logic [DATA_WIDTH-1:0]   rsp_data,
  output logic [1:0]              rsp_resp,
  output logic                    rsp_last,

  input  logic                    rty_hint,

  output logic                    lock_active
);

  logic [NUM_REGS*DATA_WIDTH-1:0] reg_storage;
  logic                           wr_event;
  logic [ADDR_WIDTH-1:0]          wr_event_addr;
  logic                           rd_event;
  logic [ADDR_WIDTH-1:0]          rd_event_addr;

  // Exposed bus wires for the SVA/cov modules.
  logic [ADDR_WIDTH-1:0]   wb_adr;
  logic [DATA_WIDTH-1:0]   wb_dat_m2s;
  logic [DATA_WIDTH-1:0]   wb_dat_s2m;
  logic                    wb_we;
  logic [DATA_WIDTH/8-1:0] wb_sel;
  logic                    wb_stb;
  logic                    wb_cyc;
  logic                    wb_lock;
  logic [2:0]              wb_cti;
  logic [1:0]              wb_bte;
  logic                    wb_ack;
  logic                    wb_err;
  logic                    wb_rty;
  logic                    wb_stall;

  wb_top #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .NUM_REGS   (NUM_REGS),
    .PIPELINED  (PIPELINED),
    .MAX_BURST  (MAX_BURST),
    .MAX_RETRIES(MAX_RETRIES)
  ) u_dut (
    .clk_i           (clk_i),
    .rst_i           (rst_i),
    .req_valid_i     (req_valid),
    .req_we_i        (req_we),
    .req_addr_i      (req_addr),
    .req_data_i      (req_data),
    .req_sel_i       (req_sel),
    .req_burst_i     (req_burst),
    .req_lock_i      (req_lock),
    .req_ready_o     (req_ready),
    .rsp_valid_o     (rsp_valid),
    .rsp_data_o      (rsp_data),
    .rsp_resp_o      (rsp_resp),
    .rsp_last_o      (rsp_last),
    .rty_hint_i      (rty_hint),
    .lock_active_o   (lock_active),
    .reg_storage_o   (reg_storage),
    .wr_event_o      (wr_event),
    .wr_event_addr_o (wr_event_addr),
    .rd_event_o      (rd_event),
    .rd_event_addr_o (rd_event_addr),
    .wb_adr          (wb_adr),
    .wb_dat_m2s      (wb_dat_m2s),
    .wb_dat_s2m      (wb_dat_s2m),
    .wb_we           (wb_we),
    .wb_sel          (wb_sel),
    .wb_stb          (wb_stb),
    .wb_cyc          (wb_cyc),
    .wb_lock         (wb_lock),
    .wb_cti          (wb_cti),
    .wb_bte          (wb_bte),
    .wb_ack          (wb_ack),
    .wb_err          (wb_err),
    .wb_rty          (wb_rty),
    .wb_stall        (wb_stall)
  );

  // SVA + coverage bind.
  wb_assertions #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .PIPELINED  (PIPELINED)
  ) u_assert (
    .clk_i      (clk_i),
    .rst_i      (rst_i),
    .wb_adr     (wb_adr),
    .wb_dat_m2s (wb_dat_m2s),
    .wb_dat_s2m (wb_dat_s2m),
    .wb_we      (wb_we),
    .wb_sel     (wb_sel),
    .wb_stb     (wb_stb),
    .wb_cyc     (wb_cyc),
    .wb_lock    (wb_lock),
    .wb_cti     (wb_cti),
    .wb_bte     (wb_bte),
    .wb_ack     (wb_ack),
    .wb_err     (wb_err),
    .wb_rty     (wb_rty),
    .wb_stall   (wb_stall)
  );

  wb_cov #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .PIPELINED  (PIPELINED)
  ) u_cov (
    .clk_i    (clk_i),
    .rst_i    (rst_i),
    .wb_we    (wb_we),
    .wb_stb   (wb_stb),
    .wb_cyc   (wb_cyc),
    .wb_lock  (wb_lock),
    .wb_cti   (wb_cti),
    .wb_ack   (wb_ack),
    .wb_err   (wb_err),
    .wb_rty   (wb_rty),
    .wb_stall (wb_stall)
  );

endmodule
