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
import zipfile
import xml.etree.ElementTree as ET
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


def apply_page_verified_corrections(root: ET.Element) -> None:
    # Short transition bars on pages 2, 5, and 6 acquired sustained/chord
    # objects from the adjacent voice or piano staff. Retain only objects whose
    # horizontal positions lie inside the printed bar and rebuild each staff's
    # cursor against the source meter.
    for number, duration in ((27, 4), (66, 8), (78, 4)):
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

    # Page 10, measures 136-137: the second bass note in each bar is a half
    # note, not the dotted half inferred by OMR.
    for number in (136, 137):
        piano = measure_for(root, "P2", number)
        bass = [
            note
            for note in piano.findall("note")
            if note.findtext("staff") == "2" and note.findtext("voice") == "5"
        ]
        last = bass[-1]
        last.find("duration").text = "4"
        last.find("type").text = "half"
        for dot in last.findall("dot"):
            last.remove(dot)


def set_metadata(root: ET.Element, title: str, creator: str, tempo: int) -> None:
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
    status = child(miscellaneous, "miscellaneous-field", "OMR draft; manual pitch and rhythm review required", name="transcription-status")
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
    # The supplied edition prints eighth-note = 132. MusicXML's sound tempo is
    # quarter notes per minute, so the equivalent playback tempo is 66 QPM.
    parser.add_argument("--tempo", type=int, default=66)
    args = parser.parse_args()
    root = read_score(args.source)
    normalize_source_meters(root)
    normalize_full_measure_rests(root)
    apply_page_verified_corrections(root)
    set_metadata(root, args.title, args.creator, args.tempo)
    label_performance_roles(root)
    add_source_lyric_phrases(root)
    write_mxl(root, args.destination)


if __name__ == "__main__":
    main()
