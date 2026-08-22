#!/usr/bin/env python3
"""Audit an OMR MusicXML/MXL score for objective structural defects.

The report is intentionally strict. It does not certify musical correctness;
it produces a page/measure worklist that must be cleared against the source
pages before the private score can be called reviewed.
"""

from __future__ import annotations

import argparse
import json
import re
import zipfile
import xml.etree.ElementTree as ET
from collections import defaultdict
from fractions import Fraction
from pathlib import Path


TYPE_QUARTERS = {
    "maxima": Fraction(32),
    "long": Fraction(16),
    "breve": Fraction(8),
    "whole": Fraction(4),
    "half": Fraction(2),
    "quarter": Fraction(1),
    "eighth": Fraction(1, 2),
    "16th": Fraction(1, 4),
    "32nd": Fraction(1, 8),
    "64th": Fraction(1, 16),
    "128th": Fraction(1, 32),
    "256th": Fraction(1, 64),
    "512th": Fraction(1, 128),
    "1024th": Fraction(1, 256),
}


def read_score(path: Path) -> ET.Element:
    if path.suffix.lower() not in {".mxl", ".zip"}:
        return ET.parse(path).getroot()
    with zipfile.ZipFile(path) as archive:
        candidates = [
            name
            for name in archive.namelist()
            if name.lower().endswith((".xml", ".musicxml"))
            and not name.startswith("META-INF/")
        ]
        if not candidates:
            raise ValueError(f"{path} contains no MusicXML document")
        return ET.fromstring(archive.read(candidates[0]))


def page_starts(root: ET.Element) -> list[int]:
    first_part = root.find("part")
    if first_part is None:
        return []
    starts: list[int] = []
    for index, measure in enumerate(first_part.findall("measure")):
        print_node = measure.find("print")
        if index == 0 or (
            print_node is not None and print_node.get("new-page") == "yes"
        ):
            starts.append(int(measure.get("number", str(index + 1))))
    return starts


def page_for_measure(measure: int, starts: list[int]) -> int:
    page = 1
    for index, start in enumerate(starts, start=1):
        if measure < start:
            break
        page = index
    return page


def expected_type_duration(note: ET.Element, divisions: int) -> Fraction | None:
    type_name = note.findtext("type")
    if not type_name or type_name not in TYPE_QUARTERS:
        return None
    duration = TYPE_QUARTERS[type_name] * divisions
    dot_factor = Fraction(1)
    dot_addition = Fraction(1, 2)
    for _ in note.findall("dot"):
        dot_factor += dot_addition
        dot_addition /= 2
    duration *= dot_factor
    modification = note.find("time-modification")
    if modification is not None:
        actual = int(modification.findtext("actual-notes", "1"))
        normal = int(modification.findtext("normal-notes", "1"))
        if actual:
            duration *= Fraction(normal, actual)
    return duration


def parse_omr_conflicts(path: Path | None, starts: list[int]) -> list[dict[str, int]]:
    if path is None or not path.exists():
        return []
    pattern = re.compile(
        r"\[.*?#(?P<page>\d+)\].*?MeasureStack#(?P<local>\d+) no correct rhythm"
    )
    conflicts: set[tuple[int, int, int]] = set()
    for line in path.read_text(errors="replace").splitlines():
        match = pattern.search(line)
        if not match:
            continue
        page = int(match.group("page"))
        local = int(match.group("local"))
        if page <= len(starts):
            conflicts.add((page, local, starts[page - 1] + local - 1))
    return [
        {"page": page, "page_measure": local, "measure": measure}
        for page, local, measure in sorted(conflicts)
    ]


def audit(root: ET.Element, omr_log: Path | None) -> dict:
    starts = page_starts(root)
    part_names = {
        score_part.get("id", ""): score_part.findtext("part-name", "Unnamed")
        for score_part in root.findall("./part-list/score-part")
    }
    issues: list[dict] = []
    signatures: dict[int, dict[str, str]] = defaultdict(dict)
    measure_counts: dict[str, int] = {}

    for part in root.findall("part"):
        part_id = part.get("id", "")
        part_name = part_names.get(part_id, part_id)
        measures = part.findall("measure")
        measure_counts[part_name] = len(measures)
        divisions = 1
        beats = 4
        beat_type = 4

        for index, measure in enumerate(measures):
            number = int(measure.get("number", str(index + 1)))
            page = page_for_measure(number, starts)
            attributes = measure.find("attributes")
            if attributes is not None:
                divisions_text = attributes.findtext("divisions")
                if divisions_text:
                    divisions = int(divisions_text)
                time = attributes.find("time")
                if time is not None:
                    beats = int(time.findtext("beats", str(beats)))
                    beat_type = int(time.findtext("beat-type", str(beat_type)))
            signatures[number][part_name] = f"{beats}/{beat_type}"
            expected = Fraction(divisions * beats * 4, beat_type)
            cursor = Fraction(0)
            furthest = Fraction(0)
            previous_note_onset = Fraction(0)

            for child in measure:
                if child.tag == "backup":
                    cursor -= Fraction(int(child.findtext("duration", "0")))
                    if cursor < 0:
                        issues.append(
                            {
                                "kind": "cursor-before-measure",
                                "page": page,
                                "measure": number,
                                "part": part_name,
                                "detail": f"backup moved cursor to {cursor}",
                            }
                        )
                elif child.tag == "forward":
                    cursor += Fraction(int(child.findtext("duration", "0")))
                    furthest = max(furthest, cursor)
                elif child.tag == "note":
                    duration_text = child.findtext("duration")
                    if duration_text is None:
                        continue
                    duration = Fraction(int(duration_text))
                    is_chord = child.find("chord") is not None
                    onset = previous_note_onset if is_chord else cursor
                    end = onset + duration
                    furthest = max(furthest, end)
                    if not is_chord:
                        previous_note_onset = onset
                        cursor = end
                    rest = child.find("rest")
                    # MusicXML represents a full-measure rest with the
                    # measure's duration while its display type may remain
                    # ``whole`` in meters shorter than 4/4. That is valid,
                    # intentional notation rather than a rhythmic mismatch.
                    is_measure_rest = rest is not None and rest.get("measure") == "yes"
                    type_duration = None if is_measure_rest else expected_type_duration(child, divisions)
                    if type_duration is not None and duration != type_duration:
                        pitch = child.find("pitch")
                        label = "rest"
                        if pitch is not None:
                            label = (
                                f"{pitch.findtext('step', '?')}"
                                f"{pitch.findtext('alter', '')}"
                                f"{pitch.findtext('octave', '?')}"
                            )
                        issues.append(
                            {
                                "kind": "note-duration-type-mismatch",
                                "page": page,
                                "measure": number,
                                "part": part_name,
                                "detail": (
                                    f"{label} duration {duration} but type/dots imply "
                                    f"{type_duration} at divisions={divisions}"
                                ),
                            }
                        )

            if furthest != expected:
                relation = "under" if furthest < expected else "over"
                issues.append(
                    {
                        "kind": f"measure-{relation}filled",
                        "page": page,
                        "measure": number,
                        "part": part_name,
                        "detail": (
                            f"span {furthest}/{expected} divisions in {beats}/{beat_type}"
                        ),
                    }
                )

    for measure, by_part in signatures.items():
        if len(set(by_part.values())) > 1:
            issues.append(
                {
                    "kind": "part-meter-disagreement",
                    "page": page_for_measure(measure, starts),
                    "measure": measure,
                    "part": "all",
                    "detail": ", ".join(f"{key}={value}" for key, value in by_part.items()),
                }
            )

    conflicts = parse_omr_conflicts(omr_log, starts)
    source_warnings = []
    for conflict in conflicts:
        source_warnings.append(
            {
                "kind": "omr-no-correct-rhythm",
                "page": conflict["page"],
                "measure": conflict["measure"],
                "part": "source stack",
                "detail": f"Audiveris page-local measure {conflict['page_measure']}",
            }
        )

    issues.sort(key=lambda item: (item["page"], item["measure"], item["kind"], item["part"]))
    source_warnings.sort(
        key=lambda item: (item["page"], item["measure"], item["kind"], item["part"])
    )
    affected = sorted({(item["page"], item["measure"]) for item in issues})
    source_affected = sorted(
        {(item["page"], item["measure"]) for item in source_warnings}
    )
    return {
        "status": "FAIL" if issues else "PASS",
        "review_status": "REVIEW_REQUIRED" if issues or source_warnings else "CLEAR",
        "scope": (
            "Structural audit only; PASS is not a musical-accuracy certification. "
            "Pitch, spelling, voicing, lyrics, dynamics, articulation, and pedal "
            "still require visual/source review. Audiveris source warnings are "
            "reported separately and never waived by structural padding."
        ),
        "page_starts": starts,
        "measure_counts": measure_counts,
        "issue_count": len(issues),
        "affected_measure_count": len(affected),
        "affected_measures": [
            {"page": page, "measure": measure} for page, measure in affected
        ],
        "issues": issues,
        "source_warning_count": len(source_warnings),
        "source_warning_measure_count": len(source_affected),
        "source_warning_measures": [
            {"page": page, "measure": measure} for page, measure in source_affected
        ],
        "source_warnings": source_warnings,
    }


def write_markdown(report: dict, path: Path) -> None:
    lines = [
        "# MusicXML structural audit",
        "",
        f"**Status:** {report['status']}",
        f"**Review status:** {report['review_status']}",
        "",
        report["scope"],
        "",
        f"- Issues: {report['issue_count']}",
        f"- Affected measures: {report['affected_measure_count']}",
        f"- Measures per part: {report['measure_counts']}",
        f"- Audiveris source warnings: {report['source_warning_count']}",
        f"- Source-warning measures: {report['source_warning_measure_count']}",
        "",
        "| Page | Measure | Part | Issue | Detail |",
        "| ---: | ---: | --- | --- | --- |",
    ]
    for issue in report["issues"]:
        detail = str(issue["detail"]).replace("|", "\\|")
        lines.append(
            f"| {issue['page']} | {issue['measure']} | {issue['part']} | "
            f"{issue['kind']} | {detail} |"
        )
    if report["source_warnings"]:
        lines.extend(
            [
                "",
                "## Source-recognition warnings",
                "",
                "These warnings come from the original Audiveris run. They remain a "
                "manual page/recording-review worklist even when the MusicXML cursor "
                "structure passes.",
                "",
                "| Page | Measure | Source warning | Detail |",
                "| ---: | ---: | --- | --- |",
            ]
        )
        for warning in report["source_warnings"]:
            detail = str(warning["detail"]).replace("|", "\\|")
            lines.append(
                f"| {warning['page']} | {warning['measure']} | "
                f"{warning['kind']} | {detail} |"
            )
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("score", type=Path)
    parser.add_argument("--omr-log", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()
    report = audit(read_score(args.score), args.omr_log)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n")
    write_markdown(report, args.markdown)
    print(
        f"{report['status']}: {report['issue_count']} issues across "
        f"{report['affected_measure_count']} measures; "
        f"{report['source_warning_count']} source warnings remain"
    )


if __name__ == "__main__":
    main()
