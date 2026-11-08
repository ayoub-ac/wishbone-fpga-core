# Resource estimates

> **Unverified estimates.** The figures in this file have not been confirmed by a recorded, reproducible synthesis run or by hardware measurement. Treat every LUT, FF, BRAM, DSP, Fmax, throughput, latency and power figure here as an unverified estimate. Run `make synth_report` with your own toolchain to get real numbers.

Numbers below are unverified estimates intended to reflect Yosys generic
synthesis (`make synth_report`), pre-place-and-route. See `SYNTH_REPORT.md` for the most recent
run; this document explains what dominates the area and how to shrink
it.

## Summary (post-Yosys, pre-PnR)

The shipped `wb_top` instances both the master and the slave wired
point-to-point, so the figures cover the COMBINED footprint. In real
integrations the master and slave are usually deployed separately.

| Target                         | Comment |
|--------------------------------|---------|
| Lattice iCE40 UP5K             | The FSM and the address comparator are tiny; the dominant LUT cost is the slave's read mux across NUM_REGS plus the master's burst counter. Fits trivially on the UP5K (5280 logic tiles). |
| Lattice ECP5 LFE5UM-25         | Same shape; `synth_ecp5 -abc9` packs the SEL-byte write logic into LUT4 networks efficiently. |
| Xilinx Artix-7 XC7A35T         | Yosys-generic synthesis here counts LUT6 + CARRY4. Vivado synth_design will fold the regfile mux into LUTRAM if the integrator opts in. |
| Cyclone V 5CSEMA5F31C6         | ALMs for the regfile + handshake; tiny. |
| Gowin GW1NR-9 (Tang Nano 9K)   | Not characterised here. Comparable to ECP5 with vendor flow. |

For exact LUT/FF/BRAM numbers run `make synth_report` and read
`SYNTH_REPORT.md`.

## What dominates the area

For the example top (`NUM_REGS = 16`, `DATA_WIDTH = 32`, master + slave
pair):

* **Slave register file storage**: 16 x 32 = 512 FFs.
* **Slave read mux**: a 16-to-1 32-bit-wide mux. Yosys generic synth maps
  this to ~32 LUT6 cells on Artix-7, ~96 LUT4 on iCE40.
* **Slave SEL-byte write logic**: per byte, a 2-input mux selecting old
  vs new. 4 bytes x 32 bits = 128 LUT-equivalent cells, fully fused
  into the regfile update path.
* **Slave decode / response FSM**: ~100 FFs (beat capture, response
  pulse generation, address/data/sel hold registers).
* **Master FSM**: ~100 FFs (state register, addr/data/wdata hold, burst
  counters, ack counter, retry counter, response buffer).
* **Master burst pipeline**: address auto-increment is a single adder
  in `BYTES` increments. ~5 LUTs.

Total (unverified estimate): roughly 800-1500 LUT and 700-1500 FF on
iCE40 / ECP5 / Artix-7 generic synth. With vendor-flow LUTRAM packing the LUT count drops.

## What you can do to shrink it

* **Use BRAM-mapped storage** for very-wide register banks (NUM_REGS
  > 256). The shipped regfile is intentionally flat-FF for fast,
  visible storage, which is the right choice up to ~64 registers.
* **Drop bursts** if your target traffic is single-beat only. Setting
  `MAX_BURST = 1` collapses the master's burst counter into a single
  flip-flop and the synthesizer prunes the auto-increment adder.
* **Use classic mode** (`PIPELINED = 0`) to drop the STALL plumbing
  on both sides. The LUT saving has not been measured.
* **Reduce DATA_WIDTH**. A 16-bit pair takes half the storage and
  half the read-mux width. Most RV32 SoC peripherals use 32-bit;
  embedded controllers sometimes use 16.

## What you can do to push throughput

The pair is intended to sustain up to one transaction per cycle in
each direction (unverified estimate). At 100 MHz with 32-bit data that
would be 400 MB/s read and 400 MB/s write; not measured.

For high-bandwidth data movement do NOT use the regfile slave shipped
here. Wrap the master alone with a streaming source that feeds
`req_data_i` from a FIFO; on the slave side, replace the regfile
storage with a BRAM-mapped buffer.

## Frequency

All figures below are unverified estimates; no timing run backs them.

* iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints:
  ~70-90 MHz typical (limited by the regfile read mux depth and the
  master's burst-counter critical path).
* ECP5: ~120-180 MHz on generic synth.
* Artix-7 -1 speed grade: ~200+ MHz typical with Yosys; easily 250+
  MHz with Vivado.
* Cyclone V: similar to Artix-7 with vendor flow.

## Power

Unverified estimate: 3-6 mW dynamic on iCE40 UP5K at 50 MHz with continuous
traffic. The regfile only toggles during a write; reads are
combinational. Static power is dominated by the FPGA itself.

## How to reproduce

```bash
make synth_report
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and
`synth_xilinx`, then `stat`, and writes the result to
`SYNTH_REPORT.md`. Vendor flows (Vivado, Quartus) are detected
automatically when on PATH.

For end-to-end place-and-route numbers (post-PnR LUT counts and
timing), run the vendor flow:
- iCE40 / ECP5: `nextpnr-ice40` / `nextpnr-ecp5` with Yosys output.
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
- Quartus: project with `rtl/` added.
