#!/usr/bin/env python3
"""Regression tests for recording-overlap evidence alignment."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent / "align-audio-evidence.py"
SPEC = importlib.util.spec_from_file_location("align_audio_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
alignment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(alignment)


def chroma(index: int) -> list[float]:
    values = [
        float(((index + 1) * (lane * 17 + 37) + lane * lane * 11) % 101 + 1)
        for lane in range(12)
    ]
    total = sum(values)
    return [value / total for value in values]


def frame(time: float, pattern_index: int, rms: float = 0.1) -> dict[str, object]:
    return {"time": time, "rms": rms, "chroma": chroma(pattern_index)}


class AudioEvidenceAlignmentTests(unittest.TestCase):
    def test_finds_query_on_active_reference_timeline(self) -> None:
        reference_frames = [frame(index * 0.25, index) for index in range(160)]
        query_frames = [frame(index * 0.25, 0, 0.0) for index in range(2)]
        query_frames.extend(
            frame(index * 0.25, 38 + index - 2) for index in range(2, 42)
        )
        reference = {
            "duration_seconds": 40.0,
            "active_audio": {"start_seconds": 2.0, "end_seconds": 40.0},
            "frames": reference_frames,
        }
        query = {
            "duration_seconds": 10.5,
            "active_audio": {"start_seconds": 0.5, "end_seconds": 10.5},
            "frames": query_frames,
        }

        result = alignment.align_reports(reference, query, window_seconds=8.0)

        self.assertEqual(9.5, result["query_start_in_reference_capture_seconds"])
        self.assertEqual(7.5, result["query_start_in_reference_content_seconds"])
        self.assertEqual(7.5, result["query_to_reference_content_offset_seconds"])
        self.assertEqual(1.0, result["similarity"])
        self.assertEqual("REVIEW_REQUIRED", result["review_status"])

    def test_rejects_mismatched_frame_intervals(self) -> None:
        reference = {
            "active_audio": {"start_seconds": 0.0, "end_seconds": 1.0},
            "frames": [frame(0.0, 0), frame(0.25, 1), frame(0.5, 2)],
        }
        query = {
            "active_audio": {"start_seconds": 0.0, "end_seconds": 1.0},
            "frames": [frame(0.0, 0), frame(0.5, 1), frame(1.0, 2)],
        }
        with self.assertRaisesRegex(ValueError, "same positive frame interval"):
            alignment.align_reports(reference, query, window_seconds=0.5)


if __name__ == "__main__":
    unittest.main()
