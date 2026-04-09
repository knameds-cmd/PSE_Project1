"""
run_all_preprocessing.py — 모든 전처리 스크립트를 순서대로 실행
============================================================
"""

import subprocess
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

scripts = [
    "parse_matpower.py",
    "preprocess_smp_demand.py",
    "preprocess_renewables.py",
    "preprocess_renewables_capacity.py",
    "preprocess_fuel_costs.py",
    "preprocess_nuclear_mustoff.py",
    "preprocess_marginal_fuel.py",
]

def main():
    print("=" * 70)
    print("  전처리 파이프라인 실행")
    print("=" * 70)

    failed = []
    for script in scripts:
        path = os.path.join(SCRIPT_DIR, script)
        print(f"\n{'─' * 70}")
        print(f"  실행: {script}")
        print(f"{'─' * 70}")

        result = subprocess.run(
            [sys.executable, path],
            capture_output=False,
            text=True
        )
        if result.returncode != 0:
            failed.append(script)
            print(f"  ✗ {script} 실패 (exit code {result.returncode})")
        else:
            print(f"  ✓ {script} 완료")

    print(f"\n{'=' * 70}")
    if failed:
        print(f"  실패: {', '.join(failed)}")
    else:
        print("  모든 전처리 완료!")

    # processed 디렉토리 확인
    processed_dir = os.path.join(SCRIPT_DIR, "..", "processed")
    if os.path.isdir(processed_dir):
        files = sorted(os.listdir(processed_dir))
        print(f"\n  processed/ 파일 목록:")
        for f in files:
            size = os.path.getsize(os.path.join(processed_dir, f))
            print(f"    {f} ({size:,} bytes)")
    print("=" * 70)


if __name__ == '__main__':
    main()
