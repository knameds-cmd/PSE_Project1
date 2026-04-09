# -*- coding: utf-8 -*-
"""
PSE 프로젝트 보고서 PDF 생성
재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석
"""

from fpdf import FPDF
import os

FONT_DIR = "C:/Windows/Fonts"
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "outputs")

class ReportPDF(FPDF):
    def __init__(self):
        super().__init__('P', 'mm', 'A4')
        # 한글 폰트 등록
        self.add_font("malgun", "", os.path.join(FONT_DIR, "malgun.ttf"))
        self.add_font("malgun", "B", os.path.join(FONT_DIR, "malgunbd.ttf"))
        self.set_auto_page_break(auto=True, margin=25)
        self.chapter_num = 0

    # ── 헤더/푸터 ──
    def header(self):
        if self.page_no() > 1:
            self.set_font("malgun", "", 8)
            self.set_text_color(120, 120, 120)
            self.cell(0, 6, "재생에너지 입찰제 도입에 따른 한국 육지계통 SMP 변화 분석", align="L")
            self.ln(8)
            self.set_draw_color(200, 200, 200)
            self.line(10, self.get_y(), 200, self.get_y())
            self.ln(3)

    def footer(self):
        self.set_y(-15)
        self.set_font("malgun", "", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 10, f"- {self.page_no()} -", align="C")

    # ── 유틸리티 ──
    def section_title(self, num, title):
        """장 제목 (예: 1. 서론)"""
        self.set_font("malgun", "B", 16)
        self.set_text_color(25, 60, 120)
        self.ln(6)
        self.cell(0, 12, f"{num}.  {title}", new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(25, 60, 120)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(5)

    def sub_title(self, num, title):
        """절 제목 (예: 1.1 배경)"""
        self.set_font("malgun", "B", 12)
        self.set_text_color(40, 80, 140)
        self.ln(3)
        self.cell(0, 9, f"{num}  {title}", new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

    def sub_sub_title(self, title):
        """소절 제목"""
        self.set_font("malgun", "B", 10.5)
        self.set_text_color(60, 60, 60)
        self.ln(2)
        self.cell(0, 7, title, new_x="LMARGIN", new_y="NEXT")
        self.ln(1)

    def body(self, text):
        """본문 텍스트"""
        self.set_font("malgun", "", 10)
        self.set_text_color(30, 30, 30)
        self.multi_cell(0, 6, text)
        self.ln(1)

    def formula(self, text):
        """수식 블록"""
        self.set_font("malgun", "", 10)
        self.set_fill_color(245, 245, 250)
        self.set_text_color(40, 40, 80)
        x = self.get_x()
        self.set_x(x + 10)
        self.multi_cell(170, 6.5, text, fill=True)
        self.set_x(x)
        self.ln(2)

    def bullet(self, text):
        """불릿 항목"""
        self.set_font("malgun", "", 10)
        self.set_text_color(30, 30, 30)
        x = self.get_x()
        self.set_x(x + 6)
        self.cell(5, 6, chr(8226))
        self.multi_cell(165, 6, text)
        self.set_x(x)
        self.ln(0.5)

    def table_header(self, col_widths, headers):
        """테이블 헤더"""
        self.set_font("malgun", "B", 9)
        self.set_fill_color(40, 70, 120)
        self.set_text_color(255, 255, 255)
        for w, h in zip(col_widths, headers):
            self.cell(w, 7, h, border=1, fill=True, align="C")
        self.ln()

    def table_row(self, col_widths, cells, highlight=False):
        """테이블 행"""
        self.set_font("malgun", "", 9)
        if highlight:
            self.set_fill_color(230, 240, 255)
        else:
            self.set_fill_color(255, 255, 255)
        self.set_text_color(30, 30, 30)
        for w, c in zip(col_widths, cells):
            self.cell(w, 6.5, str(c), border=1, fill=True, align="C")
        self.ln()

    def check_page_space(self, needed_mm=40):
        """페이지 여백 확인, 부족하면 페이지 넘김"""
        if self.get_y() + needed_mm > 270:
            self.add_page()


def build_report():
    pdf = ReportPDF()

    # ================================================================
    # 표지
    # ================================================================
    pdf.add_page()
    pdf.ln(50)
    pdf.set_font("malgun", "B", 24)
    pdf.set_text_color(25, 50, 100)
    pdf.cell(0, 14, "재생에너지 입찰제 도입에 따른", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 14, "한국 육지계통 SMP 변화 분석", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(10)
    pdf.set_draw_color(25, 60, 120)
    pdf.line(50, pdf.get_y(), 160, pdf.get_y())
    pdf.ln(12)
    pdf.set_font("malgun", "", 13)
    pdf.set_text_color(80, 80, 80)
    pdf.cell(0, 9, "Economic Dispatch 모델 기반 시나리오 분석", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(8)
    pdf.set_font("malgun", "", 11)
    pdf.cell(0, 8, "전력시스템경제 프로젝트 보고서", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(35)
    pdf.set_font("malgun", "", 11)
    pdf.set_text_color(60, 60, 60)
    pdf.cell(0, 8, "구현 환경: Julia 1.12 + JuMP + HiGHS", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 8, "2024-2025", align="C", new_x="LMARGIN", new_y="NEXT")

    # ================================================================
    # 목차
    # ================================================================
    pdf.add_page()
    pdf.set_font("malgun", "B", 18)
    pdf.set_text_color(25, 50, 100)
    pdf.cell(0, 14, "목 차", align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(10)
    toc = [
        ("1", "서론: 연구 배경 및 목적"),
        ("2", "분석 프레임워크 개요"),
        ("3", "수학적 모델: Basic Economic Dispatch"),
        ("4", "수학적 모델: Pre-revision ED (현행 제도 모사)"),
        ("5", "Calibration: Price Adder 추정"),
        ("6", "수학적 모델: Post-revision ED (입찰제 도입)"),
        ("7", "재생에너지 입찰블록 설계"),
        ("8", "SMP 결정 메커니즘: LP Dual 방식"),
        ("9", "시나리오 설계 및 민감도 분석"),
        ("10", "분석 결과"),
        ("11", "결론 및 시사점"),
    ]
    for num, title in toc:
        pdf.set_font("malgun", "", 11)
        pdf.set_text_color(30, 30, 30)
        pdf.cell(10, 8, num + ".")
        pdf.cell(0, 8, title, new_x="LMARGIN", new_y="NEXT")
    pdf.ln(5)

    # ================================================================
    # 1. 서론
    # ================================================================
    pdf.add_page()
    pdf.section_title("1", "서론: 연구 배경 및 목적")

    pdf.sub_title("1.1", "연구 배경")
    pdf.body(
        "한국 전력시장은 비용기반풀(CBP) 방식으로 운영되며, 계통한계가격(SMP)은 "
        "수급균형 제약의 한계비용(marginal cost)으로 결정된다. 현행 제도에서 재생에너지는 "
        "'음의 부하(negative load)'로 취급되어 순수요를 줄이는 역할만 하며, "
        "SMP 결정에 직접 참여하지 못한다."
    )
    pdf.body(
        "그러나 2024년 제주계통에서 시범 시행된 '재생에너지 입찰제'에서는 재생에너지 발전사업자가 "
        "전력시장에 직접 입찰할 수 있게 되어, 공급곡선(supply curve)에 포함되고 "
        "SMP 결정에 참여하는 '가격결정 자격(price-setting qualification)'을 갖는다. "
        "이 연구는 해당 제도를 육지계통에 확대 적용할 경우 SMP에 미치는 영향을 "
        "정량적으로 분석한다."
    )

    pdf.sub_title("1.2", "연구 목적")
    pdf.bullet("현행 제도(Pre-revision)와 입찰제 도입(Post-revision) 간 SMP 변화(DELTA SMP) 도출")
    pdf.bullet("4개 입찰전략 시나리오별 효과 비교")
    pdf.bullet("하한가 계수(beta)와 입찰참여율(rho) 민감도 분석")
    pdf.bullet("정책적 시사점 도출")

    pdf.sub_title("1.3", "분석 범위")
    pdf.body(
        "대상: 한국 육지계통(제주 제외). 시간 범위: 1일(24시간) 단위 분석. "
        "분석 대상일: 봄철 경부하-고재생에너지 침투일(RE가 SMP에 가장 큰 영향을 미치는 조건). "
        "모델: 선형계획법(LP) 기반 Economic Dispatch. "
        "도구: Julia 1.12 + JuMP(최적화 모델링) + HiGHS(LP 솔버)."
    )

    # ================================================================
    # 2. 분석 프레임워크
    # ================================================================
    pdf.add_page()
    pdf.section_title("2", "분석 프레임워크 개요")

    pdf.sub_title("2.1", "5단계 파이프라인")
    pdf.body("본 연구는 다음 5단계 파이프라인으로 구성된다:")
    pdf.ln(2)

    pdf.sub_sub_title("PHASE 1: Basic ED (교과서형 기준선)")
    pdf.body(
        "단순 한계비용, 출력상한만 있는 교과서적 ED 모델을 풀어 기준 SMP를 도출한다. "
        "최소출력, 램프 제약 등이 없어 '이상적' 시장을 나타낸다."
    )

    pdf.sub_sub_title("PHASE 2: Calibration (Price Adder 추정)")
    pdf.body(
        "Basic ED로는 재현할 수 없는 기동/정지 비용, 무부하 비용 등의 효과를 "
        "Price Adder라는 보정항으로 흡수한다. 실제 SMP와의 오차를 반복적으로 줄여간다."
    )

    pdf.sub_sub_title("PHASE 3: Pre-revision ED (현행 제도 SMP 재현)")
    pdf.body(
        "유효 한계비용 + Price Adder, 최소출력, 램프 제약, must-run을 반영한 ED 모델. "
        "현행 제도에서 RE는 '음의 부하'로 처리되어 SMP 결정에 직접 참여하지 않는다. "
        "이 모델의 SMP가 '기준선(baseline)'이 된다."
    )

    pdf.sub_sub_title("PHASE 4: Post-revision ED (입찰제 도입 후 SMP)")
    pdf.body(
        "RE의 일부(입찰참여분)를 4개 입찰블록으로 분할하여 공급곡선에 직접 참여시킨다. "
        "열발전과 RE 블록이 통합 최적화되며, LP dual이 SMP를 결정한다. "
        "4개 시나리오(A/B/C/D)별로 입찰가를 달리하여 비교한다."
    )

    pdf.sub_sub_title("PHASE 5: 민감도 분석")
    pdf.body(
        "하한가 계수(beta = 1.5, 2.0, 2.5)와 입찰참여율(rho = 0.1, 0.2, 0.3, 0.5)을 "
        "변경하여 결과의 강건성과 주요 영향 인자를 파악한다."
    )

    pdf.sub_title("2.2", "핵심 측정 지표")
    pdf.formula(
        "DELTA SMP_t  =  SMP_post_t  -  SMP_pre_t\n"
        "Mean DELTA   =  (1/T) * SUM_t (DELTA SMP_t)\n"
        "MAE          =  (1/T) * SUM_t |SMP_model_t - SMP_actual_t|\n"
        "RMSE         =  sqrt( (1/T) * SUM_t (SMP_model_t - SMP_actual_t)^2 )"
    )

    # ================================================================
    # 3. Basic ED
    # ================================================================
    pdf.add_page()
    pdf.section_title("3", "수학적 모델: Basic Economic Dispatch")

    pdf.sub_title("3.1", "모델 개요")
    pdf.body(
        "Basic ED는 가장 단순한 경제급전 모델로, 각 발전기의 한계비용이 일정하고 "
        "시간간 결합(램프, 기동/정지)이 없는 LP 문제이다. "
        "실제 시장과의 괴리가 크지만, 분석의 출발점으로 사용한다."
    )

    pdf.sub_title("3.2", "수식 정의")

    pdf.sub_sub_title("[B1] 목적함수: 총 발전비용 최소화")
    pdf.formula("min  SUM_{t=1}^{T} SUM_{g=1}^{G}  c_g * p_{g,t}")
    pdf.body("c_g: 클러스터 g의 한계비용 [원/MWh] (시간 불변 상수)")
    pdf.body("p_{g,t}: 클러스터 g의 시간 t 발전출력 [MW]")

    pdf.sub_sub_title("[B2] 수급균형 제약")
    pdf.formula("SUM_{g=1}^{G} p_{g,t}  =  D_t - RE_t      (for all t = 1, ..., T)")
    pdf.body(
        "D_t는 시간 t의 전력수요 [MW], RE_t는 재생에너지 발전량 [MW]이다. "
        "RE는 '음의 부하(negative load)'로 처리되어 수요에서 차감된다. "
        "우변의 D_t - RE_t를 '순수요(net demand)'라 한다."
    )

    pdf.sub_sub_title("[B3] 출력상한 제약")
    pdf.formula("0  <=  p_{g,t}  <=  P_g^max      (for all g, t)")

    pdf.sub_sub_title("[B4] SMP 해석: LP Dual")
    pdf.formula("SMP_t  =  lambda_t  =  dual( 수급균형 제약_t )")
    pdf.body(
        "LP의 수급균형 제약에 대한 쌍대변수(dual variable, shadow price)가 SMP이다. "
        "이것은 '수요가 1 MW 증가할 때 총비용의 변화량', 즉 경제학적 한계비용을 나타낸다. "
        "최적해에서 부분투입(0 < gen < pmax) 상태인 발전기의 한계비용과 일치한다."
    )

    pdf.sub_title("3.3", "한계연료원 식별")
    pdf.body(
        "각 시간대에서 SMP를 결정하는 한계연료원(marginal fuel)을 식별한다. "
        "부분투입 상태(0 < gen < pmax)인 클러스터 중 비용이 가장 높은 것이 한계연료원이다. "
        "모든 클러스터가 최소 또는 최대출력에 있으면, 투입된 클러스터 중 최고비용을 한계연료원으로 간주한다."
    )

    # ================================================================
    # 4. Pre-revision ED
    # ================================================================
    pdf.add_page()
    pdf.section_title("4", "수학적 모델: Pre-revision ED")

    pdf.sub_title("4.1", "모델 개요")
    pdf.body(
        "현행 한국 CBP 시장을 보다 정확히 모사하기 위해 Basic ED에 다음을 추가한다: "
        "(1) 유효 한계비용(시간가변), (2) 최소출력 제약(must-run), "
        "(3) 시간간 램프 제약, (4) 초과공급 시 RE 출력제한 반영."
    )

    pdf.sub_title("4.2", "유효 한계비용 [P1]")
    pdf.formula(
        "c_tilde_{g,t}  =  HR_g  x  FuelPrice_f  +  VOM_g  +  A_{g,t}"
    )
    pdf.body(
        "HR_g는 열소비율 [Gcal/MWh], FuelPrice_f는 연료단가 [원/Gcal], "
        "VOM_g는 변동운영비 [원/MWh], A_{g,t}는 Price Adder [원/MWh]이다. "
        "Price Adder는 UC 미모형 요소(기동비, 무부하비 등)를 흡수하는 보정항으로 "
        "Calibration 과정에서 추정된다."
    )

    pdf.check_page_space(50)
    pdf.sub_title("4.3", "목적함수 [P2]")
    pdf.formula("min  SUM_t SUM_g  c_tilde_{g,t} * p_{g,t}")

    pdf.sub_title("4.4", "수급균형 제약 [P3]")
    pdf.formula("SUM_g p_{g,t}  =  D_t - RE_effective_t      (for all t)")
    pdf.body("RE_effective_t는 초과공급 방지를 위해 사전 cap된 재생에너지 발전량이다 (4.7절 참조).")

    pdf.sub_title("4.5", "최소-최대 출력 제약 [P4]")
    pdf.formula(
        "must-run 발전기:   P_g^min  <=  p_{g,t}  <=  P_g^max\n"
        "일반 발전기:       0        <=  p_{g,t}  <=  P_g^max"
    )
    pdf.body(
        "must-run 발전기(원전, 열병합 등)는 열공급 의무나 계통 안정성 등의 이유로 "
        "최소출력(P_g^min) 이상을 반드시 발전해야 한다."
    )

    pdf.sub_title("4.6", "램프 제약 [P5]")
    pdf.formula(
        "p_{g,t} - p_{g,t-1}  <=  RU_g    (상향 램프, t >= 2)\n"
        "p_{g,t-1} - p_{g,t}  <=  RD_g    (하향 램프, t >= 2)"
    )
    pdf.body(
        "발전기가 1시간에 증감할 수 있는 출력의 한계를 나타낸다. "
        "원전은 느리고(600 MW/h), 가스터빈은 빠르다(5,000 MW/h)."
    )

    pdf.check_page_space(55)
    pdf.sub_title("4.7", "RE 출력제한 (사전 Cap) 처리")
    pdf.body(
        "현행 시장에서 초과공급(RE + must-run > 수요)이 발생하면 계통운영자가 "
        "RE에 출력제한 명령을 발동한다. 이를 LP 풀기 전에 사전 처리한다:"
    )
    pdf.formula(
        "must_run_min = SUM(P_g^min, for g in must-run)\n"
        "max_re_t = D_t - must_run_min\n"
        "RE_effective_t = min(RE_t, max(0, max_re_t))"
    )
    pdf.body(
        "핵심: 이 처리를 LP 내부의 결정변수(curtailment slack)로 넣으면 "
        "슬랙의 페널티 비용이 LP dual(=SMP)에 포함되어 SMP가 왜곡된다. "
        "LP 외부에서 사전 cap하면 깨끗한 dual을 얻을 수 있다."
    )

    # ================================================================
    # 5. Calibration
    # ================================================================
    pdf.add_page()
    pdf.section_title("5", "Calibration: Price Adder 추정")

    pdf.sub_title("5.1", "필요성")
    pdf.body(
        "ED 모델은 단위기약(Unit Commitment)의 기동비/정지비/무부하비 등을 모형하지 않으므로 "
        "실제 SMP와 괴리가 발생한다. Price Adder는 이러한 UC 미모형 요소를 "
        "한계비용에 더하는 보정항으로, 모형 SMP를 실제 SMP에 근사시킨다."
    )

    pdf.sub_title("5.2", "반복 보정 알고리즘")
    pdf.body("다음 절차로 Price Adder를 반복 추정한다:")
    pdf.ln(1)
    pdf.body(
        "[초기화] adder[g,t] = 0  (G개 클러스터 x T시간)\n\n"
        "[반복 (iter = 1, ..., max_iter)]:\n"
        "  1. Pre-ED를 풀어 SMP 추출\n"
        "  2. 검증지표 계산 (MAE, RMSE)\n"
        "  3. MAE < 목표값이면 종료\n"
        "  4. 각 시간대 t에서:\n"
        "     error_t = actual_smp[t] - model_smp[t]\n"
        "     부분투입(한계) 클러스터 g에 대해:\n"
        "       adder[g,t] += learning_rate * error_t"
    )

    pdf.sub_title("5.3", "핵심 원리")
    pdf.body(
        "SMP는 한계발전기(부분투입 상태)의 비용에 의해 결정된다. "
        "따라서 한계발전기의 adder만 조정해야 SMP가 변한다. "
        "비한계 발전기(최소 또는 최대출력에 고정)의 adder를 조정해도 SMP에 영향이 없다."
    )
    pdf.body(
        "학습률(learning_rate = 0.4)은 수렴 속도와 안정성의 균형을 맞추는 하이퍼파라미터이다. "
        "최대 반복횟수는 15회, 목표 MAE는 3,000 원/MWh로 설정한다."
    )

    # ================================================================
    # 6. Post-revision ED
    # ================================================================
    pdf.add_page()
    pdf.section_title("6", "수학적 모델: Post-revision ED")

    pdf.sub_title("6.1", "모델 개요")
    pdf.body(
        "재생에너지 입찰제 도입 후의 시장을 모사한다. Pre-revision ED와의 핵심 차이점은 "
        "RE의 일부(입찰참여분)가 입찰블록으로 공급곡선에 직접 참여하여 "
        "가격결정 자격을 갖는다는 것이다."
    )

    pdf.sub_title("6.2", "RE 분리 구조")
    pdf.formula(
        "RE_total  =  RE_nonbid  +  RE_bid\n\n"
        "RE_nonbid  =  (1 - rho) * RE_total    (비입찰분: 음의 부하 처리)\n"
        "RE_bid     =  rho * RE_total           (입찰분: 4개 블록으로 분할)"
    )
    pdf.body(
        "rho(입찰참여율)는 전체 RE 중 입찰제에 참여하는 비율이다 (기본값 0.3 = 30%). "
        "비입찰분은 현행과 동일하게 음의 부하로 처리되고, "
        "입찰분은 공급곡선에 별도의 입찰블록으로 참여한다."
    )

    pdf.sub_title("6.3", "목적함수 [R1]")
    pdf.formula(
        "min  SUM_t [ SUM_g c_tilde_{g,t} * p_{g,t}\n"
        "           + SUM_k b_{k,t} * r_{k,t}\n"
        "           + M * curt_t ]"
    )
    pdf.body(
        "p_{g,t}: 열발전 출력. r_{k,t}: RE 입찰블록 k의 낙찰량. "
        "b_{k,t}: RE 블록 k의 입찰가 [원/MWh]. "
        "curt_t: 비입찰 RE 출력제한량 (M = 500,000원 페널티로 억제)."
    )

    pdf.sub_title("6.4", "수급균형 제약 [R2]")
    pdf.formula(
        "SUM_g p_{g,t}  +  SUM_k r_{k,t}  +  RE_nonbid_t  -  curt_t  =  D_t"
    )
    pdf.body(
        "Pre-ED와의 결정적 차이: '순수요'가 아닌 '총수요' D_t를 사용한다. "
        "열발전(p), RE 입찰블록(r), 비입찰 RE(RE_nonbid)가 모두 공급측에서 "
        "하나의 최적화 문제로 통합된다."
    )

    pdf.sub_title("6.5", "RE 블록 제약 [R3]")
    pdf.formula("0  <=  r_{k,t}  <=  R_bar_{k,t}      (for all k, t)")
    pdf.body("R_bar_{k,t}는 블록 k의 시간 t 공급가능량 상한 [MW]이다.")

    pdf.sub_title("6.6", "기타 제약")
    pdf.body(
        "열발전의 최소-최대출력 제약 [P4]와 램프 제약 [P5]는 Pre-ED와 동일하게 유지한다. "
        "비입찰 RE의 출력제한은 0 <= curt_t <= RE_nonbid_t로 제한한다."
    )

    # ================================================================
    # 7. RE 입찰블록 설계
    # ================================================================
    pdf.add_page()
    pdf.section_title("7", "재생에너지 입찰블록 설계")

    pdf.sub_title("7.1", "블록 구조: 4블록 분할")
    pdf.body(
        "태양광(PV)과 풍력(Wind) 각각을 Low/High 두 블록으로 분할하여 총 4개 블록을 구성한다. "
        "이는 실제 입찰 시 발전사업자가 물량을 나누어 다른 가격으로 입찰할 수 있음을 반영한다."
    )
    pdf.formula(
        "PV_low  = w_low * rho_pv * avail_pv     (w_low = 0.6)\n"
        "PV_high = w_high * rho_pv * avail_pv     (w_high = 0.4)\n"
        "W_low   = w_low * rho_w * avail_w\n"
        "W_high  = w_high * rho_w * avail_w"
    )

    pdf.sub_title("7.2", "입찰 하한가 [R4]")
    pdf.formula("BidFloor  =  -beta  x  REC_price  x  1000   [원/MWh]")
    pdf.body(
        "beta: 하한가 계수 (제주 시범 2.5, 본 분석 기본값 2.0). "
        "REC_price: 신재생에너지 공급인증서 평균가격 (80 원/kWh). "
        "x 1000: kWh -> MWh 단위 변환. "
        "기본값: BidFloor = -2.0 x 80 x 1000 = -160,000 원/MWh."
    )
    pdf.body(
        "하한가가 음수인 이유: RE 사업자는 발전하면 REC 수입을 얻으므로, "
        "전력시장에서 REC 가치만큼 손해를 감수하고도 발전하는 것이 유리할 수 있다. "
        "하한가는 이 '감수 가능한 손해'의 상한을 정한다."
    )

    pdf.check_page_space(65)
    pdf.sub_title("7.3", "시나리오별 입찰가격")

    cw = [45, 40, 40, 55]
    pdf.table_header(cw, ["시나리오", "Low 블록 입찰가", "High 블록 입찰가", "정책적 의미"])
    pdf.table_row(cw, ["Case A (zero)", "0", "0", "최소 영향 입찰"])
    pdf.table_row(cw, ["Case B (floor)", "-160,000", "-160,000", "최대 공격적 입찰"])
    pdf.table_row(cw, ["Case C (mixed)", "-160,000", "0", "현실적 혼합 전략"], highlight=True)
    pdf.table_row(cw, ["Case D (conserv.)", "-80,000", "0", "보수적 전략"])
    pdf.ln(3)

    pdf.body(
        "Case A: 모든 블록이 0원으로 입찰 -> 초과공급 시 SMP 하한이 0원.\n"
        "Case B: 모든 블록이 하한가로 입찰 -> SMP가 최대한 하락.\n"
        "Case C: Low 블록은 공격적(하한가), High 블록은 보수적(0원) -> 가장 현실적.\n"
        "Case D: Low 블록을 하한가의 50%로 입찰 -> 보수적 전략."
    )

    # ================================================================
    # 8. SMP 결정 메커니즘
    # ================================================================
    pdf.add_page()
    pdf.section_title("8", "SMP 결정 메커니즘: LP Dual 방식")

    pdf.sub_title("8.1", "LP Dual의 경제학적 의미")
    pdf.formula("SMP_t  =  dual(balance_t)  =  dC* / dD_t")
    pdf.body(
        "LP의 수급균형 제약에 대한 쌍대변수(dual)는 '수요가 1 MW 증가할 때 "
        "총비용(최적 목적함수값)의 변화량'이다. 이것은 경제학적 한계비용(marginal cost)과 "
        "정확히 일치하며, 전력시장의 SMP 결정 원리 자체이다."
    )

    pdf.sub_title("8.2", "Pre-ED vs Post-ED의 SMP 차이")
    pdf.body("두 모델의 수급균형 제약 구조가 다르기 때문에 LP dual도 다르다:")
    pdf.ln(1)
    pdf.sub_sub_title("Pre-ED:")
    pdf.formula("SUM_g p_{g,t}  =  D_t - RE_total_t     -> dual = thermal marginal cost")
    pdf.body("RE 전체가 수요에서 차감되므로, SMP는 열발전의 한계비용만 반영한다.")
    pdf.ln(1)
    pdf.sub_sub_title("Post-ED:")
    pdf.formula("SUM_g p_{g,t} + SUM_k r_{k,t} + RE_nonbid_t = D_t     -> dual = unified marginal")
    pdf.body(
        "열발전과 RE 입찰블록이 통합 급전순위에서 경쟁한다. "
        "초과공급 시간대에서 RE 블록이 한계유닛(부분 낙찰)이 되면, "
        "LP dual은 해당 RE 블록의 입찰가를 반영한다."
    )

    pdf.check_page_space(55)
    pdf.sub_title("8.3", "시나리오별 차별화 원리")
    pdf.body(
        "초과공급 시간대(RE가 풍부한 낮 시간)에서 RE 블록이 한계유닛이 되면, "
        "LP dual = RE 입찰가이다. 시나리오마다 입찰가가 다르므로 SMP도 달라진다:"
    )
    cw2 = [35, 35, 40, 50]
    pdf.table_header(cw2, ["시나리오", "한계 RE 입찰가", "LP dual (SMP)", "Pre 대비 효과"])
    pdf.table_row(cw2, ["Case A", "0", "~0", "SMP 하한 = 0"])
    pdf.table_row(cw2, ["Case B", "-160,000", "~-160,000", "SMP 극단적 하락"])
    pdf.table_row(cw2, ["Case C", "-160,000 or 0", "블록 의존", "혼합 효과"])
    pdf.table_row(cw2, ["Case D", "-80,000 or 0", "블록 의존", "완화된 하락"])
    pdf.ln(2)
    pdf.body(
        "비초과공급 시간대에서는 열발전이 한계유닛이므로, "
        "4개 시나리오 모두 동일한 SMP(= thermal marginal cost)를 보인다."
    )

    pdf.check_page_space(45)
    pdf.sub_title("8.4", "Curtailment 오염 보정")
    pdf.body(
        "비입찰 RE의 출력제한(curtailment)이 활성화되면 페널티(500,000원)가 "
        "LP dual에 포함될 수 있다. 이를 감지하여 부분투입 유닛 기반 폴백으로 대체한다:"
    )
    pdf.formula(
        "if |LP_dual| > 400,000:   -> curtailment 오염 의심\n"
        "   SMP = find_marginal_from_dispatch()\n"
        "else:\n"
        "   SMP = LP_dual"
    )
    pdf.body(
        "폴백 우선순위: (1) RE 부분투입 블록의 입찰가, "
        "(2) 열발전 부분투입 클러스터의 비용, "
        "(3) 투입된 유닛 중 최고비용."
    )

    pdf.check_page_space(50)
    pdf.sub_title("8.5", "왜 LP Dual을 사용하는가")
    pdf.body("이전 구현에서는 다음 휴리스틱을 사용했으나 구조적 결함이 있었다:")
    pdf.formula("SMP = max(thermal_marginal_cost, dispatched_RE_bid_max)")
    pdf.body(
        "문제점: 열발전과 RE가 동시에 부분투입일 때, max() 연산은 항상 "
        "양수인 열발전 비용을 선택하고 음수인 RE 입찰가는 무시한다. "
        "결과적으로 4개 시나리오의 SMP가 모두 동일해진다."
    )
    pdf.body(
        "LP dual은 이 문제가 없다. 최적화 과정에서 열발전과 RE가 통합된 "
        "급전순위에서의 정확한 한계비용을 자동으로 도출한다. "
        "또한 램프 제약 등 시간간 결합 효과도 정확히 반영한다."
    )

    # ================================================================
    # 9. 시나리오 설계
    # ================================================================
    pdf.add_page()
    pdf.section_title("9", "시나리오 설계 및 민감도 분석")

    pdf.sub_title("9.1", "기본 4개 시나리오")
    pdf.body(
        "4개 시나리오는 RE 입찰블록의 가격 전략만 다르고, "
        "나머지(열발전 비용, 수요, RE 가용량, 참여율 등)는 모두 동일하다. "
        "이를 통해 '입찰가격 전략'이 SMP에 미치는 순수한 효과를 분리한다."
    )

    pdf.sub_title("9.2", "시나리오 실행 과정")
    pdf.body(
        "각 시나리오는 동일한 5단계 과정을 거친다:\n\n"
        "1) 블록 생성: build_mainland_re_blocks()로 4개 RE 입찰블록 생성\n"
        "   -> 시나리오별 입찰가만 다르게 부여\n\n"
        "2) 입력 구성: PostEDInput 조립 (총수요, 비입찰RE, RE블록, Pre-ED 비용)\n\n"
        "3) LP 풀기: solve_post_ed()로 열발전+RE블록 통합 최적화\n"
        "   -> 결정변수: p[g,t] (열발전), r[k,t] (RE블록), curt[t] (출력제한)\n\n"
        "4) SMP 결정: determine_post_smp()로 LP dual 기반 SMP 도출\n\n"
        "5) DELTA SMP: compute_delta_smp()로 Pre SMP 대비 변화 분석"
    )

    pdf.check_page_space(45)
    pdf.sub_title("9.3", "beta 민감도 분석")
    pdf.body(
        "하한가 계수 beta를 변경하여 입찰 하한가의 크기가 SMP에 미치는 영향을 분석한다. "
        "시나리오는 mixed(C)로 고정하고, beta = 1.5, 2.0, 2.5를 비교한다."
    )
    pdf.formula(
        "beta = 1.5:  BidFloor = -120,000 원/MWh\n"
        "beta = 2.0:  BidFloor = -160,000 원/MWh\n"
        "beta = 2.5:  BidFloor = -200,000 원/MWh"
    )

    pdf.sub_title("9.4", "rho 민감도 분석")
    pdf.body(
        "입찰참여율 rho를 변경하여 RE 참여 규모가 SMP에 미치는 영향을 분석한다. "
        "rho = 0.1(10%), 0.2(20%), 0.3(30%), 0.5(50%)를 비교한다."
    )
    pdf.body(
        "rho가 작으면 RE 블록 용량이 작아 한계유닛이 되지 못하고 SMP 변화가 미미하다. "
        "rho가 크면 RE가 공급곡선의 큰 부분을 차지하여 시장 구조 자체가 변한다."
    )

    # ================================================================
    # 10. 분석 결과
    # ================================================================
    pdf.add_page()
    pdf.section_title("10", "분석 결과")

    pdf.sub_title("10.1", "입력 데이터 특성")
    pdf.body(
        "봄철 경부하일을 대상으로 분석하였다. "
        "수요 범위: 36,000 ~ 51,840 MW. "
        "RE 합산 범위: 3,750 ~ 32,250 MW (정오 태양광 최대). "
        "must-run 합계: 22,000 MW (원전 18,000 + CHP 4,000). "
        "낮 시간대(10~13시)에 must-run + RE > 수요인 초과공급이 발생하여, "
        "RE 입찰블록이 한계유닛이 되는 조건이 형성된다."
    )

    pdf.sub_title("10.2", "4개 시나리오 결과")

    cw3 = [32, 26, 26, 26, 22, 22, 26]
    pdf.table_header(cw3, ["시나리오", "평균 SMP", "평균 dSMP", "최대 하락", "하락h", "상승h", "RE낙찰MWh"])
    pdf.table_row(cw3, ["Pre(기준)", "44,116", "-", "-", "-", "-", "-"])
    pdf.table_row(cw3, ["A (zero)", "64,843", "+20,727", "-73,256", "5", "3", "61,795"])
    pdf.table_row(cw3, ["B (floor)", "50,332", "+6,216", "-160,000", "5", "2", "73,565"])
    pdf.table_row(cw3, ["C (mixed)", "53,965", "+9,849", "-160,000", "6", "3", "72,309"], highlight=True)
    pdf.table_row(cw3, ["D (conserv.)", "55,729", "+11,613", "-80,000", "8", "3", "67,615"])
    pdf.ln(3)

    pdf.sub_sub_title("결과 해석")
    pdf.body(
        "1) Case B(floor)가 평균 DELTA SMP를 가장 크게 낮춘다 (+6,216). "
        "모든 RE 블록이 하한가(-160,000원)로 입찰하면 초과공급 시간대에서 "
        "SMP가 -160,000원까지 하락하여 전체 평균을 끌어내린다.\n\n"
        "2) Case A(zero)는 오히려 평균 DELTA SMP가 가장 크다 (+20,727). "
        "RE가 0원으로 입찰하면 초과공급 시 SMP 하한이 0원으로 "
        "Pre-ED의 극단적 음수 SMP(-400,000원대)보다 높아지기 때문이다.\n\n"
        "3) Case C(mixed)와 D(conservative)의 차이: "
        "D의 Low 블록 입찰가(-80,000)가 C(-160,000)의 절반이므로, "
        "초과공급 시 SMP 하락폭이 더 작고 평균 DELTA SMP도 더 크다.\n\n"
        "4) 평균 DELTA SMP가 양수인 이유: Pre-ED는 RE 출력제한으로 인해 "
        "일부 시간대에 극단적 음수 SMP(-400,000원대)가 발생하지만, "
        "Post-ED에서는 RE 블록이 LP 내에서 조절되므로 이런 극단값이 완화된다."
    )

    pdf.check_page_space(65)
    pdf.sub_title("10.3", "beta 민감도 결과")

    cw4 = [30, 35, 30, 30, 30]
    pdf.table_header(cw4, ["beta", "BidFloor(원/MWh)", "평균 dSMP", "최대 하락", "RE낙찰MWh"])
    pdf.table_row(cw4, ["1.5", "-120,000", "+10,984", "-120,000", "71,469"])
    pdf.table_row(cw4, ["2.0", "-160,000", "+9,849", "-160,000", "72,309"])
    pdf.table_row(cw4, ["2.5", "-200,000", "+9,849", "-200,000", "72,309"])
    pdf.ln(3)
    pdf.body(
        "beta가 커지면 하한가(BidFloor)의 절대값이 증가하여 "
        "초과공급 시간대의 SMP 최대 하락폭이 비례적으로 커진다. "
        "그러나 beta 2.0과 2.5의 평균 DELTA SMP는 동일한데, "
        "이는 해당 시간대에서 이미 Low 블록이 한계유닛이 아닌 경우가 있기 때문이다."
    )

    pdf.check_page_space(60)
    pdf.sub_title("10.4", "rho 민감도 결과")

    cw5 = [25, 30, 30, 30, 30]
    pdf.table_header(cw5, ["rho", "평균 dSMP", "최대 하락", "하락 시간", "RE낙찰MWh"])
    pdf.table_row(cw5, ["0.1", "+20,018", "-2", "1", "17,690"])
    pdf.table_row(cw5, ["0.2", "+6,216", "-160,000", "5", "43,870"])
    pdf.table_row(cw5, ["0.3", "+9,849", "-160,000", "6", "72,309"])
    pdf.table_row(cw5, ["0.5", "+17,830", "-108,803", "6", "123,465"])
    pdf.ln(3)
    pdf.body(
        "rho = 0.1: RE 블록 용량이 작아(17,690 MWh) 한계유닛이 되는 시간이 1시간뿐이다. "
        "SMP 변화가 거의 없다.\n\n"
        "rho = 0.2: 임계 수준을 넘어 5시간에서 SMP 하락이 발생한다. "
        "RE 블록이 한계유닛이 되기에 충분한 용량이 확보된다.\n\n"
        "rho = 0.3 (기본값): 6시간 하락, 비입찰분이 여전히 70%로 충분히 크다.\n\n"
        "rho = 0.5: RE 낙찰량이 크게 증가(123,465 MWh)하지만 "
        "비입찰분 감소로 초과공급 구조가 변화하여 최대 하락폭이 오히려 줄어든다."
    )

    # ================================================================
    # 11. 결론
    # ================================================================
    pdf.add_page()
    pdf.section_title("11", "결론 및 시사점")

    pdf.sub_title("11.1", "주요 발견")

    pdf.bullet(
        "재생에너지 입찰제 도입 시, 입찰가격 전략에 따라 SMP에 유의미한 차이가 발생한다. "
        "특히 초과공급 시간대에서 RE 블록의 입찰가가 SMP를 직접 결정한다."
    )
    pdf.bullet(
        "Case B(하한가 전면 입찰)가 SMP를 가장 크게 낮추지만, "
        "이는 SMP가 극단적 음수(-160,000원)까지 하락함을 의미하여 "
        "시장 안정성 측면에서 주의가 필요하다."
    )
    pdf.bullet(
        "Case C(혼합 전략)와 D(보수적 전략)는 서로 다른 결과를 보이며, "
        "Low/High 블록 분할 비율과 입찰가 수준이 결과에 영향을 미친다."
    )
    pdf.bullet(
        "입찰참여율(rho)이 일정 수준(~20%) 이상이어야 SMP 효과가 본격화된다. "
        "rho = 10%에서는 거의 영향이 없다."
    )

    pdf.sub_title("11.2", "방법론적 시사점")

    pdf.bullet(
        "SMP 결정 방식으로 LP dual이 휴리스틱(max 연산)보다 정확하다. "
        "LP dual은 통합 급전순위에서의 한계비용을 자동으로 도출하며, "
        "시나리오별 차별화를 정확히 반영한다."
    )
    pdf.bullet(
        "Pre-ED에서의 RE 출력제한은 LP 외부(사전 cap)에서 처리해야 "
        "LP dual(=SMP)이 왜곡되지 않는다."
    )
    pdf.bullet(
        "Price Adder를 통한 calibration은 UC 미모형 요소를 부분적으로 흡수하지만, "
        "초과공급 시간대에서는 한계가 있다."
    )

    pdf.sub_title("11.3", "정책적 함의")
    pdf.body(
        "재생에너지 입찰제를 육지계통에 확대할 경우, 하한가 수준(beta)과 "
        "참여율(rho)이 핵심 설계 변수이다. "
        "하한가가 너무 낮으면(beta가 크면) 초과공급 시 SMP가 극단적으로 하락하여 "
        "발전사업자의 수익성과 시장 안정성에 부정적 영향을 줄 수 있다. "
        "참여율은 점진적으로 확대하여 시장에 미치는 충격을 최소화하는 것이 바람직하다."
    )

    # ── 저장 ──
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    out_path = os.path.join(OUTPUT_DIR, "PSE_프로젝트_보고서.pdf")
    pdf.output(out_path)
    print(f"PDF 생성 완료: {out_path}")
    return out_path


if __name__ == "__main__":
    build_report()
