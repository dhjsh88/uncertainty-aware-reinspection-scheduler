#!/usr/bin/env python3
"""
gen_trace.py — 합성 워크로드 생성 (Normal / Bursty / Overload, seed 재현 가능).

출력 3종 (같은 prefix):
  <prefix>.csv        golden.py 입력 (arrival,stream,req_id,uncertainty,deadline,label)
  <prefix>.mem        RTL $readmemh 입력 (88b hex = 22자리/줄)
  <prefix>.meta.json  n_entry 등 메타 (trace_player의 x-대기 함정 방지: 건수를 같이 출력)

entry 88b = {stream[87:80], req_id[79:72], u[71:64], deadline[63:32], arrival[31:0]}

uncertainty: bimodal (확실 다수 + 불확실 소수), false-reject 라벨은 불확실 그룹 집중.
도착률 (단일 엔진 처리능력 = 1/LATENCY 기준):
  normal   λ = 0.6 / LATENCY
  bursty   normal + 주기적 burst(50건 연속)
  overload λ = 1.5 / LATENCY   ← 본 실험 구간

사용:
  python3 gen_trace.py --mode overload --n 10000 --seed 1 --out-prefix traces/ov_s1
"""
import argparse
import csv
import json
import os
import random


def gen(mode, n, seed, latency, nstream, dl_lo_mult, dl_hi_mult):
    rnd = random.Random(seed)
    cap_rate = 1.0 / latency
    rate = {"normal": 0.6 * cap_rate,
            "bursty": 0.6 * cap_rate,
            "overload": 1.5 * cap_rate}[mode]

    rows = []
    t = 10.0                      # run 직후 여유
    id_ctr = [0] * nstream
    burst_left = 0
    since_burst = 0
    burst_period = int(20 * latency)

    for _ in range(n):
        if mode == "bursty":
            if burst_left > 0:
                gap = 1.0                     # burst 중: 연속 도착
                burst_left -= 1
            else:
                gap = rnd.expovariate(rate)
                since_burst += gap
                if since_burst >= burst_period:
                    burst_left = 50
                    since_burst = 0
        else:
            gap = rnd.expovariate(rate)
        t += gap
        ar = int(t)

        st = rnd.randrange(nstream)
        rid = id_ctr[st] % 256
        id_ctr[st] += 1

        # bimodal uncertainty
        if rnd.random() < 0.2:                     # 불확실 소수
            u = min(255, max(0, int(rnd.gauss(200, 25))))
            label = 1 if rnd.random() < 0.30 else 0
        else:                                      # 확실 다수
            u = min(255, max(0, int(rnd.gauss(30, 15))))
            label = 1 if rnd.random() < 0.02 else 0

        dl = ar + rnd.randint(int(dl_lo_mult * latency), int(dl_hi_mult * latency))
        rows.append({"arrival": ar, "stream": st, "req_id": rid,
                     "uncertainty": u, "deadline": dl, "label": label})

    rows.sort(key=lambda r: r["arrival"])
    return rows


def write_outputs(rows, prefix, meta):
    os.makedirs(os.path.dirname(prefix) or ".", exist_ok=True)

    with open(prefix + ".csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["arrival", "stream", "req_id",
                                          "uncertainty", "deadline", "label"])
        w.writeheader()
        w.writerows(rows)

    with open(prefix + ".mem", "w") as f:
        for r in rows:
            word = ((r["stream"] & 0xFF) << 80) | ((r["req_id"] & 0xFF) << 72) \
                 | ((r["uncertainty"] & 0xFF) << 64) \
                 | ((r["deadline"] & 0xFFFFFFFF) << 32) | (r["arrival"] & 0xFFFFFFFF)
            f.write(f"{word:022x}\n")

    meta["n_entry"] = len(rows)
    with open(prefix + ".meta.json", "w") as f:
        json.dump(meta, f, indent=2)

    print(f"[gen_trace] {prefix}.csv/.mem  n_entry={len(rows)}  "
          f"span={rows[-1]['arrival'] - rows[0]['arrival']} cycles")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("normal", "bursty", "overload"), required=True)
    ap.add_argument("--n", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--latency", type=int, default=200)
    ap.add_argument("--nstream", type=int, default=4)
    ap.add_argument("--dl-lo", type=float, default=2.0, help="deadline 여유 하한 ×LATENCY")
    ap.add_argument("--dl-hi", type=float, default=10.0, help="deadline 여유 상한 ×LATENCY")
    ap.add_argument("--out-prefix", required=True)
    args = ap.parse_args()

    rows = gen(args.mode, args.n, args.seed, args.latency, args.nstream,
               args.dl_lo, args.dl_hi)
    write_outputs(rows, args.out_prefix,
                  {"mode": args.mode, "seed": args.seed, "n": args.n,
                   "latency": args.latency, "nstream": args.nstream})


if __name__ == "__main__":
    main()
