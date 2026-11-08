-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog wb_top module.
--
-- This entity exposes the master+slave loopback's port list in VHDL
-- syntax. The architecture instantiates the SystemVerilog module by
-- component name; mixed-language elaboration is supported natively by
-- Vivado, Quartus, ModelSim/Questa, and Aldec, and via the GHDL VHPI
-- bridge for open simulation.
--
-- Status: WRAPPER ONLY. The datapath itself remains in SystemVerilog
-- (rtl/*.sv). A native VHDL port of the datapath is listed as future
-- work.
--
-- I/O contract: identical to wb_top.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-high synchronous reset.
--   * Standard Wishbone B4 handshake with classic + pipelined modes.
--   * NUM_REGS x DATA_WIDTH register file in the slave.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

entity wb_top_vhdl is
  generic (
    ADDR_WIDTH  : integer := 32;
    DATA_WIDTH  : integer := 32;
    NUM_REGS    : integer := 16;
    PIPELINED   : std_logic := '1';
    MAX_BURST   : integer := 16;
    MAX_RETRIES : integer := 4
  );
  port (
    clk_i           : in  std_logic;
    rst_i           : in  std_logic;

    req_valid_i     : in  std_logic;
    req_we_i        : in  std_logic;
    req_addr_i      : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    req_data_i      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    req_sel_i       : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
    req_burst_i     : in  std_logic_vector(integer(ceil(log2(real(MAX_BURST+1))))-1 downto 0);
    req_lock_i      : in  std_logic;
    req_ready_o     : out std_logic;

    rsp_valid_o     : out std_logic;
    rsp_data_o      : out std_logic_vector(DATA_WIDTH-1 downto 0);
    rsp_resp_o      : out std_logic_vector(1 downto 0);
    rsp_last_o      : out std_logic;

    rty_hint_i      : in  std_logic;
    lock_active_o   : out std_logic;
    reg_storage_o   : out std_logic_vector(NUM_REGS*DATA_WIDTH-1 downto 0);
    wr_event_o      : out std_logic;
    wr_event_addr_o : out std_logic_vector(ADDR_WIDTH-1 downto 0);
    rd_event_o      : out std_logic;
    rd_event_addr_o : out std_logic_vector(ADDR_WIDTH-1 downto 0)
  );
end entity wb_top_vhdl;

architecture rtl of wb_top_vhdl is

  -- The SystemVerilog wb_top module (declared as a black-box component;
  -- the simulator/synth tool elaborates it from rtl/wb_top.sv).
  component wb_top is
    generic (
      ADDR_WIDTH  : integer;
      DATA_WIDTH  : integer;
      NUM_REGS    : integer;
      PIPELINED   : std_logic;
      MAX_BURST   : integer;
      MAX_RETRIES : integer
    );
    port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;
      req_valid_i     : in  std_logic;
      req_we_i        : in  std_logic;
      req_addr_i      : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
      req_data_i      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
      req_sel_i       : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
      req_burst_i     : in  std_logic_vector(integer(ceil(log2(real(MAX_BURST+1))))-1 downto 0);
      req_lock_i      : in  std_logic;
      req_ready_o     : out std_logic;
      rsp_valid_o     : out std_logic;
      rsp_data_o      : out std_logic_vector(DATA_WIDTH-1 downto 0);
      rsp_resp_o      : out std_logic_vector(1 downto 0);
      rsp_last_o      : out std_logic;
      rty_hint_i      : in  std_logic;
      lock_active_o   : out std_logic;
      reg_storage_o   : out std_logic_vector(NUM_REGS*DATA_WIDTH-1 downto 0);
      wr_event_o      : out std_logic;
      wr_event_addr_o : out std_logic_vector(ADDR_WIDTH-1 downto 0);
      rd_event_o      : out std_logic;
      rd_event_addr_o : out std_logic_vector(ADDR_WIDTH-1 downto 0)
    );
  end component;

begin

  u_inst : wb_top
    generic map (
      ADDR_WIDTH  => ADDR_WIDTH,
      DATA_WIDTH  => DATA_WIDTH,
      NUM_REGS    => NUM_REGS,
      PIPELINED   => PIPELINED,
      MAX_BURST   => MAX_BURST,
      MAX_RETRIES => MAX_RETRIES
    )
    port map (
      clk_i           => clk_i,
      rst_i           => rst_i,
      req_valid_i     => req_valid_i,
      req_we_i        => req_we_i,
      req_addr_i      => req_addr_i,
      req_data_i      => req_data_i,
      req_sel_i       => req_sel_i,
      req_burst_i     => req_burst_i,
      req_lock_i      => req_lock_i,
      req_ready_o     => req_ready_o,
      rsp_valid_o     => rsp_valid_o,
      rsp_data_o      => rsp_data_o,
      rsp_resp_o      => rsp_resp_o,
      rsp_last_o      => rsp_last_o,
      rty_hint_i      => rty_hint_i,
      lock_active_o   => lock_active_o,
      reg_storage_o   => reg_storage_o,
      wr_event_o      => wr_event_o,
      wr_event_addr_o => wr_event_addr_o,
      rd_event_o      => rd_event_o,
      rd_event_addr_o => rd_event_addr_o
    );

end architecture rtl;
