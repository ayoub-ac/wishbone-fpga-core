# Wishbone B4 FPGA core - build / lint / sim / synth
#
# Targets:
#   make lint            verilator --lint-only on RTL (master + slave +
#                        top + testbench glue)
#   make sim             build the wishbone-top simulator
#   make test            build + run sim, check for "+PASS"
#   make test-all        alias for `test`
#   make synth           Yosys: ice40 + ecp5 + xilinx generic for the top
#   make synth_report    run all available toolchains and emit SYNTH_REPORT.md
#   make vhdl-test       GHDL+Verilator co-sim of the VHDL wrapper (if installed)
#   make regen_vectors   regenerate tb/random_vectors.h from gen_random_vectors.py
#   make clean           remove build artifacts

VERILATOR ?= verilator
YOSYS     ?= yosys
GHDL      ?= ghdl
VIVADO    ?= vivado
QUARTUS   ?= quartus_sh

RTL_CORE := \
    rtl/wb_slave.sv \
    rtl/wb_master.sv \
    rtl/wb_top.sv

TB_TOP := tb/wb_top_tb.sv
TB_AUX := tb/wb_assertions.sv tb/wb_cov.sv
TB_CPP := tb/sim_main.cpp

VFLAGS := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

.PHONY: lint sim test test-all synth synth_report vhdl-test \
        regen_vectors clean

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module wb_top_tb \
	    $(RTL_CORE) $(TB_TOP) $(TB_AUX)

sim: obj_dir/Vwb_top_tb

obj_dir/Vwb_top_tb: $(RTL_CORE) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
                    tb/random_vectors.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) --assert --public-flat-rw \
	    --top-module wb_top_tb \
	    $(RTL_CORE) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
	    -o Vwb_top_tb

test: sim
	./obj_dir/Vwb_top_tb | tee test.log
	@grep -q "+PASS" test.log && echo "TESTS PASSED" || (echo "TESTS FAILED" && exit 1)

test-all: test

# ---------- Open synthesis (Yosys) ------------------------------------------
synth:
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top wb_top; synth_ice40 -top wb_top; stat" \
	    | tee synth_ice40.log
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top wb_top; synth_ecp5 -top wb_top -abc9; stat" \
	    | tee synth_ecp5.log
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top wb_top; synth_xilinx -top wb_top; stat" \
	    | tee synth_xilinx.log

# ---------- Cross-toolchain synthesis report --------------------------------
synth_report:
	@bash scripts/synth_report.sh

# ---------- VHDL co-sim (optional) ------------------------------------------
vhdl-test:
	@which $(GHDL) >/dev/null 2>&1 || { echo "ghdl not installed - skipping vhdl-test"; exit 0; }
	@which $(VERILATOR) >/dev/null 2>&1 || { echo "verilator not installed"; exit 1; }
	@bash scripts/vhdl_cosim.sh

regen_vectors:
	python3 tb/gen_random_vectors.py > tb/random_vectors.h

clean:
	rm -rf obj_dir \
	    test.log \
	    synth_ice40.log synth_ecp5.log synth_xilinx.log \
	    synth_report/ SYNTH_REPORT.md
