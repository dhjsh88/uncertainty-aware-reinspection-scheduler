#!/usr/bin/env python3
"""
golden.py — RTL과 동일 규칙의 reference model (사이클 스텝 시뮬레이션).

RTL과 트랜잭션 순서를 맞추기 위해 다음 타이밍 규칙을 명시적으로 모델링한다:
  * trace_player: 사이클당 1건, now>=arrival & FIFO not-full일 때 소비(detect).
    - 빈 큐에 push된 항목은 detect+2 사이클부터 head로 보임
      (RTL: push 레지스터 1클록 + head 레지스터 1클록)
  * pop(dispatch/expire) 후 다음 head는 pop+1 사이클부터 보임 (FWFT fill 1클록)
  * engine: grant 사이클 G → busy G+1..G+LATENCY → 다음 grant 최소 G+LATENCY+1
  * expire: 보이는 head에 대해 now > deadline 이면 pop (slack 부호 판정과 동일)
  * miss: grant 시점에 now + LATENCY > deadline
비교 1차 기준은 dispatch 순서 + counter (가이드 §6.1). cycle까지 대부분 일치하지만
±수 사이클 차이는 compare.py의 tolerance로 흡수한다.

사용:
  python3 golden.py trace.csv --mode hyb --wd 3 --wu 1 \
      --out-dispatch dispatch_gold.csv --out-counters counters_gold.csv
"""
import argparse
import csv
import sys
from collections import deque

MODES = ("fifo", "edf", "unc", "hyb")
MASK32 = 0xFFFFFFFF


def load_trace(path):
    """CSV: arrival,stream,req_id,uncertainty,deadline[,label] — arrival 오름차순 가정."""
    rows = []
    with open(path, newline="") as f:
        rd = csv.DictReader(f)
        for r in rd:
            rows.append({
                "ar": int(r["arrival"]),
                "st": int(r["stream"]),
                "id": int(r["req_id"]),
                "u":  int(r["uncertainty"]),
                "dl": int(r["deadline"]),
                "lb": int(r.get("label", 0) or 0),
            })
    for a, b in zip(rows, rows[1:]):
        if b["ar"] < a["ar"]:
            sys.exit("trace not sorted by arrival — gen_trace.py로 생성했는지 확인")
    return rows


def prio_of(mode, wd, wu, rec, slack):
    """RTL policy_core와 비트 단위 동일한 '클수록 우선' 점수."""
    if mode == "fifo":
        return (~rec["ar"]) & MASK32
    if mode == "edf":
        return (~slack) & MASK32
    if mode == "unc":
        return rec["u"]
    # hyb
    slack16 = 0xFFFF if slack > 0xFFFF else slack
    urg8 = ((0xFFFF - slack16) >> 8) & 0xFF
    return wd * urg8 + wu * rec["u"]


def simulate(trace, mode, wd, wu, latency=200, depth=64, nstream=4):
    q = [deque() for _ in range(nstream)]      # 각 원소 = record dict
    ready = [0] * nstream                      # 현재 head가 후보가 되는 최소 사이클
    cap = depth + 1                            # mem + head 레지스터

    now = 0
    idx = 0
    n = len(trace)
    engine_free = 0
    rr = 0

    dispatches = []        # (cycle, stream, req_id, record)
    expired_list = []      # (cycle, stream, req_id)
    cnt = {k: 0 for k in ("pushed", "dispatched", "expired", "miss",
                          "done_total", "busy_cycles", "recovered_fr")}
    disp_s = [0] * nstream
    sum_latency = 0

    def visible(g):
        return len(q[g]) > 0 and now >= ready[g]

    while True:
        # 종료: trace 소진 & 전 큐 빔 & 엔진 놂
        if idx >= n and all(len(x) == 0 for x in q) and now >= engine_free:
            break

        # ① expire — 보이는 head, now > deadline (slack 음수)
        for g in range(nstream):
            if visible(g):
                h = q[g][0]
                if ((h["dl"] - now) & MASK32) >> 31:   # RTL과 동일: 부호비트
                    q[g].popleft()
                    ready[g] = now + 1                 # 다음 head는 +1 사이클부터
                    cnt["expired"] += 1
                    expired_list.append((now, g, h["id"]))

        # ② dispatch — 엔진 idle이면 후보 중 1명 grant
        if now >= engine_free:
            best = None   # (prio, rank, g)
            for g in range(nstream):
                if not visible(g):
                    continue
                h = q[g][0]
                slack = (h["dl"] - now) & MASK32
                if slack >> 31:
                    continue                            # 이번 사이클 만료분은 위에서 제거됨
                p = prio_of(mode, wd, wu, h, slack)
                rank = (g - rr) % nstream
                if best is None or p > best[0] or (p == best[0] and rank < best[1]):
                    best = (p, rank, g)
            if best is not None:
                g = best[2]
                h = q[g].popleft()
                ready[g] = now + 1
                rr = (g + 1) % nstream
                cnt["dispatched"] += 1
                disp_s[g] += 1
                sum_latency += (now - h["ar"]) & MASK32
                miss = (now + latency) > h["dl"]
                if miss:
                    cnt["miss"] += 1
                if h["lb"] and not miss:
                    cnt["recovered_fr"] += 1
                engine_free = now + latency + 1
                cnt["busy_cycles"] += latency
                cnt["done_total"] += 1
                dispatches.append((now, g, h["id"], h))

        # ③ player — 사이클당 1건, full이면 head-of-line 정지
        if idx < n and now >= trace[idx]["ar"]:
            g = trace[idx]["st"]
            if len(q[g]) < cap:
                was_empty = (len(q[g]) == 0)
                q[g].append(dict(trace[idx]))
                if was_empty:
                    ready[g] = now + 2   # push 레지스터 + head 레지스터
                cnt["pushed"] += 1
                idx += 1

        now += 1

    cnt["sum_latency"] = sum_latency
    for g in range(nstream):
        cnt[f"disp_s{g}"] = disp_s[g]
    cnt["end_cycle"] = now
    return dispatches, expired_list, cnt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--mode", choices=MODES, required=True)
    ap.add_argument("--wd", type=int, default=3)
    ap.add_argument("--wu", type=int, default=1)
    ap.add_argument("--latency", type=int, default=200)
    ap.add_argument("--depth", type=int, default=64)
    ap.add_argument("--nstream", type=int, default=4)
    ap.add_argument("--out-dispatch", default="dispatch_gold.csv")
    ap.add_argument("--out-counters", default="counters_gold.csv")
    ap.add_argument("--out-expired", default=None)
    args = ap.parse_args()

    trace = load_trace(args.trace)
    disp, exp, cnt = simulate(trace, args.mode, args.wd, args.wu,
                              args.latency, args.depth, args.nstream)

    with open(args.out_dispatch, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cycle", "stream", "req_id"])
        for c, g, rid, _ in disp:
            w.writerow([c, g, rid])

    with open(args.out_counters, "w", newline="") as f:
        for k in ("pushed", "dispatched", "expired", "miss", "done_total",
                  "busy_cycles", "sum_latency",
                  "disp_s0", "disp_s1", "disp_s2", "disp_s3",
                  "end_cycle", "recovered_fr"):
            f.write(f"{k},{cnt[k]}\n")

    if args.out_expired:
        with open(args.out_expired, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["cycle", "stream", "req_id"])
            for row in exp:
                w.writerow(row)

    print(f"[golden] mode={args.mode} dispatched={cnt['dispatched']} "
          f"expired={cnt['expired']} miss={cnt['miss']} "
          f"recovered_fr={cnt['recovered_fr']}")


if __name__ == "__main__":
    main()
