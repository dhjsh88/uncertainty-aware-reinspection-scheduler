# RTL Scheduler for a Shared Reinspection Engine

This repository documents my implementation of a synthesizable Verilog scheduler for a modeled AI inspection system. Four request streams share one fixed-latency reinspection engine. Each request includes a deadline and an uncertainty score. The scheduler supports first-in, first-out (FIFO), earliest-deadline-first (EDF), uncertainty-based (UNC), and weighted hybrid (HYB) dispatch.

Project Contributions
---

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

## Results

The scheduler implements four policies:

* **FIFO** selects the oldest request
* **EDF** selects the request with the earliest deadline
* **UNC** selects the request with the highest uncertainty
* **HYB** combines deadline urgency and uncertainty using programmable weights

Test conditions: seed 7, 300 requests, `LATENCY` = 200 cycles, and
HYB `W_D:W_U` = 3:1.

| Load | Policy | Dispatched | Expired | Deadline misses | FR recovered |
|---|---|---|---|---|---|
| normal | FIFO | 295 | 5 | 8 | 22 |
| normal | EDF | 296 | 4 | **3** | 23 |
| normal | UNC | 296 | 4 | 8 | 23 |
| normal | HYB | 296 | 4 | 7 | 23 |
| bursty | FIFO | 93 | 207 | 17 | 9 |
| bursty | EDF | 95 | 205 | 25 | 6 |
| bursty | UNC | 92 | 208 | 19 | **11** |
| bursty | HYB | 93 | 207 | 22 | 11 |
| overload | FIFO | 196 | 104 | 30 | 14 |
| overload | EDF | 196 | 104 | 58 | 13 |
| overload | UNC | 195 | 105 | **27** | **17** |
| overload | HYB | 195 | 105 | 32 | 16 |

Policy choice has little effect under normal load. Under overload, the
uncertainty-aware policies produce fewer deadline misses and recover more
false rejects than EDF.

## Analysis

### EDF under overload

EDF does not account for the known, fixed processing latency. A request
cannot finish before its deadline when `remaining slack < LATENCY`. However,
EDF still favors such requests because they have the smallest remaining
slack. Under overload, 58 of the requests EDF dispatches miss their deadlines,
while each still occupies the engine for 200 cycles.

Because the second-pass latency is fixed, a single comparator can identify
these infeasible requests.

### Feasibility gate

A feasibility-gate experiment was performed in the golden model only. A
request is dropped at the queue head when `slack < LATENCY`. This reduces
deadline misses to 0 for every policy and raises EDF's on-time completions
(dispatched minus missed) from 138 to 195 under overload. However, it also removes most of the
performance differences between the policies.

The gate is a standard admission-control mechanism, so it is reported as an
analysis result rather than a design contribution. The main policy comparison
excludes the gate to preserve a meaningful scheduling problem.

### Hybrid weight sweep

A weight sweep from W_D:W_U = 8:1 to 1:8 was performed using
`sw/sweep_weights.sh`. As W_U increases, Hybrid converges toward UNC but does
not outperform it.

1. Without feasibility filtering, deadline urgency prioritizes requests that
   can no longer finish on time. Any nonzero W_D therefore degrades overload
   performance. At 8:1, deadline misses increase to 43. The best result
   occurs at W_D = 0, which makes Hybrid equivalent to UNC.
2. Hybrid quantizes deadline slack into an 8-bit urgency value. This loses
   EDF's full-resolution deadline ordering when slack is large. Under normal
   load, EDF produces 3 deadline misses, while Hybrid produces 7 even at 8:1.
3. In the synthetic workload, false-reject probability depends only on
   uncertainty and is independent of the deadline. Deadline information
   therefore provides no additional predictive value for FR recovery.

Hybrid should be reevaluated with a feasibility gate and workloads in which
uncertainty and deadline pressure are correlated. This is left as future
work.

## Repository layout

```
rtl/          synthesizable Verilog (top: scheduler_top)
tb/           tb_top.sv (self-checking TB + CSV logging), sva_bind.sv (A1-A5, xsim)
sw/           gen_trace.py · golden.py · compare.py · run_regress.sh · sweep_weights.sh
constraints/  timing.xdc (25 ns clock)
docs/         architecture.png
```

Trace files and simulation outputs are generated deterministically by the
scripts in `sw/` and are not committed.

## Synthesis results

Target: xc7z010clg400-1, Vivado 2022.2.

### Utilization

* 2,532 LUTs (14.4%)
* 753 flip-flops (2.1%)
* 0 BRAM, 0 DSP

The 8-bit Hybrid multipliers map to LUT logic, and the per-stream FIFOs are
inferred as distributed RAM. These figures are from the synthesis performed
before the performance-counter pipeline was added; the pipeline adds
approximately 100 snapshot registers.

### Timing

Timing closes at 40 MHz with a 25 ns clock period. Using the
`Flow_PerfOptimized_high` synthesis strategy, WNS is +0.694 ns. The synthesis
estimate implies an Fmax of approximately 41.1 MHz. With the default
synthesis strategy, timing closes at 37 MHz with a 27 ns period and WNS of
+1.137 ns.

The initial 100 MHz target was not met. Timing analysis identified two
critical paths.

**Performance-counter path.** The first critical path had WNS of -18.1 ns
and 58 logic levels. It ended at the 64-bit `sum_latency` accumulator because
the measurement logic was part of the combinational decision path.
Registering the grant-time operands and delaying the accumulation by one
cycle removed this bottleneck. This change did not affect any counter value
or the dispatch log. All 12 configurations were reverified and still match
the golden model exactly.

**Scheduling-decision path.** The remaining path is 25.7 ns long and
contains 43 logic levels:

```
FIFO head -> expire / policy / tournament -> grant -> pop pointer
```

Unlike the counter path, this one cannot be registered away: delaying the
grant delays the FIFO pop, so the next decision would be made on stale
state. Reaching 100 MHz would therefore require pipelining the grant
decision itself, which changes the scheduling semantics and is left as
future work.

**Application context.** The engine occupies 200 cycles per request. A
scheduler capable of making one decision per cycle at 40 MHz therefore
supports a decision rate more than two orders of magnitude above the
application's requirement.

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

The Icarus regression does not compile `tb/sva_bind.sv`. The concurrent assertions were exercised separately in the xsim runs. Generated simulation logs are not currently committed.

### Directed Cases

I also checked the following cases:

- an empty trace
- requests that were already expired when they reached a visible FIFO head
- one request for each stream with the same arrival timestamp
- an expired entry hidden behind a valid FIFO head

The trace player accepts at most one request per cycle. Requests with the same arrival timestamp were therefore injected serially rather than simultaneously.

## License

MIT. See [LICENSE](LICENSE).
