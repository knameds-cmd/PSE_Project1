"""
nuclear_mapping.py — 원전 호기명 ↔ Nuclear_XXX 매핑 테이블 생성
================================================================
KPG193_ver1_5.m의 bus 번호 + 용량 + 초기상태를 기반으로
실제 한국 원전 호기명과 모델 발전기 ID를 대응시킨다.

매핑 근거:
- bus 82:  고리/신고리/새울 (부산 기장)
- bus 124: 한빛 (전남 영광)
- bus 166: 월성/신월성 (경북 경주)
- bus 175: 한울/신한울 (경북 울진)
- 용량: 1400MW=APR1400, 1000MW=OPR1000, 950MW=모델축소OPR, 700MW=PHWR(월성), 650MW=모델축소
- 초기상태 OFF(-24h): 정비 또는 시운전 중인 호기
"""

import csv
import os
import json

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)

# ══════════════════════════════════════════════════════════════
# 매핑 테이블
# (generator_id, bus, pmax_mw, unit_name, plant_group, reactor_type, notes)
# ══════════════════════════════════════════════════════════════
MAPPING = [
    # bus 82 — 고리/신고리/새울 (7기)
    ("Nuclear_001",  82, 1400, "새울1호기",   "새울",   "APR1400", "ini OFF(-24h)"),
    ("Nuclear_002",  82, 1000, "고리3호기",   "고리",   "OPR1000", ""),
    ("Nuclear_003",  82, 1000, "고리4호기",   "고리",   "OPR1000", ""),
    ("Nuclear_004",  82, 1000, "신고리1호기", "신고리", "OPR1000", ""),
    ("Nuclear_005",  82, 1000, "신고리2호기", "신고리", "OPR1000", ""),
    ("Nuclear_006",  82,  950, "새울2호기",   "새울",   "APR1400", "모델축소 950MW"),
    ("Nuclear_007",  82,  950, "새울3호기",   "새울",   "APR1400", "모델축소 950MW, 건설중/시운전"),

    # bus 124 — 한빛 (6기)
    ("Nuclear_008", 124, 1000, "한빛1호기",   "한빛",   "OPR1000", ""),
    ("Nuclear_009", 124, 1000, "한빛2호기",   "한빛",   "OPR1000", ""),
    ("Nuclear_010", 124, 1000, "한빛3호기",   "한빛",   "OPR1000", "ini OFF(-24h)"),
    ("Nuclear_011", 124, 1000, "한빛4호기",   "한빛",   "OPR1000", "ini OFF(-24h)"),
    ("Nuclear_012", 124,  950, "한빛5호기",   "한빛",   "OPR1000", "모델축소 950MW"),
    ("Nuclear_013", 124,  950, "한빛6호기",   "한빛",   "OPR1000", "모델축소 950MW"),

    # bus 175 — 한울/신한울 (7기) [.m 파일에서 bus 175가 bus 166보다 먼저 등장]
    ("Nuclear_014", 175, 1400, "신한울1호기", "신한울", "APR1400", ""),
    ("Nuclear_015", 175, 1400, "신한울2호기", "신한울", "APR1400", ""),

    # bus 166 — 월성/신월성 (5기)
    ("Nuclear_016", 166, 1000, "신월성2호기", "신월성", "OPR1000", "ini OFF(-24h)"),
    ("Nuclear_017", 166, 1000, "신월성1호기", "신월성", "OPR1000", ""),
    ("Nuclear_018", 166,  700, "월성2호기",   "월성",   "PHWR",    "중수로"),
    ("Nuclear_019", 166,  700, "월성3호기",   "월성",   "PHWR",    "중수로"),
    ("Nuclear_020", 166,  700, "월성4호기",   "월성",   "PHWR",    "중수로, ini OFF(-24h)"),

    # bus 175 — 한울 계속 (5기)
    ("Nuclear_021", 175, 1000, "한울1호기",   "한울",   "OPR1000", ""),
    ("Nuclear_022", 175, 1000, "한울2호기",   "한울",   "OPR1000", ""),
    ("Nuclear_023", 175,  950, "한울3호기",   "한울",   "OPR1000", "모델축소 950MW"),
    ("Nuclear_024", 175,  950, "한울4호기",   "한울",   "OPR1000", "모델축소 950MW"),
    ("Nuclear_025", 175,  650, "한울5호기",   "한울",   "OPR1000", "모델축소 650MW"),
]


def build_name_to_id():
    """unit_name -> generator_id 매핑 딕셔너리."""
    return {row[3]: row[0] for row in MAPPING}


def build_id_to_name():
    """generator_id -> unit_name 매핑 딕셔너리."""
    return {row[0]: row[3] for row in MAPPING}


def main():
    # CSV 저장
    csv_path = os.path.join(OUT_DIR, "nuclear_unit_mapping.csv")
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['generator_id', 'bus', 'pmax_mw', 'unit_name',
                         'plant_group', 'reactor_type', 'notes'])
        for row in MAPPING:
            writer.writerow(row)

    print(f"Nuclear 매핑 테이블 ({len(MAPPING)}기):")
    for row in MAPPING:
        print(f"  {row[0]:>14} = {row[3]:<12} (bus {row[1]}, {row[2]}MW, {row[4]})")

    # JSON 저장 (Julia에서 읽기 편하도록)
    name_to_id = build_name_to_id()
    json_path = os.path.join(OUT_DIR, "nuclear_unit_mapping.json")
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(name_to_id, f, ensure_ascii=False, indent=2)

    print(f"\n저장 완료:")
    print(f"  {csv_path}")
    print(f"  {json_path}")

    # 검증: nuclear_must_off.csv의 호기명이 매핑에 있는지 확인
    mustoff_path = os.path.join(OUT_DIR, "nuclear_must_off.csv")
    if os.path.exists(mustoff_path):
        with open(mustoff_path, encoding='utf-8') as f:
            mustoff = list(csv.DictReader(f))
        print(f"\n매핑 검증 (nuclear_must_off.csv):")
        unmapped = []
        for row in mustoff:
            uname = row['unit_name']
            if uname in name_to_id:
                print(f"  OK  {uname} -> {name_to_id[uname]}")
            else:
                unmapped.append(uname)
                print(f"  !!  {uname} -> 매핑 없음")
        if unmapped:
            print(f"\n  경고: 매핑되지 않은 호기 {len(unmapped)}건: {unmapped}")
        else:
            print(f"\n  전체 {len(mustoff)}건 매핑 성공")


if __name__ == '__main__':
    main()
