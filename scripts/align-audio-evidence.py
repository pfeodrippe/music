#!/usr/bin/env python3
"""Align two score-audio-analyze reports by their normalized chroma evidence.

This intentionally works on the analyzer's compact JSON reports rather than
redistributing either source recording.  The query report's active-audio start
is located on the reference report's active timeline at 250 ms resolution.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


def _active_frames(report: dict[str, Any]) -> list[dict[str, Any]]:
    active = report.get("active_audio", {})
    start = float(active.get("start_seconds", 0.0))
    end = float(active.get("end_seconds", report.get("duration_seconds", 0.0)))
    return [
        frame
        for frame in report.get("frames", [])
        if start <= float(frame["time"]) < end
    ]


def _cosine(left: list[float], right: list[float]) -> float | None:
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0.0 or right_norm == 0.0:
        return None
    return sum(a * b for a, b in zip(left, right)) / (left_norm * right_norm)


def _window_similarity(
    reference: list[dict[str, Any]], query: list[dict[str, Any]], start: int, count: int
) -> tuple[float, int]:
    weighted_similarity = 0.0
    total_weight = 0.0
    compared = 0
    for index in range(count):
        reference_frame = reference[start + index]
        query_frame = query[index]
        similarity = _cosine(reference_frame["chroma"], query_frame["chroma"])
        if similarity is None:
            continue
        # Quiet frames contain little identifying evidence. Cap the influence
        # of loud frames so a short transient cannot dominate a whole window.
        weight = min(
            1.0,
            20.0
            * min(float(reference_frame.get("rms", 0.0)), float(query_frame.get("rms", 0.0))),
        )
        if weight <= 0.0:
            continue
        weighted_similarity += similarity * weight
        total_weight += weight
        compared += 1
    if total_weight == 0.0:
        return 0.0, 0
    return weighted_similarity / total_weight, compared


def align_reports(
    reference_report: dict[str, Any],
    query_report: dict[str, Any],
    *,
    window_seconds: float = 60.0,
) -> dict[str, Any]:
    reference = _active_frames(reference_report)
    query = _active_frames(query_report)
    if len(reference) < 2 or len(query) < 2:
        raise ValueError("both reports need at least two active analysis frames")

    frame_seconds = float(reference[1]["time"]) - float(reference[0]["time"])
    query_frame_seconds = float(query[1]["time"]) - float(query[0]["time"])
    if frame_seconds <= 0.0 or abs(query_frame_seconds - frame_seconds) > 0.001:
        raise ValueError("reports must use the same positive frame interval")

    window_count = min(len(query), max(2, round(window_seconds / frame_seconds)))
    if len(reference) < window_count:
        raise ValueError("reference active range is shorter than the comparison window")

    candidates: list[tuple[float, int, int]] = []
    for start in range(len(reference) - window_count + 1):
        similarity, compared = _window_similarity(reference, query, start, window_count)
        candidates.append((similarity, start, compared))
    candidates.sort(reverse=True)
    best_similarity, best_start, compared = candidates[0]

    separation_frames = max(1, round(2.0 / frame_seconds))
    independent = [
        candidate
        for candidate in candidates[1:]
        if abs(candidate[1] - best_start) > separation_frames
    ]
    runner_up_similarity = independent[0][0] if independent else 0.0

    reference_active = reference_report["active_audio"]
    query_active = query_report["active_audio"]
    reference_capture_time = float(reference[best_start]["time"])
    reference_content_time = reference_capture_time - float(reference_active["start_seconds"])
    query_content_start = float(query[0]["time"]) - float(query_active["start_seconds"])
    timeline_offset = reference_content_time - query_content_start
    reference_remaining = float(reference_active["end_seconds"]) - reference_capture_time
    query_duration = float(query_active["end_seconds"]) - float(query[0]["time"])

    return {
        "schema": 1,
        "analysis_kind": "audio_evidence_overlap_alignment",
        "frame_seconds": round(frame_seconds, 6),
        "comparison_window_seconds": round(window_count * frame_seconds, 3),
        "compared_frames": compared,
        "query_start_in_reference_capture_seconds": round(reference_capture_time, 3),
        "query_start_in_reference_content_seconds": round(reference_content_time, 3),
        "query_to_reference_content_offset_seconds": round(timeline_offset, 3),
        "overlap_seconds": round(min(reference_remaining, query_duration), 3),
        "similarity": round(best_similarity, 6),
        "runner_up_similarity": round(runner_up_similarity, 6),
        "similarity_margin": round(best_similarity - runner_up_similarity, 6),
        "review_status": "REVIEW_REQUIRED",
        "disclaimer": (
            "Chroma overlap establishes capture timing only; it does not certify "
            "score notes, rhythm, fingering, dynamics, or pedaling."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("query", type=Path)
    parser.add_argument("--window", type=float, default=60.0, metavar="SECONDS")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.window <= 0.0:
        parser.error("--window must be positive")

    reference = json.loads(args.reference.read_text())
    query = json.loads(args.query.read_text())
    result = align_reports(reference, query, window_seconds=args.window)
    result["reference_report"] = str(args.reference)
    result["query_report"] = str(args.query)
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output is None:
        print(encoded, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
        print(f"Wrote overlap alignment to {args.output}")


if __name__ == "__main__":
    main()
