# Security model

This document describes what the Wishbone B4 master + slave pair is
designed to defend against, what it is NOT designed to defend against,
and how to evaluate the claims.

The cores are a control-and-status interconnect, not a cryptographic
primitive. The threat model is therefore very different from the AES /
SHA / GHASH sibling cores. Read this whole document before deploying
the slave in a security-sensitive system.

## What is protected

### 1. Address-decode discipline

Every transaction whose address falls past `NUM_REGS * (DATA_WIDTH/8)`
or is mis-aligned with the data-bus width is answered with `ERR` (B4
§3.1.4). The slave never silently accesses an undefined register, which
means software cannot probe beyond the published register map and get
an `ACK` response.

The decode predicate is bound by an SVA assertion
(`p_resp_after_stb`, `p_resp_only_when_cyc`); a regression that breaks
the pairing fails the gate.

### 2. Exclusive termination

`ACK`, `ERR`, and `RTY` are mutually exclusive (`p_resp_mutex`). A
transaction terminates with exactly one of the three, so software /
firmware cannot observe an ambiguous state. A slave that asserts more
than one termination signal at once is a B4 violation; the bound SVA
catches the regression.

### 3. LOCK-qualified atomic transactions

`LOCK` is qualified by `CYC` (`p_lock_implies_cyc`). The slave honours
the lock as an interlock against any internal user (e.g. a refresh
arbiter); the shipped slave has no other internal user, so `LOCK` is
exposed via `lock_active_o` for downstream arbiters to consume. An
attacker cannot break atomicity by toggling `LOCK` without `CYC` — that
combination is rejected at the protocol layer.

### 4. Constant-time on the bus

Every transaction takes the same number of cycles regardless of which
register is accessed. There is no early-exit, no data-dependent
latency, no per-register pipeline. Software cannot use timing to infer
the contents of a register it could not otherwise read.

### 5. Reset hygiene

`rst_i` is synchronous active-high (B4 §3.1.3) and clears every
register to its `REG_RESET` value. Held `STB`/`CYC` across the reset
boundary are masked — the master returns to `S_IDLE` and the slave
clears its in-flight beat tracker.

## What is NOT covered (be honest)

This list is exhaustive so purchasers can evaluate fit:

* **Side-channel attacks via bus timing.** Although per-register access
  is constant-time, a sophisticated attacker who can observe `ACK` /
  `ERR` latency at fine granularity could in principle distinguish
  hit from miss. Both responses take the same wall-clock number of
  cycles in the shipped slave, but the slave does not employ
  timing-balanced gates; in a power-leakage adversary model this
  distinction may still be observable.
* **Differential power analysis on the register file.** The shipped
  storage is a flat array of flip-flops; a power attacker measuring
  leakage at the FF-update boundary can mount standard DPA against
  values written to RW registers. Mitigation requires masked storage
  and is not in scope for the GPL tier.
* **Fault injection on the FSM** (CYC glitch, ACK forge): a flipped
  flop can corrupt the response or skip a write. No duplicated-FSM /
  parity-protected variant is shipped.
* **Authenticated bus access.** The slave does not authenticate the
  master. Any master that can reach the Wishbone ports can drive any
  read / write. Authenticated bus access is a system-level property;
  use a TrustZone-style filter or a SoC firewall in front of the slave
  if your threat model requires it.
* **Unauthorised access via clock-domain crossings.** All slave logic
  runs on `clk_i`; CDC handshakes between the bus clock and a slower /
  faster user-side clock are out of scope. Wire user-side signals
  through your own CDC primitives.
* **Replay / aliasing attacks on the bus.** No anti-replay sequence
  number is exposed. Replay protection is a system-level property.

## Compliance claims

* **Wishbone B4** conformance: the master and slave implement the
  protocol exactly as specified, including:
  - Independent CYC/STB handshakes (§3.1.3).
  - STALL-driven backpressure in pipelined mode (§3.2).
  - Mutually exclusive ACK/ERR/RTY termination (§3.1.4).
  - LOCK qualification by CYC (§3.2.4).
  - Aligned-address requirement.
  The shipped Verilator regression includes 8 SVA properties that
  bind these invariants on every cycle of every test, and a 1024-
  vector random regression cross-validated against a software shadow
  of the register file.
* **Wishbone B5** (newer revision): the cores implement B4 as
  specified; B5 adds clarifications but no breaking changes for the
  features used here. Cores work as B5-conformant slaves in our
  reading, but we do not formally claim B5 compliance.

## Test methodology used to validate the security claims

The Verilator testbench runs:

1. **Functional correctness on the published register map**: `make test`.
   Tests single + burst W/R, RTY, ERR, LOCK, mid-burst reset,
   back-to-back transactions, and 1024 random transactions
   cross-checked against a Python software shadow of the regfile.
2. **SVA-enforced protocol invariants on every cycle**: see
   `tb/wb_assertions.sv`. Properties include:
   - STB asserted implies CYC asserted.
   - ACK/ERR/RTY only meaningful while CYC=1.
   - ACK/ERR/RTY mutually exclusive.
   - CYC stable while a beat is outstanding.
   - LOCK qualified by CYC.
   - STALL only meaningful with CYC=1.
   - Bounded-latency response drainage (deadlock bound).
3. **Functional coverage**: 10 bins (read seen, write seen, burst
   seen, single seen, lock seen, classic mode, pipelined mode,
   resp ACK / ERR / RTY). Coverage report printed at end of `make test`.

We do NOT run experimental fault injection or side-channel campaigns.
The constant-time-on-the-bus claim is design intent, derived from the
structure of the slave.

## How to use the core safely

1. **Use a separate slave per security domain** if your system has
   multiple privilege levels. The shipped slave does not gate on a
   master ID; the system arbiter must filter.
2. **Use LOCK for true atomic RMW only**. Holding `LOCK` for long
   bursts can starve other masters in a shared-bus system; in a
   point-to-point system the constraint relaxes.
3. **Hold `rst_i` high for at least 4 cycles** after power-on and
   before the first transaction; this gives the FSMs time to settle
   and avoids spurious `STB` being mistaken for transactions.
4. **Don't use Wishbone for high-bandwidth data movement**. The cores
   answer one transaction at a time; for streaming or DMA, wrap them
   with a dedicated streaming core (not in scope here).

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with the B4
specification? Open an issue or contact the email in the README.
Coordinated disclosure welcome. We do not currently offer a bug bounty.
