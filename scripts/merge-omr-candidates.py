#!/usr/bin/env python3
"""Conservatively merge independently audited MusicXML/MXL OMR candidates.

Only measures which have an issue in the base audit and no issue of any kind in
the candidate audit are eligible. Both parts are replaced together so their
time axes cannot diverge. This is a structural evidence merge, not a musical
accuracy certification; pitch and engraving still require source-page review.
"""

from __future__ import annotations

import argparse
import io
import json
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


def issue_measures(path: Path) -> set[int]:
    report = json.loads(path.read_text())
    return {int(issue["measure"]) for issue in report["issues"]}


def part_map(root: ET.Element) -> dict[str, ET.Element]:
    return {part.get("id", ""): part for part in root.findall("part")}


def measure_map(part: ET.Element) -> dict[int, ET.Element]:
    return {
        int(measure.get("number", str(index + 1))): measure
        for index, measure in enumerate(part.findall("measure"))
    }


def write_mxl(root: ET.Element, path: Path) -> None:
    ET.indent(root, space="  ")
    xml_buffer = io.BytesIO()
    ET.ElementTree(root).write(xml_buffer, encoding="utf-8", xml_declaration=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        mime = zipfile.ZipInfo("mimetype")
        mime.compress_type = zipfile.ZIP_STORED
        archive.writestr(mime, b"application/vnd.recordare.musicxml")
        archive.writestr(
            "META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_DEFLATED
        )
        archive.writestr(
            "score.musicxml", xml_buffer.getvalue(), compress_type=zipfile.ZIP_DEFLATED
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", type=Path)
    parser.add_argument("base_audit", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("candidate_audit", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    base = read_score(args.base)
    candidate = read_score(args.candidate)
    base_parts = part_map(base)
    candidate_parts = part_map(candidate)
    if set(base_parts) != set(candidate_parts):
        raise ValueError("candidate part IDs do not match the base score")

    eligible = issue_measures(args.base_audit) - issue_measures(args.candidate_audit)
    replaced: set[int] = set()
    for part_id, base_part in base_parts.items():
        candidate_measures = measure_map(candidate_parts[part_id])
        for index, measure in enumerate(list(base_part.findall("measure"))):
            number = int(measure.get("number", str(index + 1)))
            if number not in eligible:
                continue
            replacement = candidate_measures.get(number)
            if replacement is None:
                raise ValueError(f"candidate is missing {part_id} measure {number}")
            child_index = list(base_part).index(measure)
            base_part.remove(measure)
            base_part.insert(child_index, replacement)
            replaced.add(number)

    write_mxl(base, args.destination)
    values = ", ".join(str(number) for number in sorted(replaced))
    print(f"Replaced {len(replaced)} structurally improved measures: {values}")


if __name__ == "__main__":
    main()
