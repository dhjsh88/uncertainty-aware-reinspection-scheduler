# uncertainty-aware-reinspection-scheduler
# Deadline- and Uncertainty-Aware RTL Scheduler for Selective Reinspection

A synthesizable hardware scheduler (Verilog, Zybo Z7-10 / 100 MHz) that arbitrates
AI-vision **reinspection requests** across 4 input streams. Each request carries a
32-bit deadline and an 8-bit uncertainty score; the scheduler decides *which
borderline part gets a second inspection pass first* when the reinspection engine
is the bottleneck.

Motivated by production experience with machine-vision inspection lines, where
borderline classifications (potential false rejects) compete for limited
reinspection capacity under hard takt-time deadlines.

## Key results

**Functional correctness** — RTL matches a cycle-stepped Python golden model
**exactly** (transaction order, all performance counters, and even dispatch
cycles) across **3 workloads x 4 policies = 12 configurations**, verified on
Vivado 2022.2 xsim and Icarus Verilog. A conservation invariant
(`pushed == dispatched + expired`) holds in every run.

**Policy comparison** (seed 7, 300 requests, engine latency = 200 cycles,
Hybrid weights W_D:W_U = 3:1):

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

Headline: under light load the policy barely matters; under overload,
uncertainty-aware selection both misses fewer deadlines *and* recovers more
false rejects than deadline-only EDF.

## Analysis (what the numbers taught us)

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
gate, where the "which request first" question is non-trivial.

**Why Hybrid never wins at any weight.** A weight sweep (W_D:W_U from 8:1 to
1:8) shows Hybrid converging to UNC as W_U grows and never beating it:

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

## Architecture

```
trace_player ──► req_fifo x4 (FWFT) ──► expire_unit ──► policy_core ──► dispatch_arbiter
                                             │               │                │
                                             └── slack ──────┘         grant (1-hot, rotating tie-break)
                                                                              ▼
                            perf_counters ◄── engine_model (fixed LATENCY, non-preemptive)
```

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
sw/           gen_trace.py · golden.py · compare.py · run_regress.sh
constraints/  timing.xdc (100 MHz clock)
```

## Reproducing the results

Traces are generated deterministically — no data files are committed.

```bash
# 1) generate a workload (csv for golden, mem for RTL, meta for N_ENTRY)
python3 sw/gen_trace.py --mode overload --n 300 --seed 7 --out-prefix traces/ov_s7

# 2) golden reference
python3 sw/golden.py traces/ov_s7.csv --mode hyb --wd 3 --wu 1 \
    --out-dispatch disp_gold.csv --out-counters cnt_gold.csv

# 3) RTL sim (Icarus) — or Vivado xsim, see notes below
iverilog -g2012 -I rtl -o sim/tb.vvp \
  -DTRACE_FILE=\"traces/ov_s7.mem\" -DN_ENTRY=300 -DMODE_SEL="2'd3" \
  -DW_D="8'd3" -DW_U="8'd1" \
  -DLOG_FILE=\"disp_rtl.csv\" -DCNT_FILE=\"cnt_rtl.csv\" \
  rtl/cycle_counter.v rtl/req_fifo.v rtl/expire_unit.v rtl/policy_core.v \
  rtl/dispatch_arbiter.v rtl/engine_model.v rtl/perf_counters.v \
  rtl/trace_player.v rtl/scheduler_top.v tb/tb_top.sv
vvp sim/tb.vvp

# 4) transaction-level comparison (order + counters; cycle tolerance 3)
python3 sw/compare.py disp_gold.csv disp_rtl.csv \
    --gold-counters cnt_gold.csv --rtl-counters cnt_rtl.csv

# full regression: seeds x {normal,bursty,overload} x 4 policies
bash sw/run_regress.sh 20 300
```

### Vivado xsim notes (hard-won)

* Pass configuration by editing the `define block at the top of `tb/tb_top.sv`
  rather than via `xvlog -d` — quotes and `2'd3`-style literals do not survive
  the command line intact.
* `TRACE_FILE` must point to the **`.mem`** file (the `.csv` is for the golden
  model only).
* Use absolute paths with forward slashes for `TRACE_FILE` / `LOG_FILE` /
  `CNT_FILE`; otherwise outputs land in the xsim run directory and a stale
  empty CSV from a failed run is easy to compare against by mistake.
* `sva_bind.sv` (concurrent assertions A1-A5) compiles under xsim; Icarus does
  not support it, so the Icarus flow relies on the TB's A6 conservation check.

## Synthesis results (xc7z010clg400-1, Vivado 2022.2)

* **Utilization**: 2,532 LUTs (14.4%), 753 FFs (2.1%), **0 BRAM, 0 DSP** — the
  hybrid's 8-bit multiplies map to plain LUT logic, and the per-stream FIFOs
  infer distributed RAM. (Figures from the pre-pipeline synthesis; the counter
  pipeline below adds 101 snapshot flip-flops.)
* **Timing closure at 37 MHz** (27 ns period, WNS +1.137 ns; ~38.7 MHz implied
  Fmax at synthesis estimates). The 100 MHz initial target was not met, and the
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
  decision per cycle at 37 MHz exceeds the application's actual decision-rate
  requirement by two orders of magnitude.

## Verification methodology

* **Transaction-level, not cycle-accurate, as the pass criterion**: the golden
  model mirrors RTL register stages (push visibility +2, post-pop head +1,
  engine occupancy LATENCY+1), so cycles currently match exactly — but PASS is
  defined on dispatch *order* + counters so the reference survives RTL
  pipeline changes.
* SVA A1–A5 (grant one-hot, no grant while busy, no expired grant, FIFO
  overflow/underflow) bound to `scheduler_top`; A6 conservation checked at end
  of sim.
* Corner cases: empty trace, all-expired-on-arrival, 4-stream simultaneous
  arrival (rotating tie-break observed as 0→1→2→3), expiration of entries
  hidden behind a live head (head-only semantics).

## Status / roadmap

- [x] 12-configuration golden-vs-RTL match (this repo)
- [x] Multi-seed regression: 6 seeds x 3 loads x 4 policies (72 runs) + corner cases, all matching; xsim runs additionally monitored by SVA A1-A5
- [x] Synthesis & timing closure (37 MHz; see Synthesis results)
- [ ] N_STREAM 2/4/8 scaling table
- [ ] Correlated-workload experiment where Hybrid's weights matter

## License

MIT — see [LICENSE](LICENSE).
