# Deadline- and Uncertainty-Aware RTL Scheduler for Selective Reinspection

A synthesizable hardware scheduler (Verilog, Zybo Z7-10; synthesis timing
closed at 40 MHz) that arbitrates
AI-vision **reinspection requests** across 4 input streams. Each request carries a
32-bit deadline and an 8-bit uncertainty score; the scheduler decides *which
borderline part gets a second inspection pass first* when the reinspection engine
is the bottleneck.

Motivated by production experience with machine-vision inspection lines, where
borderline classifications (potential false rejects) compete for limited
reinspection capacity under hard takt-time deadlines.

## Results

**Functional correctness** — **3 workloads x 4 policies = 12 configurations**
PASS against a cycle-stepped Python golden model on Vivado 2022.2 xsim and
Icarus Verilog. The PASS criterion is exact transaction order plus equality of
all checked counters; beyond the criterion, dispatch cycles also matched
exactly (cycle diff 0) in all 12 runs. A conservation invariant
(`pushed == dispatched + expired`) holds in every run.

**Policy comparison.** Conditions: seed 7, 300 requests, LATENCY = 200
cycles, HYB W_D:W_U = 3:1, xsim 2022.2, compare tolerance 3 (achieved: cycle
diff 0).

| Load | Policy | Dispatched | Expired | Deadline miss | FR recovered |
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

`FR recovered` is an offline metric computed from synthetic ground-truth
labels in the trace CSV; the labels are not part of the 80-bit record and are
never visible to the RTL.

Headline: under light load the policy barely matters; under overload,
uncertainty-aware selection both misses fewer deadlines *and* recovers more
false rejects than deadline-only EDF.

## Analysis

**Why EDF misses the most deadlines under overload.** This is not a defect of
EDF itself but of a selection rule that ignores the known, fixed processing
time: with `remaining slack < LATENCY` a request is already infeasible, yet
minimum-slack selection prefers exactly those requests, wasting engine
capacity (58 dispatches x 200 cycles). The system assumes a fixed second-pass
latency, so infeasibility is decidable with a single comparator.

**Feasibility-gate experiment (golden model only).** Dropping requests with
`slack < LATENCY` at the queue head drives deadline misses to **0 for every
policy** and lifts EDF's useful throughput from 138 to 195 under overload —
but it also collapses the differences between policies. The gate is standard
admission control, so it is kept as an analysis finding rather than a design
contribution; the policy comparison above is deliberately run *without* the
gate, where the "which request first" question is non-trivial. (Reproduce
with `golden.py --gate`.)

**Why Hybrid never wins at any weight.** A weight sweep (W_D:W_U from 8:1 to
1:8, `sw/sweep_weights.sh`) shows Hybrid converging to UNC as W_U grows and
never beating it:

1. Without feasibility filtering, deadline urgency under overload prioritizes
   already-infeasible requests, so any W_D > 0 hurts (8:1 raises overload
   miss to 43; the optimal weight degenerates to W_D = 0).
2. Hybrid quantizes deadline slack to an 8-bit urgency, losing EDF's
   full-resolution deadline ordering precisely where slack is large
   (normal load: EDF miss 3 vs Hybrid 7 even at 8:1).
3. In the synthetic workload, false-reject probability is tied to uncertainty
   only and is independent of deadlines, so deadline information carries no
   additional predictive value for FR recovery.

Hybrid becomes meaningful only with (a) a feasibility gate and (b) workloads
where uncertainty and deadline pressure are correlated — left as future work.

## Scope

* **Simulation-verified**: scheduler_top and everything under it — 12
  configurations (3 loads x 4 policies) PASS against the golden model
  (criterion: transaction order + checked counters; observed cycle diff 0),
  with SVA A1-A5 active under xsim and the A6 conservation check in the TB.
* **Synthesis-only**: timing and utilization figures below are Vivado
  synthesis estimates on xc7z010clg400-1; no place-and-route or board run.
* **Not verified**: axil_regs.v (AXI4-Lite CSR wrapper) is provided for
  optional board bring-up and is outside the verified simulation top.

## Architecture

![Block diagram](docs/architecture.png)

* Record: 80 bits = `{req_id[8], uncertainty[8], deadline[32], arrival[32]}`
* Policies (2-bit mode): `00` FIFO · `01` EDF · `10` UNC · `11` HYB
  (`score = W_D*urgency8 + W_U*u`, runtime-programmable weights)
* Head-only expiration, non-preemptive engine, per-stream FWFT FIFOs
* `axil_regs.v` (AXI4-Lite CSR) is included for optional board bring-up but is
  not part of the verified simulation top

## Repository layout

```
rtl/          synthesizable Verilog (top: scheduler_top)
tb/           tb_top.sv (self-checking TB + CSV logging), sva_bind.sv (A1-A5, xsim)
sw/           gen_trace.py · golden.py · compare.py · run_regress.sh · sweep_weights.sh
constraints/  timing.xdc (25 ns clock)
docs/         architecture.png
```

Traces and simulation outputs are generated deterministically by the scripts
in `sw/` and are not committed.

## Synthesis results (xc7z010clg400-1, Vivado 2022.2)

* **Utilization**: 2,532 LUTs (14.4%), 753 FFs (2.1%), **0 BRAM, 0 DSP** — the
  hybrid's 8-bit multiplies map to plain LUT logic, and the per-stream FIFOs
  infer distributed RAM. (Figures from the pre-pipeline synthesis; the counter
  pipeline below adds 101 snapshot flip-flops.)
* **Timing closure at 40 MHz** (25 ns period, WNS +0.694 ns with synthesis
  strategy Flow_PerfOptimized_high; ~41.1 MHz implied Fmax at synthesis
  estimates. Default strategy closes at 37 MHz / 27 ns, WNS +1.137 ns). The 100 MHz initial target was not met, and the
  gap decomposes into two findings:
  1. The first critical path (WNS −18.1 ns, 58 logic levels) ended at the
     64-bit `sum_latency` statistics accumulator — measurement logic riding
     combinationally on the decision chain. Snapshotting the grant-time
     operands and accumulating one cycle later removed it **without changing
     any counter value or the dispatch log** (re-verified: 12/12
     configurations still match the golden model exactly).
  2. The remaining path (25.7 ns, 43 levels) is the single-cycle decision loop
     itself: FIFO head → expire/policy/tournament → grant → pop pointer. It
     updates architectural state, so it cannot be deferred by snapshotting;
     closing 100 MHz would require pipelining the grant decision, which
     changes scheduling semantics (decisions made on one-cycle-old state) and
     is left as future work.
* **Context**: the engine occupies 200 cycles per request, so one scheduling
  decision per cycle at 40 MHz exceeds the application's actual decision-rate
  requirement by two orders of magnitude.

## Verification methodology

* **Transaction-level, not cycle-accurate, as the pass criterion**: the golden
  model mirrors RTL register stages (push visibility +2, post-pop head +1,
  engine occupancy LATENCY+1), so cycles currently match exactly — but PASS is
  defined on dispatch *order* + counters so the reference survives RTL
  pipeline changes.
* SVA A1–A5 bound to `scheduler_top`: grant is one-hot (A1), a granted head
  is valid (A2), no grant while the engine is busy (A3), no grant of an
  expired head (A4), expire and grant never hit the same head in one cycle
  (A5). A6 (conservation) is checked at end of sim in the TB.
* Corner cases: empty trace, all-expired-on-arrival, 4-stream simultaneous
  arrival (rotating tie-break observed as 0→1→2→3), expiration of entries
  hidden behind a live head (head-only semantics).

## Status / roadmap

- [x] 12-configuration golden-vs-RTL match (this repo)
- [x] Multi-seed regression: 6 seeds x 3 loads x 4 policies (72 runs) + corner cases, all matching; xsim runs additionally monitored by SVA A1-A5
- [x] Synthesis & timing closure (40 MHz; see Synthesis results)
- [ ] N_STREAM 2/4/8 scaling table
- [ ] Correlated-workload experiment where Hybrid's weights matter

## License

MIT — see [LICENSE](LICENSE).
