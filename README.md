# RTL Scheduler for a Shared Reinspection Engine

This repository documents my implementation of a synthesizable Verilog scheduler for a modeled AI inspection system. Four request streams share one fixed-latency reinspection engine. Each request includes a deadline and an uncertainty score. The scheduler supports first-in, first-out (FIFO), earliest-deadline-first (EDF), uncertainty-based (UNC), and weighted hybrid (HYB) dispatch.

## Project Contributions


| Contribution | Location |
|---|---|
| Four-policy priority logic and tournament arbitration with rotating tie-breaking | `rtl/policy_core.v`, `rtl/dispatch_arbiter.v` |
| Per-stream FWFT request queues and head-only expiration checks | `rtl/req_fifo.v`, `rtl/expire_unit.v` |
| Scheduler integration, trace playback, and a fixed-latency engine model | `rtl/scheduler_top.v`, `rtl/trace_player.v`, `rtl/engine_model.v` |
| Registered dispatch, deadline-miss, latency, and per-stream counters | `rtl/perf_counters.v`, `rtl/cycle_counter.v` |
| SystemVerilog logging, an end-of-run conservation check, and bound assertions | `tb/tb_top.sv`, `tb/sva_bind.sv` |
| Cycle-stepped Python reference model and automated RTL comparison | `sw/golden.py`, `sw/compare.py` |
| Seeded workload generation and Icarus-based multi-seed regression | `sw/gen_trace.py`, `sw/run_regress.sh` |

## Architecture and Policy Modes

![Block diagram](docs/architecture.png)

Each stream uses a first-word fall-through (FWFT) FIFO with a registered head slot. The four visible FIFO heads feed the expiration and policy logic. Requests behind those heads do not participate in arbitration.

The internal request record is 80 bits: `{req_id[7:0], uncertainty[7:0], deadline[31:0], arrival[31:0]}`.

For each visible head, the scheduler computes `slack = deadline - now`. A head expires after its deadline has passed and is removed from the queue. An expiring head is excluded from arbitration. When the engine is idle, the arbiter grants one of the remaining candidates.

| Mode | Policy | Selection rule |
|---|---|---|
| `00` | FIFO | Oldest arrival time |
| `01` | EDF | Smallest remaining slack |
| `10` | UNC | Highest uncertainty |
| `11` | HYB | Highest weighted urgency and uncertainty score |

All four policies map their selection rule to a common larger-is-higher priority. A pairwise tournament tree selects the winning FIFO head. Equal priorities use a rotating tie-break, which advances past the previous winner.

For HYB, the scheduler saturates the remaining slack to 16 bits and converts it to an 8-bit urgency value. It then computes a 17-bit score: `W_D × urgency8 + W_U × uncertainty`. `W_D` and `W_U` are 8-bit runtime inputs.

### Trace-Driven Evaluation Top

`scheduler_top.v` is a self-contained evaluation top. `trace_player.v` reads synthetic requests and routes each one to its stream FIFO. The trace entry is 88 bits because it includes an 8-bit stream field in addition to the 80-bit request record.

The trace player injects at most one request per cycle. Requests with the same arrival timestamp are therefore serialized. `engine_model.v` provides a fixed-latency grant, busy, and done interface. It is a non-preemptive stub and does not implement the reinspection computation itself.

## Verification

### Reference Model and Comparison

`sw/golden.py` is a cycle-stepped Python reference model. It follows the same four policy rules as the RTL. It also models the timing needed to compare the two implementations:

- a request pushed into an empty queue becomes visible after two cycles
- the next head becomes visible one cycle after a pop
- the minimum grant-to-grant interval is `LATENCY + 1` cycles
- a visible head expires when `now > deadline`
- a dispatched request misses its deadline when `now + LATENCY > deadline`

`sw/compare.py` compares the RTL output with the reference model. A PASS requires the same number and ordered sequence of `(stream, req_id)` dispatches. It also requires exact agreement for the following counters:

- pushed, dispatched, expired, and deadline misses
- completed requests and busy cycles
- per-stream dispatch totals

`sum_latency` may differ by at most `tolerance × dispatched`. The default tolerance is three cycles. Dispatch-time differences are reported separately and do not determine PASS. A PASS therefore means that dispatch order and the checked counters agree. It does not require cycle-exact timestamps.

### Assertions and End-of-Run Check

`tb/sva_bind.sv` binds five assertion categories to `scheduler_top`:

- A1: a nonzero grant is one-hot
- A2: a granted FIFO head is valid
- A3: no grant occurs while the engine is busy
- A4: an expired head is not granted
- A5: grant and expiration do not target the same stream in one cycle

At the end of simulation, `tb/tb_top.sv` performs an additional conservation check. It requires `pushed == dispatched + expired`, zero residual FIFO occupancy, and an idle system.

### Simulation Runs

I ran 12 baseline configurations in Vivado 2022.2 xsim. These runs covered three synthetic workloads and four scheduling policies. The bound assertions and the RTL-to-reference comparison passed in all 12 configurations.

I also ran a six-seed regression with `sw/run_regress.sh`. It covered 6 seeds, 3 workloads, and 4 policies, for a total of 72 Icarus Verilog configurations. All 72 configurations matched the reference model in dispatch order and the counters checked by `sw/compare.py`. They also passed the end-of-run conservation check.

### Directed Cases

I also checked the following cases:

- an empty trace
- requests that were already expired when they reached a visible FIFO head
- serialized handling of four requests with the same arrival timestamp
- an expired entry hidden behind a valid FIFO head

## Policy Measurements

I compared the four policies on one deterministic trace for each load condition. Each trace contained 300 requests and used seed 7. The engine latency was 200 cycles. HYB used `W_D = 3` and `W_U = 1`.

| Workload | Policy | Dispatched | Deadline misses | On-time false-reject labels |
|---|---|---:|---:|---:|
| normal | FIFO | 295 | 8 | 22 |
| normal | EDF | 296 | 3 | 23 |
| normal | UNC | 296 | 8 | 23 |
| normal | HYB | 296 | 7 | 23 |
| bursty | FIFO | 93 | 17 | 9 |
| bursty | EDF | 95 | 25 | 6 |
| bursty | UNC | 92 | 19 | 11 |
| bursty | HYB | 93 | 22 | 11 |
| overload | FIFO | 196 | 30 | 14 |
| overload | EDF | 196 | 58 | 13 |
| overload | UNC | 195 | 27 | 17 |
| overload | HYB | 195 | 32 | 16 |

`Dispatched` and `Deadline misses` are RTL counters. A deadline miss is recorded when `now + LATENCY > deadline` at dispatch. The on-time false-reject count is calculated offline from labels in the trace CSV. 

The best policy depended on the workload. EDF produced the fewest deadline misses under normal load, FIFO under bursty load, and UNC under overload. In the overload trace, UNC recorded 27 misses, compared with 58 for EDF. The offline count of on-time false-reject labels was 17 for UNC and 13 for EDF.

## Limitations and Possible Extensions

These measurements use one generated trace for each load condition. They do not establish a general ranking of the policies. The multi-seed runs in the Verification section test RTL-to-reference agreement rather than policy performance across seeds.

The workload generator makes uncertainty scores and false-reject probabilities depend on the same synthetic group assignment. It generates deadlines separately. This construction favors uncertainty as a signal for the offline false-reject metric. 

The current RTL can dispatch a request when `slack < LATENCY`. Such a request cannot finish before its deadline. A feasibility check before arbitration is one possible extension.

The table evaluates only the 3:1 HYB setting. It does not identify an optimal weighting. A broader study could aggregate policy metrics across seeds and use workloads based on measured relationships among uncertainty, deadlines, and outcomes.

## Repository Layout

```
rtl/          synthesizable Verilog (top: scheduler_top)
tb/           tb_top.sv (self-checking TB + CSV logging), sva_bind.sv (A1-A5, xsim)
sw/           gen_trace.py · golden.py · compare.py · run_regress.sh 
constraints/  timing.xdc (25 ns clock)
docs/         architecture.png
```

Trace files and simulation outputs are generated deterministically by the
scripts in `sw/` and are not committed.

## Synthesis and Timing

The trace-driven evaluation top was synthesized in Vivado 2022.2 for the `xc7z010clg400-1`. The run used `scheduler_top` with `FIFO_DEPTH = 64`, `LATENCY = 200`, and `TDEPTH = 16384`. The trace memory was initialized with 300 requests.

### Post-Synthesis Utilization

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| Slice LUTs | 2,668 | 17,600 | 15.16% |
| LUT as logic | 2,436 | 17,600 | 13.84% |
| LUT as distributed RAM | 232 | 6,000 | 3.87% |
| Flip-flops | 846 | 35,200 | 2.40% |
| BRAM tiles | 0 | 60 | 0% |
| DSP blocks | 0 | 80 | 0% |

The four request FIFOs account for all 232 distributed-memory LUTs. The trace player, engine model, cycle counter, and performance counters are also included in these results. The figures therefore describe the complete trace-driven evaluation top rather than the reusable scheduling logic alone.

`scheduler_top` exposes 471 signal bits as top-level I/O because its control and performance-counter signals are connected directly to module ports. This exceeds the device’s 100 available I/O pins. The module is an evaluation top, not a pin-level board top. A deployable wrapper would expose these signals through an internal bus or memory-mapped interface.

### Performance-Counter Path

An earlier version placed the 64-bit `sum_latency` accumulator on the scheduling-decision path. I registered the grant vector, deadline, arrival time, and current cycle. The counter comparison and accumulation then ran one cycle later.

After this change, I reran the verification flow. The dispatch order and checked final counters remained unchanged.

### Post-Synthesis Timing

The XDC file applies a 25 ns clock constraint to `i_clk`. The current post-synthesis timing estimate reported a WNS of +0.694 ns and a TNS of 0 ns. None of the 3,303 setup endpoints failed the constraint, and the report contained no unconstrained paths.

The worst setup path had a data-path delay of 23.924 ns and 41 logic levels. It started at a visible FIFO-head register and ended at another FIFO’s head-register enable:

```text
FIFO head → slack and policy logic → tournament → grant → FIFO update
```

## License

MIT. See [LICENSE](LICENSE).
