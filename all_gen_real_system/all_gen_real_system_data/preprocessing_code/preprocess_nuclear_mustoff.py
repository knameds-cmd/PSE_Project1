"""
preprocess_nuclear_mustoff.py — 원전 계획예방정비 → nuclear_must_off.csv
====================================================================
입력: 한국수력원자력(주)_원전 호기별 계획예방정비 현황.csv (CP949)
출력: nuclear_must_off.csv (2024년 정비 일정)

컬럼: id, unit_name, off_start_date, off_end_date, off_start_day, off_end_day, duration_days
"""

import pandas as pd
import os
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(SCRIPT_DIR, "..", "raw_data")
OUT_DIR = os.path.join(SCRIPT_DIR, "..", "processed")
os.makedirs(OUT_DIR, exist_ok=True)


def date_to_day_of_year(date_str, year=2024):
    """날짜 문자열 → 연중 일수 (1~366)."""
    for fmt in ['%Y-%m-%d', '%Y/%m/%d', '%Y.%m.%d', '%Y%m%d']:
        try:
            dt = datetime.strptime(str(date_str).strip(), fmt)
            return dt.timetuple().tm_yday
        except ValueError:
            continue
    return None


def main():
    filepath = os.path.join(RAW_DIR, "한국수력원자력(주)_원전 호기별 계획예방정비 현황.csv")

    for enc in ['cp949', 'euc-kr', 'utf-8']:
        try:
            df = pd.read_csv(filepath, encoding=enc)
            break
        except UnicodeDecodeError:
            continue

    print(f"원본 컬럼: {list(df.columns)}")
    print(f"원본 행수: {len(df)}")
    if len(df) > 0:
        print(f"샘플:\n{df.head()}")

    # 컬럼 식별
    year_col = None
    unit_col = None
    start_col = None
    end_col = None
    duration_col = None

    for col in df.columns:
        lc = col.strip()
        if '연도' in lc or 'year' in lc.lower():
            year_col = col
        elif '호기' in lc or 'unit' in lc.lower():
            unit_col = col
        elif '시작' in lc and ('예정' in lc or '정비' in lc or '일' in lc):
            start_col = col
        elif '종료' in lc and ('예정' in lc or '정비' in lc or '일' in lc):
            end_col = col
        elif '기간' in lc and '예정' in lc:
            duration_col = col

    # 시작/종료 컬럼을 못 찾으면 위치 기반으로 시도
    if start_col is None or end_col is None:
        for col in df.columns:
            lc = col.strip()
            if '시작' in lc and start_col is None:
                start_col = col
            elif '종료' in lc and end_col is None:
                end_col = col

    print(f"\n매핑: 연도={year_col}, 호기={unit_col}, 시작={start_col}, 종료={end_col}")

    if year_col is None or unit_col is None:
        print("필수 컬럼을 찾을 수 없습니다.")
        print("모든 컬럼과 첫 행:")
        for col in df.columns:
            print(f"  '{col}': {df[col].iloc[0] if len(df)>0 else 'N/A'}")
        return

    # 2024년 필터
    df[year_col] = pd.to_numeric(df[year_col], errors='coerce')
    df_2024 = df[df[year_col] == 2024].copy()
    print(f"\n2024년 정비 건수: {len(df_2024)}")

    if len(df_2024) == 0:
        # 가장 최근 연도 데이터 사용
        available_years = sorted(df[year_col].dropna().unique())
        print(f"사용 가능한 연도: {available_years}")
        if available_years:
            latest = int(available_years[-1])
            df_2024 = df[df[year_col] == latest].copy()
            print(f"→ {latest}년 데이터 {len(df_2024)}건 사용")

    # 결과 생성
    records = []
    for idx, row in df_2024.iterrows():
        unit_name = str(row[unit_col]).strip()

        start_date = str(row[start_col]).strip() if start_col and pd.notna(row.get(start_col)) else ''
        end_date = str(row[end_col]).strip() if end_col and pd.notna(row.get(end_col)) else ''

        start_day = date_to_day_of_year(start_date)
        end_day = date_to_day_of_year(end_date)

        if start_day is None or end_day is None:
            print(f"  ⚠ 날짜 파싱 실패: {unit_name}, 시작={start_date}, 종료={end_date}")
            continue

        # 연말~연초 걸치는 정비 처리 (예: 12/20 ~ 다음해 2/27)
        if end_day < start_day:
            # 2024년은 366일 (윤년)
            # 2024년 내 구간만 기록 (start_day ~ 366)
            records.append({
                'id': len(records) + 1,
                'unit_name': unit_name,
                'off_start_date': start_date,
                'off_end_date': end_date,
                'off_start_day': start_day,
                'off_end_day': 366,
                'duration_days': 366 - start_day + 1
            })
        else:
            records.append({
                'id': len(records) + 1,
                'unit_name': unit_name,
                'off_start_date': start_date,
                'off_end_date': end_date,
                'off_start_day': start_day,
                'off_end_day': end_day,
                'duration_days': end_day - start_day + 1
            })

    result = pd.DataFrame(records)
    print(f"\n정비 일정 {len(result)}건:")
    for _, row in result.iterrows():
        print(f"  {row['unit_name']}: Day {row['off_start_day']}~{row['off_end_day']} ({row['duration_days']}일)")

    out_path = os.path.join(OUT_DIR, "nuclear_must_off.csv")
    result.to_csv(out_path, index=False, encoding='utf-8')
    print(f"\n✓ nuclear_must_off.csv 저장: {out_path}")


if __name__ == '__main__':
    main()
