from __future__ import annotations

from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph
from reportlab.lib.utils import ImageReader


OUT = Path("/Users/pfeodrippe/dev/music/output/pdf/holocene_custom_piano_voice_arrangement.pdf")
SOURCE_IMAGE = Path(
    "/var/folders/7r/pcj98w556f324q4ts3k9k7wc0000gn/T/TemporaryItems/"
    "NSIRD_screencaptureui_0NpwM0/Screenshot 2026-08-22 at 10.31.47\u202fAM.png"
)
PAGE_W, PAGE_H = letter

INK = colors.HexColor("#1D2733")
MUTED = colors.HexColor("#5E6C76")
ACCENT = colors.HexColor("#3B6775")
PALE = colors.HexColor("#E8F0F1")
WARM = colors.HexColor("#F6F2E9")
RULE = colors.HexColor("#CCD6D9")

APPLE_SYMBOLS = "/System/Library/Fonts/Apple Symbols.ttf"
if Path(APPLE_SYMBOLS).exists():
    pdfmetrics.registerFont(TTFont("AppleSymbols", APPLE_SYMBOLS))


def para(c: canvas.Canvas, text: str, x: float, y: float, w: float, h: float,
         size: float = 8.5, color=INK, leading: float | None = None,
         font: str = "Helvetica") -> None:
    style = ParagraphStyle(
        "local", fontName=font, fontSize=size, leading=leading or size * 1.28,
        textColor=color, alignment=TA_LEFT, spaceAfter=0,
    )
    block = Paragraph(text, style)
    _, block_h = block.wrap(w, h)
    block.drawOn(c, x, y + h - block_h)


def rounded(c: canvas.Canvas, x: float, y: float, w: float, h: float, fill) -> None:
    c.setFillColor(fill)
    c.setStrokeColor(fill)
    c.roundRect(x, y, w, h, 9, fill=1, stroke=0)


def header(c: canvas.Canvas, page: int, section: str) -> None:
    c.setFont("Helvetica-Bold", 8.5)
    c.setFillColor(INK)
    c.drawString(42, PAGE_H - 27, "HOLOCENE - CUSTOM PIANO & VOICE ARRANGEMENT")
    c.setFont("Helvetica", 8)
    c.setFillColor(MUTED)
    c.drawRightString(PAGE_W - 42, PAGE_H - 27, f"{section}  |  {page}")
    c.setStrokeColor(RULE)
    c.setLineWidth(0.6)
    c.line(42, PAGE_H - 36, PAGE_W - 42, PAGE_H - 36)


def footer(c: canvas.Canvas, page: int) -> None:
    c.setStrokeColor(RULE)
    c.setLineWidth(0.5)
    c.line(42, 34, PAGE_W - 42, 34)
    c.setFont("Helvetica", 7)
    c.setFillColor(MUTED)
    c.drawString(42, 21, "Bars 1-6: performer-supplied score image. Continuation: original accompaniment.")
    c.drawRightString(PAGE_W - 42, 21, str(page))


NOTE_ORDER = {"C": 0, "D": 1, "E": 2, "F": 3, "G": 4, "A": 5, "B": 6}


def dia(note: str) -> int:
    return int(note[-1]) * 7 + NOTE_ORDER[note[0]]


def pitch_y(note: str, bottom: float, clef: str, gap: float = 7.0) -> float:
    reference = "E4" if clef == "treble" else "G2"
    return bottom + (dia(note) - dia(reference)) * gap / 2


def notehead(c: canvas.Canvas, x: float, y: float, filled: bool = True) -> None:
    c.saveState()
    c.translate(x, y)
    c.rotate(-15)
    c.setStrokeColor(INK)
    c.setFillColor(INK if filled else colors.white)
    c.setLineWidth(0.8)
    c.ellipse(-4.0, -2.65, 4.0, 2.65, fill=1, stroke=1)
    c.restoreState()


def ledgers(c: canvas.Canvas, x: float, y: float, bottom: float, gap: float = 7) -> None:
    top = bottom + 4 * gap
    c.setStrokeColor(INK)
    c.setLineWidth(0.6)
    if y < bottom:
        ly = bottom - gap
        while ly >= y - 0.2:
            c.line(x - 6, ly, x + 6, ly)
            ly -= gap
    elif y > top:
        ly = top + gap
        while ly <= y + 0.2:
            c.line(x - 6, ly, x + 6, ly)
            ly += gap


def eighth_group(c: canvas.Canvas, xs: list[float], notes: list[str], bottom: float) -> None:
    ys = [pitch_y(n, bottom, "treble") for n in notes]
    beam_y = max(max(ys) + 22, bottom + 43)
    c.setStrokeColor(INK)
    c.setFillColor(INK)
    for x, y in zip(xs, ys):
        ledgers(c, x, y, bottom)
        notehead(c, x, y)
        c.setLineWidth(0.75)
        c.line(x + 4, y, x + 4, beam_y)
    c.setLineWidth(3.8)
    c.line(xs[0] + 4, beam_y, xs[-1] + 4, beam_y)


def dotted_half(c: canvas.Canvas, x: float, note: str, bottom: float,
                octave: str | None = None) -> None:
    ys = [pitch_y(note, bottom, "bass")]
    if octave:
        ys.append(pitch_y(octave, bottom, "bass"))
    for y in ys:
        ledgers(c, x, y, bottom)
        notehead(c, x, y, filled=False)
        c.setFillColor(INK)
        c.circle(x + 8, y, 1.25, fill=1, stroke=0)
    c.setStrokeColor(INK)
    c.setLineWidth(0.8)
    c.line(x + 4, min(ys), x + 4, max(ys) + 23)


def quarter_chord(c: canvas.Canvas, x: float, notes: list[str], bottom: float) -> None:
    ys = [pitch_y(n, bottom, "treble") for n in notes]
    previous = None
    for y in ys:
        dx = 2 if previous is not None and abs(y - previous) < 5 else 0
        ledgers(c, x + dx, y, bottom)
        notehead(c, x + dx, y)
        previous = y
    c.setStrokeColor(INK)
    c.setLineWidth(0.75)
    c.line(x + 4, min(ys), x + 4, max(ys) + 23)


def clef(c: canvas.Canvas, x: float, bottom: float, kind: str) -> None:
    c.setFillColor(INK)
    if "AppleSymbols" in pdfmetrics.getRegisteredFontNames():
        c.setFont("AppleSymbols", 36 if kind == "treble" else 29)
        c.drawString(x, bottom - (9 if kind == "treble" else 1),
                     "\U0001D11E" if kind == "treble" else "\U0001D122")
    else:
        c.setFont("Helvetica-Bold", 13)
        c.drawString(x, bottom + 8, "G" if kind == "treble" else "F")


def key_signature(c: canvas.Canvas, x: float, bottom: float, kind: str) -> None:
    # Five flats: B, E, A, D, G. Positions are staff-specific.
    positions = [3.5, 2.0, 4.0, 2.5, 0.5] if kind == "treble" else [1.5, 3.0, 1.0, 2.5, 0.5]
    c.setFont("Times-Bold", 17)
    c.setFillColor(INK)
    for i, pos in enumerate(positions):
        c.drawString(x + i * 8.2, bottom + pos * 7 - 5, "b")


def staff(c: canvas.Canvas, x0: float, x1: float, treble: float, bass: float,
          show_time: bool = True) -> None:
    c.setStrokeColor(INK)
    c.setLineWidth(0.55)
    for bottom in (treble, bass):
        for i in range(5):
            c.line(x0, bottom + i * 7, x1, bottom + i * 7)
    c.setLineWidth(1.0)
    c.line(x0, bass, x0, treble + 28)
    c.setLineWidth(1.2)
    mid = (bass + treble + 28) / 2
    c.bezier(x0 - 5, bass, x0 - 14, bass + 17, x0 - 2, mid - 4, x0 - 8, mid)
    c.bezier(x0 - 8, mid, x0 - 2, mid + 4, x0 - 14, treble + 11, x0 - 5, treble + 28)
    clef(c, x0 + 7, treble, "treble")
    clef(c, x0 + 9, bass, "bass")
    key_signature(c, x0 + 34, treble, "treble")
    key_signature(c, x0 + 34, bass, "bass")
    if show_time:
        c.setFont("Times-Bold", 15)
        for bottom in (treble, bass):
            c.drawString(x0 + 79, bottom + 14, "6")
            c.drawString(x0 + 79, bottom + 1, "4")


ARPS = {
    "Dbmaj9": ["Ab3", "Eb4", "F4", "Ab4", "F4", "Eb4", "Ab3", "Eb4", "F4", "Ab4", "F4", "Eb4"],
    "Db/F": ["Ab3", "Db4", "F4", "Ab4", "F4", "Db4", "Ab3", "Db4", "F4", "Ab4", "F4", "Db4"],
    "Bbm7(add11)": ["Ab3", "Db4", "F4", "Bb4", "F4", "Db4", "Ab3", "Db4", "F4", "Bb4", "F4", "Db4"],
    "Absus4(add9)-Ab": ["Ab3", "Bb3", "Eb4", "Ab4", "Eb4", "Db4", "C4", "Eb4", "Ab4", "Eb4", "C4", "Bb3"],
    "Gbmaj9": ["Ab3", "Bb3", "Db4", "F4", "Db4", "Bb3", "Ab3", "Bb3", "Db4", "F4", "Db4", "Bb3"],
    "Db/Ab": ["Ab3", "Db4", "F4", "Ab4", "F4", "Db4", "Ab3", "Db4", "F4", "Ab4", "F4", "Db4"],
}

LH = {
    "Dbmaj9": (("Db2", "Db3"), ("Ab2", None)),
    "Db/F": (("F2", "F3"), ("Ab2", None)),
    "Bbm7(add11)": (("Bb2", "Bb3"), ("F3", None)),
    "Absus4(add9)-Ab": (("Ab2", "Ab3"), ("Eb3", None)),
    "Gbmaj9": (("Gb2", "Gb3"), ("Db3", None)),
    "Db/Ab": (("Ab2", "Ab3"), ("Db3", None)),
}

VOICINGS = {
    "Dbmaj9": ["Ab3", "Db4", "F4", "Ab4"],
    "Db/F": ["Ab3", "Db4", "F4", "Ab4"],
    "Bbm7(add11)": ["Ab3", "Db4", "Eb4", "F4"],
    "Absus4(add9)-Ab": ["Bb3", "Db4", "Eb4", "Ab4"],
    "Gbmaj9": ["Ab3", "Bb3", "Db4", "F4"],
    "Db/Ab": ["Ab3", "Db4", "F4", "Ab4"],
}


def draw_bar(c: canvas.Canvas, x: float, w: float, treble: float, bass: float,
             chord: str, number: int, first: bool, texture: str,
             dynamic: str | None = None, wedge: str | None = None) -> None:
    content_start = x + (98 if first else 10)
    content_end = x + w - 8
    c.setFont("Helvetica-Bold", 8.2)
    c.setFillColor(ACCENT)
    c.drawCentredString((content_start + content_end) / 2, treble + 44, chord)
    c.setFont("Helvetica", 6.5)
    c.setFillColor(MUTED)
    c.drawString(x + 3, treble + 33, str(number))
    if texture == "arp":
        notes = ARPS[chord]
        xs = [content_start + (content_end - content_start) * (i + 0.5) / 12 for i in range(12)]
        eighth_group(c, xs[:6], notes[:6], treble)
        eighth_group(c, xs[6:], notes[6:], treble)
        left = LH[chord]
        dotted_half(c, content_start + (content_end - content_start) * 0.17,
                    left[0][0], bass, left[0][1])
        dotted_half(c, content_start + (content_end - content_start) * 0.62,
                    left[1][0], bass, left[1][1])
    else:
        xs = [content_start + (content_end - content_start) * (i + 0.5) / 6 for i in range(6)]
        for i, px in enumerate(xs):
            notes = VOICINGS[chord] if i in (0, 2, 4) else VOICINGS[chord][1:]
            quarter_chord(c, px, notes, treble)
        left = LH[chord]
        dotted_half(c, xs[0], left[0][0], bass, left[0][1])
        dotted_half(c, xs[3], left[1][0], bass, left[1][1])
    if dynamic:
        c.setFont("Times-Italic", 12)
        c.setFillColor(INK)
        c.drawString(content_start, bass - 25, dynamic)
    if wedge:
        y = bass - 17
        c.setStrokeColor(INK)
        c.setLineWidth(0.7)
        if wedge == "cres":
            c.line(content_start + 18, y, content_end, y + 5)
            c.line(content_start + 18, y, content_end, y - 5)
        else:
            c.line(content_start + 18, y + 5, content_end, y)
            c.line(content_start + 18, y - 5, content_end, y)
    c.setStrokeColor(INK)
    c.setLineWidth(0.75)
    c.line(x + w, bass, x + w, treble + 28)


def system(c: canvas.Canvas, y_top: float, chords: list[str], start: int,
           texture: str, dynamics: dict[int, tuple[str | None, str | None]] | None = None,
           final: bool = False, repeat: bool = False) -> None:
    x0, x1 = 52, PAGE_W - 45
    treble, bass = y_top - 39, y_top - 111
    staff(c, x0, x1, treble, bass, show_time=True)
    first_extra = 98
    body = x1 - x0 - first_extra
    widths = [(body / len(chords)) + (first_extra if i == 0 else 0) for i in range(len(chords))]
    x = x0
    for i, (chord, width) in enumerate(zip(chords, widths)):
        dyn, wedge = (dynamics or {}).get(i, (None, None))
        draw_bar(c, x, width, treble, bass, chord, start + i, i == 0,
                 texture, dyn, wedge)
        x += width
    if final:
        c.setLineWidth(0.8)
        c.line(x1 - 8, bass, x1 - 8, treble + 28)
        c.setLineWidth(2.2)
        c.line(x1 - 2, bass, x1 - 2, treble + 28)
    if repeat:
        c.setLineWidth(2.1)
        c.line(x1 - 5, bass, x1 - 5, treble + 28)
        c.setLineWidth(0.8)
        c.line(x1 - 10, bass, x1 - 10, treble + 28)
        c.setFillColor(INK)
        c.circle(x1 - 15, treble + 10, 1.4, fill=1, stroke=0)
        c.circle(x1 - 15, treble + 18, 1.4, fill=1, stroke=0)


def cover(c: canvas.Canvas) -> None:
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 25)
    c.drawString(48, PAGE_H - 82, "Holocene")
    c.setFont("Helvetica", 13)
    c.setFillColor(ACCENT)
    c.drawString(49, PAGE_H - 104, "Custom piano & voice arrangement")
    rounded(c, 48, PAGE_H - 169, PAGE_W - 96, 46, WARM)
    c.setFont("Helvetica-Bold", 9)
    c.setFillColor(INK)
    c.drawString(63, PAGE_H - 146, "D-flat major")
    c.drawString(187, PAGE_H - 146, "6/4")
    c.drawString(252, PAGE_H - 146, "Quarter = approx. 84")
    c.drawString(410, PAGE_H - 146, "Voice-led")

    c.setFont("Helvetica-Bold", 11)
    c.drawString(48, PAGE_H - 198, "FULL PERFORMANCE ROADMAP")
    rows = [
        ("OPENING", "Supplied bars 1-6", "mf, then settle"),
        ("VERSE 1", "Cell A x2", "p; voice enters"),
        ("CHORUS 1", "Cell B", "p to mp"),
        ("INTERLUDE", "Cell A, bars 1-2", "thin texture"),
        ("VERSE 2", "Cell A x3", "gradual build"),
        ("CHORUS 2", "Cell B", "mp; broader bass"),
        ("INTERLUDE", "Cell A, bars 1-2", "return to p"),
        ("VERSE 3", "Cell A x2", "p to crescendo"),
        ("FINAL CHORUS", "Cell C", "mf; widest register"),
        ("OUTRO", "Cell D", "rit. and release"),
    ]
    x, y, rh = 48, PAGE_H - 222, 24
    widths = [108, 145, PAGE_W - 96 - 253]
    for i, row in enumerate(rows):
        c.setFillColor(PALE if i % 2 == 0 else colors.white)
        c.rect(x, y - rh, sum(widths), rh, fill=1, stroke=0)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 8.1)
        c.drawString(x + 8, y - 16, row[0])
        c.setFont("Helvetica", 8.1)
        c.drawString(x + widths[0] + 7, y - 16, row[1])
        c.setFillColor(MUTED)
        c.drawString(x + widths[0] + widths[1] + 7, y - 16, row[2])
        y -= rh

    rounded(c, 48, 76, PAGE_W - 96, 155, PALE)
    c.setFont("Helvetica-Bold", 10)
    c.setFillColor(INK)
    c.drawString(62, 209, "WHAT IS EXACT AND WHAT IS ARRANGED")
    para(c,
         "Page 2 reproduces the <b>six measures supplied by you</b> as the source opening. "
         "Pages 3-5 are a new accompaniment built in the same D-flat/6/4 sound world and "
         "organized around the song's verse/chorus form. They are intended for singing the "
         "song from memory or alongside a licensed vocal score.",
         62, 140, PAGE_W - 124, 54, size=8.7, leading=12)
    para(c,
         "This continuation is intentionally not represented as a note-for-note transcription "
         "of the official recording. Pedal with each harmony, keep the repeated figure even, "
         "and let the vocal determine phrase length at section boundaries.",
         62, 100, PAGE_W - 124, 40, size=8.2, color=MUTED, leading=11)
    footer(c, 1)


def supplied_page(c: canvas.Canvas) -> None:
    header(c, 2, "SUPPLIED OPENING - BARS 1-6")
    c.setFont("Helvetica-Bold", 17)
    c.setFillColor(INK)
    c.drawString(46, PAGE_H - 70, "Opening score supplied by the performer")
    c.setFont("Helvetica", 8.4)
    c.setFillColor(MUTED)
    c.drawString(47, PAGE_H - 87, "Use these measures exactly as shown. The green line is a playback cursor, not notation.")
    if not SOURCE_IMAGE.exists():
        raise FileNotFoundError(SOURCE_IMAGE)
    img = ImageReader(str(SOURCE_IMAGE))
    iw, ih = img.getSize()
    max_w, max_h = PAGE_W - 72, 560
    scale = min(max_w / iw, max_h / ih)
    dw, dh = iw * scale, ih * scale
    x, y = (PAGE_W - dw) / 2, PAGE_H - 120 - dh
    c.setFillColor(colors.white)
    c.setStrokeColor(RULE)
    c.rect(x - 4, y - 4, dw + 8, dh + 8, fill=1, stroke=1)
    c.drawImage(img, x, y, width=dw, height=dh, preserveAspectRatio=True, mask="auto")
    rounded(c, 46, 64, PAGE_W - 92, 72, WARM)
    para(c,
         "<b>Harmony visible:</b> Bbm7/Db - Db/F - Bbm7 - Gb13 - Db. "
         "The continuation preserves D-flat as the tonal center and uses related color tones "
         "(maj9, add11, sus4/add9) so the piano remains spacious under the vocal.",
         60, 79, PAGE_W - 120, 42, size=8.3, leading=11)
    footer(c, 2)


def verse_page(c: canvas.Canvas) -> None:
    header(c, 3, "CELL A - VERSE / INTERLUDE")
    c.setFont("Helvetica-Bold", 17)
    c.setFillColor(INK)
    c.drawString(46, PAGE_H - 69, "Cell A - continuous finger-picked texture")
    c.setFont("Helvetica", 8.4)
    c.setFillColor(MUTED)
    c.drawString(47, PAGE_H - 86, "Twelve even eighth notes per 6/4 bar. Slightly project the highest note of each group.")
    systems = [
        (["Dbmaj9", "Bbm7(add11)"], 7),
        (["Absus4(add9)-Ab", "Bbm7(add11)"], 9),
        (["Gbmaj9", "Gbmaj9"], 11),
    ]
    for i, ((chords, start), top) in enumerate(zip(systems, [PAGE_H - 116, PAGE_H - 315, PAGE_H - 514])):
        dyn = {0: (("p" if i == 0 else None), "cres" if i == 1 else ("dim" if i == 2 else None))}
        system(c, top, chords, start, "arp", dyn, repeat=i == 2)
    footer(c, 3)


def chorus_page(c: canvas.Canvas) -> None:
    header(c, 4, "CELL B - CHORUS")
    c.setFont("Helvetica-Bold", 17)
    c.setFillColor(INK)
    c.drawString(46, PAGE_H - 69, "Cell B - opening choruses")
    c.setFont("Helvetica", 8.4)
    c.setFillColor(MUTED)
    c.drawString(47, PAGE_H - 86, "Six quarter-note pulses per bar over dotted-half bass changes. Keep it broad, never heavy.")
    systems = [
        (["Gbmaj9", "Bbm7(add11)"], 13),
        (["Absus4(add9)-Ab", "Gbmaj9"], 15),
        (["Bbm7(add11)", "Absus4(add9)-Ab"], 17),
        (["Gbmaj9", "Db/Ab"], 19),
    ]
    tops = [PAGE_H - 114, PAGE_H - 280, PAGE_H - 446, PAGE_H - 612]
    for i, ((chords, start), top) in enumerate(zip(systems, tops)):
        dyn = {0: (("p" if i == 0 else None), "cres" if i in (0, 1) else ("dim" if i == 3 else None))}
        system(c, top, chords, start, "chord", dyn, final=i == 3)
    footer(c, 4)


def final_page(c: canvas.Canvas) -> None:
    header(c, 5, "CELLS C & D - FINAL BUILD / OUTRO")
    c.setFont("Helvetica-Bold", 17)
    c.setFillColor(INK)
    c.drawString(46, PAGE_H - 69, "Cell C - final chorus ending")
    c.setFont("Helvetica", 8.4)
    c.setFillColor(MUTED)
    c.drawString(47, PAGE_H - 86, "Play Cell B, then substitute these final two bars with octave bass and a gentle crescendo.")
    system(c, PAGE_H - 116, ["Gbmaj9", "Dbmaj9"], 19, "chord",
           {0: ("mf", "cres"), 1: (None, "dim")}, final=True)
    c.setFont("Helvetica-Bold", 15)
    c.setFillColor(INK)
    c.drawString(46, PAGE_H - 320, "Cell D - four-bar outro")
    c.setFont("Helvetica", 8.4)
    c.setFillColor(MUTED)
    c.drawString(47, PAGE_H - 337, "Return to eighth notes. Begin the ritardando in the third bar; let D-flat ring.")
    system(c, PAGE_H - 367, ["Bbm7(add11)", "Gbmaj9"], 1, "arp",
           {0: ("p", "dim")})
    system(c, PAGE_H - 566, ["Absus4(add9)-Ab", "Dbmaj9"], 3, "arp",
           {0: ("rit.", None), 1: ("pp", None)}, final=True)
    footer(c, 5)


def build() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(OUT), pagesize=letter)
    c.setTitle("Holocene - Custom Piano & Voice Arrangement")
    c.setAuthor("Custom performance arrangement")
    c.setSubject("D-flat major, 6/4 piano accompaniment for singer-pianist")
    cover(c)
    c.showPage()
    supplied_page(c)
    c.showPage()
    verse_page(c)
    c.showPage()
    chorus_page(c)
    c.showPage()
    final_page(c)
    c.save()


if __name__ == "__main__":
    build()
