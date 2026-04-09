"""
preprocess_smp_demand.py — 시간별 SMP + 전력수요 → smp_demand.csv
================================================================
입력:
  - HOME_전력거래_계통한계가격_시간별SMP.csv (CP949, wide format)
  - 한국전력거래소_시간별 전국 전력수요량_20241231.csv (CP949, wide format)
출력:
  - smp_demand.csv (date, hour, smp_mainland, demand_mainland)
  - 2024년만 필터, 8784행 (366일 × 24시간)
"""

import pandas as pd
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)


def load_wide_to_long(filepath, encoding, value_name, date_col_idx=0):
    """wide 포맷 (날짜 + 24시간 열) → long 포맷 변환."""
    df = pd.read_csv(filepath, encoding=encoding)
    date_col = df.columns[date_col_idx]

    # 시간 열 찾기 (01시~24시 또는 1시~24시)
    hour_cols = {}
    for col in df.columns[1:]:
        col_str = str(col).strip()
        # "01시", "1시", "01", "1" 등 다양한 형태 처리
        match = None
        for pattern in [r'(\d+)시', r'^(\d+)$']:
            import re
            m = re.match(pattern, col_str)
            if m:
                match = m
                break
        if match:
            h = int(match.group(1))
            if 1 <= h <= 24:
                hour_cols[col] = h

    if len(hour_cols) < 24:
        # 첫 24개 숫자 열을 시간으로 간주
        numeric_cols = [c for c in df.columns[1:] if pd.api.types.is_numeric_dtype(df[c])]
        hour_cols = {c: i+1 for i, c in enumerate(numeric_cols[:24])}

    records = []
    for _, row in df.iterrows():
        date_val = str(row[date_col]).strip()
        for col, hour in hour_cols.items():
            try:
                val = float(row[col])
            except (ValueError, TypeError):
                val = float('nan')
            records.append({'date': date_val, 'hour': hour, value_name: val})

    return pd.DataFrame(records)


def main():
    # ── SMP 로딩 ──
    smp_file = os.path.join(RAW_DIR, "HOME_전력거래_계통한계가격_시간별SMP.csv")
    smp_df = load_wide_to_long(smp_file, 'cp949', 'smp_mainland')
    # SMP 단위: 원/kWh → 원/MWh (×1000)
    smp_df['smp_mainland'] = smp_df['smp_mainland'] * 1000.0
    print(f"SMP 로딩: {len(smp_df)}행, 범위: {smp_df['smp_mainland'].min():.0f}~{smp_df['smp_mainland'].max():.0f} 원/MWh")

    # ── 수요 로딩 ──
    demand_file = os.path.join(RAW_DIR, "한국전력거래소_시간별 전국 전력수요량_20241231.csv")
    demand_df = load_wide_to_long(demand_file, 'cp949', 'demand_mainland')
    print(f"수요 로딩: {len(demand_df)}행, 범위: {demand_df['demand_mainland'].min():.0f}~{demand_df['demand_mainland'].max():.0f} MW")

    # ── 날짜 정규화 ──
    # 날짜 포맷: "2024/12/31" 또는 "2024-01-01" 등
    for df in [smp_df, demand_df]:
        df['date'] = df['date'].str.replace('/', '-')

    # ── 2024년 필터 ──
    smp_df = smp_df[smp_df['date'].str.startswith('2024')].copy()
    demand_df = demand_df[demand_df['date'].str.startswith('2024')].copy()
    print(f"2024 필터 후: SMP {len(smp_df)}행, 수요 {len(demand_df)}행")

    # ── 병합 ──
    merged = pd.merge(smp_df, demand_df, on=['date', 'hour'], how='inner')
    merged = merged.sort_values(['date', 'hour']).reset_index(drop=True)

    # NaN 제거
    merged = merged.dropna(subset=['smp_mainland', 'demand_mainland'])

    print(f"병합 결과: {len(merged)}행")
    print(f"  SMP 범위: {merged['smp_mainland'].min():.0f}~{merged['smp_mainland'].max():.0f} 원/MWh")
    print(f"  수요 범위: {merged['demand_mainland'].min():.0f}~{merged['demand_mainland'].max():.0f} MW")

    # ── 저장 ──
    out_path = os.path.join(OUT_DIR, "smp_demand.csv")
    merged.to_csv(out_path, index=False, encoding='utf-8')
    print(f"✓ smp_demand.csv 저장: {out_path}")


if __name__ == '__main__':
    main()
