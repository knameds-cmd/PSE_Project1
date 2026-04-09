"""
preprocess_renewables.py — 재생에너지 발전량 → renewables_generation_mwh.csv
=========================================================================
입력: 재생에너지_발전량_2024.csv (UTF-8, long format)
  컬럼: 날짜, 거래시간, 태양광_합계, 풍력_육지
출력: renewables_generation_mwh.csv (date, hour, solar_mainland, wind_mainland)
"""

import pandas as pd
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)


def main():
    filepath = os.path.join(RAW_DIR, "재생에너지_발전량_2024.csv")

    # 인코딩 자동 탐지
    for enc in ['utf-8', 'cp949', 'euc-kr']:
        try:
            df = pd.read_csv(filepath, encoding=enc)
            break
        except UnicodeDecodeError:
            continue

    print(f"원본 컬럼: {list(df.columns)}")
    print(f"원본 행수: {len(df)}")

    # 컬럼 매핑
    col_map = {}
    for col in df.columns:
        lc = col.strip().lower()
        if '날짜' in lc or 'date' in lc:
            col_map[col] = 'date'
        elif '거래시간' in lc or '시간' in lc or 'hour' in lc:
            col_map[col] = 'hour'
        elif '태양광' in lc or 'solar' in lc:
            col_map[col] = 'solar_mainland'
        elif '풍력' in lc and ('육지' in lc or 'land' in lc or '합계' not in lc):
            col_map[col] = 'wind_mainland'
        elif '풍력' in lc:
            if 'wind_mainland' not in col_map.values():
                col_map[col] = 'wind_mainland'

    df = df.rename(columns=col_map)

    # 필요한 열만 추출
    required = ['date', 'hour', 'solar_mainland', 'wind_mainland']
    for r in required:
        if r not in df.columns:
            raise ValueError(f"필수 컬럼 '{r}' 없음. 현재 컬럼: {list(df.columns)}")

    df = df[required].copy()

    # 타입 변환
    df['hour'] = pd.to_numeric(df['hour'], errors='coerce').astype(int)
    df['solar_mainland'] = pd.to_numeric(df['solar_mainland'], errors='coerce').fillna(0.0)
    df['wind_mainland'] = pd.to_numeric(df['wind_mainland'], errors='coerce').fillna(0.0)

    # 날짜 정규화
    df['date'] = df['date'].astype(str).str.replace('/', '-')

    df = df.sort_values(['date', 'hour']).reset_index(drop=True)

    print(f"결과: {len(df)}행")
    print(f"  태양광: {df['solar_mainland'].min():.1f}~{df['solar_mainland'].max():.1f} MW")
    print(f"  풍력: {df['wind_mainland'].min():.1f}~{df['wind_mainland'].max():.1f} MW")

    out_path = os.path.join(OUT_DIR, "renewables_generation_mwh.csv")
    df.to_csv(out_path, index=False, encoding='utf-8')
    print(f"✓ renewables_generation_mwh.csv 저장: {out_path}")


if __name__ == '__main__':
    main()
