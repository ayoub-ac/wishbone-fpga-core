// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Wishbone B4 top-level loopback module.
//
// Wires a single Wishbone B4 master to a single slave through a
// point-to-point connection. The user request / response interface on
// the master is exposed; the slave's register file is also exposed via
// the user-side hooks.
//
// This is the recommended starting point for integrators that want to
// drop in a CSR / regfile slave behind a control master, or to use the
// loopback as a self-test under reset.
//
// Both master and slave can be elaborated in classic or pipelined mode.
// The PIPELINED parameter sets BOTH (the only sensible configuration —
// mixing modes between master and slave is illegal under B4).

module wb_top #(
  parameter int unsigned ADDR_WIDTH  = 32,
  parameter int unsigned DATA_WIDTH  = 32,
  parameter int unsigned NUM_REGS    = 16,
  parameter bit          PIPELINED   = 1'b1,
  parameter int unsigned MAX_BURST   = 16,
  parameter int unsigned MAX_RETRIES = 4,
  parameter logic [NUM_REGS*DATA_WIDTH-1:0] REG_RESET = {NUM_REGS*DATA_WIDTH{1'b0}}
) (
  input  logic                    clk_i,
  input  logic                    rst_i,

  // User-side request interface (drives the master)
  input  logic                    req_valid_i,
  input  logic                    req_we_i,
  input  logic [ADDR_WIDTH-1:0]   req_addr_i,
  input  logic [DATA_WIDTH-1:0]   req_data_i,
  input  logic [DATA_WIDTH/8-1:0] req_sel_i,
  input  logic [$clog2(MAX_BURST+1)-1:0] req_burst_i,
  input  logic                    req_lock_i,
  output logic                    req_ready_o,

  // User-side response interface (from the master)
  output logic                    rsp_valid_o,
  output logic [DATA_WIDTH-1:0]   rsp_data_o,
  output logic [1:0]              rsp_resp_o,
  output logic                    rsp_last_o,

  // Slave-side hooks
  input  logic                    rty_hint_i,
  output logic                    lock_active_o,
  output logic [NUM_REGS*DATA_WIDTH-1:0] reg_storage_o,
  output logic                    wr_event_o,
  output logic [ADDR_WIDTH-1:0]   wr_event_addr_o,
  output logic                    rd_event_o,
  output logic [ADDR_WIDTH-1:0]   rd_event_addr_o,

  // Wishbone bus interface (exposed for SVA binding and external visibility)
  output logic [ADDR_WIDTH-1:0]   wb_adr,
  output logic [DATA_WIDTH-1:0]   wb_dat_m2s,
  output logic [DATA_WIDTH-1:0]   wb_dat_s2m,
  output logic                    wb_we,
  output logic [DATA_WIDTH/8-1:0] wb_sel,
  output logic                    wb_stb,
  output logic                    wb_cyc,
  output logic                    wb_lock,
  output logic [2:0]              wb_cti,
  output logic [1:0]              wb_bte,
  output logic                    wb_ack,
  output logic                    wb_err,
  output logic                    wb_rty,
  output logic                    wb_stall
);

  // Internal Wishbone wires (master -> slave -> master).
  logic [ADDR_WIDTH-1:0]   m_adr;
  logic [DATA_WIDTH-1:0]   m_dat;
  logic                    m_we;
  logic [DATA_WIDTH/8-1:0] m_sel;
  logic                    m_stb;
  logic                    m_cyc;
  logic                    m_lock;
  logic [2:0]              m_cti;
  logic [1:0]              m_bte;
  logic [DATA_WIDTH-1:0]   s_dat;
  logic                    s_ack;
  logic                    s_err;
  logic                    s_rty;
  logic                    s_stall;

  wb_master #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .PIPELINED  (PIPELINED),
    .MAX_BURST  (MAX_BURST),
    .MAX_RETRIES(MAX_RETRIES)
  ) u_master (
    .clk_i       (clk_i),
    .rst_i       (rst_i),
    .wb_adr_o    (m_adr),
    .wb_dat_o    (m_dat),
    .wb_dat_i    (s_dat),
    .wb_we_o     (m_we),
    .wb_sel_o    (m_sel),
    .wb_stb_o    (m_stb),
    .wb_cyc_o    (m_cyc),
    .wb_lock_o   (m_lock),
    .wb_cti_o    (m_cti),
    .wb_bte_o    (m_bte),
    .wb_ack_i    (s_ack),
    .wb_err_i    (s_err),
    .wb_rty_i    (s_rty),
    .wb_stall_i  (s_stall),
    .req_valid_i (req_valid_i),
    .req_we_i    (req_we_i),
    .req_addr_i  (req_addr_i),
    .req_data_i  (req_data_i),
    .req_sel_i   (req_sel_i),
    .req_burst_i (req_burst_i),
    .req_lock_i  (req_lock_i),
    .req_ready_o (req_ready_o),
    .rsp_valid_o (rsp_valid_o),
    .rsp_data_o  (rsp_data_o),
    .rsp_resp_o  (rsp_resp_o),
    .rsp_last_o  (rsp_last_o)
  );

  wb_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .NUM_REGS   (NUM_REGS),
    .PIPELINED  (PIPELINED),
    .REG_RESET  (REG_RESET)
  ) u_slave (
    .clk_i           (clk_i),
    .rst_i           (rst_i),
    .wb_adr_i        (m_adr),
    .wb_dat_i        (m_dat),
    .wb_dat_o        (s_dat),
    .wb_we_i         (m_we),
    .wb_sel_i        (m_sel),
    .wb_stb_i        (m_stb),
    .wb_cyc_i        (m_cyc),
    .wb_lock_i       (m_lock),
    .wb_cti_i        (m_cti),
    .wb_bte_i        (m_bte),
    .wb_ack_o        (s_ack),
    .wb_err_o        (s_err),
    .wb_rty_o        (s_rty),
    .wb_stall_o      (s_stall),
    .rty_hint_i      (rty_hint_i),
    .lock_active_o   (lock_active_o),
    .reg_storage_o   (reg_storage_o),
    .wr_event_o      (wr_event_o),
    .wr_event_addr_o (wr_event_addr_o),
    .rd_event_o      (rd_event_o),
    .rd_event_addr_o (rd_event_addr_o)
  );

  // Expose the bus for the SVA / coverage modules.
  assign wb_adr     = m_adr;
  assign wb_dat_m2s = m_dat;
  assign wb_dat_s2m = s_dat;
  assign wb_we      = m_we;
  assign wb_sel     = m_sel;
  assign wb_stb     = m_stb;
  assign wb_cyc     = m_cyc;
  assign wb_lock    = m_lock;
  assign wb_cti     = m_cti;
  assign wb_bte     = m_bte;
  assign wb_ack     = s_ack;
  assign wb_err     = s_err;
  assign wb_rty     = s_rty;
  assign wb_stall   = s_stall;

endmodule
