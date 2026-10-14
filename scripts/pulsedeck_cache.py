#!/usr/bin/env python3
"""
PulseDeck AI - Python Companion Cache Schema & Validator (Phase 0 / Phase 2)
Shared versioned cache schema interface for Swift and Python.

Ensures:
1. Ordered and bounded cue markers: 0.0 <= startTrim <= vocalEntry <= mixOut <= endTrim <= duration
2. Invalidation check against source file fingerprint & analyzer version
3. Preservation of manual overrides during re-analysis with deep immutability
4. Safe clamping of preserved manual cues against shortened track durations
5. Strict schema validation (schemaVersion == "1.0.0", required fields, track cue ordering)
6. Atomic serialization via temporary file write, fsync, and POSIX rename
"""

import copy
import json
import math
import os
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional

SCHEMA_VERSION = "1.0.0"
CURRENT_ANALYZER_VERSION = "accelerate-dsp-v1.0"


@dataclass
class CueMarkers:
    startTrimCue: float
    vocalEntryCue: float
    mixOutCue: float
    endTrimCue: float

    def validate(self, duration: float) -> bool:
        """
        Enforce strict ordering and bounds:
        0.0 <= startTrimCue <= vocalEntryCue <= mixOutCue <= endTrimCue <= duration.
        Rejects non-finite values and negative durations.
        """
        if not (
            math.isfinite(self.startTrimCue)
            and math.isfinite(self.vocalEntryCue)
            and math.isfinite(self.mixOutCue)
            and math.isfinite(self.endTrimCue)
            and math.isfinite(duration)
        ):
            return False
        if duration < 0.0:
            return False
        return (
            0.0 <= self.startTrimCue
            and self.startTrimCue <= self.vocalEntryCue
            and self.vocalEntryCue <= self.mixOutCue
            and self.mixOutCue <= self.endTrimCue
            and self.endTrimCue <= duration
        )

    def clamped(self, duration: float) -> "CueMarkers":
        """
        Clamps and orders cues safely to fit within track duration without inversion.
        Rejects negative or non-finite durations meaningfully with ValueError.
        """
        if not math.isfinite(duration) or duration < 0.0:
            raise ValueError(f"Invalid duration for cue clamping: {duration}")

        for name, val in [
            ("startTrimCue", self.startTrimCue),
            ("vocalEntryCue", self.vocalEntryCue),
            ("mixOutCue", self.mixOutCue),
            ("endTrimCue", self.endTrimCue),
        ]:
            if not math.isfinite(val):
                raise ValueError(f"Invalid non-finite cue marker value for {name}: {val}")

        max_dur = float(duration)
        s = min(max(0.0, float(self.startTrimCue)), max_dur)
        v = min(max(s, float(self.vocalEntryCue)), max_dur)
        m = min(max(v, float(self.mixOutCue)), max_dur)
        e = min(max(m, float(self.endTrimCue)), max_dur)
        return CueMarkers(startTrimCue=s, vocalEntryCue=v, mixOutCue=m, endTrimCue=e)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "CueMarkers":
        required = ["startTrimCue", "vocalEntryCue", "mixOutCue", "endTrimCue"]
        for req in required:
            if req not in data:
                raise KeyError(f"CueMarkers missing required field: '{req}'")
            val = data[req]
            if not isinstance(val, (int, float)) or not math.isfinite(val):
                raise ValueError(f"CueMarkers field '{req}' must be a finite number, got {val}")
        return cls(
            startTrimCue=float(data["startTrimCue"]),
            vocalEntryCue=float(data["vocalEntryCue"]),
            mixOutCue=float(data["mixOutCue"]),
            endTrimCue=float(data["endTrimCue"]),
        )


@dataclass
class ManualOverrides:
    isManual: bool = False
    overriddenFields: List[str] = field(default_factory=list)
    updatedAt: Optional[str] = None
    author: Optional[str] = None
    notes: Optional[str] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ManualOverrides":
        if "isManual" not in data or not isinstance(data["isManual"], bool):
            raise ValueError("ManualOverrides requires boolean 'isManual'")
        if "overriddenFields" not in data or not isinstance(data["overriddenFields"], list):
            raise ValueError("ManualOverrides requires list 'overriddenFields'")
        return cls(
            isManual=data["isManual"],
            overriddenFields=[str(f) for f in data["overriddenFields"]],
            updatedAt=data.get("updatedAt"),
            author=data.get("author"),
            notes=data.get("notes"),
        )


@dataclass
class WaveformMetadata:
    sampleCount: int
    downsampleFactor: int
    peakValues: List[float]
    lowBandPeaks: List[float]
    midBandPeaks: List[float]
    highBandPeaks: List[float]

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "WaveformMetadata":
        required = [
            "sampleCount",
            "downsampleFactor",
            "peakValues",
            "lowBandPeaks",
            "midBandPeaks",
            "highBandPeaks",
        ]
        for r in required:
            if r not in data:
                raise KeyError(f"WaveformMetadata missing required field: '{r}'")
        return cls(
            sampleCount=int(data["sampleCount"]),
            downsampleFactor=int(data["downsampleFactor"]),
            peakValues=[float(x) for x in data["peakValues"]],
            lowBandPeaks=[float(x) for x in data["lowBandPeaks"]],
            midBandPeaks=[float(x) for x in data["midBandPeaks"]],
            highBandPeaks=[float(x) for x in data["highBandPeaks"]],
        )


@dataclass
class BeatGrid:
    firstBeatOffsetSeconds: float
    beatIntervalSeconds: float
    beatTimestamps: List[float]

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "BeatGrid":
        required = ["firstBeatOffsetSeconds", "beatIntervalSeconds", "beatTimestamps"]
        for r in required:
            if r not in data:
                raise KeyError(f"BeatGrid missing required field: '{r}'")
        return cls(
            firstBeatOffsetSeconds=float(data["firstBeatOffsetSeconds"]),
            beatIntervalSeconds=float(data["beatIntervalSeconds"]),
            beatTimestamps=[float(x) for x in data["beatTimestamps"]],
        )


@dataclass
class StructureSection:
    name: str
    startSeconds: float
    endSeconds: float
    energyLevel: float

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "StructureSection":
        required = ["name", "startSeconds", "endSeconds", "energyLevel"]
        for r in required:
            if r not in data:
                raise KeyError(f"StructureSection missing required field: '{r}'")
        return cls(
            name=str(data["name"]),
            startSeconds=float(data["startSeconds"]),
            endSeconds=float(data["endSeconds"]),
            energyLevel=float(data["energyLevel"]),
        )


@dataclass
class VocalSegment:
    startSeconds: float
    endSeconds: float
    confidence: float

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "VocalSegment":
        required = ["startSeconds", "endSeconds", "confidence"]
        for r in required:
            if r not in data:
                raise KeyError(f"VocalSegment missing required field: '{r}'")
        return cls(
            startSeconds=float(data["startSeconds"]),
            endSeconds=float(data["endSeconds"]),
            confidence=float(data["confidence"]),
        )


@dataclass
class TrackStructure:
    sections: List[StructureSection]
    vocalSegments: List[VocalSegment]

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "TrackStructure":
        if "sections" not in data or "vocalSegments" not in data:
            raise KeyError("TrackStructure requires 'sections' and 'vocalSegments'")
        return cls(
            sections=[StructureSection.from_dict(s) for s in data["sections"]],
            vocalSegments=[VocalSegment.from_dict(v) for v in data["vocalSegments"]],
        )


@dataclass
class TrackCacheEntry:
    relativePath: str
    fileFingerprint: str
    fileSizeBytes: int
    fileModificationTime: str
    duration: float
    sampleRate: float
    channels: int
    bitDepth: int
    bpm: float
    musicalKey: str
    confidence: float
    waveformMetadata: WaveformMetadata
    beatGrid: BeatGrid
    structure: TrackStructure
    cueMarkers: CueMarkers
    aiTrimBypass: bool
    manualOverrides: ManualOverrides
    analyzerVersion: str
    analysisTimestamp: str

    def is_valid_against(self, current_fingerprint: str, analyzer_version: str) -> bool:
        """Checks if cache entry is up to date with file content and DSP version."""
        return (
            self.fileFingerprint == current_fingerprint
            and self.analyzerVersion == analyzer_version
        )

    def merge_preserving_overrides(self, new_analysis: "TrackCacheEntry") -> "TrackCacheEntry":
        """
        Preserve manual edits when re-analyzing a track.
        Never allow automated analysis to clobber manual user edits.
        Guarantees complete immutability of both caller and argument objects via deepcopy.
        Clamps preserved cues to new track duration to ensure valid ordering and bounds:
        0.0 <= startTrimCue <= vocalEntryCue <= mixOutCue <= endTrimCue <= duration.
        """
        if not self.manualOverrides.isManual:
            return copy.deepcopy(new_analysis)

        merged = copy.deepcopy(new_analysis)
        merged.manualOverrides = copy.deepcopy(self.manualOverrides)
        merged.aiTrimBypass = self.aiTrimBypass

        if "cueMarkers" in self.manualOverrides.overriddenFields:
            # Clamp preserved cues to new track duration to guarantee valid bounds
            merged.cueMarkers = self.cueMarkers.clamped(merged.duration)
        if "bpm" in self.manualOverrides.overriddenFields:
            merged.bpm = self.bpm
        if "musicalKey" in self.manualOverrides.overriddenFields:
            merged.musicalKey = self.musicalKey

        # Final invariant verification: cues must be ordered and bounded
        if not merged.cueMarkers.validate(merged.duration):
            merged.cueMarkers = merged.cueMarkers.clamped(merged.duration)

        return merged

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "TrackCacheEntry":
        required_fields = [
            "relativePath",
            "fileFingerprint",
            "fileSizeBytes",
            "fileModificationTime",
            "duration",
            "sampleRate",
            "channels",
            "bitDepth",
            "bpm",
            "musicalKey",
            "confidence",
            "waveformMetadata",
            "beatGrid",
            "structure",
            "cueMarkers",
            "aiTrimBypass",
            "manualOverrides",
            "analyzerVersion",
            "analysisTimestamp",
        ]
        for f in required_fields:
            if f not in data:
                raise KeyError(f"TrackCacheEntry missing required field: '{f}'")

        duration = float(data["duration"])
        if not math.isfinite(duration) or duration < 0.0:
            raise ValueError(f"TrackCacheEntry duration must be non-negative and finite: {duration}")

        cues = CueMarkers.from_dict(data["cueMarkers"])
        if not cues.validate(duration):
            raise ValueError(
                f"CueMarkers violate ordering/bounds for duration {duration}: {cues}"
            )

        confidence = float(data["confidence"])
        if not (0.0 <= confidence <= 1.0):
            raise ValueError(f"Confidence score must be between 0.0 and 1.0, got: {confidence}")

        return cls(
            relativePath=str(data["relativePath"]),
            fileFingerprint=str(data["fileFingerprint"]),
            fileSizeBytes=int(data["fileSizeBytes"]),
            fileModificationTime=str(data["fileModificationTime"]),
            duration=duration,
            sampleRate=float(data["sampleRate"]),
            channels=int(data["channels"]),
            bitDepth=int(data["bitDepth"]),
            bpm=float(data["bpm"]),
            musicalKey=str(data["musicalKey"]),
            confidence=confidence,
            waveformMetadata=WaveformMetadata.from_dict(data["waveformMetadata"]),
            beatGrid=BeatGrid.from_dict(data["beatGrid"]),
            structure=TrackStructure.from_dict(data["structure"]),
            cueMarkers=cues,
            aiTrimBypass=bool(data["aiTrimBypass"]),
            manualOverrides=ManualOverrides.from_dict(data["manualOverrides"]),
            analyzerVersion=str(data["analyzerVersion"]),
            analysisTimestamp=str(data["analysisTimestamp"]),
        )


@dataclass
class PulseDeckLibraryCache:
    schemaVersion: str = SCHEMA_VERSION
    generatedAt: Optional[str] = None
    libraryRoot: str = "PulseDeck_Library"
    tracks: Dict[str, TrackCacheEntry] = field(default_factory=dict)
    schema: Optional[str] = "../docs/cache_schema_v1.json"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "PulseDeckLibraryCache":
        if not isinstance(data, dict):
            raise ValueError("Cache root must be a JSON object")

        # Required fields in root cache schema: schemaVersion, libraryRoot, tracks
        required = ["schemaVersion", "libraryRoot", "tracks"]
        for r in required:
            if r not in data:
                raise KeyError(f"Cache root missing required property: '{r}'")

        version = data["schemaVersion"]
        if version != SCHEMA_VERSION:
            raise ValueError(
                f"Unsupported schema version: '{version}' (expected '{SCHEMA_VERSION}')"
            )

        library_root = data["libraryRoot"]
        if not isinstance(library_root, str) or not library_root.strip():
            raise ValueError(f"Invalid libraryRoot: {library_root}")

        raw_tracks = data["tracks"]
        if not isinstance(raw_tracks, dict):
            raise ValueError("Property 'tracks' must be a dictionary")

        parsed_tracks: Dict[str, TrackCacheEntry] = {}
        for track_path, entry_dict in raw_tracks.items():
            if not isinstance(entry_dict, dict):
                raise ValueError(f"Track entry for '{track_path}' must be a dictionary")
            parsed_entry = TrackCacheEntry.from_dict(entry_dict)
            parsed_tracks[track_path] = parsed_entry

        return cls(
            schemaVersion=version,
            generatedAt=data.get("generatedAt"),
            libraryRoot=library_root,
            tracks=parsed_tracks,
            schema=data.get("$schema"),
        )

    @classmethod
    def load(cls, file_path: str) -> "PulseDeckLibraryCache":
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return cls.from_dict(data)

    def save_atomic(self, file_path: str) -> None:
        """
        Serialize atomically: writes to temporary file in destination directory,
        flushes, fsyncs, and POSIX renames to target.
        """
        target_dir = os.path.dirname(os.path.abspath(file_path))
        os.makedirs(target_dir, exist_ok=True)
        temp_fd, temp_path = tempfile.mkstemp(dir=target_dir, prefix=".cache_tmp_")
        try:
            with open(temp_fd, "w", encoding="utf-8") as f:
                json_dict = {
                    "$schema": self.schema,
                    "schemaVersion": self.schemaVersion,
                    "generatedAt": self.generatedAt,
                    "libraryRoot": self.libraryRoot,
                    "tracks": {
                        k: asdict(v) if hasattr(v, "__dataclass_fields__") else v
                        for k, v in self.tracks.items()
                    },
                }
                json.dump(json_dict, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_path, file_path)
        except Exception:
            if os.path.exists(temp_path):
                os.remove(temp_path)
            raise


def validate_cache_file(cache_path: str) -> bool:
    print(f"[PulseDeck Cache Validator] Loading: {cache_path}")
    if not os.path.exists(cache_path):
        print(f"Error: Cache file not found at {cache_path}", file=sys.stderr)
        return False

    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: Malformed JSON in {cache_path}: {e}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error reading {cache_path}: {e}", file=sys.stderr)
        return False

    try:
        cache = PulseDeckLibraryCache.from_dict(data)
    except (KeyError, ValueError, TypeError) as e:
        print(f"Error: Schema validation failed for {cache_path}: {e}", file=sys.stderr)
        return False

    print(f"Schema Version: {cache.schemaVersion}")
    print(f"Library Root: {cache.libraryRoot}")
    print(f"Track Count: {len(cache.tracks)}")

    for track_path, entry in cache.tracks.items():
        if not entry.cueMarkers.validate(entry.duration):
            print(
                f"Error: Track '{track_path}' has invalid cue markers for duration {entry.duration}: {entry.cueMarkers}",
                file=sys.stderr,
            )
            return False

    return True


if __name__ == "__main__":
    default_cache = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "PulseDeck_Library",
        ".pulsedeck_ai_cache.json",
    )
    target = sys.argv[1] if len(sys.argv) > 1 else default_cache
    if validate_cache_file(target):
        print("PulseDeck Cache validation: SUCCESS")
        sys.exit(0)
    else:
        print("PulseDeck Cache validation: FAILED")
        sys.exit(1)
