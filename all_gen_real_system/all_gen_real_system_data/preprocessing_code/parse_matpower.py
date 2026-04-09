"""
parse_matpower.py — KPG193_ver1_5.m 파싱 → generators.csv, gencost.csv, genthermal.csv
======================================================================================
MATPOWER 케이스 파일(.m)에서 mpc.gen, mpc.gencost, mpc.genthermal 행렬을 추출하여
개별 발전기 122기의 데이터를 CSV로 저장한다.

단위 주의: gencost의 계수는 천원(1000won) 단위이므로, marginal_cost 계산 시 ×1000 변환.
"""

import re
import csv
import os

# ── 경로 설정 ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)

M_FILE = os.path.join(RAW_DIR, "KPG193_ver1_5.m")


def parse_matrix_block(lines, start_marker):
    """
    lines 전체에서 start_marker (예: 'mpc.gen =') 이후 '];' 까지의
    데이터 행들을 파싱하여 (숫자 리스트, 연료 주석) 튜플의 리스트를 반환.
    """
    rows = []
    inside = False
    for line in lines:
        stripped = line.strip()
        if start_marker in stripped:
            inside = True
            continue
        if inside:
            if stripped.startswith('];'):
                break
            if not stripped or stripped.startswith('%'):
                continue
            # 세미콜론 기준으로 데이터 / 주석 분리
            parts = stripped.split(';')
            data_part = parts[0].strip()
            comment = parts[1].strip() if len(parts) > 1 else ''
            # 연료 타입 추출 (% LNG, % Coal, % Nuclear)
            fuel = ''
            fuel_match = re.search(r'%\s*(LNG|Coal|Nuclear)', comment)
            if fuel_match:
                fuel = fuel_match.group(1)
            # 숫자 파싱
            nums = [float(x) for x in data_part.split()]
            rows.append((nums, fuel))
    return rows


def main():
    with open(M_FILE, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    # ── 3개 행렬 파싱 ──
    gen_rows = parse_matrix_block(lines, 'mpc.gen =')
    gencost_rows = parse_matrix_block(lines, 'mpc.gencost =')
    genthermal_rows = parse_matrix_block(lines, 'mpc.genthermal =')

    n = len(gen_rows)
    print(f"파싱 완료: gen={len(gen_rows)}, gencost={len(gencost_rows)}, genthermal={len(genthermal_rows)}")
    assert len(gencost_rows) == n, f"gencost 행 수 불일치: {len(gencost_rows)} != {n}"
    assert len(genthermal_rows) == n, f"genthermal 행 수 불일치: {len(genthermal_rows)} != {n}"

    # ── 발전기 이름 생성 (연료별 순번) ──
    fuel_counters = {}
    names = []
    fuels = []
    for _, fuel in gen_rows:
        if fuel not in fuel_counters:
            fuel_counters[fuel] = 0
        fuel_counters[fuel] += 1
        name = f"{fuel}_{fuel_counters[fuel]:03d}"
        names.append(name)
        fuels.append(fuel)

    print(f"연료별 발전기 수: { {k: v for k, v in fuel_counters.items()} }")

    # ══════════════════════════════════════════════════════════
    # 1. generators.csv
    # ══════════════════════════════════════════════════════════
    gen_path = os.path.join(OUT_DIR, "generators.csv")
    with open(gen_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['name', 'fuel', 'pmin', 'pmax', 'ramp_up', 'ramp_down', 'marginal_cost'])
        for i in range(n):
            gen = gen_rows[i][0]
            gc = gencost_rows[i][0]
            gt = genthermal_rows[i][0]

            pmax = gen[8]   # mpc.gen col9 (0-indexed: 8)
            pmin = gen[9]   # mpc.gen col10 (0-indexed: 9)
            ramp_up = gt[5]   # mpc.genthermal col6 (0-indexed: 5)
            ramp_down = gt[6] # mpc.genthermal col7 (0-indexed: 6)

            # gencost: type=2, startup, shutdown, n=3, a(c2), b(c1), c(c0)
            a = gc[4]  # quadratic coefficient
            b = gc[5]  # linear coefficient

            # 중점 한계비용: MC = (2a * (Pmin+Pmax)/2 + b) * 1000 원/MWh
            p_mid = (pmin + pmax) / 2.0
            marginal_cost = (2.0 * a * p_mid + b) * 1000.0

            writer.writerow([
                names[i], fuels[i],
                round(pmin, 2), round(pmax, 2),
                round(ramp_up, 2), round(ramp_down, 2),
                round(marginal_cost, 2)
            ])
    print(f"✓ generators.csv 저장 ({n}행): {gen_path}")

    # ══════════════════════════════════════════════════════════
    # 2. gencost.csv
    # ══════════════════════════════════════════════════════════
    gencost_path = os.path.join(OUT_DIR, "gencost.csv")
    with open(gencost_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['name', 'a', 'b', 'c', 'startup_cost'])
        for i in range(n):
            gc = gencost_rows[i][0]
            # gc: [type, startup, shutdown, n, a, b, c]
            startup_cost = gc[1]
            a = gc[4]
            b = gc[5]
            c = gc[6]
            writer.writerow([names[i], a, b, c, startup_cost])
    print(f"✓ gencost.csv 저장 ({n}행): {gencost_path}")

    # ══════════════════════════════════════════════════════════
    # 3. genthermal.csv
    # ══════════════════════════════════════════════════════════
    genthermal_path = os.path.join(OUT_DIR, "genthermal.csv")
    gt_cols = [
        'name', 'type_thermal', 'UT', 'DT', 'inistate', 'initialpower',
        'ramp_up', 'ramp_down', 'startup_limit', 'shutdown_limit',
        'startup1', 'startup2', 'startup3',
        'startupdelay1', 'startupdelay2', 'startupdelay3'
    ]
    with open(genthermal_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(gt_cols)
        for i in range(n):
            gt = genthermal_rows[i][0]
            row = [names[i]] + [gt[j] for j in range(15)]
            writer.writerow(row)
    print(f"✓ genthermal.csv 저장 ({n}행): {genthermal_path}")


if __name__ == '__main__':
    main()
