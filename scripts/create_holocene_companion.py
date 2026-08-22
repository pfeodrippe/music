from __future__ import annotations

import math
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph


OUT = Path("/Users/pfeodrippe/dev/music/output/pdf/holocene_piano_voice_performance_companion.pdf")
PAGE_W, PAGE_H = letter

INK = colors.HexColor("#1D2733")
MUTED = colors.HexColor("#5F6B76")
ACCENT = colors.HexColor("#3C6573")
PALE = colors.HexColor("#EAF0F1")
WARM = colors.HexColor("#F6F2EA")

APPLE_SYMBOLS = "/System/Library/Fonts/Apple Symbols.ttf"
HELVETICA = "/System/Library/Fonts/Helvetica.ttc"

if Path(APPLE_SYMBOLS).exists():
    pdfmetrics.registerFont(TTFont("AppleSymbols", APPLE_SYMBOLS))


def p(c: canvas.Canvas, text: str, x: float, y: float, w: float, h: float,
      size: float = 9, color=INK, align=TA_LEFT, leading: float | None = None,
      font: str = "Helvetica") -> None:
    style = ParagraphStyle(
        "local",
        fontName=font,
        fontSize=size,
        leading=leading or size * 1.28,
        textColor=color,
        alignment=align,
        spaceAfter=0,
    )
    para = Paragraph(text, style)
    _, rendered_h = para.wrap(w, h)
    para.drawOn(c, x, y + h - rendered_h)


def round_rect(c: canvas.Canvas, x: float, y: float, w: float, h: float,
               fill, radius: float = 8, stroke=None) -> None:
    c.setFillColor(fill)
    c.setStrokeColor(stroke or fill)
    c.roundRect(x, y, w, h, radius, fill=1, stroke=1 if stroke else 0)


def header(c: canvas.Canvas, page_no: int, section: str) -> None:
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(42, PAGE_H - 28, "HOLOCENE - PIANO & VOICE PERFORMANCE COMPANION")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 8)
    c.drawRightString(PAGE_W - 42, PAGE_H - 28, f"{section}  |  {page_no}")
    c.setStrokeColor(colors.HexColor("#CFD7DA"))
    c.setLineWidth(0.6)
    c.line(42, PAGE_H - 36, PAGE_W - 42, PAGE_H - 36)


def footer(c: canvas.Canvas, page_no: int) -> None:
    c.setStrokeColor(colors.HexColor("#D7DDDF"))
    c.setLineWidth(0.5)
    c.line(42, 34, PAGE_W - 42, 34)
    c.setFont("Helvetica", 7.2)
    c.setFillColor(MUTED)
    c.drawString(42, 22, "Original accompaniment study in C - vocal melody and lyrics intentionally omitted")
    c.drawRightString(PAGE_W - 42, 22, str(page_no))


NOTE_ORDER = {"C": 0, "D": 1, "E": 2, "F": 3, "G": 4, "A": 5, "B": 6}


def diatonic(note: str) -> int:
    letter = note[0]
    octave = int(note[-1])
    return octave * 7 + NOTE_ORDER[letter]


def note_y(note: str, staff_bottom: float, clef: str, gap: float = 7) -> float:
    ref = "E4" if clef == "treble" else "G2"
    return staff_bottom + (diatonic(note) - diatonic(ref)) * (gap / 2)


def ledger_lines(c: canvas.Canvas, x: float, y: float, staff_bottom: float,
                 gap: float = 7) -> None:
    top = staff_bottom + 4 * gap
    c.setStrokeColor(INK)
    c.setLineWidth(0.65)
    if y < staff_bottom - 0.1:
        ly = staff_bottom - gap
        while ly >= y - 0.1:
            c.line(x - 6, ly, x + 6, ly)
            ly -= gap
    elif y > top + 0.1:
        ly = top + gap
        while ly <= y + 0.1:
            c.line(x - 6, ly, x + 6, ly)
            ly += gap


def notehead(c: canvas.Canvas, x: float, y: float, filled: bool = True,
             scale: float = 1.0) -> None:
    c.saveState()
    c.translate(x, y)
    c.rotate(-15)
    c.setStrokeColor(INK)
    c.setFillColor(INK if filled else colors.white)
    c.setLineWidth(0.85)
    c.ellipse(-4.2 * scale, -2.8 * scale, 4.2 * scale, 2.8 * scale,
              fill=1, stroke=1)
    c.restoreState()


def draw_half_note(c: canvas.Canvas, x: float, note: str, staff_bottom: float,
                   clef: str, octave_note: str | None = None) -> None:
    ys = [note_y(note, staff_bottom, clef)]
    if octave_note:
        ys.append(note_y(octave_note, staff_bottom, clef))
    for y in ys:
        ledger_lines(c, x, y, staff_bottom)
        notehead(c, x, y, filled=False)
    c.setStrokeColor(INK)
    c.setLineWidth(0.8)
    c.line(x + 4, min(ys), x + 4, max(ys) + 23)


def draw_eighth_group(c: canvas.Canvas, xs: list[float], notes: list[str],
                      staff_bottom: float, clef: str = "treble") -> None:
    ys = [note_y(n, staff_bottom, clef) for n in notes]
    beam_y = max(max(ys) + 23, staff_bottom + 4 * 7 + 14)
    c.setStrokeColor(INK)
    c.setFillColor(INK)
    for x, y in zip(xs, ys):
        ledger_lines(c, x, y, staff_bottom)
        notehead(c, x, y)
        c.setLineWidth(0.8)
        c.line(x + 4, y, x + 4, beam_y)
    c.setLineWidth(4)
    c.line(xs[0] + 4, beam_y, xs[-1] + 4, beam_y)


def draw_quarter_chord(c: canvas.Canvas, x: float, notes: list[str],
                       staff_bottom: float, clef: str = "treble") -> None:
    ys = [note_y(n, staff_bottom, clef) for n in notes]
    for i, y in enumerate(ys):
        dx = 2 if i and abs(y - ys[i - 1]) < 5 else 0
        ledger_lines(c, x + dx, y, staff_bottom)
        notehead(c, x + dx, y)
    c.setStrokeColor(INK)
    c.setLineWidth(0.8)
    c.line(x + 4, min(ys), x + 4, max(ys) + 24)


def draw_clef(c: canvas.Canvas, x: float, staff_bottom: float, clef: str) -> None:
    c.setFillColor(INK)
    if "AppleSymbols" in pdfmetrics.getRegisteredFontNames():
        c.setFont("AppleSymbols", 37 if clef == "treble" else 30)
        glyph = "\U0001D11E" if clef == "treble" else "\U0001D122"
        y = staff_bottom - 9 if clef == "treble" else staff_bottom - 1
        c.drawString(x, y, glyph)
    else:
        c.setFont("Helvetica-Bold", 13)
        c.drawString(x, staff_bottom + 8, "G" if clef == "treble" else "F")


def draw_grand_staff(c: canvas.Canvas, x0: float, x1: float,
                     treble_bottom: float, bass_bottom: float,
                     time_signature: bool = False) -> None:
    c.setStrokeColor(INK)
    c.setLineWidth(0.6)
    for bottom in (treble_bottom, bass_bottom):
        for i in range(5):
            y = bottom + i * 7
            c.line(x0, y, x1, y)
    c.setLineWidth(1.0)
    c.line(x0, bass_bottom, x0, treble_bottom + 28)
    # Compact bracket/brace at the left.
    c.setLineWidth(1.2)
    c.bezier(x0 - 5, bass_bottom, x0 - 13, bass_bottom + 18,
             x0 - 2, (bass_bottom + treble_bottom) / 2 - 2,
             x0 - 8, (bass_bottom + treble_bottom) / 2 + 3)
    c.bezier(x0 - 8, (bass_bottom + treble_bottom) / 2 + 3,
             x0 - 2, (bass_bottom + treble_bottom) / 2 + 8,
             x0 - 13, treble_bottom + 10, x0 - 5, treble_bottom + 28)
    draw_clef(c, x0 + 7, treble_bottom, "treble")
    draw_clef(c, x0 + 9, bass_bottom, "bass")
    if time_signature:
        c.setFont("Times-Bold", 15)
        c.setFillColor(INK)
        for bottom in (treble_bottom, bass_bottom):
            c.drawString(x0 + 36, bottom + 14, "4")
            c.drawString(x0 + 36, bottom + 1, "4")


ARPS = {
    "Cadd9": ["G3", "D4", "E4", "G4", "D4", "E4", "G4", "E4"],
    "Am7(add11)": ["G3", "C4", "E4", "A4", "E4", "C4", "G3", "C4"],
    "Gsus4(add9) - G": ["G3", "A3", "D4", "G4", "D4", "C4", "B3", "D4"],
    "Fmaj9": ["G3", "A3", "C4", "E4", "C4", "A3", "G3", "C4"],
    "Cadd9/G": ["G3", "C4", "D4", "E4", "G4", "E4", "D4", "C4"],
}

LH = {
    "Cadd9": (("C2", None), ("G2", None)),
    "Am7(add11)": (("A2", None), ("E3", None)),
    "Gsus4(add9) - G": (("G2", None), ("D3", None)),
    "Fmaj9": (("F2", None), ("C3", None)),
    "Cadd9/G": (("G2", None), ("C3", None)),
}

CHORUS_CHORDS = {
    "Fmaj9": ["A3", "C4", "E4", "G4"],
    "Am7(add11)": ["G3", "C4", "D4", "E4"],
    "Gsus4(add9) - G": ["A3", "C4", "D4", "G4"],
    "Cadd9/G": ["G3", "C4", "D4", "E4"],
    "Cadd9": ["G3", "D4", "E4", "G4"],
}


def draw_bar(c: canvas.Canvas, x: float, w: float, treble: float, bass: float,
             chord: str, bar_no: int, first: bool = False,
             style: str = "arp", dynamic: str | None = None,
             hairpin: str | None = None) -> None:
    content_x0 = x + (47 if first else 9)
    content_x1 = x + w - 8
    c.setFillColor(ACCENT)
    c.setFont("Helvetica-Bold", 8.6)
    c.drawCentredString((content_x0 + content_x1) / 2, treble + 45, chord)
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 6.8)
    c.drawString(x + 3, treble + 33, str(bar_no))

    if style == "arp":
        notes = ARPS[chord]
        positions = [content_x0 + (content_x1 - content_x0) * (i + 0.5) / 8 for i in range(8)]
        draw_eighth_group(c, positions[:4], notes[:4], treble)
        draw_eighth_group(c, positions[4:], notes[4:], treble)
        lh = LH[chord]
        draw_half_note(c, content_x0 + (content_x1 - content_x0) * 0.18,
                       lh[0][0], bass, "bass", lh[0][1])
        draw_half_note(c, content_x0 + (content_x1 - content_x0) * 0.60,
                       lh[1][0], bass, "bass", lh[1][1])
    else:
        voicing = CHORUS_CHORDS[chord]
        positions = [content_x0 + (content_x1 - content_x0) * t for t in (0.13, 0.37, 0.61, 0.85)]
        for i, px in enumerate(positions):
            if i in (0, 2):
                draw_quarter_chord(c, px, voicing, treble)
            else:
                inner = voicing[1:]
                draw_quarter_chord(c, px, inner, treble)
        root, fifth = LH[chord]
        octave_map = {"F2": "F3", "A2": "A3", "G2": "G3", "C2": "C3"}
        draw_half_note(c, positions[0], root[0], bass, "bass", octave_map.get(root[0]))
        draw_half_note(c, positions[2], fifth[0], bass, "bass")

    if dynamic:
        c.setFillColor(INK)
        c.setFont("Times-Italic", 12)
        c.drawString(content_x0, bass - 25, dynamic)
    if hairpin:
        y = bass - 17
        c.setStrokeColor(INK)
        c.setLineWidth(0.7)
        if hairpin == "cres":
            c.line(content_x0 + 18, y, content_x1, y + 5)
            c.line(content_x0 + 18, y, content_x1, y - 5)
        else:
            c.line(content_x0 + 18, y + 5, content_x1, y)
            c.line(content_x0 + 18, y - 5, content_x1, y)

    c.setStrokeColor(INK)
    c.setLineWidth(0.8)
    c.line(x + w, bass, x + w, treble + 28)


def draw_system(c: canvas.Canvas, y_top: float, chords: list[str], start_bar: int,
                style: str, dynamics: dict[int, tuple[str | None, str | None]] | None = None,
                end_repeat: bool = False, double_final: bool = False) -> None:
    x0, x1 = 54, PAGE_W - 46
    treble = y_top - 40
    bass = y_top - 112
    draw_grand_staff(c, x0, x1, treble, bass, time_signature=True)
    n = len(chords)
    widths = []
    initial = 49
    body = x1 - x0 - initial
    for i in range(n):
        widths.append((body / n) + (initial if i == 0 else 0))
    x = x0
    for i, (chord, w) in enumerate(zip(chords, widths)):
        dyn, hair = (dynamics or {}).get(i, (None, None))
        draw_bar(c, x, w, treble, bass, chord, start_bar + i,
                 first=i == 0, style=style, dynamic=dyn, hairpin=hair)
        x += w
    if end_repeat:
        c.setLineWidth(2.1)
        c.line(x1 - 5, bass, x1 - 5, treble + 28)
        c.setLineWidth(0.8)
        c.line(x1 - 10, bass, x1 - 10, treble + 28)
        c.setFillColor(INK)
        c.circle(x1 - 15, treble + 10, 1.5, fill=1, stroke=0)
        c.circle(x1 - 15, treble + 18, 1.5, fill=1, stroke=0)
    if double_final:
        c.setLineWidth(0.8)
        c.line(x1 - 7, bass, x1 - 7, treble + 28)
        c.setLineWidth(2.2)
        c.line(x1 - 2, bass, x1 - 2, treble + 28)


def title_page_content(c: canvas.Canvas) -> None:
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 24)
    c.drawString(48, PAGE_H - 82, "Holocene")
    c.setFont("Helvetica", 13)
    c.setFillColor(ACCENT)
    c.drawString(49, PAGE_H - 103, "Piano & voice performance companion")

    round_rect(c, 48, PAGE_H - 166, PAGE_W - 96, 44, WARM)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(62, PAGE_H - 143, "Key C major")
    c.drawString(178, PAGE_H - 143, "4/4")
    c.drawString(238, PAGE_H - 143, "Quarter = 75")
    c.drawString(358, PAGE_H - 143, "Warm, spacious folk ballad")

    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 11)
    c.drawString(48, PAGE_H - 194, "PERFORMANCE ROADMAP")

    roadmap = [
        ("INTRO", "Cell A x2", "pp - piano only"),
        ("VERSE 1", "Cell A x2", "pp to p; enter voice"),
        ("CHORUS 1", "Cell B", "p to mp"),
        ("INTERLUDE", "Cell A x1", "return to p"),
        ("VERSE 2", "Cell A x3", "gradual build"),
        ("CHORUS 2", "Cell B", "mp; broader bass"),
        ("INTERLUDE", "Cell A x1", "thin texture"),
        ("VERSE 3", "Cell A x2", "p, then crescendo"),
        ("FINAL CHORUS", "Cell C", "mf; widest register"),
        ("OUTRO", "Cell D", "rit. and fade"),
    ]
    x, y = 48, PAGE_H - 219
    row_h = 24
    col = [105, 115, PAGE_W - 96 - 220]
    for i, row in enumerate(roadmap):
        fill = PALE if i % 2 == 0 else colors.white
        c.setFillColor(fill)
        c.rect(x, y - row_h, sum(col), row_h, fill=1, stroke=0)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 8.2)
        c.drawString(x + 8, y - 16, row[0])
        c.setFont("Helvetica", 8.2)
        c.drawString(x + col[0] + 7, y - 16, row[1])
        c.setFillColor(MUTED)
        c.drawString(x + col[0] + col[1] + 7, y - 16, row[2])
        y -= row_h

    round_rect(c, 48, 76, PAGE_W - 96, 126, PALE)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(62, 181, "HOW TO USE THIS SCORE")
    p(c,
      "This is a complete <b>performance roadmap and original piano accompaniment</b>. "
      "It deliberately omits the protected vocal melody and lyrics. Sing from memory or "
      "place a licensed piano/vocal edition beside it. Cell A supplies the finger-picked "
      "verse texture; Cell B supplies the chorus; Cell C expands the final chorus; Cell D "
      "closes the performance.",
      62, 108, PAGE_W - 124, 62, size=8.7, color=INK, leading=12)
    p(c,
      "Pedal: change with every chord. Half-pedal in the middle register; clear completely "
      "whenever the bass changes. Keep the right hand under the vocal and leave the final "
      "chord ringing.",
      62, 86, PAGE_W - 124, 32, size=8.2, color=MUTED, leading=11)


def page_cell_a(c: canvas.Canvas) -> None:
    header(c, 2, "CELL A - INTRO / VERSE")
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 18)
    c.drawString(46, PAGE_H - 70, "Cell A - finger-picked verse texture")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 8.5)
    c.drawString(47, PAGE_H - 87, "Even eighth notes; top voice slightly projected. Repeat according to the roadmap.")

    draw_system(c, PAGE_H - 119,
                ["Cadd9", "Am7(add11)", "Gsus4(add9) - G"],
                1, "arp", {0: ("pp", "cres")})
    draw_system(c, PAGE_H - 294,
                ["Am7(add11)", "Fmaj9", "Fmaj9"],
                4, "arp", {2: (None, "dim")}, end_repeat=True)

    round_rect(c, 46, 96, PAGE_W - 92, 182, WARM)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(60, 257, "VOICE-FIRST PERFORMANCE NOTES")
    notes = [
        ("Intro", "First pass: RH only or very light single bass notes. Second pass: use the written LH."),
        ("Verses", "Do not accent every bass change. The singer supplies the phrase; the piano supplies the horizon."),
        ("Bar 3", "Resolve C to B only on the final eighth note. That small release keeps the harmony alive."),
        ("Bar 6", "Leave a breath-sized space before repeating. Release pedal with the singer's breath."),
        ("Balance", "Aim for 70% voice / 30% piano. If a word loses clarity, remove RH notes before playing softer."),
    ]
    yy = 234
    for label, text in notes:
        c.setFillColor(ACCENT)
        c.setFont("Helvetica-Bold", 8.2)
        c.drawString(60, yy, label.upper())
        p(c, text, 118, yy - 9, PAGE_W - 186, 22, size=8.1, color=INK, leading=10)
        yy -= 31
    footer(c, 2)


def page_cell_b(c: canvas.Canvas) -> None:
    header(c, 3, "CELL B - CHORUS")
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 18)
    c.drawString(46, PAGE_H - 70, "Cell B - opening choruses")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 8.5)
    c.drawString(47, PAGE_H - 87, "Broader quarter-note voicings over a calm half-note bass. Keep the pulse flowing.")

    systems = [
        (["Fmaj9", "Am7(add11)", "Gsus4(add9) - G", "Fmaj9"], 1),
        (["Am7(add11)", "Gsus4(add9) - G", "Fmaj9", "Am7(add11)"], 5),
        (["Cadd9/G", "Am7(add11)", "Fmaj9", "Cadd9"], 9),
    ]
    tops = [PAGE_H - 118, PAGE_H - 309, PAGE_H - 500]
    for idx, ((chords, start), top) in enumerate(zip(systems, tops)):
        dyn = {0: (("p" if idx == 0 else None), "cres" if idx < 2 else "dim")}
        draw_system(c, top, chords, start, "chord", dyn, double_final=idx == 2)

    c.setFillColor(MUTED)
    c.setFont("Helvetica-Oblique", 7.7)
    c.drawString(48, 50, "At bar 11, let the Fmaj9 breathe; move to Cadd9 only after the vocal resolves.")
    footer(c, 3)


def page_cells_cd(c: canvas.Canvas) -> None:
    header(c, 4, "CELLS C & D - FINAL BUILD / OUTRO")
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 18)
    c.drawString(46, PAGE_H - 70, "Cell C - final chorus")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 8.5)
    c.drawString(47, PAGE_H - 87, "Play Cell B, but use these expanded voicings for its final four bars.")

    draw_system(c, PAGE_H - 120,
                ["Cadd9/G", "Am7(add11)", "Fmaj9", "Cadd9"],
                9, "chord", {0: ("mf", "cres"), 3: (None, "dim")}, double_final=True)

    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 15)
    c.drawString(46, PAGE_H - 336, "Cell D - four-bar outro")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 8.5)
    c.drawString(47, PAGE_H - 352, "Return to arpeggios. Begin ritardando in bar 3; hold the final chord freely.")
    draw_system(c, PAGE_H - 383,
                ["Am7(add11)", "Fmaj9", "Gsus4(add9) - G", "Cadd9"],
                1, "arp", {0: ("p", "dim"), 2: ("rit.", None), 3: ("pp", None)}, double_final=True)

    round_rect(c, 46, 70, PAGE_W - 92, 108, PALE)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(60, 157, "FINAL CHECK BEFORE PERFORMING")
    checks = [
        "Memorize the roadmap so your eyes can return to the singer's phrasing.",
        "Record one full take at 75 BPM; check tempo sag, pedal blur, and vocal diction.",
        "If the climax feels forced, transpose the licensed vocal line and every chord together.",
        "End smaller than you think: the last silence is part of the arrangement.",
    ]
    yy = 136
    for item in checks:
        c.setFillColor(ACCENT)
        c.circle(64, yy + 2, 2, fill=1, stroke=0)
        p(c, item, 75, yy - 7, PAGE_W - 140, 20, size=8.2, color=INK, leading=10)
        yy -= 21
    footer(c, 4)


def build() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(OUT), pagesize=letter)
    c.setTitle("Holocene - Piano & Voice Performance Companion")
    c.setAuthor("Original accompaniment study")
    c.setSubject("Piano accompaniment and performance roadmap in C major")

    title_page_content(c)
    footer(c, 1)
    c.showPage()

    page_cell_a(c)
    c.showPage()

    page_cell_b(c)
    c.showPage()

    page_cells_cd(c)
    c.save()


if __name__ == "__main__":
    build()
