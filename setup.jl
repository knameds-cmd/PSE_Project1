# ============================================================
# setup.jl  ─  최초 1회 실행: 패키지 설치
# 사용법:  julia setup.jl
# ============================================================

import Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

println("\n✓ 모든 패키지가 설치되었습니다. 이제 run_basic.jl을 실행하세요.")
println("  julia --project=. src/run_basic.jl")
