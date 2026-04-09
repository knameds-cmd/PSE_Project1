"""
preprocess_marginal_fuel.py — 연료원별 SMP 결정횟수 → marginal_fuel_counts.csv
============================================================================
입력: HOME_전력거래_계통한계가격_연료원별SMP결정.csv (CP949)
출력: marginal_fuel_counts.csv (월별 연료원별 SMP 결정 시간 수)
"""

import pandas as pd
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)


def main():
    filepath = os.path.join(RAW_DIR, "HOME_전력거래_계통한계가격_연료원별SMP결정.csv")

    for enc in ['cp949', 'euc-kr', 'utf-8']:
        try:
            df = pd.read_csv(filepath, encoding=enc)
            break
        except UnicodeDecodeError:
            continue

    print(f"원본 컬럼: {list(df.columns)}")
    print(f"원본 행수: {len(df)}")
    if len(df) > 0:
        print(f"데이터:\n{df}")

    # 컬럼명 정규화
    col_map = {}
    for col in df.columns:
        lc = col.strip()
        if '기간' in lc or '기준' in lc or 'date' in lc.lower():
            col_map[col] = 'date'
        elif 'LNG' in col or 'lng' in col.lower():
            col_map[col] = 'LNG'
        elif '무연탄' in lc:
            col_map[col] = 'anthracite'
        elif '유연탄' in lc or '역청탄' in lc:
            col_map[col] = 'bituminous'
        elif '핵' in lc or '원자력' in lc or '원전' in lc:
            col_map[col] = 'nuclear'
        elif '유류' in lc or '석유' in lc:
            col_map[col] = 'oil'
        elif '합계' in lc or '전체' in lc or 'total' in lc.lower():
            col_map[col] = 'total_hours'
        else:
            col_map[col] = col.strip()

    df = df.rename(columns=col_map)

    # 날짜 정규화
    if 'date' in df.columns:
        df['date'] = df['date'].astype(str).str.replace('/', '-')

    # 2024년 필터
    df_2024 = df[df['date'].str.startswith('2024')].copy() if 'date' in df.columns else df.copy()
    print(f"\n2024년 데이터: {len(df_2024)}행")

    out_path = os.path.join(OUT_DIR, "marginal_fuel_counts.csv")
    df_2024.to_csv(out_path, index=False, encoding='utf-8')
    print(f"✓ marginal_fuel_counts.csv 저장: {out_path}")


if __name__ == '__main__':
    main()
