#!/usr/bin/env python3
"""
compare.py — RTL dispatch 로그 vs golden 트랜잭션 비교.

1차 기준 (가이드 §6.1): dispatch "순서"(stream,req_id 시퀀스) 완전 일치 + counter 일치.
cycle은 tolerance(기본 3) 내 차이 허용 — cycle-accurate 강제하지 않는다.
counter 중 sum_latency는 cycle 오프셋에 종속이라 tol×dispatched 허용.

사용:
  python3 compare.py dispatch_gold.csv dispatch_rtl.csv \
      --gold-counters counters_gold.csv --rtl-counters counters_rtl.csv --tol 3
종료코드: 0=PASS, 1=FAIL
"""
import argparse
import csv
import sys


def load_dispatch(path):
    out = []
    with open(path, newline="") as f:
        rd = csv.DictReader(f)
        for r in rd:
            out.append((int(r["cycle"]), int(r["stream"]), int(r["req_id"])))
    return out


def load_counters(path):
    d = {}
    with open(path, newline="") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            k, v = line.split(",")
            d[k.strip()] = int(v)
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gold_dispatch")
    ap.add_argument("rtl_dispatch")
    ap.add_argument("--gold-counters", default=None)
    ap.add_argument("--rtl-counters", default=None)
    ap.add_argument("--tol", type=int, default=3, help="cycle 차이 허용치")
    args = ap.parse_args()

    ok = True
    g = load_dispatch(args.gold_dispatch)
    r = load_dispatch(args.rtl_dispatch)

    # ① 트랜잭션 순서
    if len(g) != len(r):
        print(f"[FAIL] dispatch count mismatch: golden={len(g)} rtl={len(r)}")
        ok = False
    n = min(len(g), len(r))
    max_dc = 0
    for i in range(n):
        gc, gs, gi = g[i]
        rc, rs, ri = r[i]
        if (gs, gi) != (rs, ri):
            print(f"[FAIL] order mismatch at #{i}: golden=(s{gs},id{gi},c{gc}) "
                  f"rtl=(s{rs},id{ri},c{rc})")
            lo = max(0, i - 3)
            for j in range(lo, min(n, i + 4)):
                print(f"    #{j}: golden={g[j]}  rtl={r[j]}")
            ok = False
            break
        dc = abs(gc - rc)
        max_dc = max(max_dc, dc)
        if dc > args.tol:
            print(f"[WARN] cycle diff {dc} > tol at #{i}: golden c{gc} rtl c{rc}")
    if ok:
        print(f"[OK] transaction order match: {n} dispatches, max cycle diff = {max_dc}")

    # ② counter
    if args.gold_counters and args.rtl_counters:
        gc_ = load_counters(args.gold_counters)
        rc_ = load_counters(args.rtl_counters)
        exact_keys = ("pushed", "dispatched", "expired", "miss", "done_total",
                      "busy_cycles", "disp_s0", "disp_s1", "disp_s2", "disp_s3")
        for k in exact_keys:
            if k in gc_ and k in rc_:
                if gc_[k] != rc_[k]:
                    print(f"[FAIL] counter {k}: golden={gc_[k]} rtl={rc_[k]}")
                    ok = False
        if "sum_latency" in gc_ and "sum_latency" in rc_:
            allow = args.tol * max(1, gc_.get("dispatched", 1))
            d = abs(gc_["sum_latency"] - rc_["sum_latency"])
            if d > allow:
                print(f"[FAIL] sum_latency diff {d} > {allow}")
                ok = False
        if ok:
            print("[OK] counters match")

    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
