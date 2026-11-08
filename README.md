# wishbone-fpga-core

[![License: GPL-3.0 | commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)

> **Status: experimental and unverified.** This core was written with AI assistance and has not been independently verified in simulation regressions, formal proofs or hardware. Claims in this repository about protocol compliance, test results, timing and resource use are unverified. Do not use it in production or safety-critical designs without your own verification. No support or maintenance is provided.

Parameterizable Wishbone B4 master and slave IP cores in SystemVerilog,
the open-hardware alternative to AXI for OpenROAD / Caravel, LiteX,
Pulpissimo, and the OpenCores ecosystem.

The cores are intended to implement the Wishbone B4 specification
(OpenCores / Silicore B4); compliance is not verified. Intended features:
classic-standard cycles, B4 pipelined cycles with STALL back-pressure,
incrementing bursts (the master drives `CTI` / `BTE`; the slave does not
decode them), mutually-exclusive `ACK / ERR / RTY` termination, and
`LOCK`-qualified transactions.
Targets iCE40, ECP5, Xilinx 7-series, Cyclone V, and Tang Nano 9K.

Tests are included (1024 random transactions checked against a
software model, edge cases such as burst, lock, retry, error, mid-burst
reset and address decode, and SystemVerilog assertions on protocol
invariants); results not independently confirmed.

## Quickstart

```bash
git clone https://github.com/ayoub-ac/wishbone-fpga-core.git
cd wishbone-fpga-core
make lint test            # Verilator lint + 1024 random + edge-case suite
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth
flow. Python 3 for `make regen_vectors`.

## Architecture

```
                     +----------------------+
   user_request ---->|     wb_master        |
   user_response <---|  (FSM, burst counter,|---> wb_cyc, wb_stb, wb_we
                     |   retry handler)     |---> wb_adr, wb_dat, wb_sel
                     +-----------+----------+---> wb_lock, wb_cti, wb_bte
                                 |
                                 v Wishbone B4 bus
                     +----------------------+
                     |     wb_slave         |
                     |  (decode + regfile,  |---> reg_storage (user-visible)
                     |   ACK/ERR/RTY,       |---> wr_event / rd_event pulses
                     |   STALL backpressure)|
                     +----------------------+
```

Both modules share the `PIPELINED` parameter; selecting `0` configures
both for classic-standard cycles, selecting `1` enables the B4 pipelined
handshake. Mixing modes is illegal under B4 and is not supported.

See [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md) for full Wishbone-side
timing diagrams and the per-channel protocol.

## Headline numbers

Unverified estimates (see `RESOURCE_ESTIMATES.md`); run `make synth_report`
for real numbers (`wb_top` with `NUM_REGS=16`, `DATA_WIDTH=32`):

| Target           | Notes                  |
|------------------|------------------------|
| iCE40 UP5K       | see `SYNTH_REPORT.md`  |
| ECP5 LFE5UM-25   | see `SYNTH_REPORT.md`  |
| Xilinx Artix-7   | see `SYNTH_REPORT.md`  |

Vendor flows (Vivado / Diamond / Quartus) may pack smaller than the
Yosys numbers; not measured.

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer.

```bash
make lint            # static check the RTL (master + slave + top + tb)
make test            # build and run regression (1024 random + edge cases)
```

The testbench is intended to end with `+PASS all tests passed` and exit 0
on success; results not independently confirmed.

## Verification

Tests are included; results not independently confirmed. Three
techniques are intended in the testbench: 9 directed
tests (single + burst W/R, ERR / RTY / LOCK, mid-burst reset,
back-to-back), SVA properties (`tb/wb_assertions.sv` — STB->CYC,
response mutex, CYC stability, LOCK qualification, no-stall-when-idle,
deadlock bound), and 10 functional coverage bins (`tb/wb_cov.sv`). The
1024 random transactions are intended to be checked against a Python
software shadow of the slave regfile.

The `classic_mode` coverage bin only fires when the design is
elaborated with `PIPELINED = 0`; in the shipped pipelined build it is
intentionally a miss-by-design and not gated.

`make synth_report` runs every available toolchain on the same RTL and
emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side LUT/FF
table. Yosys is mandatory; Vivado and Quartus are detected automatically
and skipped with a notice when not on `$PATH`.

## Variants

| Variant                                  | Use case                                                                      |
|------------------------------------------|-------------------------------------------------------------------------------|
| `rtl/wb_top.sv`                          | Master + slave wired point-to-point; drop-in self-test integration            |
| `rtl/wb_master.sv`                       | Stand-alone Wishbone B4 master, classic + pipelined                           |
| `rtl/wb_slave.sv`                        | Stand-alone Wishbone B4 slave with NUM_REGS x DATA_WIDTH regfile              |
| `vhdl_wrapper/wb_top_vhdl.vhd`           | VHDL-2008 entity wrapping the SV core for VHDL-only designs                   |

## License

Dual-licensed: GPL-3.0-or-later for open-source projects, commercial
license for closed-source products. See [`LICENSE.md`](LICENSE.md).

## Citation

```bibtex
@misc{wishbone-fpga-core,
  title  = {{wishbone-fpga-core}: a parameterizable Wishbone B4 master + slave IP core in SystemVerilog with classic and pipelined modes},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/wishbone-fpga-core}}
}
```

## References

- *Wishbone B4 Specification, Revision B.4*, OpenCores / Silicore Corp.,
  2010. <https://opencores.org/howto/wishbone>
- LiteX SoC builder, *Wishbone bus reference and integration guide*.
- OpenROAD / Caravel SoC, *Caravel user-project Wishbone interface*.

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
