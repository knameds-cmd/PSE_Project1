"""
preprocess_renewables_capacity.py — 신재생 발전설비 현황 → renewables_capacity_mw.csv
=================================================================================
입력: HOME_발전설비_신재생_발전기현황.csv (CP949)
출력: renewables_capacity_mw.csv (에너지원별 총 설비용량)
"""

import pandas as pd
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)


def main():
    filepath = os.path.join(RAW_DIR, "HOME_발전설비_신재생_발전기현황.csv")

    for enc in ['cp949', 'euc-kr', 'utf-8']:
        try:
            df = pd.read_csv(filepath, encoding=enc)
            break
        except UnicodeDecodeError:
            continue

    print(f"원본 컬럼: {list(df.columns)}")
    print(f"원본 행수: {len(df)}")

    # 컬럼 찾기: 에너지원, 정격용량(또는 인가용량)
    energy_col = None
    capacity_col = None
    for col in df.columns:
        lc = col.strip()
        if '에너지원' in lc or '연료' in lc or '발전원' in lc:
            energy_col = col
        elif '정격용량' in lc or '인가용량' in lc or '설비용량' in lc or '용량' in lc:
            if capacity_col is None:
                capacity_col = col

    if energy_col is None or capacity_col is None:
        print(f"컬럼 탐색 실패. 에너지원={energy_col}, 용량={capacity_col}")
        print(f"전체 컬럼: {list(df.columns)}")
        # 가능한 컬럼 출력
        for col in df.columns:
            print(f"  '{col}': {df[col].dtype}, sample={df[col].iloc[0] if len(df)>0 else 'N/A'}")
        return

    print(f"에너지원 컬럼: '{energy_col}', 용량 컬럼: '{capacity_col}'")

    # 용량을 숫자로 변환
    df[capacity_col] = pd.to_numeric(df[capacity_col], errors='coerce').fillna(0.0)

    # 에너지원별 분류 및 집계
    df['energy_type'] = 'other'
    for idx, row in df.iterrows():
        src = str(row[energy_col]).strip()
        if '태양' in src:
            df.at[idx, 'energy_type'] = 'solar'
        elif '풍력' in src or 'wind' in src.lower():
            df.at[idx, 'energy_type'] = 'wind'

    # 집계
    summary = df.groupby('energy_type')[capacity_col].agg(['sum', 'count']).reset_index()
    summary.columns = ['energy_type', 'total_capacity_mw', 'count']
    summary = summary.sort_values('total_capacity_mw', ascending=False)

    print("\n에너지원별 설비용량:")
    for _, row in summary.iterrows():
        print(f"  {row['energy_type']}: {row['total_capacity_mw']:.1f} MW ({int(row['count'])}기)")

    # 상세 (개별 발전기) - 태양광/풍력만
    re_df = df[df['energy_type'].isin(['solar', 'wind'])].copy()

    # 발전소별 집계
    plant_col = None
    for col in df.columns:
        if '발전소' in col or '설비' in col:
            plant_col = col
            break

    # 에너지원별 총합 저장 (태양광/풍력만)
    re_summary = summary[summary['energy_type'].isin(['solar', 'wind'])].copy()
    out_path = os.path.join(OUT_DIR, "renewables_capacity_mw.csv")
    re_summary.to_csv(out_path, index=False, encoding='utf-8')
    print(f"\n✓ renewables_capacity_mw.csv 저장: {out_path}")


if __name__ == '__main__':
    main()
