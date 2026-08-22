#!/usr/bin/env python3
"""Add exchange metadata to a private OMR draft and emit a standard MXL.

This does not claim to correct optical-recognition errors. The resulting file
records its review status explicitly and stays under the gitignored
``local-content`` tree.
"""

from __future__ import annotations

import argparse
import copy
import io
import json
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path


CONTAINER = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/>
  </rootfiles>
</container>
"""

# Meter changes read directly from the 12 user-supplied source pages. Audiveris
# missed most of the short 2/4 bars and consequently treated long stretches as
# 2/4. Values are (beats, beat-type), keyed by printed measure number.
SOURCE_METER_CHANGES = {
    1: (4, 4),
    3: (2, 4),
    4: (4, 4),
    15: (2, 4),
    16: (4, 4),
    27: (2, 4),
    28: (4, 4),
    66: (2, 4),
    67: (4, 4),
    78: (2, 4),
    79: (4, 4),
    90: (2, 4),
    91: (4, 4),
    126: (2, 4),
    127: (4, 4),
    138: (2, 4),
    139: (4, 4),
}

SOURCE_PAGE_STARTS = (1, 16, 28, 42, 55, 70, 84, 98, 115, 131, 147, 165)

# Audiveris emitted a 24-unit sliver as measure 138 immediately before the
# genuine 2/4 bar.  It contains no piano events and shifts every following
# measure number by one.  Removing it before applying source-numbered repairs
# keeps page starts, meter changes, lyric phrases, and review ledgers aligned
# with the measure numbers printed in the supplied edition.
OMR_SPURIOUS_MEASURE = 138

# Phrase text read from the user-supplied pages. Audiveris recognized the
# vocal pitches but emitted no MusicXML lyric elements at all. Phrase-level
# directions preserve the singer text without pretending that syllable-level
# alignment has already passed manual review.
SOURCE_LYRIC_PHRASES = {
    13: "Some way, baby, it's part of me, apart from me",
    19: "You're laying waste to Halloween",
    25: "You fucked it friend, it's on its head, it struck the street",
    31: "You're in Milwaukee off your feet",
    37: "At once, I knew I was not magnificent",
    45: "Strayed above the highway aisle",
    52: "Jagged vacance thick with ice",
    58: "But I could see for miles, miles, miles, miles",
    63: "Third and Lake, it burnt away the hallway",
    70: "Was where we learned to celebrate",
    76: "Automatic bought the years you'd talk to me",
    82: "That night you played me 'Lip Parade'",
    87: "Not the needle, nor the thread, the lost decree",
    94: "Saying nothing, that's enough for me",
    98: "At once, I knew I was not magnificent",
    106: "Strayed above the highway aisle",
    114: "Jagged vacance thick with ice",
    119: "But I could see for miles, miles, miles, miles",
    123: "Christmas night, it clutched the light, the hollow bright",
    127: "Above my brother and his tangled spine",
    135: "We smoked the screen to make it what it was to be",
    142: "Now to know it in my memory",
    147: "At once, I knew I was not magnificent",
    156: "High above the highway aisles",
    164: "Jagged vacance thick with ice",
    169: "But I could see for miles, miles, miles",
}


def child(parent: ET.Element, tag: str, text: str | None = None, **attrs: str) -> ET.Element:
    element = ET.Element(tag, attrs)
    element.text = text
    parent.append(element)
    return element


def read_score(path: Path) -> ET.Element:
    with zipfile.ZipFile(path) as archive:
        candidates = [name for name in archive.namelist() if name.lower().endswith((".xml", ".musicxml")) and not name.startswith("META-INF/")]
        if not candidates:
            raise ValueError(f"{path} contains no MusicXML document")
        return ET.fromstring(archive.read(candidates[0]))


def normalize_omr_measure_sequence(root: ET.Element) -> bool:
    piano = measure_for(root, "P2", OMR_SPURIOUS_MEASURE)
    width = float(piano.get("width", "inf"))
    if width > 32 or piano.findall("note"):
        return False

    for part in root.findall("part"):
        phantom = part.find(f"measure[@number='{OMR_SPURIOUS_MEASURE}']")
        if phantom is None:
            raise ValueError(
                f"missing phantom measure {OMR_SPURIOUS_MEASURE} in {part.get('id')}"
            )
        part.remove(phantom)
        for measure in part.findall("measure"):
            number = int(measure.get("number", "0"))
            if number > OMR_SPURIOUS_MEASURE:
                measure.set("number", str(number - 1))
    return True


def normalize_source_meters(root: ET.Element) -> None:
    for part in root.findall("part"):
        for measure in part.findall("measure"):
            number = int(measure.get("number", "0"))
            meter = SOURCE_METER_CHANGES.get(number)
            if meter is None:
                continue
            attributes = measure.find("attributes")
            if attributes is None:
                attributes = ET.Element("attributes")
                measure.insert(0, attributes)
            time = attributes.find("time")
            if time is None:
                time = child(attributes, "time")
            for old in list(time):
                time.remove(old)
            child(time, "beats", str(meter[0]))
            child(time, "beat-type", str(meter[1]))


def measure_for(root: ET.Element, part_id: str, number: int) -> ET.Element:
    measure = root.find(f"./part[@id='{part_id}']/measure[@number='{number}']")
    if measure is None:
        raise ValueError(f"missing {part_id} measure {number}")
    return measure


def note_x(note: ET.Element) -> float:
    return float(note.get("default-x", "0"))


def rebuild_staff_voices(
    measure: ET.Element,
    upper: list[ET.Element],
    lower: list[ET.Element],
    measure_duration: int,
) -> None:
    for element in list(measure):
        if element.tag in {"note", "backup", "forward"}:
            measure.remove(element)
    measure.extend(upper)
    if lower:
        backup = child(measure, "backup")
        child(backup, "duration", str(measure_duration))
        measure.extend(lower)


def normalize_full_measure_rests(root: ET.Element) -> None:
    for part in root.findall("part"):
        divisions = 1
        beats = 4
        beat_type = 4
        for measure in part.findall("measure"):
            attributes = measure.find("attributes")
            if attributes is not None:
                if attributes.findtext("divisions"):
                    divisions = int(attributes.findtext("divisions", "1"))
                time = attributes.find("time")
                if time is not None:
                    beats = int(time.findtext("beats", str(beats)))
                    beat_type = int(time.findtext("beat-type", str(beat_type)))
            expected = divisions * beats * 4 // beat_type
            notes = measure.findall("note")
            for note in measure.findall("note"):
                rest = note.find("rest")
                if rest is not None and rest.get("measure") == "yes":
                    duration = note.find("duration")
                    if duration is None:
                        duration = child(note, "duration")
                    duration.text = str(expected)
            if notes and all(
                note.find("rest") is not None
                and note.find("rest").get("measure") == "yes"
                for note in notes
            ):
                for backup in measure.findall("backup"):
                    duration = backup.find("duration")
                    if duration is not None:
                        duration.text = str(expected)


def pad_recognition_gaps(root: ET.Element) -> list[dict]:
    """Make every recognized voice lane meter-complete without inventing notes.

    Audiveris often stopped a voice halfway through a bar when it missed the
    second occurrence of a repeated figure.  A MusicXML ``forward`` advances
    that lane without asserting a rest glyph or a recovered pitch.  When the
    lane is followed by ``backup``, increasing the backup by the same amount
    preserves the original onset of the next lane.

    Every inserted span is returned for the private review ledger.  Structural
    validity therefore becomes independently testable while musical recovery
    remains visibly incomplete and cannot be mistaken for transcription.
    """
    part_names = {
        score_part.get("id", ""): score_part.findtext("part-name", "Unnamed")
        for score_part in root.findall("./part-list/score-part")
    }
    gaps: list[dict] = []
    for part in root.findall("part"):
        part_id = part.get("id", "")
        divisions = 1
        beats = 4
        beat_type = 4
        for measure in part.findall("measure"):
            attributes = measure.find("attributes")
            if attributes is not None:
                divisions_text = attributes.findtext("divisions")
                if divisions_text:
                    divisions = int(divisions_text)
                time = attributes.find("time")
                if time is not None:
                    beats = int(time.findtext("beats", str(beats)))
                    beat_type = int(time.findtext("beat-type", str(beat_type)))
            expected = divisions * beats * 4 // beat_type
            cursor = 0
            measure_had_time = False
            lane_had_time = False
            lane_voice = "1"
            lane_staff: str | None = None

            for element in list(measure):
                if element.tag == "note":
                    duration_text = element.findtext("duration")
                    if duration_text is None:
                        continue
                    lane_had_time = True
                    measure_had_time = True
                    lane_voice = element.findtext("voice", lane_voice)
                    lane_staff = element.findtext("staff", lane_staff)
                    if element.find("chord") is None:
                        cursor += int(duration_text)
                elif element.tag == "forward":
                    duration = int(element.findtext("duration", "0"))
                    lane_had_time = True
                    measure_had_time = True
                    lane_voice = element.findtext("voice", lane_voice)
                    lane_staff = element.findtext("staff", lane_staff)
                    cursor += duration
                elif element.tag == "backup":
                    if lane_had_time and cursor < expected:
                        gap = expected - cursor
                        forward = ET.Element("forward")
                        child(forward, "duration", str(gap))
                        child(forward, "voice", lane_voice)
                        if lane_staff is not None:
                            child(forward, "staff", lane_staff)
                        measure.insert(list(measure).index(element), forward)
                        backup_duration = element.find("duration")
                        if backup_duration is None:
                            backup_duration = child(element, "duration", "0")
                        backup_duration.text = str(int(backup_duration.text or "0") + gap)
                        gaps.append(
                            {
                                "part_id": part_id,
                                "part": part_names.get(part_id, part_id),
                                "measure": int(measure.get("number", "0")),
                                "voice": lane_voice,
                                "staff": lane_staff,
                                "gap_divisions": gap,
                                "divisions": divisions,
                                "meter": f"{beats}/{beat_type}",
                            }
                        )
                        cursor = expected
                    cursor -= int(element.findtext("duration", "0"))
                    lane_had_time = False
                    lane_voice = "1"
                    lane_staff = None

            if lane_had_time and cursor < expected:
                gap = expected - cursor
                forward = child(measure, "forward")
                child(forward, "duration", str(gap))
                child(forward, "voice", lane_voice)
                if lane_staff is not None:
                    child(forward, "staff", lane_staff)
                gaps.append(
                    {
                        "part_id": part_id,
                        "part": part_names.get(part_id, part_id),
                        "measure": int(measure.get("number", "0")),
                        "voice": lane_voice,
                        "staff": lane_staff,
                        "gap_divisions": gap,
                        "divisions": divisions,
                        "meter": f"{beats}/{beat_type}",
                    }
                )
            elif not measure_had_time:
                forward = child(measure, "forward")
                child(forward, "duration", str(expected))
                child(forward, "voice", "1")
                gaps.append(
                    {
                        "part_id": part_id,
                        "part": part_names.get(part_id, part_id),
                        "measure": int(measure.get("number", "0")),
                        "voice": "1",
                        "staff": None,
                        "gap_divisions": expected,
                        "divisions": divisions,
                        "meter": f"{beats}/{beat_type}",
                    }
                )
    return gaps


def write_gap_ledger(gaps: list[dict], json_path: Path | None, markdown_path: Path | None) -> None:
    affected = sorted({(gap["part"], gap["measure"]) for gap in gaps})
    by_part = Counter(gap["part"] for gap in gaps)
    report = {
        "schema": 1,
        "status": "REVIEW_REQUIRED" if gaps else "CLEAR",
        "scope": (
            "Forward spans make MusicXML voice cursors meter-complete but do not "
            "assert recovered notes or rests. Every entry requires page and, when "
            "available, lawful recording review."
        ),
        "gap_count": len(gaps),
        "affected_part_measure_count": len(affected),
        "gaps_by_part": dict(sorted(by_part.items())),
        "gaps": gaps,
    }
    if json_path is not None:
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(report, indent=2) + "\n")
    if markdown_path is not None:
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# Private transcription recognition-gap ledger",
            "",
            f"**Status:** {report['status']}",
            "",
            report["scope"],
            "",
            f"- Forward gaps: {report['gap_count']}",
            f"- Affected part/measures: {report['affected_part_measure_count']}",
            f"- Gaps by part: {report['gaps_by_part']}",
            "",
            "| Measure | Part | Voice | Staff | Missing divisions | Meter |",
            "| ---: | --- | ---: | ---: | ---: | --- |",
        ]
        for gap in gaps:
            lines.append(
                f"| {gap['measure']} | {gap['part']} | {gap['voice']} | "
                f"{gap['staff'] or '-'} | {gap['gap_divisions']} / {gap['divisions']} | "
                f"{gap['meter']} |"
            )
        markdown_path.write_text("\n".join(lines) + "\n")


def source_page_for_measure(measure: int) -> int:
    page = 1
    for index, start in enumerate(SOURCE_PAGE_STARTS, start=1):
        if measure < start:
            break
        page = index
    return page


def write_source_review_ledger(
    root: ET.Element,
    gaps: list[dict],
    json_path: Path | None,
    markdown_path: Path | None,
) -> None:
    """Write the private measure/part review matrix without inflating claims."""
    gap_counts = Counter((gap["part_id"], gap["measure"]) for gap in gaps)
    part_names = {
        score_part.get("id", ""): score_part.findtext("part-name", "Unnamed")
        for score_part in root.findall("./part-list/score-part")
    }
    entries: list[dict] = []
    for part in root.findall("part"):
        part_id = part.get("id", "")
        for measure in part.findall("measure"):
            number = int(measure.get("number", "0"))
            page_complete = (
                part_id == "P2" and number in PAGE_VERIFIED_PIANO_MEASURES
            ) or (
                part_id == "P1" and number in PAGE_VERIFIED_VOCAL_MEASURES
            )
            recognition_gaps = gap_counts[(part_id, number)]
            entries.append(
                {
                    "part_id": part_id,
                    "part": part_names.get(part_id, part_id),
                    "measure": number,
                    "source_page": source_page_for_measure(number),
                    "page_review_status": (
                        "PAGE_COMPLETE" if page_complete else "REVIEW_REQUIRED"
                    ),
                    "recording_review_status": "NOT_VERIFIED",
                    "recognition_gap_count": recognition_gaps,
                    "scope": (
                        "Source-page pitches, durations, voices/staves, rests, and "
                        "beaming verified for the complete accompaniment bar"
                        if page_complete
                        else "OMR-derived content; complete symbol review not yet recorded"
                    ),
                }
            )
    page_complete = sum(entry["page_review_status"] == "PAGE_COMPLETE" for entry in entries)
    report = {
        "schema": 1,
        "status": "REVIEW_REQUIRED",
        "scope": (
            "Measure-by-measure private source-review matrix. PAGE_COMPLETE means "
            "only that the named part/measure was checked against the supplied "
            "engraving. Recording review is an independent mandatory gate."
        ),
        "entry_count": len(entries),
        "page_complete_count": page_complete,
        "review_required_count": len(entries) - page_complete,
        "recording_verified_count": 0,
        "entries": entries,
    }
    if json_path is not None:
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(report, indent=2) + "\n")
    if markdown_path is not None:
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# Private source-review matrix",
            "",
            f"**Status:** {report['status']}",
            "",
            report["scope"],
            "",
            f"- Part/measure entries: {report['entry_count']}",
            f"- Page-complete entries: {report['page_complete_count']}",
            f"- Remaining page-review entries: {report['review_required_count']}",
            "- Recording-verified entries: 0",
            "",
            "| Page | Measure | Part | Page review | Recording review | Gaps | Scope |",
            "| ---: | ---: | --- | --- | --- | ---: | --- |",
        ]
        for entry in entries:
            lines.append(
                f"| {entry['source_page']} | {entry['measure']} | {entry['part']} | "
                f"{entry['page_review_status']} | {entry['recording_review_status']} | "
                f"{entry['recognition_gap_count']} | {entry['scope']} |"
            )
        markdown_path.write_text("\n".join(lines) + "\n")


# Source page 1 establishes the two sparse accompaniment figures used through
# the opening. Each full-bar entry is (three-note right-hand tail, bass pair):
# eighth rest, G4, eighth rest, G4, tail[0], tail[1] quarter, tail[2]; the bass
# is low eighth, eighth rest, upper eighth, eighth rest, half rest. Measures 3
# and 15 are the printed 2/4 transitions and use the four-eighth opening only.
PAGE1_FULL_PIANO = {
    1: (("E4", "E4", "E4"), ("C3", "C4")),
    2: (("E4", "E4", "E4"), ("C3", "C4")),
    4: (("D4", "E4", "D4"), ("G2", "G3")),
    5: (("E4", "E4", "E4"), ("G2", "G3")),
    6: (("E4", "E4", "E4"), ("G2", "G3")),
    7: (("E4", "E4", "E4"), ("G2", "G3")),
    8: (("E4", "E4", "E4"), ("A2", "A3")),
    9: (("D4", "E4", "D4"), ("F2", "F3")),
    10: (("D4", "E4", "D4"), ("F2", "F3")),
    11: (("D4", "E4", "D4"), ("F2", "F3")),
    12: (("D4", "E4", "D4"), ("F2", "F3")),
    13: (("D4", "E4", "D4"), ("C3", "C4")),
    14: (("D4", "E4", "D4"), ("C3", "C4")),
}

PAGE1_SHORT_PIANO = {
    3: ("A2", "A3"),
    15: ("A2", "A3"),
}

# Source page 2 continues the same complete seven-event right-hand figure in
# every 4/4 piano bar, with the printed bass pair changing by phrase. Measure
# 27 is the 2/4 transition and contains only the four-eighth opening. Rebuilding
# the entire page removes two OMR-created cursor gaps without inventing notes.
PAGE2_FULL_PIANO = {
    16: ("G2", "G3"),
    17: ("G2", "G3"),
    18: ("G2", "G3"),
    19: ("G2", "G3"),
    20: ("A2", "A3"),
    21: ("F2", "F3"),
    22: ("F2", "F3"),
    23: ("F2", "F3"),
    24: ("F2", "F3"),
    25: ("C3", "C4"),
    26: ("C3", "C4"),
}


PAGE8_ACCOMPANIMENT = {
    98: (("A4", "C5"), (("C4",), "F4")),
    99: (("A4", "C5"), (("C4",), "F4")),
    100: (("A4", "C5"), (("C4",), "F4")),
    101: (("A4", "C5"), (("C4",), "F4")),
    102: (("A4", "C5"), (("A3",), "E4")),
    103: (("A4", "C5"), (("A3",), "E4")),
    104: (("G4", "B4"), (("B2", "G3"), "D4")),
    105: (("G4", "B4"), (("B2", "G3"), "D4")),
    106: (("A4", "C5"), (("D3", "C4"), "F4")),
    107: (("A4", "C5"), (("C4",), "F4")),
    108: (("A4", "C5"), (("C4",), "F4")),
    109: (("A4", "C5"), (("C4",), "F4")),
    110: (("A4", "C5"), (("C3", "A3"), "E4")),
    111: (("A4", "C5"), (("C3", "A3"), "E4")),
    112: (("G4", "B4"), (("B2", "G3"), "D4")),
    113: (("G4", "B4"), (("B2", "G3"), "D4")),
    114: (("A4", "C5"), (("E3",), "C4")),
}

# Page 9 begins with the final six bars of the sparse accompaniment figure.
# Each entry names the two printed right-hand and left-hand eighth-note pairs;
# the second pair changes voicing in measures 121-122 and must not be inferred
# by blindly repeating beat 2.  Measures 123-125 use the next printed texture
# and are rebuilt separately below.  Measures 126-130 were fully recognized
# and have also been checked symbol-by-symbol against the supplied engraving.
PAGE9_SPARSE_ACCOMPANIMENT = {
    115: ((("A4", "C5"), ("A4", "C5")), (("A3", "E4"), ("A3", "E4"))),
    116: ((("A4", "C5"), ("A4", "C5")), (("G3", "E4"), ("G3", "E4"))),
    117: ((("G4", "C5"), ("G4", "C5")), (("G3", "C4"), ("G3", "C4"))),
    118: ((("G4", "C5"), ("G4", "C5")), (("G3", "D4"), ("G3", "D4"))),
    119: ((("G4", "C5"), ("G4", "C5")), (("G3", "D4"), ("G3", "D4"))),
    120: ((("G4", "C5"), ("G4", "C5")), (("G3", "D4"), ("G3", "D4"))),
    121: ((("E4", "A4"), ("C4", "E4")), (("A3", "C4"), ("F3", "A3"))),
    122: ((("D4", "G4"), ("A3", "C4")), (("F3", "A3"), ("C3", "E3"))),
}

# Page 10 uses two repeating right-hand cells: D5-G5-E5 and C5-G5-C5,
# each preceded by an eighth rest.  Values are (cell, left-hand half notes).
# Measure 138 is the printed 2/4 transition and therefore contains one cell
# and one left-hand half note; every other entry is 4/4 and repeats twice.
PAGE10_ACCOMPANIMENT = {
    131: (("D5", "G5", "E5"), ("A3", "A3")),
    132: (("C5", "G5", "C5"), ("F2", "F3")),
    133: (("C5", "G5", "C5"), ("F3", "F3")),
    134: (("C5", "G5", "C5"), ("F3", "F3")),
    135: (("C5", "G5", "C5"), ("F3", "F3")),
    136: (("D5", "G5", "E5"), ("C3", "C4")),
    137: (("D5", "G5", "E5"), ("C4", "C4")),
    138: (("D5", "G5", "E5"), ("A3",)),
    139: (("D5", "G5", "E5"), ("A3", "A3")),
    140: (("D5", "G5", "E5"), ("A3", "A3")),
    141: (("D5", "G5", "E5"), ("A3", "A3")),
    142: (("D5", "G5", "E5"), ("A3", "A3")),
    143: (("D5", "G5", "E5"), ("A3", "A3")),
    144: (("C5", "G5", "C5"), ("F2", "F3")),
    145: (("C5", "G5", "C5"), ("F3", "F3")),
    146: (("C5", "G5", "C5"), ("F3", "F3")),
}

# Page 11 continues the final C5-G5-C5 cell for measure 147, then changes to
# the printed un-beamed eighth-note figure.  Bass values are the alternating
# quarter-note pair repeated twice in each bar.
PAGE11_BASS = {
    148: ("F3", "C4"),
    149: ("F3", "C4"),
    150: ("F3", "C4"),
    151: ("F3", "C4"),
    152: ("A2", "A3"),
    153: ("A2", "A3"),
    154: ("G2", "G3"),
    155: ("G2", "G3"),
    156: ("F3", "C4"),
    157: ("F3", "C4"),
    158: ("F3", "C4"),
    159: ("F3", "C4"),
    160: ("A2", "A3"),
    161: ("A2", "A3"),
    162: ("G2", "G3"),
    163: ("G2", "G3"),
    164: ("F3", "C4"),
}

# Page 12 continues the un-beamed right-hand figure for six bars.  The first
# two bass bars retain the F3-C4 alternation; the next four move to G2-G3.
# Measures 171-172 are the printed half-note cadence, followed by a tied low
# E2 across the two closing whole-rest bars.
PAGE12_PATTERN_BASS = {
    165: ("F3", "C4"),
    166: ("F3", "C4"),
    167: ("G2", "G3"),
    168: ("G2", "G3"),
    169: ("G2", "G3"),
    170: ("G2", "G3"),
}

PAGE12_CADENCE = {
    171: (("G3", "E3"), (("A4", "C5", "E5"), ("F4", "A4", "C5"))),
    172: (("G3", "C3"), (("A4", "C5", "E5"), ("F4", "A4", "C5"))),
}

PAGE_VERIFIED_PIANO_MEASURES = frozenset(
    {
        *range(1, 16),
        *range(16, 28),
        *PAGE8_ACCOMPANIMENT,
        *range(115, 131),
        *PAGE10_ACCOMPANIMENT,
        *range(147, 165),
        *range(165, 175),
    }
)

PAGE_VERIFIED_VOCAL_MEASURES = frozenset(range(1, 28))


def notated_note(
    name: str | None,
    duration: int,
    note_type: str,
    voice: str,
    staff: str,
    *,
    chord: bool = False,
    beam: str | None = None,
    tie: str | None = None,
    arpeggiate: bool = False,
    measure_rest: bool = False,
    dots: int = 0,
    lyric: str | None = None,
    syllabic: str = "single",
) -> ET.Element:
    note = ET.Element("note")
    if chord:
        child(note, "chord")
    if name is None:
        rest = child(note, "rest")
        if measure_rest:
            rest.set("measure", "yes")
    else:
        pitch = child(note, "pitch")
        child(pitch, "step", name[0])
        child(pitch, "octave", name[1:])
    child(note, "duration", str(duration))
    if tie is not None:
        child(note, "tie", type=tie)
    child(note, "voice", voice)
    child(note, "type", note_type)
    for _ in range(dots):
        child(note, "dot")
    child(note, "staff", staff)
    if beam is not None:
        child(note, "beam", beam, number="1")
    if tie is not None or arpeggiate:
        notations = child(note, "notations")
        if tie is not None:
            child(notations, "tied", type=tie)
        if arpeggiate:
            child(notations, "arpeggiate")
    if lyric is not None:
        lyric_element = child(note, "lyric", number="1")
        child(lyric_element, "syllabic", syllabic)
        child(lyric_element, "text", lyric)
    return note


def append_eighth_pair(
    destination: list[ET.Element],
    first: tuple[str, ...],
    second: str,
    voice: str,
    staff: str,
) -> None:
    for index, pitch in enumerate(first):
        destination.append(
            notated_note(
                pitch,
                1,
                "eighth",
                voice,
                staff,
                chord=index != 0,
                beam="begin" if index == 0 else None,
            )
        )
    destination.append(notated_note(second, 1, "eighth", voice, staff, beam="end"))


def append_eighth_run(
    destination: list[ET.Element],
    pitches: tuple[str, ...],
    voice: str,
    staff: str,
) -> None:
    for index, pitch in enumerate(pitches):
        beam = "begin" if index == 0 else "end" if index == len(pitches) - 1 else "continue"
        destination.append(notated_note(pitch, 1, "eighth", voice, staff, beam=beam))


def final_unbeamed_upper_pattern() -> list[ET.Element]:
    return [
        notated_note(None, 1, "eighth", "1", "1"),
        notated_note("G5", 1, "eighth", "1", "1"),
        notated_note(None, 1, "eighth", "1", "1"),
        notated_note("G5", 1, "eighth", "1", "1"),
        notated_note("C5", 1, "eighth", "1", "1"),
        notated_note("D5", 2, "quarter", "1", "1"),
        notated_note("C5", 1, "eighth", "1", "1"),
    ]


def half_note_chord(pitches: tuple[str, ...]) -> list[ET.Element]:
    return [
        notated_note(
            pitch,
            4,
            "half",
            "1",
            "1",
            chord=index != 0,
            arpeggiate=index == 0,
        )
        for index, pitch in enumerate(pitches)
    ]


def opening_upper_pattern(tail: tuple[str, str, str]) -> list[ET.Element]:
    return [
        notated_note(None, 1, "eighth", "1", "1"),
        notated_note("G4", 1, "eighth", "1", "1"),
        notated_note(None, 1, "eighth", "1", "1"),
        notated_note("G4", 1, "eighth", "1", "1"),
        notated_note(tail[0], 1, "eighth", "1", "1"),
        notated_note(tail[1], 2, "quarter", "1", "1"),
        notated_note(tail[2], 1, "eighth", "1", "1"),
    ]


def opening_lower_pattern(pair: tuple[str, str]) -> list[ET.Element]:
    return [
        notated_note(pair[0], 1, "eighth", "5", "2"),
        notated_note(None, 1, "eighth", "5", "2"),
        notated_note(pair[1], 1, "eighth", "5", "2"),
        notated_note(None, 1, "eighth", "5", "2"),
        notated_note(None, 4, "half", "5", "2"),
    ]


def opening_short_upper_pattern() -> list[ET.Element]:
    return [
        notated_note(None, 1, "eighth", "1", "1"),
        notated_note("G4", 1, "eighth", "1", "1"),
        notated_note(None, 1, "eighth", "1", "1"),
        notated_note("G4", 1, "eighth", "1", "1"),
    ]


def opening_short_lower_pattern(pair: tuple[str, str]) -> list[ET.Element]:
    return [
        notated_note(pair[0], 1, "eighth", "5", "2"),
        notated_note(None, 1, "eighth", "5", "2"),
        notated_note(pair[1], 1, "eighth", "5", "2"),
        notated_note(None, 1, "eighth", "5", "2"),
    ]


def replace_page1_parts(root: ET.Element) -> None:
    """Transcribe both parts on source page 1 and its outgoing vocal tie."""
    for number, (tail, bass_pair) in PAGE1_FULL_PIANO.items():
        rebuild_staff_voices(
            measure_for(root, "P2", number),
            opening_upper_pattern(tail),
            opening_lower_pattern(bass_pair),
            8,
        )
    for number, bass_pair in PAGE1_SHORT_PIANO.items():
        rebuild_staff_voices(
            measure_for(root, "P2", number),
            opening_short_upper_pattern(),
            opening_short_lower_pattern(bass_pair),
            4,
        )

    for number in range(1, 13):
        duration = 4 if number == 3 else 8
        rebuild_staff_voices(
            measure_for(root, "P1", number),
            [notated_note(None, duration, "whole", "1", "1", measure_rest=True)],
            [],
            duration,
        )
    for number in (13, 14):
        rebuild_staff_voices(
            measure_for(root, "P1", number),
            [
                notated_note("E4", 2, "quarter", "1", "1"),
                notated_note("E4", 1, "eighth", "1", "1"),
                notated_note("E4", 4, "half", "1", "1"),
                notated_note("E4", 1, "eighth", "1", "1"),
            ],
            [],
            8,
        )
    rebuild_staff_voices(
        measure_for(root, "P1", 15),
        [
            notated_note("E4", 2, "quarter", "1", "1"),
            notated_note("D4", 1, "eighth", "1", "1", beam="begin"),
            notated_note(
                "D4", 1, "eighth", "1", "1", beam="end", tie="start"
            ),
        ],
        [],
        4,
    )
    rebuild_staff_voices(
        measure_for(root, "P1", 16),
        [notated_note("D4", 8, "whole", "1", "1", tie="stop")],
        [],
        8,
    )


def replace_page2_parts(root: ET.Element) -> None:
    """Transcribe both parts on source page 2 and its outgoing vocal tie."""
    for number, bass_pair in PAGE2_FULL_PIANO.items():
        rebuild_staff_voices(
            measure_for(root, "P2", number),
            opening_upper_pattern(("D4", "E4", "D4")),
            opening_lower_pattern(bass_pair),
            8,
        )
    rebuild_staff_voices(
        measure_for(root, "P2", 27),
        opening_short_upper_pattern(),
        opening_short_lower_pattern(("A2", "A3")),
        4,
    )

    rebuild_staff_voices(
        measure_for(root, "P1", 16),
        [notated_note("D4", 8, "whole", "1", "1", tie="stop")],
        [],
        8,
    )
    for number in (17, 18, 22, 23):
        rebuild_staff_voices(
            measure_for(root, "P1", number),
            [notated_note(None, 8, "whole", "1", "1", measure_rest=True)],
            [],
            8,
        )
    for number, lyric in ((19, "You're"), (24, "You")):
        rebuild_staff_voices(
            measure_for(root, "P1", number),
            [
                notated_note(None, 4, "half", "1", "1"),
                notated_note(None, 3, "quarter", "1", "1", dots=1),
                notated_note("E4", 1, "eighth", "1", "1", lyric=lyric),
            ],
            [],
            8,
        )
    rebuild_staff_voices(
        measure_for(root, "P1", 20),
        [
            notated_note("E4", 2, "quarter", "1", "1", lyric="lay", syllabic="begin"),
            notated_note("E4", 1, "eighth", "1", "1", lyric="ing", syllabic="end"),
            notated_note("E4", 4, "half", "1", "1", lyric="waste"),
            notated_note("D4", 1, "eighth", "1", "1", lyric="to"),
        ],
        [],
        8,
    )
    rebuild_staff_voices(
        measure_for(root, "P1", 21),
        [
            notated_note("D4", 2, "quarter", "1", "1", lyric="Hal", syllabic="begin"),
            notated_note("C4", 1, "eighth", "1", "1", lyric="lo", syllabic="middle"),
            notated_note("C4", 4, "half", "1", "1", lyric="ween", syllabic="end"),
            notated_note(None, 1, "eighth", "1", "1"),
        ],
        [],
        8,
    )
    for number, words in (
        (25, ("fucked", "it", "friend,", "it's")),
        (26, ("on", "its", "head,", "it")),
    ):
        rebuild_staff_voices(
            measure_for(root, "P1", number),
            [
                notated_note("E4", 2, "quarter", "1", "1", lyric=words[0]),
                notated_note("F4", 1, "eighth", "1", "1", lyric=words[1]),
                notated_note("D4", 4, "half", "1", "1", lyric=words[2]),
                notated_note("E4", 1, "eighth", "1", "1", lyric=words[3]),
            ],
            [],
            8,
        )
    rebuild_staff_voices(
        measure_for(root, "P1", 27),
        [
            notated_note("E4", 2, "quarter", "1", "1", lyric="struck"),
            notated_note("D4", 1, "eighth", "1", "1", beam="begin", lyric="the"),
            notated_note("D4", 1, "eighth", "1", "1", beam="end", tie="start", lyric="street"),
        ],
        [],
        4,
    )
    rebuild_staff_voices(
        measure_for(root, "P1", 28),
        [notated_note("D4", 8, "whole", "1", "1", tie="stop")],
        [],
        8,
    )


def replace_page8_accompaniment(root: ET.Element) -> None:
    """Transcribe the complete visible accompaniment in source page 8.

    The combined Audiveris pass recognized only the first half of these bars
    and doubled every beamed eighth duration.  The source page visibly contains
    both occurrences of each pair.  This replacement is deliberately bounded
    to P2 measures 98-114 and does not make a recording-accuracy claim.
    """
    for number, (upper_pair, lower_pair) in PAGE8_ACCOMPANIMENT.items():
        upper: list[ET.Element] = []
        lower: list[ET.Element] = []
        for _ in range(2):
            upper.append(notated_note(None, 2, "quarter", "1", "1"))
            append_eighth_pair(upper, (upper_pair[0],), upper_pair[1], "1", "1")
            append_eighth_pair(lower, lower_pair[0], lower_pair[1], "5", "2")
            lower.append(notated_note(None, 2, "quarter", "5", "2"))
        rebuild_staff_voices(measure_for(root, "P2", number), upper, lower, 8)


def replace_page9_accompaniment(root: ET.Element) -> None:
    """Transcribe the complete piano part visible on source page 9.

    The OMR pass stopped after beat 2 in measures 115-122 and 124-125,
    misread simultaneous notes in several left-hand pairs, and omitted the
    independent low E2 whole note in measure 123.  This replacement is bounded
    to the supplied page and does not make a recording-accuracy claim.
    """
    for number, (upper_pairs, lower_pairs) in PAGE9_SPARSE_ACCOMPANIMENT.items():
        upper: list[ET.Element] = []
        lower: list[ET.Element] = []
        for upper_pair, lower_pair in zip(upper_pairs, lower_pairs, strict=True):
            upper.append(notated_note(None, 2, "quarter", "1", "1"))
            append_eighth_pair(upper, (upper_pair[0],), upper_pair[1], "1", "1")
            append_eighth_pair(lower, (lower_pair[0],), lower_pair[1], "5", "2")
            lower.append(notated_note(None, 2, "quarter", "5", "2"))
        rebuild_staff_voices(measure_for(root, "P2", number), upper, lower, 8)

    rebuild_staff_voices(
        measure_for(root, "P2", 123),
        [notated_note(None, 8, "whole", "1", "1")],
        [notated_note("E2", 8, "whole", "5", "2")],
        8,
    )

    for number, lower_halves in ((124, ("C3", "C4")), (125, ("C4", "C4"))):
        upper: list[ET.Element] = []
        for _ in range(2):
            upper.append(notated_note(None, 1, "eighth", "1", "1"))
            append_eighth_run(upper, ("D5", "G5", "E5"), "1", "1")
        lower = [
            notated_note(pitch, 4, "half", "5", "2")
            for pitch in lower_halves
        ]
        rebuild_staff_voices(measure_for(root, "P2", number), upper, lower, 8)


def replace_page10_accompaniment(root: ET.Element) -> None:
    """Transcribe the complete piano part visible on source page 10."""
    for number, (upper_cell, lower_halves) in PAGE10_ACCOMPANIMENT.items():
        upper: list[ET.Element] = []
        for _ in lower_halves:
            upper.append(notated_note(None, 1, "eighth", "1", "1"))
            append_eighth_run(upper, upper_cell, "1", "1")
        lower = [
            notated_note(pitch, 4, "half", "5", "2")
            for pitch in lower_halves
        ]
        duration = 4 if number == 138 else 8
        rebuild_staff_voices(measure_for(root, "P2", number), upper, lower, duration)


def replace_page11_accompaniment(root: ET.Element) -> None:
    """Transcribe the complete piano part visible on source page 11."""
    upper_147: list[ET.Element] = []
    for _ in range(2):
        upper_147.append(notated_note(None, 1, "eighth", "1", "1"))
        append_eighth_run(upper_147, ("C5", "G5", "C5"), "1", "1")
    lower_147 = [
        notated_note("F3", 4, "half", "5", "2"),
        notated_note("F3", 4, "half", "5", "2"),
    ]
    rebuild_staff_voices(measure_for(root, "P2", 147), upper_147, lower_147, 8)

    for number, bass_pair in PAGE11_BASS.items():
        upper = final_unbeamed_upper_pattern()
        lower = [
            notated_note(pitch, 2, "quarter", "5", "2")
            for pitch in (*bass_pair, *bass_pair)
        ]
        rebuild_staff_voices(measure_for(root, "P2", number), upper, lower, 8)


def replace_page12_accompaniment(root: ET.Element) -> None:
    """Transcribe the complete piano part visible on source page 12."""
    for number, bass_pair in PAGE12_PATTERN_BASS.items():
        lower = [
            notated_note(pitch, 2, "quarter", "5", "2")
            for pitch in (*bass_pair, *bass_pair)
        ]
        rebuild_staff_voices(
            measure_for(root, "P2", number),
            final_unbeamed_upper_pattern(),
            lower,
            8,
        )

    for number, (bass_halves, upper_chords) in PAGE12_CADENCE.items():
        upper = [
            note
            for chord_pitches in upper_chords
            for note in half_note_chord(chord_pitches)
        ]
        lower = [
            notated_note(pitch, 4, "half", "5", "2")
            for pitch in bass_halves
        ]
        rebuild_staff_voices(measure_for(root, "P2", number), upper, lower, 8)

    rebuild_staff_voices(
        measure_for(root, "P2", 173),
        [notated_note(None, 8, "whole", "1", "1", measure_rest=True)],
        [notated_note("E2", 8, "whole", "5", "2", tie="start")],
        8,
    )
    rebuild_staff_voices(
        measure_for(root, "P2", 174),
        [notated_note(None, 8, "whole", "1", "1", measure_rest=True)],
        [notated_note("E2", 8, "whole", "5", "2", tie="stop")],
        8,
    )


def apply_page_verified_corrections(root: ET.Element) -> None:
    # Page 1, measures 1-15: rebuild both the complete sparse piano pattern and
    # the optional vocal line. The final D4 ties into the whole note at the
    # beginning of page 2, so restore both ends of that cross-page tie.
    replace_page1_parts(root)

    # Page 2, measures 16-27: rebuild the complete repeated piano figure and
    # vocal phrases, including the F4/D4 melodic motion OMR flattened to E4
    # and the final D4 tie into measure 28 on page 3.
    replace_page2_parts(root)

    # Short transition bars on pages 5 and 6 acquired sustained/chord objects
    # from the adjacent voice or piano staff. Retain only objects whose
    # horizontal positions lie inside the printed bar and rebuild each staff's
    # cursor against the source meter. Page-2 measure 27 is already rebuilt
    # without coordinate-dependent filtering by replace_page2_parts above.
    for number, duration in ((66, 8), (78, 4)):
        voice = measure_for(root, "P1", number)
        for note in list(voice.findall("note")):
            if note_x(note) < 20:
                voice.remove(note)

        piano = measure_for(root, "P2", number)
        upper = [
            note
            for note in piano.findall("note")
            if note.findtext("staff", "1") == "1" and note_x(note) >= 20
        ]
        lower = [
            note
            for note in piano.findall("note")
            if note.findtext("staff", "1") == "2" and note_x(note) >= 20
        ]
        rebuild_staff_voices(piano, upper, lower, duration)

    # Page 5, measure 58: the upper accompaniment was read correctly, while
    # three overlapping bass voices included a spurious whole note. The next
    # printed bar repeats the same bass figure, so use its fully recognized
    # staff-2 sequence.
    measure_58 = measure_for(root, "P2", 58)
    measure_59 = measure_for(root, "P2", 59)
    upper_58 = [note for note in measure_58.findall("note") if note.findtext("staff") == "1"]
    lower_58 = [
        copy.deepcopy(note)
        for note in measure_59.findall("note")
        if note.findtext("staff") == "2"
    ]
    rebuild_staff_voices(measure_58, upper_58, lower_58, 16)

    # Page 6, measure 79: the voice line is a whole-bar rest. Piano has the
    # same seven-event right-hand figure as measures 80-82; Audiveris prepended
    # a carried vocal chord and omitted the final D/rest eighths.
    voice_79 = measure_for(root, "P1", 79)
    voice_80 = measure_for(root, "P1", 80)
    full_rest = copy.deepcopy(voice_80.find("note"))
    if full_rest is None:
        raise ValueError("missing source whole-measure rest in P1 measure 80")
    rebuild_staff_voices(voice_79, [full_rest], [], 8)

    piano_79 = measure_for(root, "P2", 79)
    piano_80 = measure_for(root, "P2", 80)
    upper_79 = [
        note
        for note in piano_79.findall("note")
        if note.findtext("staff") == "1" and note_x(note) >= 20
    ]
    lower_79 = [
        note
        for note in piano_79.findall("note")
        if note.findtext("staff") == "2" and note_x(note) >= 20
    ]
    upper_80 = [note for note in piano_80.findall("note") if note.findtext("staff") == "1"]
    lower_80 = [note for note in piano_80.findall("note") if note.findtext("staff") == "2"]
    upper_79.append(copy.deepcopy(upper_80[-1]))
    lower_79.append(copy.deepcopy(lower_80[-1]))
    rebuild_staff_voices(piano_79, upper_79, lower_79, 8)

    # Page 6, measure 83: quarter + eighth + eighth + dotted-quarter +
    # eighth. OMR stretched the third note and omitted the final A3 eighth.
    voice_83 = measure_for(root, "P1", 83)
    notes_83 = voice_83.findall("note")
    third = next(note for note in notes_83 if 145 <= note_x(note) <= 160)
    third.find("duration").text = "1"
    third.find("type").text = "eighth"
    for dot in third.findall("dot"):
        third.remove(dot)
    final_note = copy.deepcopy(next(note for note in notes_83 if 185 <= note_x(note) <= 200))
    final_note.set("default-x", "286")
    final_note.find("duration").text = "1"
    final_note.find("type").text = "eighth"
    for dot in final_note.findall("dot"):
        final_note.remove(dot)
    notations = final_note.find("notations")
    if notations is not None:
        final_note.remove(notations)
    for backup in list(voice_83.findall("backup")):
        voice_83.remove(backup)
    voice_83.append(final_note)

    # Page 8, measures 98-114: the dense accompaniment consists of alternating
    # beamed eighth pairs and quarter rests in both staves. Audiveris doubled
    # the pair durations and stopped after beat 2. Rebuild only the complete
    # pitches/rhythms visibly present in the supplied engraving.
    replace_page8_accompaniment(root)

    # Page 9, measures 115-125: recover the complete two-hand figures and the
    # independently printed low E2 in measure 123. Measures 126-130 required
    # no XML mutation after visual review.
    replace_page9_accompaniment(root)

    # Page 10, measures 131-146: rebuild the complete repeating texture,
    # including the 2/4 transition and the corrected C4 bass notes in 136-137.
    replace_page10_accompaniment(root)

    # Page 11, measures 147-164: rebuild the final beamed cell followed by the
    # complete un-beamed right-hand figure and quarter-note bass alternation.
    replace_page11_accompaniment(root)

    # Page 12, measures 165-174: finish the repeated two-hand figure, the two
    # arpeggiated half-note cadence bars, and the tied low-E close.
    replace_page12_accompaniment(root)


def set_metadata(root: ET.Element, title: str, creator: str, tempo: int, recognition_gap_count: int) -> None:
    work = root.find("work")
    if work is None:
        work = ET.Element("work")
        root.insert(0, work)
    work_title = work.find("work-title")
    if work_title is None:
        work_title = child(work, "work-title")
    work_title.text = title

    identification = root.find("identification")
    if identification is None:
        identification = ET.Element("identification")
        root.insert(1, identification)
    composer = next((node for node in identification.findall("creator") if node.get("type") == "composer"), None)
    if composer is None:
        composer = child(identification, "creator", creator, type="composer")
    else:
        composer.text = creator
    rights = identification.find("rights")
    if rights is None:
        rights = child(identification, "rights")
    rights.text = "Private study transcription from user-supplied pages; do not redistribute."

    miscellaneous = identification.find("miscellaneous")
    if miscellaneous is None:
        miscellaneous = child(identification, "miscellaneous")
    status = child(
        miscellaneous,
        "miscellaneous-field",
        (
            f"Meter-complete OMR draft with {recognition_gap_count} explicit "
            "forward-padded recognition gaps; manual pitch and rhythm review required"
        ),
        name="transcription-status",
    )
    status.tail = "\n"

    first_measure = root.find("./part/measure")
    if first_measure is not None:
        direction = ET.Element("direction", {"placement": "above"})
        direction_type = child(direction, "direction-type")
        metronome = child(direction_type, "metronome")
        child(metronome, "beat-unit", "quarter")
        child(metronome, "per-minute", str(tempo))
        child(direction, "sound", tempo=str(tempo))
        insert_at = 1 if first_measure.find("attributes") is not None else 0
        first_measure.insert(insert_at, direction)


def label_performance_roles(root: ET.Element) -> None:
    """Keep the sung line as an optional guide, never as piano target notes."""
    names = {
        "P1": "Vocal guide (optional)",
        "P2": "Piano reduction (draft)",
    }
    for score_part in root.findall("./part-list/score-part"):
        part_id = score_part.get("id", "")
        name = score_part.find("part-name")
        if name is not None and part_id in names:
            name.text = names[part_id]
        if part_id == "P2":
            instrument = score_part.find("./score-instrument/instrument-name")
            if instrument is not None:
                instrument.text = "Acoustic Grand Piano"
            midi_program = score_part.find("./midi-instrument/midi-program")
            if midi_program is not None:
                midi_program.text = "1"


def add_source_lyric_phrases(root: ET.Element) -> None:
    for number, text in SOURCE_LYRIC_PHRASES.items():
        measure = measure_for(root, "P1", number)
        direction = ET.Element("direction", {"placement": "above"})
        direction_type = child(direction, "direction-type")
        words = child(direction_type, "words", text)
        words.set("font-style", "italic")
        words.set("font-size", "9")
        attributes = measure.find("attributes")
        insert_at = 1 if attributes is not None else 0
        measure.insert(insert_at, direction)


def write_mxl(root: ET.Element, path: Path) -> None:
    ET.indent(root, space="  ")
    xml_buffer = io.BytesIO()
    ET.ElementTree(root).write(xml_buffer, encoding="utf-8", xml_declaration=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        mime = zipfile.ZipInfo("mimetype")
        mime.compress_type = zipfile.ZIP_STORED
        archive.writestr(mime, b"application/vnd.recordare.musicxml")
        archive.writestr("META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("score.musicxml", xml_buffer.getvalue(), compress_type=zipfile.ZIP_DEFLATED)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--title", default="Holocene")
    parser.add_argument("--creator", default="Bon Iver")
    parser.add_argument("--gap-json", type=Path)
    parser.add_argument("--gap-markdown", type=Path)
    parser.add_argument("--source-review-json", type=Path)
    parser.add_argument("--source-review-markdown", type=Path)
    parser.add_argument(
        "--skip-page-corrections",
        action="store_true",
        help=(
            "normalize a new OMR candidate without applying coordinate-specific "
            "repairs verified against the current reference recognition"
        ),
    )
    # A clean, temporary Chrome/BlackHole capture of the authorized SoundCloud
    # stream produced strong 146.5/148.9 quarter-note candidates, matching the
    # published 147-148 BPM analyses. The supplied score's printed metronome
    # glyph is also a quarter note; never halve it as though it were an eighth.
    # Use 147 as the recording-calibrated base while a longer variable-tempo
    # audit remains a separate synchronization gate.
    parser.add_argument("--tempo", type=int, default=147)
    args = parser.parse_args()
    root = read_score(args.source)
    normalize_omr_measure_sequence(root)
    normalize_source_meters(root)
    normalize_full_measure_rests(root)
    if not args.skip_page_corrections:
        apply_page_verified_corrections(root)
    label_performance_roles(root)
    gaps = pad_recognition_gaps(root)
    set_metadata(root, args.title, args.creator, args.tempo, len(gaps))
    add_source_lyric_phrases(root)
    write_mxl(root, args.destination)
    write_gap_ledger(gaps, args.gap_json, args.gap_markdown)
    write_source_review_ledger(
        root,
        gaps,
        args.source_review_json,
        args.source_review_markdown,
    )


if __name__ == "__main__":
    main()
