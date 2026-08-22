#!/usr/bin/env python3
"""Focused regression tests for private MusicXML repair and audit semantics."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parent


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


finalize = load_script("finalize_private_mxl", "finalize-private-mxl.py")
audit_module = load_script("audit_musicxml", "audit-musicxml.py")


def two_lane_underfilled_score() -> ET.Element:
    return ET.fromstring(
        """
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>Piano</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>2</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <pitch><step>C</step><octave>4</octave></pitch>
                <duration>4</duration><voice>1</voice><type>half</type><staff>1</staff>
              </note>
              <backup><duration>4</duration></backup>
              <note>
                <pitch><step>C</step><octave>3</octave></pitch>
                <duration>4</duration><voice>2</voice><type>half</type><staff>2</staff>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
    )


class PrivateMxlPipelineTests(unittest.TestCase):
    def test_phantom_measure_is_removed_and_following_bars_are_renumbered(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P1"><part-name>Voice</part-name></score-part>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P1">
                <measure number="137" width="200"/>
                <measure number="138" width="24"><note><rest/></note></measure>
                <measure number="139" width="174"/>
              </part>
              <part id="P2">
                <measure number="137" width="200"/>
                <measure number="138" width="24"/>
                <measure number="139" width="174">
                  <attributes><time><beats>2</beats><beat-type>4</beat-type></time></attributes>
                </measure>
              </part>
            </score-partwise>
            """
        )

        self.assertTrue(finalize.normalize_omr_measure_sequence(root))
        for part_id in ("P1", "P2"):
            numbers = [
                int(measure.get("number", "0"))
                for measure in root.findall(f"./part[@id='{part_id}']/measure")
            ]
            self.assertEqual([137, 138], numbers)
        self.assertEqual(
            "2",
            root.findtext("./part[@id='P2']/measure[@number='138']/attributes/time/beats"),
        )

    def test_padding_completes_each_lane_without_inventing_notes(self) -> None:
        root = two_lane_underfilled_score()

        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual(2, len(gaps))
        self.assertEqual([4, 4], [gap["gap_divisions"] for gap in gaps])
        self.assertEqual(2, len(root.findall("./part/measure/forward")))
        self.assertEqual("8", root.findtext("./part/measure/backup/duration"))
        self.assertEqual(2, len(root.findall("./part/measure/note")))
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual("CLEAR", report["review_status"])

    def test_source_warning_does_not_turn_structural_pass_into_fail(self) -> None:
        root = two_lane_underfilled_score()
        finalize.pad_recognition_gaps(root)
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "omr.log"
            log.write_text("[sheet#1] MeasureStack#1 no correct rhythm\n")
            report = audit_module.audit(root, log)

        self.assertEqual("PASS", report["status"])
        self.assertEqual("REVIEW_REQUIRED", report["review_status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(1, report["source_warning_count"])

    def test_page1_rebuilds_both_parts_and_cross_page_vocal_tie(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P1"><part-name>Voice</part-name></score-part>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P1"/>
              <part id="P2"/>
            </score-partwise>
            """
        )

        def append_measures(part_id: str, final_measure: int) -> None:
            part = root.find(f"./part[@id='{part_id}']")
            assert part is not None
            for number in range(1, final_measure + 1):
                measure = ET.SubElement(part, "measure", {"number": str(number)})
                if number in (1, 3, 4, 15, 16):
                    attributes = ET.SubElement(measure, "attributes")
                    ET.SubElement(attributes, "divisions").text = "2"
                    time = ET.SubElement(attributes, "time")
                    ET.SubElement(time, "beats").text = (
                        "2" if number in (3, 15) else "4"
                    )
                    ET.SubElement(time, "beat-type").text = "4"

        append_measures("P1", 16)
        append_measures("P2", 15)
        finalize.replace_page1_parts(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(196, len(root.findall("./part/measure/note")))
        self.assertEqual(15, len(root.findall("./part[@id='P2']/measure/backup")))

        def pitches(part_id: str, measure: int, staff: str) -> list[str]:
            result = []
            for note in root.findall(
                f"./part[@id='{part_id}']/measure[@number='{measure}']/note"
            ):
                if note.findtext("staff") != staff or note.find("rest") is not None:
                    continue
                pitch = note.find("pitch")
                assert pitch is not None
                result.append(pitch.findtext("step", "") + pitch.findtext("octave", ""))
            return result

        self.assertEqual(
            ["G4", "G4", "D4", "E4", "D4"], pitches("P2", 4, "1")
        )
        self.assertEqual(["A2", "A3"], pitches("P2", 8, "2"))
        self.assertEqual(["F2", "F3"], pitches("P2", 12, "2"))
        self.assertEqual(["C3", "C4"], pitches("P2", 14, "2"))
        self.assertEqual(["A2", "A3"], pitches("P2", 15, "2"))
        self.assertEqual(["E4", "E4", "E4", "E4"], pitches("P1", 13, "1"))
        self.assertEqual(["E4", "D4", "D4"], pitches("P1", 15, "1"))
        self.assertEqual(["D4"], pitches("P1", 16, "1"))
        self.assertEqual(
            "start",
            root.find("./part[@id='P1']/measure[@number='15']/note[3]/tie").get(
                "type"
            ),
        )
        self.assertEqual(
            "stop",
            root.find("./part[@id='P1']/measure[@number='16']/note/tie").get(
                "type"
            ),
        )

        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(31, review["entry_count"])
        self.assertEqual(31, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])

    def test_page2_rebuilds_both_parts_lyrics_and_cross_page_tie(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P1"><part-name>Voice</part-name></score-part>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P1"/>
              <part id="P2"/>
            </score-partwise>
            """
        )

        def append_measures(part_id: str, final_measure: int) -> None:
            part = root.find(f"./part[@id='{part_id}']")
            assert part is not None
            for number in range(16, final_measure + 1):
                measure = ET.SubElement(part, "measure", {"number": str(number)})
                if number in (16, 27, 28):
                    attributes = ET.SubElement(measure, "attributes")
                    ET.SubElement(attributes, "divisions").text = "2"
                    time = ET.SubElement(attributes, "time")
                    ET.SubElement(time, "beats").text = "2" if number == 27 else "4"
                    ET.SubElement(time, "beat-type").text = "4"

        append_measures("P1", 28)
        append_measures("P2", 27)
        finalize.replace_page2_parts(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(171, len(root.findall("./part/measure/note")))
        self.assertEqual(12, len(root.findall("./part[@id='P2']/measure/backup")))
        self.assertEqual(0, len(root.findall("./part/measure/forward")))

        def pitches(part_id: str, measure: int, staff: str) -> list[str]:
            result = []
            for note in root.findall(
                f"./part[@id='{part_id}']/measure[@number='{measure}']/note"
            ):
                if note.findtext("staff") != staff or note.find("rest") is not None:
                    continue
                pitch = note.find("pitch")
                assert pitch is not None
                result.append(pitch.findtext("step", "") + pitch.findtext("octave", ""))
            return result

        self.assertEqual(["F2", "F3"], pitches("P2", 21, "2"))
        self.assertEqual(["C3", "C4"], pitches("P2", 25, "2"))
        self.assertEqual(["D4", "C4", "C4"], pitches("P1", 21, "1"))
        self.assertEqual(["E4", "F4", "D4", "E4"], pitches("P1", 25, "1"))
        self.assertEqual(["E4", "D4", "D4"], pitches("P1", 27, "1"))
        self.assertEqual(["D4"], pitches("P1", 28, "1"))

        pickup = root.findall("./part[@id='P1']/measure[@number='19']/note")
        self.assertEqual(["4", "3", "1"], [note.findtext("duration") for note in pickup])
        self.assertEqual(1, len(pickup[1].findall("dot")))
        self.assertEqual(
            ["fucked", "it", "friend,", "it's"],
            [
                lyric.findtext("text", "")
                for lyric in root.findall(
                    "./part[@id='P1']/measure[@number='25']/note/lyric"
                )
            ],
        )
        self.assertEqual(
            "start",
            root.find("./part[@id='P1']/measure[@number='27']/note[3]/tie").get(
                "type"
            ),
        )
        self.assertEqual(
            "stop",
            root.find("./part[@id='P1']/measure[@number='28']/note/tie").get(
                "type"
            ),
        )

        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(25, review["entry_count"])
        self.assertEqual(24, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])

    def test_page8_accompaniment_is_complete_without_padding(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P2">
                <measure number="98">
                  <attributes>
                    <divisions>2</divisions>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                  </attributes>
                </measure>
              </part>
            </score-partwise>
            """
        )
        part = root.find("part")
        assert part is not None
        for number in range(99, 115):
            part.append(ET.Element("measure", {"number": str(number)}))

        finalize.replace_page8_accompaniment(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(218, len(root.findall("./part/measure/note")))
        self.assertEqual(17, len(root.findall("./part/measure/backup")))
        self.assertEqual(0, len(root.findall("./part/measure/forward")))
        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(17, review["entry_count"])
        self.assertEqual(17, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])

    def test_page9_accompaniment_recovers_both_halves_and_low_bass(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P2">
                <measure number="115">
                  <attributes>
                    <divisions>2</divisions>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                  </attributes>
                </measure>
              </part>
            </score-partwise>
            """
        )
        part = root.find("part")
        assert part is not None
        for number in range(116, 126):
            part.append(ET.Element("measure", {"number": str(number)}))

        finalize.replace_page9_accompaniment(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(118, len(root.findall("./part/measure/note")))
        self.assertEqual(11, len(root.findall("./part/measure/backup")))

        def pitches(measure: int, staff: str) -> list[str]:
            result = []
            for note in root.findall(f"./part/measure[@number='{measure}']/note"):
                if note.findtext("staff") != staff or note.find("rest") is not None:
                    continue
                pitch = note.find("pitch")
                assert pitch is not None
                result.append(pitch.findtext("step", "") + pitch.findtext("octave", ""))
            return result

        self.assertEqual(["E4", "A4", "C4", "E4"], pitches(121, "1"))
        self.assertEqual(["F3", "A3", "C3", "E3"], pitches(122, "2"))
        self.assertEqual(["E2"], pitches(123, "2"))
        self.assertEqual(["C3", "C4"], pitches(124, "2"))
        self.assertEqual(["C4", "C4"], pitches(125, "2"))

        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(11, review["entry_count"])
        self.assertEqual(11, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])

    def test_page10_accompaniment_rebuilds_transition_and_bass_pitches(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P2">
                <measure number="131">
                  <attributes>
                    <divisions>2</divisions>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                  </attributes>
                </measure>
              </part>
            </score-partwise>
            """
        )
        part = root.find("part")
        assert part is not None
        for number in range(132, 147):
            measure = ET.Element("measure", {"number": str(number)})
            if number in (138, 139):
                attributes = ET.SubElement(measure, "attributes")
                time = ET.SubElement(attributes, "time")
                ET.SubElement(time, "beats").text = "2" if number == 138 else "4"
                ET.SubElement(time, "beat-type").text = "4"
            part.append(measure)

        finalize.replace_page10_accompaniment(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(155, len(root.findall("./part/measure/note")))
        self.assertEqual(16, len(root.findall("./part/measure/backup")))

        def pitches(measure: int, staff: str) -> list[str]:
            result = []
            for note in root.findall(f"./part/measure[@number='{measure}']/note"):
                if note.findtext("staff") != staff or note.find("rest") is not None:
                    continue
                pitch = note.find("pitch")
                assert pitch is not None
                result.append(pitch.findtext("step", "") + pitch.findtext("octave", ""))
            return result

        self.assertEqual(["C3", "C4"], pitches(136, "2"))
        self.assertEqual(["C4", "C4"], pitches(137, "2"))
        self.assertEqual(["D5", "G5", "E5"], pitches(138, "1"))
        self.assertEqual(["A3"], pitches(138, "2"))
        self.assertEqual(
            ["C5", "G5", "C5", "C5", "G5", "C5"],
            pitches(144, "1"),
        )
        self.assertEqual(["F2", "F3"], pitches(144, "2"))

        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(16, review["entry_count"])
        self.assertEqual(16, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])

    def test_page11_accompaniment_rebuilds_all_printed_figures(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P2">
                <measure number="147">
                  <attributes>
                    <divisions>2</divisions>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                  </attributes>
                </measure>
              </part>
            </score-partwise>
            """
        )
        part = root.find("part")
        assert part is not None
        for number in range(148, 165):
            part.append(ET.Element("measure", {"number": str(number)}))

        finalize.replace_page11_accompaniment(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(197, len(root.findall("./part/measure/note")))
        self.assertEqual(18, len(root.findall("./part/measure/backup")))
        self.assertEqual(0, len(root.findall("./part/measure/forward")))

        def pitches(measure: int, staff: str) -> list[str]:
            result = []
            for note in root.findall(f"./part/measure[@number='{measure}']/note"):
                if note.findtext("staff") != staff or note.find("rest") is not None:
                    continue
                pitch = note.find("pitch")
                assert pitch is not None
                result.append(pitch.findtext("step", "") + pitch.findtext("octave", ""))
            return result

        self.assertEqual(
            ["C5", "G5", "C5", "C5", "G5", "C5"],
            pitches(147, "1"),
        )
        self.assertEqual(["F3", "F3"], pitches(147, "2"))
        self.assertEqual(
            ["G5", "G5", "C5", "D5", "C5"],
            pitches(148, "1"),
        )
        self.assertEqual(["F3", "C4", "F3", "C4"], pitches(148, "2"))
        self.assertEqual(["A2", "A3", "A2", "A3"], pitches(152, "2"))
        self.assertEqual(["G2", "G3", "G2", "G3"], pitches(154, "2"))
        self.assertEqual(["F3", "C4", "F3", "C4"], pitches(156, "2"))
        self.assertEqual(["A2", "A3", "A2", "A3"], pitches(160, "2"))
        self.assertEqual(["G2", "G3", "G2", "G3"], pitches(162, "2"))
        self.assertEqual(["F3", "C4", "F3", "C4"], pitches(164, "2"))
        self.assertEqual([], root.findall("./part/measure[@number='148']/note/beam"))

        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(18, review["entry_count"])
        self.assertEqual(18, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])

    def test_page12_accompaniment_rebuilds_cadence_and_tied_close(self) -> None:
        root = ET.fromstring(
            """
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P2"><part-name>Piano</part-name></score-part>
              </part-list>
              <part id="P2">
                <measure number="165">
                  <attributes>
                    <divisions>2</divisions>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                  </attributes>
                </measure>
              </part>
            </score-partwise>
            """
        )
        part = root.find("part")
        assert part is not None
        for number in range(166, 175):
            part.append(ET.Element("measure", {"number": str(number)}))

        finalize.replace_page12_accompaniment(root)
        gaps = finalize.pad_recognition_gaps(root)
        report = audit_module.audit(root, None)

        self.assertEqual([], gaps)
        self.assertEqual("PASS", report["status"])
        self.assertEqual(0, report["issue_count"])
        self.assertEqual(10, len(root.findall("./part/measure/backup")))
        self.assertEqual(0, len(root.findall("./part/measure/forward")))

        def pitches(measure: int, staff: str) -> list[str]:
            result = []
            for note in root.findall(f"./part/measure[@number='{measure}']/note"):
                if note.findtext("staff") != staff or note.find("rest") is not None:
                    continue
                pitch = note.find("pitch")
                assert pitch is not None
                result.append(pitch.findtext("step", "") + pitch.findtext("octave", ""))
            return result

        self.assertEqual(["F3", "C4", "F3", "C4"], pitches(165, "2"))
        self.assertEqual(["G2", "G3", "G2", "G3"], pitches(167, "2"))
        self.assertEqual(["G2", "G3", "G2", "G3"], pitches(170, "2"))
        self.assertEqual(
            ["A4", "C5", "E5", "F4", "A4", "C5"],
            pitches(171, "1"),
        )
        self.assertEqual(["G3", "E3"], pitches(171, "2"))
        self.assertEqual(["G3", "C3"], pitches(172, "2"))
        self.assertEqual(["E2"], pitches(173, "2"))
        self.assertEqual(["E2"], pitches(174, "2"))
        self.assertEqual(
            "start",
            root.find("./part/measure[@number='173']/note/tie").get("type"),
        )
        self.assertEqual(
            "stop",
            root.find("./part/measure[@number='174']/note/tie").get("type"),
        )
        self.assertEqual(
            "yes",
            root.find("./part/measure[@number='173']/note/rest").get("measure"),
        )

        with tempfile.TemporaryDirectory() as directory:
            review_path = Path(directory) / "review.json"
            finalize.write_source_review_ledger(root, gaps, review_path, None)
            review = json.loads(review_path.read_text())
        self.assertEqual(10, review["entry_count"])
        self.assertEqual(10, review["page_complete_count"])
        self.assertEqual(0, review["recording_verified_count"])


if __name__ == "__main__":
    unittest.main()
