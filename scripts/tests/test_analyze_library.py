#!/usr/bin/env python3
"""Hermetic offline analyzer and safe cache-output tests."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import analyze_library
from pulsedeck_cache import (
    BeatGrid,
    CueMarkers,
    ManualOverrides,
    PulseDeckLibraryCache,
    TrackCacheEntry,
    TrackStructure,
    WaveformMetadata,
)


def track_entry(path="crate/song.wav", *, bpm=120.0, cues=None, overrides=None):
    duration = 120.0
    return TrackCacheEntry(
        relativePath=path,
        fileFingerprint="sha256-test",
        fileSizeBytes=12,
        fileModificationTime="2026-10-16T00:00:00Z",
        duration=duration,
        sampleRate=22050.0,
        channels=2,
        bitDepth=32,
        bpm=bpm,
        musicalKey="Unknown",
        confidence=0.8 if bpm else 0.0,
        waveformMetadata=WaveformMetadata(1, 1, [0.0], [0.0], [0.0], [0.0]),
        beatGrid=BeatGrid(0.0, 0.5 if bpm else 1.0, [0.0, 0.5] if bpm else []),
        structure=TrackStructure([], []),
        cueMarkers=cues or CueMarkers(0.0, 0.0, duration, duration),
        aiTrimBypass=False,
        manualOverrides=overrides or ManualOverrides(),
        analyzerVersion=analyze_library.ANALYZER_VERSION,
        analysisTimestamp="2026-10-16T00:00:00Z",
    )


class AnalyzeLibraryTests(unittest.TestCase):
    def test_unknown_tempo_uses_empty_grid_and_one_second_sentinel(self):
        grid = analyze_library.estimate_beat_grid(0, 0, [], 30)
        self.assertEqual(grid.firstBeatOffsetSeconds, 0)
        self.assertEqual(grid.beatIntervalSeconds, 1)
        self.assertEqual(grid.beatTimestamps, [])

    def test_beat_grid_discards_nonfinite_and_out_of_duration_values(self):
        grid = analyze_library.estimate_beat_grid(120, 0.8, [1, float("nan"), -1, 121, 0], 120)
        self.assertEqual(grid.beatTimestamps, [0.0, 1.0])
        self.assertEqual(grid.firstBeatOffsetSeconds, 0.0)
        self.assertEqual(grid.beatIntervalSeconds, 0.5)

    def test_dry_run_never_changes_library_or_existing_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "library"
            root.mkdir()
            audio = root / "crate" / "song.wav"
            audio.parent.mkdir()
            audio.write_bytes(b"test audio bytes")
            cache_path = Path(temp) / "cache.json"
            original_cache = PulseDeckLibraryCache(libraryRoot=str(root))
            original_cache.save_atomic(str(cache_path))
            cache_before = cache_path.read_bytes()
            audio_before = audio.read_bytes()
            args = analyze_library.build_parser().parse_args([
                "--library-root", str(root), "--cache", str(cache_path)
            ])

            with patch.object(analyze_library, "analyze_track", return_value=track_entry()):
                result = analyze_library.run(args, dependency_loader=lambda: (object(), object(), object()))

            self.assertEqual(result, 0)
            self.assertEqual(cache_path.read_bytes(), cache_before)
            self.assertEqual(audio.read_bytes(), audio_before)
            self.assertEqual(list(root.rglob("*")), [audio.parent, audio])

    def test_output_copy_round_trips_and_preserves_manual_values(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "library"
            root.mkdir()
            audio = root / "crate" / "song.wav"
            audio.parent.mkdir()
            audio.write_bytes(b"test audio bytes")
            cache_path = Path(temp) / "cache.json"
            output_path = Path(temp) / "verified" / "cache.json"
            manual = track_entry(
                cues=CueMarkers(1, 5, 90, 110),
                overrides=ManualOverrides(isManual=True, overriddenFields=["cueMarkers", "bpm"], author="DJ"),
            )
            cache = PulseDeckLibraryCache(libraryRoot=str(root), tracks={manual.relativePath: manual})
            cache.save_atomic(str(cache_path))
            cache_before = cache_path.read_bytes()
            audio_before = audio.read_bytes()
            args = analyze_library.build_parser().parse_args([
                "--library-root", str(root), "--cache", str(cache_path), "--output-cache", str(output_path)
            ])

            with patch.object(analyze_library, "analyze_track", return_value=track_entry(bpm=130)):
                result = analyze_library.run(args, dependency_loader=lambda: (object(), object(), object()))

            self.assertEqual(result, 0)
            self.assertEqual(cache_path.read_bytes(), cache_before)
            self.assertEqual(audio.read_bytes(), audio_before)
            verified = PulseDeckLibraryCache.load(str(output_path))
            saved = verified.tracks["crate/song.wav"]
            self.assertEqual(saved.bpm, 120)
            self.assertEqual(saved.cueMarkers, manual.cueMarkers)
            self.assertEqual(saved.manualOverrides, manual.manualOverrides)

    def test_missing_optional_dependencies_gives_install_command_without_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "library"
            root.mkdir()
            cache_path = Path(temp) / "cache.json"
            cache = PulseDeckLibraryCache(libraryRoot=str(root))
            cache.save_atomic(str(cache_path))
            original = cache_path.read_bytes()
            args = analyze_library.build_parser().parse_args([
                "--library-root", str(root), "--cache", str(cache_path)
            ])
            with patch("builtins.print") as output:
                result = analyze_library.run(
                    args,
                    dependency_loader=lambda: (_ for _ in ()).throw(analyze_library.DependencyError(
                        "Install with: python3 -m pip install -r requirements-analysis.txt"
                    )),
                )
            self.assertEqual(result, 2)
            self.assertIn("requirements-analysis.txt", output.call_args.args[0])
            self.assertEqual(cache_path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
