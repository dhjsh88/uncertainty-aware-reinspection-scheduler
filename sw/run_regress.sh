#!/usr/bin/env bash
#=============================================================================
# run_regress.sh — 랜덤 회귀: seed × 부하 × 정책 전 조합 RTL vs golden 비교
# 사용: bash sw/run_regress.sh <n_seeds> <n_requests>   (기본 20 seed, 300건)
# iverilog 기준. Vivado xsim 사용 시 컴파일 라인만 교체 (sva_bind.sv 추가).
#=============================================================================
set -u
NSEED=${1:-20}
NREQ=${2:-300}
mkdir -p sim traces
FAIL=0; TOTAL=0
for SEED in $(seq 1 "$NSEED"); do
  for LOAD in normal bursty overload; do
    PFX=traces/${LOAD}_s${SEED}
    python3 sw/gen_trace.py --mode $LOAD --n $NREQ --seed $SEED --out-prefix $PFX > /dev/null
    N=$(python3 -c "import json;print(json.load(open('$PFX.meta.json'))['n_entry'])")
    for M in 0 1 2 3; do
      case $M in 0) MN=fifo;; 1) MN=edf;; 2) MN=unc;; 3) MN=hyb;; esac
      TAG=${LOAD}_s${SEED}_${MN}
      iverilog -g2012 -I rtl -o sim/tb_$TAG.vvp \
        -DTRACE_FILE=\"$PFX.mem\" -DN_ENTRY=$N -DMODE_SEL="2'd$M" \
        -DW_D="8'd3" -DW_U="8'd1" \
        -DLOG_FILE=\"sim/disp_rtl_$TAG.csv\" -DCNT_FILE=\"sim/cnt_rtl_$TAG.csv\" \
        rtl/cycle_counter.v rtl/req_fifo.v rtl/expire_unit.v rtl/policy_core.v \
        rtl/dispatch_arbiter.v rtl/engine_model.v rtl/perf_counters.v \
        rtl/trace_player.v rtl/scheduler_top.v tb/tb_top.sv || { FAIL=$((FAIL+1)); continue; }
      vvp sim/tb_$TAG.vvp > sim/log_$TAG.txt
      python3 sw/golden.py $PFX.csv --mode $MN --wd 3 --wu 1 \
        --out-dispatch sim/disp_gold_$TAG.csv --out-counters sim/cnt_gold_$TAG.csv > /dev/null
      if python3 sw/compare.py sim/disp_gold_$TAG.csv sim/disp_rtl_$TAG.csv \
           --gold-counters sim/cnt_gold_$TAG.csv --rtl-counters sim/cnt_rtl_$TAG.csv \
           --tol 3 > sim/cmp_$TAG.txt; then :; else
        FAIL=$((FAIL+1)); echo "FAIL: $TAG (sim/cmp_$TAG.txt)"
      fi
      grep -q "A6 conservation PASS" sim/log_$TAG.txt || { FAIL=$((FAIL+1)); echo "A6 FAIL: $TAG"; }
      TOTAL=$((TOTAL+1))
      rm -f sim/tb_$TAG.vvp
    done
  done
done
echo "=============================="
echo "regression: $((TOTAL-FAIL))/$TOTAL PASS"
[ $FAIL -eq 0 ]
