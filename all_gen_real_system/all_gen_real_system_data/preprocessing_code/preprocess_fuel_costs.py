"""
preprocess_fuel_costs.py — 연료비용 데이터 → fuel_costs.csv
=========================================================
입력: HOME_전력거래_연료비용.csv (CP949, 3행 헤더, wide format)
출력: fuel_costs.csv (year_month, fuel, fuel_cost_won_per_gcal)

파일 구조 (3행 헤더):
  행1: 기간, 연료별비용(5열), 발전별비용(5열), 전력별비용(5열)
  행2: (공백), 핵연료, 유연탄, 무연탄, 유류, LNG, 핵연료, 유연탄, 무연탄, 유류, LNG, ...
  행3: (공백), 원/kWh, 원/ton, 원/ton, 원/kl, 원/ton, 원/Gcal, 원/Gcal, 원/Gcal, 원/Gcal, 원/Gcal, ...

발전별비용 (원/Gcal) 열을 사용: 인덱스 6~10 (0-based)
"""

import pandas as pd
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)


def main():
    filepath = os.path.join(RAW_DIR, "HOME_전력거래_연료비용.csv")

    # 헤더 없이 읽기
    df = pd.read_csv(filepath, encoding='cp949', header=None)
    print(f"전체 shape: {df.shape}")
    print(f"행1: {list(df.iloc[0])}")
    print(f"행2: {list(df.iloc[1])}")
    print(f"행3: {list(df.iloc[2])}")

    # 데이터 행 (인덱스 3부터)
    data = df.iloc[3:].copy().reset_index(drop=True)

    # 컬럼 인덱스:
    # 0: 기간
    # 1-5: 연료별비용 (핵연료, 유연탄, 무연탄, 유류, LNG) - 원래 단위
    # 6-10: 발전별비용 (핵연료, 유연탄, 무연탄, 유류, LNG) - 원/Gcal ← 이것 사용
    # 11-15: 전력별비용

    # 발전별비용(원/Gcal) 추출
    fuel_names_kr = ['nuclear', 'coal', 'anthracite', 'oil', 'lng']
    col_indices = [6, 7, 8, 9, 10]  # 발전별비용 열

    records = []
    for _, row in data.iterrows():
        ym = str(row.iloc[0]).strip()
        if not ym or pd.isna(row.iloc[0]):
            continue
        # 날짜 정규화
        ym = ym.replace('/', '-')

        for fuel, ci in zip(fuel_names_kr, col_indices):
            try:
                val = float(row.iloc[ci])
            except (ValueError, TypeError):
                val = float('nan')
            records.append({
                'year_month': ym,
                'fuel': fuel,
                'fuel_cost_won_per_gcal': val
            })

    result = pd.DataFrame(records)

    # 2024년 필터
    result_2024 = result[result['year_month'].str.startswith('2024')].copy()

    print(f"\n전체 연료비용: {len(result)}행")
    print(f"2024년: {len(result_2024)}행")

    # 2024년 연료별 평균
    if len(result_2024) > 0:
        print("\n2024년 연료별 평균 (원/Gcal):")
        for fuel in fuel_names_kr:
            subset = result_2024[result_2024['fuel'] == fuel]
            avg = subset['fuel_cost_won_per_gcal'].mean()
            print(f"  {fuel}: {avg:,.0f}")

    # 전체 데이터 저장 (2024년만이 아닌 전체 - 다른 연도 참조 가능)
    out_path = os.path.join(OUT_DIR, "fuel_costs.csv")
    result.to_csv(out_path, index=False, encoding='utf-8')
    print(f"\n✓ fuel_costs.csv 저장 ({len(result)}행): {out_path}")


if __name__ == '__main__':
    main()
