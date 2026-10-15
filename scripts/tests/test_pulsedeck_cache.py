#!/usr/bin/env python3
"""
Unit tests for PulseDeck AI Python Companion Cache Schema & Validator.
Covers Grok code review requirements:
1. Immutability of inputs during merge_preserving_overrides (deepcopy verification).
2. CueMarkers ordering, bounds, and safe clamping to shortened track durations.
3. Strict schema validation, malformed JSON handling, and prevention of false successes.
4. Atomic serialization and round-trip verification.
"""

import copy
import json
import math
import os
import sys
import tempfile
import unittest

# Ensure scripts directory is on sys.path
SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from pulsedeck_cache import (
    BeatGrid,
    CueMarkers,
    ManualOverrides,
    PulseDeckLibraryCache,
    SCHEMA_VERSION,
    StructureSection,
    TrackCacheEntry,
    TrackStructure,
    VocalSegment,
    WaveformMetadata,
    validate_cache_file,
)


def create_sample_entry(
    relative_path: str = "Test_Track.mp3",
    duration: float = 200.0,
    bpm: float = 124.0,
    musical_key: str = "8A",
    cue_markers: CueMarkers = None,
    manual_overrides: ManualOverrides = None,
    ai_trim_bypass: bool = False,
    fingerprint: str = "fp_abc123",
    analyzer_version: str = "accelerate-dsp-v1.0",
) -> TrackCacheEntry:
    """Helper factory for valid TrackCacheEntry instances."""
    if cue_markers is None:
        start_trim = min(5.0, duration * 0.05)
        vocal_entry = min(20.0, duration * 0.15)
        mix_out = max(vocal_entry, duration * 0.85)
        end_trim = max(mix_out, duration * 0.95)
        cue_markers = CueMarkers(
            startTrimCue=start_trim,
            vocalEntryCue=vocal_entry,
            mixOutCue=mix_out,
            endTrimCue=end_trim,
        )
    if manual_overrides is None:
        manual_overrides = ManualOverrides(
            isManual=False,
            overriddenFields=[],
            updatedAt=None,
            author=None,
            notes=None,
        )
    return TrackCacheEntry(
        relativePath=relative_path,
        fileFingerprint=fingerprint,
        fileSizeBytes=1048576,
        fileModificationTime="2026-10-14T12:00:00Z",
        duration=duration,
        sampleRate=44100.0,
        channels=2,
        bitDepth=16,
        bpm=bpm,
        musicalKey=musical_key,
        confidence=0.95,
        waveformMetadata=WaveformMetadata(
            sampleCount=100,
            downsampleFactor=256,
            peakValues=[0.1, 0.5, 0.8],
            lowBandPeaks=[0.05, 0.3, 0.6],
            midBandPeaks=[0.08, 0.4, 0.7],
            highBandPeaks=[0.02, 0.2, 0.4],
        ),
        beatGrid=BeatGrid(
            firstBeatOffsetSeconds=0.25,
            beatIntervalSeconds=0.4838,
            beatTimestamps=[0.25, 0.7338, 1.2176],
        ),
        structure=TrackStructure(
            sections=[
                StructureSection(
                    name="Intro",
                    startSeconds=0.0,
                    endSeconds=30.0,
                    energyLevel=0.4,
                ),
                StructureSection(
                    name="Main",
                    startSeconds=30.0,
                    endSeconds=180.0,
                    energyLevel=0.85,
                ),
                StructureSection(
                    name="Outro",
                    startSeconds=180.0,
                    endSeconds=200.0,
                    energyLevel=0.3,
                ),
            ],
            vocalSegments=[
                VocalSegment(
                    startSeconds=20.0,
                    endSeconds=160.0,
                    confidence=0.9,
                )
            ],
        ),
        cueMarkers=cue_markers,
        aiTrimBypass=ai_trim_bypass,
        manualOverrides=manual_overrides,
        analyzerVersion=analyzer_version,
        analysisTimestamp="2026-10-14T12:00:00Z",
    )


class TestCueMarkers(unittest.TestCase):
    """Tests for CueMarkers validation and duration clamping."""

    def test_valid_cue_markers(self):
        cues = CueMarkers(startTrimCue=0.0, vocalEntryCue=15.0, mixOutCue=120.0, endTrimCue=150.0)
        self.assertTrue(cues.validate(150.0))
        self.assertTrue(cues.validate(200.0))

    def test_cue_markers_boundary_conditions(self):
        # All cues at 0.0 with 0.0 duration
        zero_cues = CueMarkers(0.0, 0.0, 0.0, 0.0)
        self.assertTrue(zero_cues.validate(0.0))

        # Start trim at duration
        max_cues = CueMarkers(100.0, 100.0, 100.0, 100.0)
        self.assertTrue(max_cues.validate(100.0))

    def test_invalid_cue_ordering(self):
        # startTrim > vocalEntry
        c1 = CueMarkers(startTrimCue=20.0, vocalEntryCue=10.0, mixOutCue=50.0, endTrimCue=60.0)
        self.assertFalse(c1.validate(100.0))

        # vocalEntry > mixOut
        c2 = CueMarkers(startTrimCue=10.0, vocalEntryCue=70.0, mixOutCue=50.0, endTrimCue=80.0)
        self.assertFalse(c2.validate(100.0))

        # mixOut > endTrim
        c3 = CueMarkers(startTrimCue=10.0, vocalEntryCue=20.0, mixOutCue=90.0, endTrimCue=80.0)
        self.assertFalse(c3.validate(100.0))

    def test_invalid_cue_bounds(self):
        # Negative startTrimCue
        c1 = CueMarkers(startTrimCue=-1.0, vocalEntryCue=10.0, mixOutCue=50.0, endTrimCue=60.0)
        self.assertFalse(c1.validate(100.0))

        # endTrimCue exceeds duration
        c2 = CueMarkers(startTrimCue=0.0, vocalEntryCue=10.0, mixOutCue=50.0, endTrimCue=105.0)
        self.assertFalse(c2.validate(100.0))

        # Negative track duration
        c3 = CueMarkers(0.0, 0.0, 0.0, 0.0)
        self.assertFalse(c3.validate(-1.0))

    def test_non_finite_cues(self):
        nan_cue = CueMarkers(float("nan"), 10.0, 50.0, 60.0)
        self.assertFalse(nan_cue.validate(100.0))

        inf_cue = CueMarkers(0.0, 10.0, float("inf"), 60.0)
        self.assertFalse(inf_cue.validate(100.0))

        valid_cue = CueMarkers(0.0, 10.0, 50.0, 60.0)
        self.assertFalse(valid_cue.validate(float("nan")))
        self.assertFalse(valid_cue.validate(float("inf")))

    def test_clamped_shortened_duration(self):
        # Original cues configured for duration 240.0
        cues = CueMarkers(startTrimCue=10.0, vocalEntryCue=30.0, mixOutCue=200.0, endTrimCue=220.0)
        # Clamped to shortened track duration 150.0
        clamped = cues.clamped(150.0)
        self.assertEqual(clamped.startTrimCue, 10.0)
        self.assertEqual(clamped.vocalEntryCue, 30.0)
        self.assertEqual(clamped.mixOutCue, 150.0)
        self.assertEqual(clamped.endTrimCue, 150.0)
        self.assertTrue(clamped.validate(150.0))

    def test_clamped_severely_shortened_duration(self):
        # Duration shorter than startTrim
        cues = CueMarkers(startTrimCue=50.0, vocalEntryCue=80.0, mixOutCue=120.0, endTrimCue=180.0)
        clamped = cues.clamped(30.0)
        self.assertEqual(clamped.startTrimCue, 30.0)
        self.assertEqual(clamped.vocalEntryCue, 30.0)
        self.assertEqual(clamped.mixOutCue, 30.0)
        self.assertEqual(clamped.endTrimCue, 30.0)
        self.assertTrue(clamped.validate(30.0))

    def test_clamped_with_negative_cues(self):
        # Negative cue values get clamped up to 0.0
        cues = CueMarkers(startTrimCue=-10.0, vocalEntryCue=-5.0, mixOutCue=50.0, endTrimCue=80.0)
        clamped = cues.clamped(100.0)
        self.assertEqual(clamped.startTrimCue, 0.0)
        self.assertEqual(clamped.vocalEntryCue, 0.0)
        self.assertEqual(clamped.mixOutCue, 50.0)
        self.assertEqual(clamped.endTrimCue, 80.0)
        self.assertTrue(clamped.validate(100.0))

    def test_clamped_rejects_invalid_durations(self):
        cues = CueMarkers(0.0, 10.0, 50.0, 60.0)
        with self.assertRaises(ValueError):
            cues.clamped(-10.0)
        with self.assertRaises(ValueError):
            cues.clamped(float("nan"))
        with self.assertRaises(ValueError):
            cues.clamped(float("inf"))

    def test_clamped_rejects_non_finite_cues(self):
        cues = CueMarkers(float("nan"), 10.0, 50.0, 60.0)
        with self.assertRaises(ValueError):
            cues.clamped(100.0)


class TestMergePreservingOverrides(unittest.TestCase):
    """Tests verifying complete immutability and override preservation."""

    def test_immutability_of_both_inputs(self):
        original_cues = CueMarkers(10.0, 20.0, 180.0, 190.0)
        original_overrides = ManualOverrides(
            isManual=True,
            overriddenFields=["cueMarkers", "bpm", "musicalKey"],
            author="DJ Tester",
            notes="Custom mix points",
        )
        existing_entry = create_sample_entry(
            duration=200.0,
            bpm=128.0,
            musical_key="11B",
            cue_markers=original_cues,
            manual_overrides=original_overrides,
            ai_trim_bypass=True,
        )

        new_cues = CueMarkers(2.0, 15.0, 170.0, 185.0)
        new_analysis = create_sample_entry(
            duration=200.0,
            bpm=126.0,
            musical_key="8A",
            cue_markers=new_cues,
            manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
            ai_trim_bypass=False,
        )

        # Deep copies for baseline mutation comparison
        existing_snapshot = copy.deepcopy(existing_entry)
        new_analysis_snapshot = copy.deepcopy(new_analysis)

        merged = existing_entry.merge_preserving_overrides(new_analysis)

        # Verify neither existing_entry nor new_analysis was mutated
        self.assertEqual(existing_entry, existing_snapshot)
        self.assertEqual(new_analysis, new_analysis_snapshot)

        # Verify independence: mutating merged does not affect inputs
        merged.bpm = 999.0
        merged.cueMarkers.startTrimCue = 99.0
        merged.manualOverrides.author = "Modified Author"
        self.assertEqual(existing_entry.bpm, 128.0)
        self.assertEqual(existing_entry.cueMarkers.startTrimCue, 10.0)
        self.assertEqual(existing_entry.manualOverrides.author, "DJ Tester")
        self.assertEqual(new_analysis.bpm, 126.0)

    def test_overrides_applied_correctly(self):
        existing_entry = create_sample_entry(
            bpm=130.0,
            musical_key="4A",
            cue_markers=CueMarkers(12.0, 24.0, 160.0, 175.0),
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["bpm", "musicalKey", "cueMarkers"],
            ),
            ai_trim_bypass=True,
        )
        new_analysis = create_sample_entry(
            bpm=125.0,
            musical_key="9B",
            cue_markers=CueMarkers(5.0, 15.0, 180.0, 195.0),
            manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
            ai_trim_bypass=False,
        )

        merged = existing_entry.merge_preserving_overrides(new_analysis)
        self.assertTrue(merged.manualOverrides.isManual)
        self.assertEqual(merged.bpm, 130.0)
        self.assertEqual(merged.musicalKey, "4A")
        self.assertEqual(merged.cueMarkers.startTrimCue, 12.0)
        self.assertTrue(merged.aiTrimBypass)

    def test_non_manual_returns_independent_copy_of_new_analysis(self):
        non_manual_existing = create_sample_entry(
            manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
            bpm=120.0,
        )
        new_analysis = create_sample_entry(
            manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
            bpm=128.0,
        )
        merged = non_manual_existing.merge_preserving_overrides(new_analysis)

        self.assertEqual(merged.bpm, 128.0)
        # Verify independence
        merged.bpm = 140.0
        self.assertEqual(new_analysis.bpm, 128.0)

    def test_cue_clamping_on_shortened_reanalysis(self):
        # Existing track has manual cues set for a 220s file
        manual_cues = CueMarkers(10.0, 30.0, 190.0, 210.0)
        existing_entry = create_sample_entry(
            duration=220.0,
            cue_markers=manual_cues,
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["cueMarkers"],
            ),
        )

        # File was re-edited / replaced with a 150s version
        new_analysis = create_sample_entry(
            duration=150.0,
            cue_markers=CueMarkers(2.0, 10.0, 130.0, 145.0),
            manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
        )

        merged = existing_entry.merge_preserving_overrides(new_analysis)
        self.assertEqual(merged.duration, 150.0)
        self.assertTrue(merged.cueMarkers.validate(150.0))
        self.assertEqual(merged.cueMarkers.startTrimCue, 10.0)
        self.assertEqual(merged.cueMarkers.vocalEntryCue, 30.0)
        self.assertEqual(merged.cueMarkers.mixOutCue, 150.0)
        self.assertEqual(merged.cueMarkers.endTrimCue, 150.0)

    def test_invalid_new_duration_nan_inf_negative_preserves_existing_entry(self):
        manual_cues = CueMarkers(10.0, 20.0, 150.0, 175.0)
        existing_entry = create_sample_entry(
            duration=180.0,
            fingerprint="fp_v1",
            analyzer_version="dsp-v1",
            cue_markers=manual_cues,
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["cueMarkers"],
            ),
        )

        for invalid_duration in [float("nan"), -30.0, float("inf"), float("-inf")]:
            new_analysis = create_sample_entry(
                duration=invalid_duration,
                fingerprint="fp_new",
                analyzer_version="dsp-v2",
                manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
            )
            existing_snap = copy.deepcopy(existing_entry)
            merged = existing_entry.merge_preserving_overrides(new_analysis)

            self.assertEqual(existing_entry, existing_snap, "Input existing entry must not be mutated")
            self.assertEqual(merged.duration, 180.0, "Must preserve original duration on invalid new duration")
            self.assertEqual(merged.fileFingerprint, "fp_v1", "Must preserve original fingerprint")
            self.assertEqual(merged.analyzerVersion, "dsp-v1", "Must preserve original analyzerVersion")
            self.assertEqual(merged.cueMarkers.startTrimCue, 10.0)
            self.assertEqual(merged.cueMarkers.endTrimCue, 175.0)

    def test_nan_or_non_finite_manual_cue_preserves_existing_entry(self):
        # Existing track has a manual NaN vocalEntryCue
        manual_cues_nan = CueMarkers(10.0, float("nan"), 150.0, 175.0)
        existing_entry = create_sample_entry(
            duration=180.0,
            fingerprint="fp_orig",
            analyzer_version="dsp-v1",
            cue_markers=manual_cues_nan,
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["cueMarkers"],
            ),
        )
        new_analysis = create_sample_entry(
            duration=200.0,
            fingerprint="fp_new",
            analyzer_version="dsp-v2",
            manual_overrides=ManualOverrides(isManual=False, overriddenFields=[]),
        )

        existing_snap = copy.deepcopy(existing_entry)
        merged = existing_entry.merge_preserving_overrides(new_analysis)

        # Must not raise from clamped, must return deepcopy(self)
        self.assertEqual(existing_entry.duration, existing_snap.duration)
        self.assertTrue(math.isnan(merged.cueMarkers.vocalEntryCue))
        self.assertEqual(merged.cueMarkers.startTrimCue, 10.0)
        self.assertEqual(merged.cueMarkers.mixOutCue, 150.0)
        self.assertEqual(merged.cueMarkers.endTrimCue, 175.0)
        self.assertEqual(merged.duration, 180.0)
        self.assertEqual(merged.fileFingerprint, "fp_orig")
        self.assertEqual(merged.analyzerVersion, "dsp-v1")

        # Also test infinite manual cue
        existing_inf = create_sample_entry(
            duration=180.0,
            fingerprint="fp_inf_cue",
            analyzer_version="dsp-v1",
            cue_markers=CueMarkers(10.0, 20.0, float("inf"), 175.0),
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["cueMarkers"],
            ),
        )
        merged_inf = existing_inf.merge_preserving_overrides(new_analysis)
        self.assertTrue(math.isinf(merged_inf.cueMarkers.mixOutCue))
        self.assertEqual(merged_inf.fileFingerprint, "fp_inf_cue")
        self.assertEqual(merged_inf.duration, 180.0)



    def test_partial_overrides(self):
        # Only BPM overridden, cues should come from new_analysis
        existing_entry = create_sample_entry(
            bpm=135.0,
            musical_key="1A",
            cue_markers=CueMarkers(10.0, 20.0, 150.0, 160.0),
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["bpm"],
            ),
        )
        new_cues = CueMarkers(4.0, 12.0, 175.0, 190.0)
        new_analysis = create_sample_entry(
            bpm=122.0,
            musical_key="6B",
            cue_markers=new_cues,
        )

        merged = existing_entry.merge_preserving_overrides(new_analysis)
        self.assertEqual(merged.bpm, 135.0)  # preserved
        self.assertEqual(merged.musicalKey, "6B")  # from new analysis
        self.assertEqual(merged.cueMarkers, new_cues)  # from new analysis


class TestSchemaValidation(unittest.TestCase):
    """Tests for strict schema validation, malformed JSON, and false success prevention."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_temp_file(self, content: str) -> str:
        path = os.path.join(self.temp_dir.name, "cache_test.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return path

    def test_validate_default_empty_cache(self):
        cache_data = {
            "$schema": "../docs/cache_schema_v1.json",
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": "2026-10-14T20:00:00Z",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertTrue(validate_cache_file(path))

    def test_validate_cache_with_valid_track(self):
        track = create_sample_entry()
        cache = PulseDeckLibraryCache(
            schemaVersion=SCHEMA_VERSION,
            libraryRoot="PulseDeck_Library",
            tracks={"00_Test_Tracks_Dev/Test_Track.mp3": track},
        )
        path = os.path.join(self.temp_dir.name, "valid_cache.json")
        cache.save_atomic(path)
        self.assertTrue(validate_cache_file(path))

    def test_malformed_json_returns_false(self):
        path = self._write_temp_file("{\"schemaVersion\": \"1.0.0\", broken_json: [}")
        self.assertFalse(validate_cache_file(path))

    def test_nonexistent_file_returns_false(self):
        path = os.path.join(self.temp_dir.name, "does_not_exist.json")
        self.assertFalse(validate_cache_file(path))

    def test_unsupported_schema_version_returns_false(self):
        cache_data = {
            "schemaVersion": "2.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_missing_required_root_field_returns_false(self):
        # Missing libraryRoot
        cache_data = {
            "schemaVersion": "1.0.0",
            "tracks": {},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_missing_track_required_field_returns_false(self):
        track_dict = json.loads(json.dumps(create_sample_entry(), default=lambda o: o.__dict__))
        # Remove required duration field
        del track_dict["duration"]
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": track_dict},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_track_cue_markers_exceeding_duration_returns_false(self):
        track_dict = json.loads(json.dumps(create_sample_entry(duration=100.0), default=lambda o: o.__dict__))
        # endTrimCue is 195.0, duration is 100.0 -> violates bounds
        track_dict["cueMarkers"]["endTrimCue"] = 105.0
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": track_dict},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_track_cue_markers_inverted_ordering_returns_false(self):
        track_dict = json.loads(json.dumps(create_sample_entry(duration=200.0), default=lambda o: o.__dict__))
        # Invert vocalEntry and startTrim
        track_dict["cueMarkers"]["startTrimCue"] = 50.0
        track_dict["cueMarkers"]["vocalEntryCue"] = 20.0
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": track_dict},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_missing_subobject_field_returns_false(self):
        # Missing peakValues in waveformMetadata
        track_dict = json.loads(json.dumps(create_sample_entry(), default=lambda o: o.__dict__))
        del track_dict["waveformMetadata"]["peakValues"]
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": track_dict},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_negative_track_duration_returns_false(self):
        track_dict = json.loads(json.dumps(create_sample_entry(), default=lambda o: o.__dict__))
        track_dict["duration"] = -10.0
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": track_dict},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_non_dict_root_returns_false(self):
        path = self._write_temp_file("[\"not\", \"a\", \"dict\"]")
        self.assertFalse(validate_cache_file(path))

    def test_non_dict_track_entry_returns_false(self):
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": "invalid_string_entry"},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))

    def test_invalid_confidence_range_returns_false(self):
        track_dict = json.loads(json.dumps(create_sample_entry(), default=lambda o: o.__dict__))
        track_dict["confidence"] = 1.5  # Must be 0.0 .. 1.0
        cache_data = {
            "schemaVersion": "1.0.0",
            "libraryRoot": "PulseDeck_Library",
            "tracks": {"Test_Track.mp3": track_dict},
        }
        path = self._write_temp_file(json.dumps(cache_data))
        self.assertFalse(validate_cache_file(path))


class TestAtomicSaveAndRoundTrip(unittest.TestCase):
    """Tests for atomic file writes and round-trip fidelity."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_atomic_save_round_trip(self):
        track1 = create_sample_entry(relative_path="Track1.mp3", duration=180.0, bpm=125.0)
        track2 = create_sample_entry(
            relative_path="Track2.mp3",
            duration=210.0,
            bpm=130.0,
            manual_overrides=ManualOverrides(
                isManual=True,
                overriddenFields=["bpm"],
                author="DJ Test",
            ),
        )

        original_cache = PulseDeckLibraryCache(
            schemaVersion=SCHEMA_VERSION,
            generatedAt="2026-10-14T20:30:00Z",
            libraryRoot="PulseDeck_Library",
            tracks={"Track1.mp3": track1, "Track2.mp3": track2},
        )

        save_path = os.path.join(self.temp_dir.name, "sub_dir", ".pulsedeck_ai_cache.json")
        original_cache.save_atomic(save_path)

        self.assertTrue(os.path.exists(save_path))
        loaded_cache = PulseDeckLibraryCache.load(save_path)

        self.assertEqual(loaded_cache.schemaVersion, original_cache.schemaVersion)
        self.assertEqual(loaded_cache.libraryRoot, original_cache.libraryRoot)
        self.assertEqual(len(loaded_cache.tracks), 2)
        self.assertEqual(loaded_cache.tracks["Track1.mp3"].bpm, 125.0)
        self.assertEqual(loaded_cache.tracks["Track2.mp3"].bpm, 130.0)
        self.assertTrue(loaded_cache.tracks["Track2.mp3"].manualOverrides.isManual)
        self.assertEqual(loaded_cache.tracks["Track2.mp3"].manualOverrides.author, "DJ Test")

    def test_rejected_save_preserves_existing_file_and_leaves_no_temp_file(self):
        # 1. Write an initial valid cache
        track1 = create_sample_entry(relative_path="Track1.mp3", duration=180.0, bpm=125.0)
        valid_cache = PulseDeckLibraryCache(
            schemaVersion=SCHEMA_VERSION,
            generatedAt="2026-10-14T20:30:00Z",
            libraryRoot="PulseDeck_Library",
            tracks={"Track1.mp3": track1},
        )
        save_path = os.path.join(self.temp_dir.name, ".pulsedeck_ai_cache.json")
        valid_cache.save_atomic(save_path)
        self.assertTrue(os.path.exists(save_path))

        with open(save_path, "r", encoding="utf-8") as f:
            initial_content = f.read()

        # 2. Build an invalid cache with cues violating ordering (startTrimCue > vocalEntryCue)
        bad_track = create_sample_entry(relative_path="TrackBad.mp3", duration=100.0)
        bad_track.cueMarkers = CueMarkers(startTrimCue=50.0, vocalEntryCue=20.0, mixOutCue=80.0, endTrimCue=100.0)
        invalid_cache = PulseDeckLibraryCache(
            schemaVersion=SCHEMA_VERSION,
            generatedAt="2026-10-14T20:35:00Z",
            libraryRoot="PulseDeck_Library",
            tracks={"Track1.mp3": track1, "TrackBad.mp3": bad_track},
        )

        # 3. Attempt save_atomic — must raise ValueError from validate()
        with self.assertRaises(ValueError):
            invalid_cache.save_atomic(save_path)

        # 4. Verify previous file content remains completely unchanged
        with open(save_path, "r", encoding="utf-8") as f:
            current_content = f.read()
        self.assertEqual(current_content, initial_content, "Previous file content must be unchanged on rejected save")

        # 5. Verify no .cache_tmp files exist in the directory
        files = os.listdir(self.temp_dir.name)
        temp_files = [f for f in files if f.startswith(".cache_tmp_")]
        self.assertEqual(len(temp_files), 0, "No temporary files should be left behind on rejected save")



if __name__ == "__main__":
    unittest.main()
