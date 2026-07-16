from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_ALIGN_VERTICAL
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor


OUT = "Flick Series_MVP_기능기획서.docx"
FONT_NAME = "AppleGothic"


def set_cell_shading(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), fill)


def set_cell_margins(table, top=80, start=120, bottom=80, end=120):
    tbl_pr = table._tbl.tblPr
    tbl_cell_mar = tbl_pr.find(qn("w:tblCellMar"))
    if tbl_cell_mar is None:
        tbl_cell_mar = OxmlElement("w:tblCellMar")
        tbl_pr.append(tbl_cell_mar)
    for tag, value in (("top", top), ("start", start), ("bottom", bottom), ("end", end)):
        node = tbl_cell_mar.find(qn(f"w:{tag}"))
        if node is None:
            node = OxmlElement(f"w:{tag}")
            tbl_cell_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def set_table_width(table, width_dxa=9360):
    tbl_pr = table._tbl.tblPr
    tbl_w = tbl_pr.find(qn("w:tblW"))
    if tbl_w is None:
        tbl_w = OxmlElement("w:tblW")
        tbl_pr.append(tbl_w)
    tbl_w.set(qn("w:w"), str(width_dxa))
    tbl_w.set(qn("w:type"), "dxa")
    tbl_layout = tbl_pr.find(qn("w:tblLayout"))
    if tbl_layout is None:
        tbl_layout = OxmlElement("w:tblLayout")
        tbl_pr.append(tbl_layout)
    tbl_layout.set(qn("w:type"), "fixed")


def set_cell_width(cell, width_dxa):
    tc_pr = cell._tc.get_or_add_tcPr()
    tc_w = tc_pr.find(qn("w:tcW"))
    if tc_w is None:
        tc_w = OxmlElement("w:tcW")
        tc_pr.append(tc_w)
    tc_w.set(qn("w:w"), str(width_dxa))
    tc_w.set(qn("w:type"), "dxa")


def format_table(table, widths):
    table.style = "Table Grid"
    table.autofit = False
    set_table_width(table, sum(widths))
    set_cell_margins(table)
    for row_index, row in enumerate(table.rows):
        for idx, cell in enumerate(row.cells):
            set_cell_width(cell, widths[idx])
            cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            for paragraph in cell.paragraphs:
                paragraph.paragraph_format.space_before = Pt(0)
                paragraph.paragraph_format.space_after = Pt(4)
                for run in paragraph.runs:
                    run.font.name = FONT_NAME
                    rfonts = run._element.rPr.rFonts
                    rfonts.set(qn("w:ascii"), FONT_NAME)
                    rfonts.set(qn("w:hAnsi"), FONT_NAME)
                    rfonts.set(qn("w:eastAsia"), FONT_NAME)
                    rfonts.set(qn("w:cs"), FONT_NAME)
                    run.font.size = Pt(10)
            if row_index == 0:
                set_cell_shading(cell, "F8F9FA")
                for paragraph in cell.paragraphs:
                    for run in paragraph.runs:
                        run.bold = True


def set_font(run, size=None, bold=None, color=None):
    run.font.name = FONT_NAME
    rfonts = run._element.rPr.rFonts
    rfonts.set(qn("w:ascii"), FONT_NAME)
    rfonts.set(qn("w:hAnsi"), FONT_NAME)
    rfonts.set(qn("w:eastAsia"), FONT_NAME)
    rfonts.set(qn("w:cs"), FONT_NAME)
    if size:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color:
        run.font.color.rgb = RGBColor.from_string(color)


def add_para(doc, text="", style=None, after=8):
    p = doc.add_paragraph(style=style)
    p.paragraph_format.space_after = Pt(after)
    p.paragraph_format.line_spacing = 1.15
    if text:
        r = p.add_run(text)
        set_font(r, 11)
    return p


def add_bullet(doc, text):
    p = doc.add_paragraph(style="List Bullet")
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.15
    r = p.add_run(text)
    set_font(r, 11)
    return p


def add_number(doc, text):
    p = doc.add_paragraph(style="List Number")
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.15
    r = p.add_run(text)
    set_font(r, 11)
    return p


def add_heading(doc, text, level):
    p = doc.add_heading(text, level=level)
    if level == 1:
        p.paragraph_format.space_before = Pt(20)
        p.paragraph_format.space_after = Pt(6)
    elif level == 2:
        p.paragraph_format.space_before = Pt(18)
        p.paragraph_format.space_after = Pt(6)
    else:
        p.paragraph_format.space_before = Pt(16)
        p.paragraph_format.space_after = Pt(4)
    for run in p.runs:
        set_font(run, {1: 20, 2: 16, 3: 14}.get(level, 12), bold=False, color="000000" if level < 3 else "434343")
    return p


def add_kv_table(doc, rows):
    table = doc.add_table(rows=1, cols=2)
    table.rows[0].cells[0].text = "항목"
    table.rows[0].cells[1].text = "내용"
    for label, value in rows:
        cells = table.add_row().cells
        cells[0].text = label
        cells[1].text = value
    format_table(table, [2160, 7200])
    doc.add_paragraph().paragraph_format.space_after = Pt(4)
    return table


def add_matrix_table(doc, headers, rows, widths):
    table = doc.add_table(rows=1, cols=len(headers))
    for i, header in enumerate(headers):
        table.rows[0].cells[i].text = header
    for row_data in rows:
        cells = table.add_row().cells
        for i, value in enumerate(row_data):
            cells[i].text = value
    format_table(table, widths)
    doc.add_paragraph().paragraph_format.space_after = Pt(4)
    return table


def build():
    doc = Document()
    section = doc.sections[0]
    section.page_width = Inches(8.5)
    section.page_height = Inches(11)
    section.top_margin = Inches(1)
    section.bottom_margin = Inches(1)
    section.left_margin = Inches(1)
    section.right_margin = Inches(1)
    section.header_distance = Inches(0.492)
    section.footer_distance = Inches(0.492)

    styles = doc.styles
    normal = styles["Normal"]
    normal.font.name = FONT_NAME
    normal_rfonts = normal._element.rPr.rFonts
    normal_rfonts.set(qn("w:ascii"), FONT_NAME)
    normal_rfonts.set(qn("w:hAnsi"), FONT_NAME)
    normal_rfonts.set(qn("w:eastAsia"), FONT_NAME)
    normal_rfonts.set(qn("w:cs"), FONT_NAME)
    normal.font.size = Pt(11)
    normal.paragraph_format.space_after = Pt(8)
    normal.paragraph_format.line_spacing = 1.15

    title = doc.add_paragraph()
    title.paragraph_format.space_before = Pt(0)
    title.paragraph_format.space_after = Pt(3)
    run = title.add_run("Flick Series MVP 기능 기획서")
    set_font(run, 26, bold=False, color="000000")

    subtitle = add_para(doc, "노트북 힌지 제스처 기반 macOS 유틸리티 시리즈", after=8)
    subtitle.runs[0].font.color.rgb = RGBColor(85, 85, 85)

    meta = add_para(doc, "문서 유형: MVP 확장 기능 기획서  |  버전: v1.0  |  작성일: 2026.07.15  |  상태: 기획 확정 전 검토본", after=14)
    meta.runs[0].font.color.rgb = RGBColor(85, 85, 85)

    add_heading(doc, "1. 문서 목적", 1)
    add_para(
        doc,
        "본 문서는 Flick Series MVP 확장 범위에서 신규 기능인 Flick Focus와 Flick Hide의 제품 의도, 사용자 가치, 동작 범위, 구현 후보, 우선순위를 정리한 기능 기획서이다. 개발, 디자인, QA, 데모 준비 담당자가 동일한 기준으로 기능을 이해하고 납품 가능 여부를 판단할 수 있도록 작성한다.",
    )

    add_heading(doc, "2. 제품 개요", 1)
    add_para(
        doc,
        "Flick Series는 노트북 힌지, 즉 Lid의 움직임 패턴을 입력 장치로 활용하는 macOS 유틸리티 시리즈이다. 사용자는 마우스 조작이나 키보드 단축키 없이 노트북 화면을 특정 방식으로 움직여 창 정리, 집중 모드, Desktop 접근 같은 작업 환경 제어 기능을 실행한다.",
    )
    add_para(doc, "핵심 제품 철학은 다음과 같다.", after=4)
    add_bullet(doc, "Flick Series는 일반적인 창 관리 앱이 아니다.")
    add_bullet(doc, "핵심 가설은 노트북 힌지를 자연스러운 입력 장치로 사용할 수 있는지 검증하는 것이다.")
    add_bullet(doc, "MVP 기능은 모두 “노트북을 닫는 동작”만으로 작업 공간을 정리하고 전환할 수 있어야 한다.")

    add_heading(doc, "3. 명칭 및 입력 규칙", 1)
    add_para(doc, "입력 제스처와 앱 기능명은 서로 다른 명명 규칙을 따른다. 이 규칙은 UI 문구, 로그, 문서, 데모 스크립트에서 일관되게 적용한다.")
    add_matrix_table(
        doc,
        ["구분", "규칙", "예시"],
        [
            ["제스처 입력", "Flick이라는 단어를 사용하지 않는다. 사용 가능한 제스처는 Close와 Open 두 개뿐이다.", "Close, Open"],
            ["앱 기능", "기존처럼 Flick 접두어를 유지한다.", "Flick Arrange, Flick Focus, Flick Hide"],
        ],
        [1800, 5400, 2160],
    )

    add_heading(doc, "4. 제스처 정의", 1)
    add_matrix_table(
        doc,
        ["제스처", "입력 패턴", "설명", "MVP 사용 여부"],
        [
            ["Close", "110° → 90° → 97°", "화면을 빠르게 닫았다가 약간 복원하는 동작", "사용"],
            ["Open", "100° → 120° → 113°", "화면을 빠르게 열었다가 약간 복원하는 동작", "보류"],
        ],
        [1200, 2200, 4160, 1800],
    )
    add_para(doc, "현재 MVP 확장 범위에서는 Close 제스처만 기능 실행 트리거로 사용한다. Open 제스처 기반 기능은 향후 확장 아이디어로만 관리한다.")

    add_heading(doc, "5. MVP 기능 구성", 1)
    add_matrix_table(
        doc,
        ["우선순위", "기능명", "트리거", "상태", "핵심 가치"],
        [
            ["P0", "Flick Arrange", "Close", "완료", "복잡해진 작업 공간을 즉시 정리한다."],
            ["P1", "Flick Focus", "Close", "신규 구현", "현재 작업 중인 창만 남겨 집중 환경을 만든다."],
            ["P2", "Flick Hide", "Close", "신규 구현", "모든 창을 숨겨 Desktop에 즉시 접근한다."],
        ],
        [1100, 2100, 1300, 1500, 3360],
    )

    add_heading(doc, "6. 기능 요구사항", 1)
    add_heading(doc, "6.1 Flick Arrange", 2)
    add_kv_table(
        doc,
        [
            ("트리거", "Close"),
            ("현재 상태", "구현 완료"),
            ("기능 설명", "현재 열려 있는 창들을 자동 정렬한다."),
            ("사용자 목적", "복잡해진 작업 공간을 즉시 정리한다."),
            ("MVP 기준", "기존 구현을 유지하며 신규 기능과 명칭 규칙만 충돌 없이 정리한다."),
        ],
    )

    add_heading(doc, "6.2 Flick Focus", 2)
    add_kv_table(
        doc,
        [
            ("트리거", "Close"),
            ("목적", "현재 작업 중인 창에 집중하도록 주변 작업 환경을 정리한다."),
            ("핵심 동작", "현재 활성 창(active window)을 제외한 모든 일반 앱 창을 숨긴다."),
            ("실행 전 예시", "Chrome, VSCode(활성), Discord, Finder"),
            ("실행 후 예시", "VSCode만 표시하고 나머지 창은 숨김 상태로 전환한다."),
        ],
    )
    add_heading(doc, "포함 범위", 3)
    add_bullet(doc, "모든 일반 앱 창을 대상으로 한다.")
    add_bullet(doc, "현재 활성 창은 유지한다.")
    add_heading(doc, "제외 범위", 3)
    add_bullet(doc, "macOS 메뉴바, Dock, 시스템 UI는 제어 대상에서 제외한다.")
    add_bullet(doc, "초기 버전에서는 Focus ON/OFF 토글을 필수 범위로 보지 않는다.")
    add_heading(doc, "구현 후보", 3)
    add_bullet(doc, "NSApplication.hide() 기반으로 앱 단위 숨김을 수행한다.")
    add_bullet(doc, "필요 시 AXUIElement 기반으로 창 단위 제어를 검토한다.")
    add_heading(doc, "수용 기준", 3)
    add_number(doc, "Close 제스처가 인식되면 현재 활성 창만 화면에 남는다.")
    add_number(doc, "비활성 일반 앱 창은 Hide 상태로 전환된다.")
    add_number(doc, "메뉴바, Dock, 시스템 UI는 기능 실행 후에도 정상적으로 유지된다.")
    add_number(doc, "초기 버전에서는 같은 제스처를 반복 실행해도 오류나 창 상태 깨짐이 없어야 한다.")

    add_heading(doc, "6.3 Flick Hide", 2)
    add_kv_table(
        doc,
        [
            ("트리거", "Close"),
            ("목적", "사용자가 바탕화면 파일에 즉시 접근할 수 있도록 Desktop 보기 상태를 만든다."),
            ("핵심 동작", "모든 일반 앱 창을 숨긴다."),
            ("실행 전 예시", "Chrome, VSCode, Discord, Finder"),
            ("실행 후 예시", "Desktop만 표시한다."),
        ],
    )
    add_heading(doc, "Flick Focus와의 차이", 3)
    add_matrix_table(
        doc,
        ["기능", "남기는 창", "사용 맥락"],
        [
            ["Flick Focus", "활성 창 1개 유지", "현재 작업에 집중하고 싶을 때"],
            ["Flick Hide", "모든 창 숨김", "Desktop 파일이나 바탕화면 접근이 필요할 때"],
        ],
        [2200, 2600, 4560],
    )
    add_heading(doc, "구현 후보", 3)
    add_bullet(doc, "macOS Show Desktop 동작 호출을 검토한다.")
    add_bullet(doc, "Mission Control 관련 API 또는 시스템 이벤트 기반 접근을 검토한다.")
    add_heading(doc, "수용 기준", 3)
    add_number(doc, "Close 제스처가 인식되면 모든 일반 앱 창이 화면에서 사라진다.")
    add_number(doc, "Desktop 영역과 바탕화면 파일이 사용 가능해야 한다.")
    add_number(doc, "메뉴바, Dock, 시스템 UI는 제어 대상에서 제외된다.")

    add_heading(doc, "7. 우선순위 및 개발 순서", 1)
    add_para(doc, "MVP 확장 개발은 사용자 체감 가치와 구현 난이도를 기준으로 Flick Focus를 우선한다. Flick Hide는 구현 난이도는 낮지만 활용 빈도가 Focus보다 낮을 가능성이 있어 후순위로 둔다.")
    add_matrix_table(
        doc,
        ["순서", "기능", "판단 근거", "권장 액션"],
        [
            ["1", "Flick Arrange", "P0 완료 기능", "현재 동작 유지 및 신규 명칭 규칙 반영 여부만 확인"],
            ["2", "Flick Focus", "실사용 가치가 가장 높고 구현 난이도가 상대적으로 낮음", "P1로 우선 구현"],
            ["3", "Flick Hide", "구현은 쉽지만 Focus 대비 사용 빈도는 낮을 가능성", "P2로 구현 또는 데모용 후보 유지"],
        ],
        [900, 1800, 4560, 2100],
    )

    add_heading(doc, "8. MVP 범위", 1)
    add_heading(doc, "포함", 2)
    add_bullet(doc, "Close 제스처를 이용한 Flick Arrange, Flick Focus, Flick Hide 실행")
    add_bullet(doc, "기능명 Flick 접두어 유지")
    add_bullet(doc, "제스처명 Close/Open 규칙 적용")
    add_bullet(doc, "일반 앱 창 대상 Hide 또는 유지 동작")
    add_heading(doc, "제외", 2)
    add_bullet(doc, "Open 제스처 기반 Launcher, Recent Apps, Recall 기능")
    add_bullet(doc, "Flick Focus 토글 모드")
    add_bullet(doc, "시스템 UI, Dock, 메뉴바 제어")
    add_bullet(doc, "고급 창 관리 앱 수준의 레이아웃 커스터마이징")

    add_heading(doc, "9. UX 및 데모 시나리오", 1)
    add_para(doc, "데모는 사용자가 키보드 단축키를 외우지 않아도 노트북 화면을 닫는 동작만으로 작업 환경이 바뀐다는 점을 보여주는 데 집중한다.")
    add_number(doc, "여러 앱 창이 열린 복잡한 작업 상태를 준비한다.")
    add_number(doc, "Close 제스처로 Flick Arrange를 실행해 창 정리 효과를 보여준다.")
    add_number(doc, "VSCode 등 작업 중인 창을 활성화한 뒤 Close 제스처로 Flick Focus를 실행한다.")
    add_number(doc, "활성 창만 남고 나머지 앱이 숨겨지는지 확인한다.")
    add_number(doc, "Flick Hide 구현 이후에는 Close 제스처로 Desktop만 표시되는 시나리오를 추가한다.")

    add_heading(doc, "10. 검수 체크리스트", 1)
    add_matrix_table(
        doc,
        ["검수 항목", "기준", "결과"],
        [
            ["제스처 명칭", "입력 제스처 문구에 Flick 단어를 사용하지 않는다.", "확인 필요"],
            ["기능 명칭", "앱 기능명은 Flick Arrange, Flick Focus, Flick Hide로 표기한다.", "확인 필요"],
            ["Flick Focus", "활성 창 1개만 유지하고 나머지 일반 앱 창을 숨긴다.", "확인 필요"],
            ["Flick Hide", "모든 일반 앱 창을 숨기고 Desktop 접근이 가능하다.", "확인 필요"],
            ["시스템 UI", "메뉴바, Dock, 시스템 UI는 제어 대상에서 제외한다.", "확인 필요"],
            ["반복 실행", "동일 제스처 반복 실행 시 오류나 앱 상태 깨짐이 없어야 한다.", "확인 필요"],
        ],
        [2400, 5160, 1800],
    )

    add_heading(doc, "11. 향후 확장 아이디어", 1)
    add_para(doc, "Open 제스처 기반 기능은 현재 개발 범위에서 제외하며, MVP 검증 이후 별도 기획으로 전환한다.")
    add_bullet(doc, "Launcher: 자주 쓰는 앱 또는 액션 실행")
    add_bullet(doc, "Recent Apps: 최근 사용 앱 전환")
    add_bullet(doc, "Recall: 이전 작업 상태 복원 또는 최근 작업 호출")

    add_heading(doc, "12. 결론", 1)
    add_para(
        doc,
        "Flick Series의 MVP 확장 방향은 창 관리 기능 자체보다 ‘노트북 힌지를 입력 장치로 사용할 수 있는가’라는 제품 가설 검증에 초점을 둔다. Flick Focus는 이 가설을 가장 명확하게 보여주는 P1 기능이며, Flick Hide는 Desktop 접근이라는 보조 사용 사례를 강화하는 P2 기능이다. 초기 구현은 Close 제스처 중심으로 단순하고 안정적인 실행 경험을 만드는 데 집중한다.",
    )

    doc.save(OUT)


if __name__ == "__main__":
    build()
