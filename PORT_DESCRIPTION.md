# Port description

Detailed handshake protocol and timing for the Wishbone B4 master + slave
pair (`wb_top`, `wb_master`, `wb_slave`). The timing and protocol
behaviour below is intended; Wishbone B4 compliance is not verified.

## Reset

`rst_i` is **synchronous active-high** (Wishbone B4 §3.1.3). Hold it
high for at least 4 clock cycles before the first transaction. After
de-assertion the master is idle (`req_ready_o` = 1) and the slave
holds `ACK = ERR = RTY = STALL = 0`.

```
clk_i    __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
rst_i    ‾‾‾‾‾‾‾|_______________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾
req_ready          X X X X X X X X X X X X X 1 1 1 1 1 1
```

## Classic standard cycle (PIPELINED = 0)

Per Wishbone B4 §3.2.1, the master holds STB until the slave answers
ACK/ERR/RTY. The slave latency is 1 cycle (sampled on the cycle the
master raises STB; ACK on the next).

```
clk_i    |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
CYC      |‾‾‾‾‾‾‾|___________________
STB      |‾‾‾‾‾‾‾|___________________
ADR      |a       |__________________
DAT_M2S  |d       |__________________
WE       |w       |__________________
SEL      |s       |__________________
ACK      _____|‾‾|___________________
DAT_S2M  _____|r |___________________
```

## B4 pipelined cycle (PIPELINED = 1)

STB pulses one cycle per accepted beat. The slave drives STALL when it
cannot accept a beat this cycle. ACK trails the accepted beat by 1
cycle (in the shipped 1-deep pipeline; deeper pipelines push ACK out
further).

```
clk_i    |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
CYC      |‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|__________
STB      |‾‾|‾‾|‾‾|________|__________
STALL    _________________|__________
ACK      _____|‾‾|‾‾|‾‾|____________
```

* CYC stays high until the burst completes (SVA `p_cyc_stable_in_burst`).
* STB pulses for each beat the master wants to launch.
* STALL is the slave's "not ready" signal; the master must hold STB
  high (or re-pulse) on the next cycle if it still has a beat queued.
* ACK trails the accepted beat by the slave's internal latency.

## Bursts via CTI / BTE

Per Wishbone B4 §3.2.3:

| `CTI[2:0]` | Encoding   | Use                                              |
|------------|------------|--------------------------------------------------|
| `3'b000`   | classic    | single-beat transfer (no burst)                  |
| `3'b001`   | const-addr | constant-address burst (FIFO style; addr stays)  |
| `3'b010`   | incr       | incrementing burst (addr += DATA_WIDTH/8 / beat) |
| `3'b111`   | end-burst  | final beat marker                                |

| `BTE[1:0]` | Burst type     |
|------------|----------------|
| `2'b00`    | linear         |
| `2'b01`    | 4-beat wrap    |
| `2'b10`    | 8-beat wrap    |
| `2'b11`    | 16-beat wrap   |

The shipped master emits `CTI = INCR (3'b010)` for all but the last
beat of a multi-beat burst, and `CTI = END (3'b111)` on the last beat.
For single beats it emits `CTI = CLASSIC (3'b000)`. `BTE` defaults to
linear.

## Response codes

| Termination | Encoded as     | When emitted                                              |
|-------------|----------------|-----------------------------------------------------------|
| `ACK`       | `wb_ack_o = 1` | normal completion                                         |
| `ERR`       | `wb_err_o = 1` | address out-of-range OR mis-aligned                       |
| `RTY`       | `wb_rty_o = 1` | integrator-driven via `rty_hint_i` (e.g. busy / arb-loss) |

Mutually exclusive (B4 §3.1.4): at most one is high in any cycle.

## LOCK semantics

`wb_lock_o` is qualified by `wb_cyc_o`. While both are high, the slave
exposes `lock_active_o = 1` so a downstream arbiter or refresh path
knows not to grab the slave for unrelated traffic. `LOCK` does NOT
imply that the master holds the bus across multiple disjoint cycles —
B4 atomicity is across one CYC window only.

## User request / response interface

| Signal               | Dir | Width                     | Description                                                          |
|----------------------|-----|---------------------------|----------------------------------------------------------------------|
| `req_valid_i`        | in  | 1                         | Pulse high to enqueue a transaction. Captured on the clock edge.     |
| `req_we_i`           | in  | 1                         | 1 = write, 0 = read.                                                 |
| `req_addr_i`         | in  | ADDR_WIDTH                | Byte address (DATA_WIDTH/8 aligned for in-range vectors).            |
| `req_data_i`         | in  | DATA_WIDTH                | Write payload, replicated across burst beats.                        |
| `req_sel_i`          | in  | DATA_WIDTH/8              | Per-byte enable; forwarded to `wb_sel_o`.                            |
| `req_burst_i`        | in  | log2(MAX_BURST+1)         | Beats in this burst (1 = single, up to MAX_BURST).                   |
| `req_lock_i`         | in  | 1                         | Drive high to assert `wb_lock_o` for the burst.                      |
| `req_ready_o`        | out | 1                         | High when the master is idle and can accept a fresh request.         |
| `rsp_valid_o`        | out | 1                         | One-cycle pulse on each completed beat.                              |
| `rsp_data_o`         | out | DATA_WIDTH                | Read data for the completed beat.                                    |
| `rsp_resp_o`         | out | 2                         | 00 = ACK, 01 = ERR, 10 = RTY.                                        |
| `rsp_last_o`         | out | 1                         | One-cycle pulse on the last beat of the burst.                       |

## Slave-side hooks

| Signal               | Dir | Description                                                                |
|----------------------|-----|----------------------------------------------------------------------------|
| `rty_hint_i`         | in  | Hint to the slave to answer `RTY` on the next response                     |
| `lock_active_o`      | out | Slave-side mirror of `wb_lock_i && wb_cyc_i` for downstream arbiters       |
| `reg_storage_o`      | out | Packed array of every register value; user logic reads what software wrote |
| `wr_event_o`         | out | One-cycle pulse on a successful write (in-range, ACK)                      |
| `wr_event_addr_o`    | out | Address of the registered write event                                      |
| `rd_event_o`         | out | One-cycle pulse on a successful read accept                                |
| `rd_event_addr_o`    | out | Address of the registered read event                                       |

## Latency summary

Intended latencies from the RTL design; not verified in simulation or hardware.

| Phase                                    | Cycles                |
|------------------------------------------|-----------------------|
| Single-beat: STB accept -> ACK            | 1                     |
| Burst beat -> ACK trail (pipelined)       | 1 (1-deep pipeline)   |
| Reset assert -> ready to accept           | 1 (after rst_i low)   |
| Back-to-back burst beats                  | 0 (when no STALL)     |
| Master `S_GAP` recovery between bursts    | 1                     |

The slave is purely combinational on the response side (no skid except
the one-deep beat capture). The master FSM has 5 states and is purely
synchronous; the response interface presents one beat per cycle when
back-to-back ACKs arrive.
