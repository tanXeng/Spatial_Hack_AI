from __future__ import annotations

from pathlib import Path
from typing import Iterable

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.opc.constants import RELATIONSHIP_TYPE as RT
from docx.shared import Inches, Pt, RGBColor


OUT = Path("/Users/event/Documents/Spatial AI/Boxing_ML_Datasets_and_Documentation.docx")

BLUE = "2E74B5"
DEEP_BLUE = "17365D"
INK = "1F2933"
MUTED = "52606D"
PALE_BLUE = "E8EEF5"
PALE_TEAL = "E8F5F2"
PALE_GOLD = "FFF4D6"
PALE_RED = "FDECEC"
PALE_GREY = "F4F6F8"
WHITE = "FFFFFF"
GREEN = "1F7A5A"
AMBER = "A15C00"
RED = "A33A3A"
GREY = "58636E"
LINK_BLUE = "0563C1"

STATUS = {
    "OPEN": ("OPEN", GREEN, "E4F4EC"),
    "LIMITED": ("LIMITED", AMBER, "FFF2D6"),
    "CONTROLLED": ("CONTROLLED", DEEP_BLUE, "E8EEF5"),
    "DESCRIBED": ("PAPER-ONLY", GREY, "EEF1F4"),
}


def set_cell_shading(cell, fill: str) -> None:
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), fill)


def set_cell_margins(cell, top=80, start=120, bottom=80, end=120) -> None:
    tc = cell._tc
    tc_pr = tc.get_or_add_tcPr()
    tc_mar = tc_pr.first_child_found_in("w:tcMar")
    if tc_mar is None:
        tc_mar = OxmlElement("w:tcMar")
        tc_pr.append(tc_mar)
    for margin, value in (("top", top), ("start", start), ("bottom", bottom), ("end", end)):
        node = tc_mar.find(qn(f"w:{margin}"))
        if node is None:
            node = OxmlElement(f"w:{margin}")
            tc_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def set_table_borders(table, color="CDD5DF", size="4") -> None:
    tbl_pr = table._tbl.tblPr
    borders = tbl_pr.find(qn("w:tblBorders"))
    if borders is None:
        borders = OxmlElement("w:tblBorders")
        tbl_pr.append(borders)
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        tag = qn(f"w:{edge}")
        elem = borders.find(tag)
        if elem is None:
            elem = OxmlElement(f"w:{edge}")
            borders.append(elem)
        elem.set(qn("w:val"), "single")
        elem.set(qn("w:sz"), size)
        elem.set(qn("w:space"), "0")
        elem.set(qn("w:color"), color)


def remove_table_borders(table) -> None:
    tbl_pr = table._tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        elem = OxmlElement(f"w:{edge}")
        elem.set(qn("w:val"), "nil")
        borders.append(elem)
    tbl_pr.append(borders)


def set_repeat_table_header(row) -> None:
    tr_pr = row._tr.get_or_add_trPr()
    tbl_header = OxmlElement("w:tblHeader")
    tbl_header.set(qn("w:val"), "true")
    tr_pr.append(tbl_header)


def prevent_row_split(row) -> None:
    tr_pr = row._tr.get_or_add_trPr()
    cant_split = OxmlElement("w:cantSplit")
    cant_split.set(qn("w:val"), "true")
    tr_pr.append(cant_split)


def set_fixed_layout(table) -> None:
    tbl_pr = table._tbl.tblPr
    layout = tbl_pr.find(qn("w:tblLayout"))
    if layout is None:
        layout = OxmlElement("w:tblLayout")
        tbl_pr.append(layout)
    layout.set(qn("w:type"), "fixed")


def set_cell_width(cell, width_inches: float) -> None:
    width = Inches(width_inches)
    cell.width = width
    tc_pr = cell._tc.get_or_add_tcPr()
    tc_w = tc_pr.find(qn("w:tcW"))
    if tc_w is None:
        tc_w = OxmlElement("w:tcW")
        tc_pr.append(tc_w)
    tc_w.set(qn("w:w"), str(int(width.twips)))
    tc_w.set(qn("w:type"), "dxa")


def set_keep_with_next(paragraph, value=True) -> None:
    paragraph.paragraph_format.keep_with_next = value


def set_keep_together(paragraph, value=True) -> None:
    paragraph.paragraph_format.keep_together = value


def add_hyperlink(paragraph, text: str, url: str, color=LINK_BLUE, underline=True):
    part = paragraph.part
    rid = part.relate_to(url, RT.HYPERLINK, is_external=True)
    hyperlink = OxmlElement("w:hyperlink")
    hyperlink.set(qn("r:id"), rid)
    new_run = OxmlElement("w:r")
    r_pr = OxmlElement("w:rPr")
    c = OxmlElement("w:color")
    c.set(qn("w:val"), color)
    r_pr.append(c)
    if underline:
        u = OxmlElement("w:u")
        u.set(qn("w:val"), "single")
        r_pr.append(u)
    new_run.append(r_pr)
    t = OxmlElement("w:t")
    t.text = text
    new_run.append(t)
    hyperlink.append(new_run)
    paragraph._p.append(hyperlink)
    return hyperlink


def add_field(paragraph, instruction: str) -> None:
    run = paragraph.add_run()
    fld_begin = OxmlElement("w:fldChar")
    fld_begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = instruction
    fld_sep = OxmlElement("w:fldChar")
    fld_sep.set(qn("w:fldCharType"), "separate")
    text = OxmlElement("w:t")
    text.text = "1"
    fld_end = OxmlElement("w:fldChar")
    fld_end.set(qn("w:fldCharType"), "end")
    for node in (fld_begin, instr, fld_sep, text, fld_end):
        run._r.append(node)


def set_run(run, size=None, bold=None, color=None, italic=None, font="Calibri"):
    run.font.name = font
    run._element.rPr.rFonts.set(qn("w:eastAsia"), font)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color:
        run.font.color.rgb = RGBColor.from_string(color)
    if italic is not None:
        run.italic = italic
    return run


def add_rule(paragraph, color=BLUE, size="18"):
    p_pr = paragraph._p.get_or_add_pPr()
    p_bdr = p_pr.find(qn("w:pBdr"))
    if p_bdr is None:
        p_bdr = OxmlElement("w:pBdr")
        p_pr.append(p_bdr)
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), size)
    bottom.set(qn("w:space"), "6")
    bottom.set(qn("w:color"), color)
    p_bdr.append(bottom)


def add_status_tag(paragraph, status: str) -> None:
    label, color, fill = STATUS[status]
    run = paragraph.add_run(f"  {label}  ")
    set_run(run, size=8.5, bold=True, color=color)
    r_pr = run._r.get_or_add_rPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), fill)
    r_pr.append(shd)


def add_link_line(doc: Document, links: Iterable[tuple[str, str]], prefix="Links"):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(6)
    set_run(p.add_run(prefix + ": "), size=9.2, bold=True, color=MUTED)
    links = list(links)
    for i, (label, url) in enumerate(links):
        if i:
            set_run(p.add_run("  ·  "), size=9.2, color=MUTED)
        add_hyperlink(p, label, url)
    return p


def add_callout(doc: Document, title: str, body: str, fill=PALE_BLUE, accent=BLUE):
    table = doc.add_table(rows=1, cols=1)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_fixed_layout(table)
    set_cell_width(table.cell(0, 0), 6.5)
    cell = table.cell(0, 0)
    set_cell_shading(cell, fill)
    set_cell_margins(cell, 130, 170, 130, 170)
    remove_table_borders(table)
    p = cell.paragraphs[0]
    p.paragraph_format.space_after = Pt(2)
    set_run(p.add_run(title), size=10.5, bold=True, color=accent)
    p2 = cell.add_paragraph()
    p2.paragraph_format.space_after = Pt(0)
    set_run(p2.add_run(body), size=9.5, color=INK)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)
    return table


def add_matrix_table(doc, headers, rows, widths, font_size=8.6, header_fill=PALE_BLUE, keep_table=False):
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_fixed_layout(table)
    set_table_borders(table)
    hdr = table.rows[0]
    set_repeat_table_header(hdr)
    for i, (label, width) in enumerate(zip(headers, widths)):
        set_cell_width(hdr.cells[i], width)
        set_cell_shading(hdr.cells[i], header_fill)
        set_cell_margins(hdr.cells[i])
        hdr.cells[i].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
        p = hdr.cells[i].paragraphs[0]
        p.paragraph_format.space_after = Pt(0)
        set_run(p.add_run(label), size=8.7, bold=True, color=DEEP_BLUE)
    for row_data in rows:
        row = table.add_row()
        prevent_row_split(row)
        for i, (value, width) in enumerate(zip(row_data, widths)):
            set_cell_width(row.cells[i], width)
            set_cell_margins(row.cells[i])
            row.cells[i].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.TOP
            p = row.cells[i].paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            if isinstance(value, dict) and "link" in value:
                add_hyperlink(p, value.get("text", value["link"]), value["link"])
            elif isinstance(value, tuple) and len(value) == 3 and value[0] == "status":
                add_status_tag(p, value[1])
            else:
                set_run(p.add_run(str(value)), size=font_size, color=INK)
    if keep_table:
        all_rows = table.rows
        for row in all_rows[:-1]:
            for cell in row.cells:
                for p in cell.paragraphs:
                    p.paragraph_format.keep_with_next = True
    doc.add_paragraph().paragraph_format.space_after = Pt(0)
    return table


def add_detail_entry(doc, item):
    h = doc.add_paragraph(style="Heading 3")
    set_run(h.add_run(item["title"]), size=12, bold=True, color=DEEP_BLUE)
    add_status_tag(h, item["status"])
    set_keep_with_next(h)

    table = doc.add_table(rows=4, cols=2)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_fixed_layout(table)
    set_table_borders(table, color="D8DEE6", size="3")
    labels = ["Snapshot", "Best ML uses", "Access & rights", "Watch-outs"]
    values = [item["snapshot"], item["uses"], item["access"], item["caveat"]]
    for r, (label, value) in enumerate(zip(labels, values)):
        row = table.rows[r]
        prevent_row_split(row)
        set_cell_width(row.cells[0], 1.20)
        set_cell_width(row.cells[1], 5.30)
        set_cell_margins(row.cells[0], 75, 110, 75, 110)
        set_cell_margins(row.cells[1], 75, 120, 75, 120)
        set_cell_shading(row.cells[0], PALE_GREY)
        row.cells[0].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.TOP
        row.cells[1].vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.TOP
        p0 = row.cells[0].paragraphs[0]
        p0.paragraph_format.space_after = Pt(0)
        set_run(p0.add_run(label), size=8.8, bold=True, color=MUTED)
        p1 = row.cells[1].paragraphs[0]
        p1.paragraph_format.space_after = Pt(0)
        set_run(p1.add_run(value), size=9.2, color=INK)
        if r < len(labels) - 1:
            p0.paragraph_format.keep_with_next = True
            p1.paragraph_format.keep_with_next = True
        else:
            # Keep the final row attached to its source links.
            p0.paragraph_format.keep_with_next = True
            p1.paragraph_format.keep_with_next = True
    add_link_line(doc, item["links"])


def setup_styles(doc: Document):
    styles = doc.styles
    normal = styles["Normal"]
    normal.font.name = "Calibri"
    normal._element.rPr.rFonts.set(qn("w:eastAsia"), "Calibri")
    normal.font.size = Pt(10.5)
    normal.font.color.rgb = RGBColor.from_string(INK)
    normal.paragraph_format.space_after = Pt(6)
    normal.paragraph_format.line_spacing = 1.18

    for name, size, color, before, after in (
        ("Title", 28, DEEP_BLUE, 0, 12),
        ("Subtitle", 13, MUTED, 0, 10),
        ("Heading 1", 16, BLUE, 18, 10),
        ("Heading 2", 13, BLUE, 14, 7),
        ("Heading 3", 12, DEEP_BLUE, 10, 5),
    ):
        style = styles[name]
        style.font.name = "Calibri"
        style._element.rPr.rFonts.set(qn("w:eastAsia"), "Calibri")
        style.font.size = Pt(size)
        style.font.color.rgb = RGBColor.from_string(color)
        style.font.bold = name != "Subtitle"
        style.paragraph_format.space_before = Pt(before)
        style.paragraph_format.space_after = Pt(after)
        style.paragraph_format.keep_with_next = True

    for list_name in ("List Bullet", "List Number"):
        st = styles[list_name]
        st.font.name = "Calibri"
        st.font.size = Pt(10.2)
        st.paragraph_format.left_indent = Inches(0.375)
        st.paragraph_format.first_line_indent = Inches(-0.188)
        st.paragraph_format.space_after = Pt(4)
        st.paragraph_format.line_spacing = 1.18

    if "Small Note" not in styles:
        st = styles.add_style("Small Note", WD_STYLE_TYPE.PARAGRAPH)
        st.font.name = "Calibri"
        st.font.size = Pt(8.7)
        st.font.color.rgb = RGBColor.from_string(MUTED)
        st.paragraph_format.space_after = Pt(4)
        st.paragraph_format.line_spacing = 1.08


def setup_page(doc: Document):
    section = doc.sections[0]
    section.page_width = Inches(8.5)
    section.page_height = Inches(11)
    section.top_margin = Inches(0.75)
    section.bottom_margin = Inches(0.70)
    section.left_margin = Inches(1)
    section.right_margin = Inches(1)
    section.header_distance = Inches(0.35)
    section.footer_distance = Inches(0.35)
    section.different_first_page_header_footer = True

    header = section.header
    p = header.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    p.paragraph_format.space_after = Pt(0)
    set_run(p.add_run("BOXING ML DATA LANDSCAPE  ·  SOURCE AUDIT"), size=8, bold=True, color=MUTED)
    add_rule(p, color="AFC6DC", size="8")

    footer = section.footer
    p = footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(2)
    set_run(p.add_run("Boxing ML Data & Documentation  ·  "), size=8, color=MUTED)
    add_field(p, "PAGE")
    set_run(p.add_run(" / "), size=8, color=MUTED)
    add_field(p, "NUMPAGES")


def add_cover(doc: Document):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(8)
    p.paragraph_format.space_after = Pt(26)
    p.alignment = WD_ALIGN_PARAGRAPH.LEFT
    set_run(p.add_run("RESEARCH REFERENCE  /  ML DATA LANDSCAPE"), size=9.5, bold=True, color=BLUE)
    add_rule(p, color=BLUE, size="22")

    title = doc.add_paragraph(style="Title")
    title.alignment = WD_ALIGN_PARAGRAPH.LEFT
    set_run(title.add_run("Boxing ML Data &\nDocumentation"), size=28, bold=True, color=DEEP_BLUE)

    sub = doc.add_paragraph(style="Subtitle")
    set_run(sub.add_run("A source-linked catalog for computer vision, sensors, biomechanics, commentary, bout analytics, scoring, safety and transfer learning"), size=13, color=MUTED)

    meta = doc.add_table(rows=1, cols=3)
    meta.alignment = WD_TABLE_ALIGNMENT.CENTER
    meta.autofit = False
    set_fixed_layout(meta)
    remove_table_borders(meta)
    for i, (head, body, fill) in enumerate((
        ("AUDIT DATE", "7 August 2026", PALE_BLUE),
        ("SCOPE", "Sport of boxing", PALE_TEAL),
        ("FORMAT", "Curated + de-duplicated", PALE_GOLD),
    )):
        cell = meta.cell(0, i)
        set_cell_width(cell, 2.10 if i != 2 else 2.30)
        set_cell_shading(cell, fill)
        set_cell_margins(cell, 130, 150, 130, 150)
        pp = cell.paragraphs[0]
        pp.paragraph_format.space_after = Pt(3)
        set_run(pp.add_run(head), size=8, bold=True, color=MUTED)
        pp2 = cell.add_paragraph()
        pp2.paragraph_format.space_after = Pt(0)
        set_run(pp2.add_run(body), size=10.2, bold=True, color=DEEP_BLUE)

    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    add_callout(
        doc,
        "The short answer",
        "The best immediately usable boxing-specific sources are split across video/event labels (Olympic Boxing and BoxingWeb), commentary metadata (BoxComm), and laboratory sensors (two CC BY biomechanics releases). No single open dataset covers broadcast video, punch type, contact, score, injury and athlete identity with commercial training rights. Production work will usually require first-party or directly licensed capture.",
        fill=PALE_BLUE,
    )

    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(12)
    p.paragraph_format.space_after = Pt(2)
    set_run(p.add_run("What this document gives you"), size=11, bold=True, color=DEEP_BLUE)
    for text in (
        "A practical shortlist by model objective, followed by a detailed boxing-specific catalog.",
        "Clear access labels: open, limited, controlled, or described without a verified release.",
        "Direct hyperlinks to data, papers, code, rules, medical guidance, schemas and annotation tools.",
        "Rights, provenance, leakage and evaluation warnings that affect whether a benchmark is safe to use.",
    ):
        doc.add_paragraph(text, style="List Bullet")

    p = doc.add_paragraph(style="Small Note")
    p.paragraph_format.space_before = Pt(10)
    set_run(p.add_run("Coverage note. "), size=8.7, bold=True, color=MUTED)
    set_run(p.add_run("“Available” means publicly discoverable as of the audit date. Private federation, broadcaster, gym, wearable-vendor and proprietary statistics archives are outside the catalog unless a public access route or documentation page could be verified."), size=8.7, color=MUTED)
    doc.add_page_break()


CORE_DATASETS = [
    {
        "title": "Olympic Boxing Punch Classification Video Dataset",
        "status": "LIMITED",
        "snapshot": "Multi-camera competition video recorded in Poland at 1080p/50 fps. The paper reports 312,774 reviewed frames, including 11,345 punch frames, with eight labels: head/body/block/miss × left/right. Faces are blurred.",
        "uses": "Punch detection and classification; boxer/clash detection; temporal action models; research benchmarks under competition-like viewpoints.",
        "access": "Kaggle download; custom non-commercial academic teaching/research and nonprofit-research restriction. The repository's MIT license covers code, not the footage.",
        "caveat": "Severe class imbalance; two-view labeling; source archive is very large. Preserve subject/bout separation and do not treat adjacent frames as independent samples.",
        "links": [
            ("Labelled data", "https://www.kaggle.com/datasets/piotrstefaskiue/olympic-boxing-punch-classification-video-dataset"),
            ("Unlabelled videos", "https://www.kaggle.com/datasets/piotrstefaskiue/olympic-boxing-video-dataset-unlabeled"),
            ("Paper", "https://pmc.ncbi.nlm.nih.gov/articles/PMC11353713/"),
            ("Code", "https://github.com/piotr-stefanski/boxing-fight-video-analysis"),
        ],
    },
    {
        "title": "BoxingWeb — public BoxMind event dataset",
        "status": "LIMITED",
        "snapshot": "Fifty manually annotated elite-match rounds at 30 fps, split 40/10. Public files include MP4, skeleton PKL and event JSON with time bounds, hand, distance, punch family, target and effective/ineffective result.",
        "uses": "Fine-grained event detection and localization; punch/contact effectiveness; skeleton-conditioned modeling; tactical feature extraction and outcome modeling.",
        "access": "Official GitHub plus Tsinghua Cloud download. The repository instructs users to consult a LICENSE, but no license file was present when audited; obtain written reuse terms.",
        "caveat": "Do not confuse the public 50-round set with the paper's combined 80-round total: BoxingStudio's additional 30 four-camera rounds are private. Larger BoxingWeb-Full and BoxerGraph resources are not all public.",
        "links": [
            ("Repository", "https://github.com/gouba2333/BoxingWeb"),
            ("Download", "https://cloud.tsinghua.edu.cn/d/c435311fecda4566ae76/"),
            ("BoxMind paper", "https://arxiv.org/abs/2601.11492"),
        ],
    },
    {
        "title": "BoxComm — boxing commentary and multimodal benchmark",
        "status": "LIMITED",
        "snapshot": "Metadata for 445 World Boxing Championship matches (405 train, 40 evaluation) and more than 52,000 commentary sentences. Includes timestamps, ASR/commentary, punch-event JSON, skeleton PKL and commentary types.",
        "uses": "Commentary generation; temporal event detection; video-language alignment; tactical/contextual narration; rhythm and category-conditioned evaluation.",
        "access": "Hugging Face and GitHub; non-commercial academic research. Raw broadcasts are not owned or redistributed by the authors; users receive URLs/timestamps and reconstruction tooling.",
        "caveat": "Source links can decay, local paths may not resolve, and annotations do not grant broadcast rights. License the underlying video separately.",
        "links": [
            ("Training metadata", "https://huggingface.co/datasets/gouba2333/BoxComm-Dataset"),
            ("Evaluation metadata", "https://huggingface.co/datasets/gouba2333/BoxComm"),
            ("Project", "https://gouba2333.github.io/BoxComm"),
            ("Code", "https://github.com/gouba2333/BoxComm"),
            ("Paper", "https://arxiv.org/abs/2604.04419"),
        ],
    },
    {
        "title": "Biomechanics of Punching — Effective Mass Analysis",
        "status": "OPEN",
        "snapshot": "Raw high-frequency punching sensor workbooks, summary data, README and filtering/impulse notebooks covering jab, cross, lead hook and rear hook in a laboratory force-transfer study.",
        "uses": "Force, impulse and effective-mass regression; punch-type classification; sensor feature engineering; physics-informed models.",
        "access": "Direct Zenodo download under CC BY 4.0. Cite the dataset and distinguish the concept record from the archived version record.",
        "caveat": "Laboratory force-plate domain and male cohort limit direct generalization to bouts. Confirm subject IDs and split by athlete before training.",
        "links": [
            ("Zenodo concept", "https://zenodo.org/records/14966350"),
            ("Archived version", "https://zenodo.org/records/14966351"),
            ("Metadata", "https://data.niaid.nih.gov/resources?id=zenodo_14966350"),
            ("Study", "https://www.mdpi.com/2076-3417/15/7/4008"),
        ],
    },
    {
        "title": "Orthodox vs southpaw stance kinetics — four punches",
        "status": "OPEN",
        "snapshot": "Synchronized fist IMU and AMTI ground-reaction-force data from 30 male boxers performing jab, cross, lead hook and rear hook in orthodox and southpaw stances. Raw/summary XLSX plus notebook; roughly 392 MB.",
        "uses": "Stance and punch classification; force/impulse regression; asymmetry and biomechanics studies; multimodal sensor fusion.",
        "access": "Zenodo dataset under CC BY 4.0. The associated article has different CC BY-NC-ND terms, so cite each artifact under its own license.",
        "caveat": "Male-only, controlled laboratory strikes. Use athlete-level splits and retain stance/punch hierarchy rather than flattening labels prematurely.",
        "links": [
            ("Dataset", "https://zenodo.org/records/17186871"),
            ("Paper", "https://reference-global.com/article/10.2478/bhk-2026-0003?tab=article"),
        ],
    },
    {
        "title": "Straight-punch kinetics — rear cross and lead jab",
        "status": "LIMITED",
        "snapshot": "A 63.2 MB ZIP of Excel files with synchronized fist/forearm/upper-arm IMUs and force-plate Fx/Fy/Fz measurements, plus Python processing code for individual strikes.",
        "uses": "Jab-vs-cross classification; punch-force and timing regression; segment-chain feature analysis; biomechanics reproducibility.",
        "access": "Direct Zenodo download, but the record's Rights field is blank. The open-access papers do not automatically license the deposited data; contact the authors before reuse beyond evaluation.",
        "caveat": "Only two punch types; packaging and subject identifiers require inspection. Split by participant, not extracted strike window.",
        "links": [
            ("Dataset", "https://zenodo.org/records/10729180"),
            ("Code", "https://github.com/Dareczin/boxing_biomechanics"),
            ("Study", "https://doi.org/10.3390/app14072830"),
        ],
    },
    {
        "title": "Elite-boxer bilateral wrist IMU punch data",
        "status": "LIMITED",
        "snapshot": "Six CSVs (~11.4 MB) at 200 Hz: lead/rear × jab/hook/uppercut, with bilateral triaxial accelerometer and gyroscope channels. The paper describes 320 shadowboxing punches from eight elite boxers.",
        "uses": "Wearable punch classification; active learning; low-latency feature extraction; bilateral signal comparison.",
        "access": "Direct Zenodo download, but no explicit data license appears in the Rights field. Do not infer the article's CC BY license applies to the files.",
        "caveat": "Very small athlete pool and controlled shadowboxing. Six released aggregates differ from the paper's richer punch taxonomy; inspect IDs and collection structure before validation.",
        "links": [
            ("Dataset", "https://zenodo.org/records/14965635"),
            ("Paper", "https://pmc.ncbi.nlm.nih.gov/articles/PMC12061147/"),
        ],
    },
    {
        "title": "DRCA-MLHM boxing head-impact subset",
        "status": "LIMITED",
        "snapshot": "A boxing subset of 260 head impacts from Prevent Biometrics Hybrid instrumented mouthguards, with linear/angular kinematics and derived temporal/spectral features used to predict brain strain and strain rate.",
        "uses": "Head-impact biomechanics; domain adaptation; surrogate prediction of whole-brain maximum principal strain and strain rate.",
        "access": "The paper points to a public GitHub repository for associated code/data, but no explicit repository or data license was verified.",
        "caveat": "Kinematics/biomechanical targets are not clinical diagnoses. Treat athlete privacy and device calibration as material constraints; confirm reuse permission.",
        "links": [
            ("Repository", "https://github.com/xzhan96-stf/drca-mlhm"),
            ("Paper", "https://pmc.ncbi.nlm.nih.gov/articles/PMC11781752/"),
        ],
    },
    {
        "title": "Combat Sports Dataset — Zenodo / Roboflow",
        "status": "LIMITED",
        "snapshot": "7,757 640×640 images for YOLO-style training with boxing bag, cross, high guard, hook, kick, low guard and person labels; approximately 391 MB.",
        "uses": "Object/action detection bootstrapping for gyms, bags, guards and broad strikes; pretraining before boxing-specific fine-tuning.",
        "access": "Zenodo archive and originating Roboflow project. The description says Public Domain, while Zenodo's formal Rights field is empty; verify the upstream media chain.",
        "caveat": "Mixed combat-sport content and broad labels. De-duplicate augmented images and audit source-media copyright before commercial use.",
        "links": [
            ("Zenodo", "https://zenodo.org/records/15349809"),
            ("Roboflow source", "https://universe.roboflow.com/combatsports/combatsports-merge-attempt/dataset/2"),
        ],
    },
    {
        "title": "NealBeans / BoxingDataset — clipped Olympic derivative",
        "status": "LIMITED",
        "snapshot": "A derivative card describing 2,278 short clips totaling 1,562.9 seconds, with Olympic Boxing's eight classes and per-clip metadata such as timestamps, duration, source and fps.",
        "uses": "Short-clip classifiers and VLM fine-tuning experiments when the source Olympic media is available.",
        "access": "Hugging Face; license marked 'other' and inherits the original non-commercial restriction.",
        "caveat": "Not independent data. The audited repository tree exposed only about 1.16 MB of CSV/JSONL metadata and no MP4 payloads, so reconstruct from the licensed Kaggle source if permitted.",
        "links": [
            ("Dataset card", "https://huggingface.co/datasets/NealBeans/BoxingDataset"),
            ("README", "https://huggingface.co/datasets/NealBeans/BoxingDataset/blob/main/README.md"),
        ],
    },
]


PAPER_ONLY = [
    ("Motion Tape boxing", "480 performed jabs/lead hooks across shadowboxing, 5-lb-weight and heavy-bag conditions; wearable skin-strain sensors with Vicon reference. Data only on request for ethics/clinical-trial reasons.", "https://pmc.ncbi.nlm.nih.gov/articles/PMC12390462/"),
    ("18-class wrist-IMU strike study", "15 martial artists, 2,880 strikes at 100 Hz; six punches × shadowboxing/bag/pads. No public archive verified.", "https://www.mdpi.com/1424-8220/21/24/8409"),
    ("ShadowPunch", "Claimed 27+ HD videos, 230,502 frames at 60 fps and punch/no-punch plus pose labels. Submission withdrawn; no live dataset or license found.", "https://openreview.net/forum?id=Jq8HYNZG9s"),
    ("BoxMAC", "Describes 15 professional boxers, 13 multi-label actions and >60,000 annotated frames. Paper withdrawn; no public repository verified.", "https://arxiv.org/abs/2412.18204"),
    ("BoxingVI", "Describes 6,915 segmented clips from 20 public videos/18 athletes, six punch classes and AlphaPose trajectories. No official data release or license found.", "https://arxiv.org/abs/2511.16524"),
    ("Synthetic 3DCG boxing-match data", "Synthetic RGB at 30 fps plus 17-keypoint skeletons, four punches and hit/miss labels from 96 camera positions. Paper is CC BY-NC-ND; dataset not released.", "https://www.scitepress.org/Papers/2024/130184/130184.pdf"),
    ("Multi-person physics-based boxing pose", ">20 minutes of multi-camera elite sparring plus synchronized marker ground truth. Authors say data will be released; no release verified.", "https://arxiv.org/abs/2504.08175"),
    ("AIS depth-boxing", "605 punches from 14 elite boxers, six fine-grained punch types with temporal labels in overhead depth imagery. No public download verified.", "https://www.sciencedirect.com/science/article/pii/S1077314217300668"),
    ("Boxer tracking / re-identification corpus", "Describes 11 hours, 45 athletes and 189 top-view bouts. No data download or license found.", "https://arxiv.org/abs/2311.11471"),
    ("RGB-D boxing-pose images", "A 280-image, person-disjoint study set with five boxing poses captured using RealSense D455. No release located.", "https://www.frontiersin.org/journals/neurorobotics/articles/10.3389/fnbot.2023.1148545/full"),
    ("FACTS boxing derivative", "Resegments the Olympic dataset into 8,000 15-frame clips for fine-grained classification. It is a preprocessing derivative, not new footage; no persistent independent release verified.", "https://arxiv.org/abs/2412.16454"),
]


TRANSFER_ROWS = [
    ({"text": "UCF101", "link": "https://www.crcv.ucf.edu/research/data-sets/ucf101/"}, "RGB video", "13,320 clips / 101 classes; Boxing Punching Bag, Boxing Speed Bag, Punch", "Research benchmark; YouTube source rights unclear", "Action pretraining; bag/air-punch scenes"),
    ({"text": "KTH Actions", "link": "https://www.csc.kth.se/cvap/actions/"}, "RGB video", "2,391 sequences; 25 subjects; boxing among 6 actions", "Non-commercial research + acknowledgement", "Controlled coarse boxing baseline"),
    ({"text": "UTD-MHAD", "link": "https://cove.thecvf.com/datasets/247"}, "RGB/depth/skeleton/IMU", "861 samples; 27 actions incl. front boxing", "No clear license on listing; contact authors", "Cross-modal action and sensor fusion"),
    ({"text": "NTU RGB+D / 120", "link": "https://rose1.ntu.edu.sg/dataset/actionRecognition/"}, "RGB/depth/IR/skeleton", "56,880 / 114,480 samples; punch/slap interaction", "Academic non-commercial; no redistribution", "Pose/contact pretraining at scale"),
    ({"text": "Purdue Olympus", "link": "https://engineering.purdue.edu/RVL/Database/HumanActivity/"}, "12-view RGB", "12 subjects; 9 actions incl. boxing", "Signed license + credentials", "Controlled multiview viewpoint robustness"),
    ({"text": "UCF-ARG", "link": "https://vision.eecs.ucf.edu/data/UCF-ARG.html"}, "Multiview RGB", "Aerial, rooftop and ground views; includes boxing", "License unclear; contact UCF", "Cross-view action recognition"),
    ({"text": "Kinetics", "link": "https://github.com/cvdfoundation/kinetics-dataset"}, "Web video IDs/times", "Up to ~650K clips; boxing/punch-related classes", "Annotations/code are not source-video rights", "Large-scale checkpoint pretraining"),
    ({"text": "HAA500", "link": "https://www.cse.ust.hk/haa/"}, "RGB video", "10,000 clips / 500 classes; punching sandbag", "Source-media terms require review", "Fine-grained atomic action transfer"),
    ({"text": "HMDB51", "link": "https://serre.lab.brown.edu/resource/hmdb-a-large-human-motion-database/"}, "RGB video", "6,849 clips / 51 actions; one coarse punch class", "Research benchmark; third-party clips", "Legacy action transfer; not a punch taxonomy"),
    ({"text": "MSRAction3D", "link": "https://doi.org/10.1109/CVPRW.2010.5543273"}, "Depth/skeleton", "567 sequences; forward punch and side boxing", "Legacy dataset; verify mirror terms", "Small 3D skeleton baseline"),
    ({"text": "AVA / AVA-Kinetics", "link": "https://sites.research.google/gr/ava/download/"}, "Localized person-actions", "Movie/YouTube segments with boxes and action labels", "Annotations vs underlying-media rights differ", "Actor localization and contact actions"),
    ({"text": "CMU MoCap boxing", "link": "https://mocap.cs.cmu.edu/search.php?maincat=4&subcat=8"}, "3D motion capture", "Searchable boxing motion sequences", "Free incl. commercial products; no raw-data resale/crawling", "3D motion priors and retargeting"),
    ({"text": "mmFiT", "link": "https://data.mendeley.com/datasets/d3dt5tb74h/1"}, "mmWave radar", "7 fitness activities incl. boxing; 2 participants", "CC BY 4.0", "Radar activity recognition proof-of-concept"),
    ({"text": "COCO keypoints", "link": "https://cocodataset.org/"}, "Images + pose", "Person keypoints; no boxing labels", "Annotations CC BY 4.0; per-image licenses vary", "General pose backbone pretraining"),
    ({"text": "MPII Human Pose", "link": "https://www.mpi-inf.mpg.de/de/departments/computer-vision-and-machine-learning/software-and-datasets/mpii-human-pose-dataset"}, "Images + pose", "~25K images / >40K people / 16 joints", "YouTube-derived; review agreement", "Sports-pose transfer"),
]


COMMUNITY_ROWS = [
    ({"text": "Boxpunch Detector", "link": "https://universe.roboflow.com/markmcquade/boxpunch-detector/dataset/19"}, "347 source / 744 generated", "11 messy bag/punch/no-punch labels", "CC BY 4.0", "Tiny; vertical-flip augmentation; many forks"),
    ({"text": "Boxing Punching Detection", "link": "https://universe.roboflow.com/projectcnn/boxing-punching-detection-nv2oc/dataset/1"}, "2,347 images", "bag, cross, hook, jab, no-punch, uppercut", "Claims Public Domain", "Probable Boxpunch derivative; license conflict"),
    ({"text": "Detecting Punches", "link": "https://universe.roboflow.com/tanishq-sardana-axjt1/detecting-punches-in-boxing"}, "204 images", "bag, cross, jab, no-punch", "CC BY 4.0", "Extremely small; no provenance"),
    ({"text": "Boxing-2", "link": "https://universe.roboflow.com/opencv-aj1ab/boxing-2"}, "268 images", "block, punch", "CC BY 4.0", "No label-boundary guidance"),
    ({"text": "techling boxing", "link": "https://universe.roboflow.com/techling/boxing-r3kow/dataset/1"}, "1,134 source / 3,180 generated", "blue boxer, red boxer", "CC BY 4.0", "Only 2 test images; augmentation dominates"),
    ({"text": "Boxer Labelling", "link": "https://universe.roboflow.com/boxerclassification/boxer-labelling"}, "1,073 images", "blue boxer, red boxer", "CC BY 4.0", "Likely overlap with techling; hash-deduplicate"),
    ({"text": "SPAR.ai labels", "link": "https://universe.roboflow.com/sparai/spar.ai-labels-hi1ry"}, "3,395 images", "boxer, referee", "Claims Public Domain", "Combat-sport scope and provenance unclear"),
    ({"text": "Boxing Player Detection", "link": "https://universe.roboflow.com/boxing-game-detection/boxing-player-detection"}, "300 source images", "referee, blue-player, red-player", "CC BY 4.0", "May include game/synthetic imagery"),
    ({"text": "Project Boxing", "link": "https://universe.roboflow.com/epf-engineering-school/project-boxing"}, "110 images", "face, body, referee, boxer, gloves", "CC BY 4.0", "Tiny; known 110-image clone lineage"),
    ({"text": "Boxing Gloves N2", "link": "https://universe.roboflow.com/boxing-uuhxl/boxing-gloves-n2/dataset/1"}, "989 source / 2,365 generated", "glove instance masks; duplicated class casing", "CC BY 4.0", "Merge labels; unrealistic augmentation"),
    ({"text": "Punch Detection", "link": "https://universe.roboflow.com/cougaraiworkshop/punch-detection-4ggzh"}, "453 images", "contact, fighter, gloves, landed/thrown, etc.", "CC BY 4.0", "Useful semantics; definitions absent"),
    ({"text": "Boxing Project 1", "link": "https://universe.roboflow.com/boxing-s6q5h/boxing-project-1-mwapf/dataset/1"}, "210 source; v1 has 59 generated", "boxer keypoints", "CC BY 4.0", "No landmark schema; 2-image test in v1"),
    ({"text": "Kick and punch detection", "link": "https://universe.roboflow.com/georgebrown/kick-and-punch-object-detection/dataset/11"}, "2,047 source images", "stand, grappling, kick, punch", "CC BY 4.0", "MMA; Google/YouTube screenshots; many forks"),
]


KAGGLE_ROWS = [
    ({"text": "Boxing Matches — mexwell", "link": "https://www.kaggle.com/datasets/mexwell/boxing-matches"}, ">300K bouts; 26 columns", "Winner/record analysis", "Unknown", "Likely scraped; provenance and temporal leakage risk"),
    ({"text": "Predict the Winner — Iyad Elwy", "link": "https://www.kaggle.com/datasets/iyadelwy/boxing-matches-dataset-predict-winner"}, "Two tabular files; count not public", "Bout winner prediction", "CC0", "Sparse provenance; guard against post-bout features"),
    ({"text": "Professional Boxers with Records", "link": "https://www.kaggle.com/datasets/nomansiddiqui1010/professional-boxers-dataset-with-records"}, "328 fighters + profile images", "Athlete clustering/profile models", "MIT label", "MIT may not cover third-party images"),
    ({"text": "Sports Training Monitoring", "link": "https://www.kaggle.com/datasets/ziya07/sports-training-monitoring-dataset"}, "Aggregated 2-second sensor features", "jab/cross/hook/uppercut/idle", "CC0", "Athlete/device/protocol and raw streams unspecified"),
    ({"text": "Boxing Twitter", "link": "https://www.kaggle.com/datasets/bwandowando/boxing-twitter-dataset"}, "~1.99M tweets", "NLP/sentiment/event response", "CC BY-NC-SA 4.0 label", "Platform terms, deletions and privacy still apply"),
    ({"text": "Boxer Data", "link": "https://www.kaggle.com/datasets/mertcankarakoc/boxer-data"}, "Unspecified Selenium scrape", "Exploratory fighter records", "Original authors", "No schema, source or redistribution authorization"),
    ({"text": "100 Sports Image Classification", "link": "https://www.kaggle.com/datasets/gpiosenka/sports-classification"}, "14,493 images / 100 classes", "Static boxing-scene classification", "CC0 label", "Audit original web-image rights"),
    ({"text": "Sports Image — 22 classes", "link": "https://www.kaggle.com/datasets/sheikhzaib/sports-image-image-classification"}, "Count not public", "Static sports classification", "CC0 label", "Original image sources unclear"),
]


STRUCTURED_ROWS = [
    ({"text": "Open Boxing data + API", "link": "https://openboxing.org/data/"}, "CSV + JSON", "Bouts, champions, titles, reigns, locations, references", "Repository is MIT; preserve source citations", "Title-history and outcome features; verify coverage"),
    ({"text": "Mendeley Boxing Data", "link": "https://data.mendeley.com/datasets/vpbsd5bryy/1"}, "XLSX / 4,670 boxer-fight rows", "1,234 men, 2009–2017; purses, records, title fights, PPV, network and promoter", "CC BY 4.0", "Commission-record missingness; pair rows into bouts"),
    ({"text": "Boxing Data API", "link": "https://boxing-data.com/docs/"}, "Commercial REST API", "Fights, fighters, schedules, titles, organizations, results/scorecards", "Paid/freemium; contract controls ML reuse", "No bulk dump; verify provenance and redistribution"),
    ({"text": "FiveThirtyEight undefeated boxers", "link": "https://github.com/fivethirtyeight/data/tree/master/undefeated-boxers"}, "Small CSV", "Fighter/date/cumulative-win series", "Review repository license/source", "Narrow historical snapshot; BoxRec-derived"),
    ({"text": "Wikidata Query Service", "link": "https://query.wikidata.org/"}, "SPARQL / RDF", "Boxers, countries, divisions, identifiers and notable events", "Structured data CC0", "Bout-level coverage is incomplete and community-edited"),
    ({"text": "Olympedia boxing", "link": "https://www.olympedia.org/sports/BOX"}, "Web records", "Olympic participants, events and results", "No open bulk-training license verified", "Reference/validation source; do not scrape by default"),
    ({"text": "Paris 2024 result sheets", "link": "https://library.olympics.com/"}, "Official PDFs", "Brackets, decisions, NOCs and judge scores", "IOC copyrighted", "Public viewing is not open corpus permission"),
    ({"text": "World Boxing rankings", "link": "https://worldboxing.org/wp-content/uploads/2026/07/World-Boxing-Ranking-2026-July.pdf"}, "Monthly PDF", "Name, NOC, weight category and rank", "No open license", "Time-stamped labels; archive versions for reproducibility"),
    ({"text": "CPSC NEISS injury data", "link": "https://www.cpsc.gov/Research--Statistics/NEISS-Injury-Data"}, "Annual deidentified ED microdata", "Boxing product code 1207; diagnosis/body part/disposition/narrative", "US federal data; follow query/statistical guidance", "Do not re-identify; coding changes and sampling weights matter"),
    ({"text": "FITBIR controlled data", "link": "https://fitbir.nih.gov/content/access-data"}, "Clinical/research repository", "TBI imaging, assessments and related studies", "Controlled DUA; research/noncommercial", "Sensitive; no redistribution/reidentification; confirm service status"),
    ({"text": "BoxRec", "link": "https://boxrec.com/en/policies/terms_conditions/public"}, "Proprietary web database", "Broad fighter/event/result/official graph", "No public API/dump; automated extraction prohibited", "License/export required—do not build a scraper"),
]


DOC_ROWS = [
    ({"text": "World Boxing Competition Rules", "link": "https://worldboxing.org/wp-content/uploads/2025/09/World-Boxing-Competition-Rules-Nov-2024-Approved-4.pdf"}, "Olympic-style competition", "Bout format, age/weight, judging, fouls, knockdowns, decisions, equipment", "Canonical label ontology and validation rules"),
    ({"text": "World Boxing Medical Handbook 2025", "link": "https://worldboxing.org/wp-content/uploads/2025/08/WB-Medical-Handbook-2025.pdf"}, "Medical/safety", "Exams, exclusions, concussion/head injury, restrictions, return to boxing", "Clinical-label definitions; not patient data"),
    ({"text": "World Boxing competitions hub", "link": "https://worldboxing.org/competitions/"}, "Current official hub", "Rules, rankings, medical forms, anti-doping and event docs", "Prefer hub when documents are revised"),
    ({"text": "USA Boxing 2026 Rule Book", "link": "https://www.usaboxing.org/usa-boxing-rulebook"}, "US amateur", "Current national competition rules effective 1 Jan 2026", "US-specific scoring/event rubric"),
    ({"text": "USA Boxing officials hub", "link": "https://www.usaboxing.org/officials"}, "Officials/forms", "Officials and R&J manuals, criteria, scorecard, bout/incident/physician forms", "Annotation guidelines and form schemas"),
    ({"text": "ABC Unified Boxing Rules", "link": "https://www.abcboxing.com/unified-rules-boxing/"}, "US professional", "Rounds, scoring, knockdowns, fouls and outcomes", "Professional event/outcome ontology"),
    ({"text": "ABC Boxing Judge Manual", "link": "https://www.abcboxing.com/wp-content/uploads/2025/10/ABC-BOXING-JUDGE-MANUAL.pdf"}, "Professional judging", "Clean punching, aggressiveness, ring generalship, defense and round scoring", "Human-label rubric for score models"),
    ({"text": "ABC Boxing Referee Manual", "link": "https://www.abcboxing.com/wp-content/uploads/2025/09/ABC-BOXING-REFEREE-MANUAL.pdf"}, "Refereeing/stoppages", "Commands, fouls, counts, injury and stoppage procedures", "Temporal event/stoppage annotations"),
    ({"text": "ARP position statements", "link": "https://ringsidearp.org/consensus-statements/"}, "Combat-sports medicine", "Concussion, neuroimaging, weight management and high-risk athletes", "Safety taxonomy and clinical governance"),
    ({"text": "NINDS Sport-Related Concussion CDEs", "link": "https://commondataelements.ninds.nih.gov/Sport-Related%20Concussion"}, "Clinical standardization", "Common data elements, forms and outcome guidance", "Interoperable concussion schemas; some instruments proprietary"),
    ({"text": "Olympic ODF Boxing Data Dictionary", "link": "https://odf.olympictech.org/2024-Paris/OG/PDF/ODF_BOX_Data_Dictionary.pdf"}, "Official result schema", "Phases, boxer IDs/NOCs, decisions, judges and round scores", "Canonical database/message design; © IOC"),
    ({"text": "IBA rules hub", "link": "https://www.iba.sport/about-iba/boxing-rules/"}, "IBA competition variant", "Technical/competition and related rules", "Use only for IBA-governed labels"),
    ({"text": "WBC rules and documents", "link": "https://wbcboxing.com/en/rules-and-documents/"}, "Professional title variant", "Championship, scoring, safety and ring-official documents", "Apply only where WBC rules govern"),
    ({"text": "WBA rules", "link": "https://www.wbaboxing.com/wba-regulations/rules-of-world-boxing-association"}, "Professional title variant", "WBA championship/ranking governance", "Apply only where WBA rules govern"),
    ({"text": "IBF championship/bout rules", "link": "https://www.ibf-usba-boxing.com/wp-content/uploads/BoutRulesUpdate2025.pdf"}, "Professional title variant", "Rounds, weigh-in, scoring and contest procedures", "Apply only where IBF rules govern"),
    ({"text": "WBO regulations", "link": "https://www.wboboxing.com/wp-content/uploads/2025/04/2021-WBO-Regulations-of-World-Championship-Contests-logo.pdf"}, "Professional title variant", "WBO championship contest rules", "Apply only where WBO rules govern"),
]


TOOL_ROWS = [
    ({"text": "CVAT track mode", "link": "https://docs.cvat.ai/docs/annotation/manual-annotation/modes/track-mode-basics/"}, "Boxes/tracks/keyframes", "Interpolated boxer, glove, referee and ring-object tracks"),
    ({"text": "Label Studio video tracking", "link": "https://labelstud.io/templates/video_object_detector.html"}, "Video boxes + temporal labels", "Self-hosted review workflows for licensed broadcasts"),
    ({"text": "MMAction2 custom datasets", "link": "https://mmaction2.readthedocs.io/en/stable/advanced_guides/customize_dataset.html"}, "Video/action/skeleton training", "VideoDataset, AVA-style detection and PoseDataset formats"),
    ({"text": "MMPose custom datasets", "link": "https://mmpose.readthedocs.io/en/latest/advanced_guides/customize_datasets.html"}, "2D/3D keypoints", "COCO-format pose labels and custom skeleton metadata"),
    ({"text": "MediaPipe Pose Landmarker", "link": "https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker/index"}, "33-landmark inference", "Fast first-pass pose extraction; validate occlusion and stance bias"),
    ({"text": "COCO keypoint format", "link": "https://cocodataset.org/#format-data"}, "Interchange schema", "Widely supported person/keypoint JSON"),
    ({"text": "MOTChallenge format", "link": "https://motchallenge.net/instructions/"}, "Tracking evaluation", "Stable boxer/referee identities and MOT metrics"),
    ({"text": "YouTube trainability API", "link": "https://developers.google.com/youtube/v3/video-trainability"}, "Rights signal", "Check third-party-training permission; not a download authorization"),
    ({"text": "Wikimedia Commons reuse", "link": "https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia/en"}, "Item-level media rights", "Filter by exact license; preserve attribution/share-alike obligations"),
    ({"text": "DVIDS API terms", "link": "https://api.dvidshub.net/docs/tos"}, "US military media", "Item-level public-domain boxing/training footage where marked"),
]


def add_executive_summary(doc):
    doc.add_heading("1. Executive summary", level=1)
    p = doc.add_paragraph()
    set_run(p.add_run("This catalog contains "), size=10.5, color=INK)
    set_run(p.add_run("boxing-specific datasets, transfer benchmarks, community releases, structured records, medical sources and authoritative documentation"), size=10.5, bold=True, color=DEEP_BLUE)
    set_run(p.add_run(". It is deliberately de-duplicated: mirrors and obvious forks are recorded under a representative lineage rather than counted as new data."), size=10.5, color=INK)

    add_callout(
        doc,
        "Most useful immediate combination",
        "For research: Olympic Boxing or BoxingWeb for video events; the two CC BY biomechanics releases for sensor models; Open Boxing/Mendeley/Wikidata for structured features; and World Boxing/ABC/ODF documents for label definitions. For commercial deployment: use those sources as design references and pretraining only where terms allow, then collect or directly license representative bout footage with athlete, venue and broadcaster rights.",
        fill=PALE_TEAL,
        accent=GREEN,
    )

    doc.add_heading("Best starting source by objective", level=2)
    rows = [
        ("Fine-grained punch video", "Olympic Boxing + BoxingWeb", "Rich punch/event labels; research terms or unclear media rights"),
        ("Boxing commentary / VLM", "BoxComm + licensed source video", "Strong language/event metadata; broadcast video must be licensed"),
        ("Wearable punch recognition", "Elite wrist IMU + stance/effective-mass sets", "One small license-unclear set plus two CC BY laboratory sets"),
        ("Force / impact regression", "Effective mass + stance kinetics", "Best explicit open licensing; athlete-level splits required"),
        ("Bout / purse analytics", "Open Boxing + Mendeley Boxing Data + Wikidata", "Structured features with better licensing than scraped Kaggle copies"),
        ("Injury / concussion research", "NEISS + NINDS CDEs + controlled FITBIR", "No open synchronized boxing video–clinical injury corpus exists"),
        ("Commercial vision model", "Licensed first-party capture + allowed transfer weights", "Public benchmarks rarely include commercial broadcast rights"),
    ]
    add_matrix_table(doc, ["Objective", "Start with", "Why / constraint"], rows, [1.55, 2.15, 2.80], font_size=9.0)

    doc.add_heading("Access-status legend", level=2)
    legend_rows = []
    for key, meaning in (
        ("OPEN", "Directly downloadable with an explicit open data license verified."),
        ("LIMITED", "Downloadable or reconstructable, but non-commercial, unclear, item-level or upstream media restrictions apply."),
        ("CONTROLLED", "Registration, request, DUA, payment or written permission is required."),
        ("DESCRIBED", "A paper/project describes the data, but no public live release and dataset license were verified."),
    ):
        legend_rows.append((("status", key, ""), meaning))
    add_matrix_table(doc, ["Status", "Meaning"], legend_rows, [1.35, 5.15], font_size=9.1, keep_table=True)

    doc.add_heading("Four conclusions that should shape the project", level=2)
    bullets = [
        ("Do not equate access with permission.", " Kaggle, Zenodo, Hugging Face, YouTube and public PDFs can be accessible while still lacking ML-training or redistribution rights."),
        ("Separate every rights layer.", " Code, pretrained weights, annotations, source video, commentary, scorecards and health records can each have different owners and terms."),
        ("Split by identity and event.", " Random frames or sensor windows leak boxer, bout, camera and background identity, producing inflated test results."),
        ("Rules are label specifications, not corpora.", " World Boxing, ABC, USA Boxing and sanctioning-body manuals are authoritative ontologies; bulk text training still needs permission."),
    ]
    for lead, tail in bullets:
        p = doc.add_paragraph(style="List Bullet")
        set_run(p.add_run(lead), bold=True, color=DEEP_BLUE)
        set_run(p.add_run(tail), color=INK)


def add_core_section(doc):
    doc.add_heading("2. Boxing-specific datasets", level=1)
    p = doc.add_paragraph("The entries below are ordered by practical value and evidence quality, not by raw size. Each status describes the dataset—not the paper or code license.")
    set_run(p.runs[0], color=MUTED, italic=True)
    for item in CORE_DATASETS:
        add_detail_entry(doc, item)

    doc.add_heading("Additional public but weakly documented sources", level=2)
    rows = [
        ({"text": "punch_dataset", "link": "https://github.com/hasanshin/punch_dataset"}, "Sparse files for straight/swing/uppercut/uraken × left/right", "Public GitHub; no README, schema, sample count or license", "Inspect manually; provenance not adequate for production"),
        ({"text": "PoseC3D boxing project", "link": "https://github.com/dhanush-bhargav/mmaction2"}, "Community PKL keypoints; ~270 train / 70 validation; six punches", "Branch dbhargav-dev; no clear data license/provenance", "Useful implementation example, not a clean benchmark"),
    ]
    add_matrix_table(doc, ["Source", "What is there", "Access", "Assessment"], rows, [1.35, 2.05, 1.55, 1.55], font_size=8.6)

    doc.add_heading("Described in research, but not presently public", level=2)
    p = doc.add_paragraph("These are valuable leads for author outreach or methodology review. They should not be placed in a training plan as downloadable data until access and rights are confirmed.")
    set_run(p.runs[0], color=MUTED)
    rows = []
    for title, detail, link in PAPER_ONLY:
        rows.append(({"text": title, "link": link}, detail, "PAPER-ONLY"))
    add_matrix_table(doc, ["Study / dataset", "Verified description", "Status"], rows, [1.65, 4.15, 0.70], font_size=8.25)


def add_transfer_section(doc):
    doc.add_heading("3. Transfer-learning and pose/action foundations", level=1)
    p = doc.add_paragraph("These sources contain boxing, punching or useful pose/action supervision, but most do not distinguish boxing punch types or landed contact. They are best used for initialization, representation learning, or robustness testing—not as the final ground truth.")
    set_run(p.runs[0], color=MUTED)
    add_matrix_table(
        doc,
        ["Dataset", "Modality", "Scale / relevant label", "Access / rights", "Best role"],
        TRANSFER_ROWS,
        [1.20, 1.05, 1.75, 1.35, 1.15],
        font_size=7.65,
    )

    add_callout(
        doc,
        "Checkpoint licensing matters too",
        "An Apache-2.0 code repository does not erase the restrictions of the dataset used to train a published weight file. Record the model card, training sources, weight license and allowed use separately from framework code.",
        fill=PALE_GOLD,
        accent=AMBER,
    )


def add_community_section(doc):
    doc.add_heading("4. Community-hosted datasets and discovery leads", level=1)
    p = doc.add_paragraph("Community repositories can accelerate prototyping, but their uploader-selected licenses often do not establish rights to the underlying broadcast frames or web images. Treat them as leads until provenance is audited. Exact-looking mirrors and forks are consolidated below.")
    set_run(p.runs[0], color=MUTED)

    doc.add_heading("Roboflow Universe — representative lineages", level=2)
    add_matrix_table(
        doc,
        ["Project", "Scale", "Labels", "Displayed license", "Critical issue"],
        COMMUNITY_ROWS,
        [1.25, 1.05, 1.55, 1.05, 1.60],
        font_size=7.45,
    )

    doc.add_heading("Kaggle and static-image / tabular community releases", level=2)
    add_matrix_table(
        doc,
        ["Dataset", "Scale", "Task", "Displayed license", "Critical issue"],
        KAGGLE_ROWS,
        [1.45, 1.15, 1.30, 1.05, 1.55],
        font_size=7.65,
    )

    add_callout(
        doc,
        "Community-data acceptance test",
        "Before ingesting: open the actual archive; inspect labels and split manifests; hash-deduplicate originals and augmentations; identify the source of every image/video; reconcile any upstream license; and run a small manual annotation audit. A platform badge alone is not sufficient provenance.",
        fill=PALE_RED,
        accent=RED,
    )


def add_structured_section(doc):
    doc.add_heading("5. Bouts, fighters, scoring, business and health data", level=1)
    p = doc.add_paragraph("These resources support outcome models, ranking graphs, purse economics, clinical surveillance and schema design. They do not replace punch-level supervision and must be time-split to avoid using future records to predict past bouts.")
    set_run(p.runs[0], color=MUTED)
    add_matrix_table(
        doc,
        ["Source", "Format / scale", "Fields", "Access / rights", "ML note"],
        STRUCTURED_ROWS,
        [1.30, 1.20, 1.65, 1.35, 1.00],
        font_size=7.45,
    )

    doc.add_heading("Official commission results: useful, but jurisdiction-specific", level=2)
    rows = [
        ({"text": "California CSAC results", "link": "https://www.dca.ca.gov/csac/stats_regs/"}, "Event/result PDFs; some include purses, suspensions or personal fields", "DCA permits copying for non-commercial use with notices; minimize PII/medical data"),
        ({"text": "Nevada results", "link": "https://boxing.nv.gov/results/2026_Results/"}, "Official event result records", "No clear open ML/bulk-reuse license; request permission"),
        ({"text": "Pennsylvania results", "link": "https://www.pa.gov/agencies/dos/programs/state-athletic/results"}, "Official event result records", "No clear open ML/bulk-reuse license; request permission"),
    ]
    add_matrix_table(doc, ["Source", "Content", "Constraint"], rows, [1.65, 2.20, 2.65], font_size=8.7)


def add_docs_section(doc):
    doc.add_heading("6. Authoritative rules, schemas and safety documentation", level=1)
    add_callout(
        doc,
        "Use documents as annotation contracts",
        "Translate the governing rule set into versioned label definitions, decision logic and annotator examples. Record organization, jurisdiction, effective date and event because Olympic-style, national-amateur and professional title rules are not interchangeable.",
        fill=PALE_BLUE,
    )
    add_matrix_table(
        doc,
        ["Document", "Domain", "What it defines", "ML use"],
        DOC_ROWS,
        [1.60, 1.20, 2.35, 1.35],
        font_size=7.75,
    )

    p = doc.add_paragraph(style="Small Note")
    set_run(p.add_run("Rights note. "), bold=True, color=MUTED)
    set_run(p.add_run("No open-content license was found for most federation, commission and sanctioning-body manuals. Hyperlink and cite them for definitions; obtain permission before bulk text ingestion, republishing excerpts, or training a document model on the full corpus."), color=MUTED)


def add_tools_section(doc):
    doc.add_heading("7. Annotation, formats and model-development documentation", level=1)
    p = doc.add_paragraph("A consistent schema is more valuable than a larger pile of incompatible labels. The sources below cover video tracking, temporal action labels, pose, model inputs and rights-aware media discovery.")
    set_run(p.runs[0], color=MUTED)
    add_matrix_table(doc, ["Documentation", "Function", "Recommended use"], TOOL_ROWS, [2.0, 1.65, 2.85], font_size=8.35)

    doc.add_heading("Recommended boxing annotation schema", level=2)
    schema_rows = [
        ("Asset", "asset_id, rights_id, bout_id, round, camera_id, fps, time base, source URI, hash"),
        ("People", "boxer_id, corner/color, stance, track_id, visible/occluded, referee track"),
        ("Punch event", "start/contact/end; lead/rear; jab/cross/hook/uppercut/other; head/body; landed/blocked/missed; confidence"),
        ("Context", "range (long/mid/close), ring zone, opponent state, clinch, knockdown, foul, stoppage, replay flag"),
        ("Pose/sensors", "keypoint schema/version; device/site; sampling rate; clock offset; calibration; missingness"),
        ("Outcome", "round scores by judge, deductions, decision code, official result, rule-set version"),
        ("Safety", "deidentified event flags only unless governed by consent/IRB/DUA; never infer a clinical diagnosis from video alone"),
    ]
    add_matrix_table(doc, ["Layer", "Minimum fields"], schema_rows, [1.25, 5.25], font_size=8.8)


def add_plan_section(doc):
    doc.add_heading("8. Recommended training and evaluation plan", level=1)

    doc.add_heading("A. Choose the product target before the data", level=2)
    rows = [
        ("Gym punch coach", "First-party phone/video + wrist IMU", "Punch family, hand, form, tempo; personal calibration", "Pose + temporal classifier / sensor fusion"),
        ("Broadcast analytics", "Direct broadcaster/event license", "Tracks, punches, contact, round/score context", "Detector + tracker + temporal event model"),
        ("Commentary system", "Licensed bout video + BoxComm-style annotations", "Play-by-play, tactical and contextual sentences", "Video-language model with grounded events"),
        ("Impact / biomechanics", "CC BY lab sensors + new calibrated cohort", "Force, impulse, stance, participant/device metadata", "Physics-informed regression + uncertainty"),
        ("Bout outcome", "Open Boxing/Mendeley + time-stamped licensed records", "Pre-bout-only record, age, stance, division, activity", "Temporal tabular/graph model"),
    ]
    add_matrix_table(doc, ["Product", "Data backbone", "Labels", "Model family"], rows, [1.25, 1.75, 2.05, 1.45], font_size=8.25)

    doc.add_heading("B. Split to match deployment", level=2)
    for text in (
        "Hold out boxers, bouts and venues—not random frames. For sensors, hold out participants and preferably a device/session as well.",
        "Keep every derivative clip, frame and augmentation from one source video in the same partition.",
        "Use a chronological test for rankings/outcomes. Freeze the feature timestamp at bout announcement or weigh-in to prevent future-record leakage.",
        "Report performance separately by gender, skin tone/lighting, stance, weight class, camera angle, occlusion, experience and left/right hand where sample sizes permit.",
    ):
        doc.add_paragraph(text, style="List Bullet")

    doc.add_heading("C. Measure the right thing", level=2)
    metrics = [
        ("Punch event detection", "mAP at temporal IoU, event F1 with tolerance windows, onset/contact timing error"),
        ("Punch classification", "Macro-F1, balanced accuracy, per-class recall, confusion by hand/target"),
        ("Tracking", "HOTA, IDF1, ID switches, track recall under occlusion and camera cuts"),
        ("Pose", "OKS/AP or PCK, wrist/elbow error, temporal jitter and missing-joint rate"),
        ("Sensors / force", "Participant-held-out macro-F1; MAE/RMSE; calibration curves and confidence intervals"),
        ("Commentary", "Grounded event precision/recall, timing, category compliance, factuality, expert human review"),
        ("Outcome models", "Time-split log loss/Brier, calibration, subgroup stability; compare with simple rating baselines"),
    ]
    add_matrix_table(doc, ["Task", "Primary metrics"], metrics, [1.65, 4.85], font_size=8.35)

    doc.add_heading("D. Provenance ledger — non-negotiable fields", level=2)
    p = doc.add_paragraph("Maintain one row per asset and one row per derived artifact. At minimum record:")
    set_run(p.runs[0], color=MUTED)
    for text in (
        "Source URL and immutable item/version ID; retrieval date; file hash; original creator and rights holder.",
        "Exact license/terms version; commercial-training permission; redistribution/derivatives; attribution and share-alike obligations.",
        "Consent/release, age/minor status, biometric/health flags, jurisdiction, retention and deletion requirements.",
        "Transformation lineage from source video to frames, clips, pose, embeddings, labels and model weights.",
        "Rule-set and annotation-guide version; annotator/reviewer IDs; disagreement/adjudication; quality sample results.",
    ):
        doc.add_paragraph(text, style="List Bullet")

    add_callout(
        doc,
        "Medical boundary",
        "No verified open dataset pairs boxing video/punch events with clinical concussion or injury diagnoses at useful scale. Treat head-impact and NEISS sources as separate research domains. A model must not diagnose or clear an athlete to return from video or wearable signals without validated clinical governance.",
        fill=PALE_RED,
        accent=RED,
    )


def add_source_notes(doc):
    doc.add_heading("9. Audit notes and link hygiene", level=1)
    for text in (
        "All hyperlinks were checked or corroborated against an official page, repository, dataset card, DOI record or peer-reviewed paper during the 7 August 2026 audit.",
        "Counts can refer to source videos, clips, frames, annotations or generated images. The report labels the unit whenever the public source made it clear.",
        "Platform metadata can change. Re-check the live license, files and access route immediately before acquisition, and archive the terms/version used for approval.",
        "A missing license is not a public-domain dedication. Contact the creator or rights holder for a written license before training, redistribution or commercialization.",
        "The catalog excludes boxing videogame/Atari datasets, boxer-dog images, packaging 'box' data and generic violence sets unless a source explicitly supports physical boxing ML.",
    ):
        doc.add_paragraph(text, style="List Bullet")

    doc.add_heading("Legally safer media discovery", level=2)
    rows = [
        ({"text": "DVIDS boxing media", "link": "https://www.dvidshub.net/search?q=boxing"}, "Often US-government public domain where item says so", "Check every item's restrictions, releases and withdrawal status; domain is military/training"),
        ({"text": "Wikimedia Commons boxing", "link": "https://commons.wikimedia.org/wiki/Category:Boxing"}, "Mixed CC BY / CC BY-SA / public-domain files", "Filter and store item-level license/attribution; personality and trademark rights remain"),
        ({"text": "Library of Congress films", "link": "https://www.loc.gov/free-to-use/public-domain-films-from-the-national-film-registry"}, "Selected public-domain films", "Verify each item’s rights notice; historical domain shift"),
    ]
    add_matrix_table(doc, ["Source", "Rights signal", "Caution"], rows, [1.75, 2.10, 2.65], font_size=8.05)

def build():
    doc = Document()
    setup_styles(doc)
    setup_page(doc)
    props = doc.core_properties
    props.title = "Boxing ML Data & Documentation"
    props.subject = "Source-linked boxing datasets and documentation for machine learning"
    props.author = "OpenAI Codex"
    props.keywords = "boxing, machine learning, datasets, computer vision, biomechanics, IMU, scoring, documentation"
    props.comments = "Source audit completed 7 August 2026."

    add_cover(doc)
    add_executive_summary(doc)
    add_core_section(doc)
    add_transfer_section(doc)
    add_community_section(doc)
    add_structured_section(doc)
    add_docs_section(doc)
    add_tools_section(doc)
    add_plan_section(doc)
    add_source_notes(doc)

    # Avoid a visually sparse final paragraph after tables and keep compatibility broad.
    doc.settings.update_fields_on_open = True
    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc.save(OUT)
    print(OUT)


if __name__ == "__main__":
    build()
