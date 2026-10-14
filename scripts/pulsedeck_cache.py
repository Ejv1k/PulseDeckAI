#!/usr/bin/env python3
"""
PulseDeck AI - Python Companion Cache Schema & Validator (Phase 0 / Phase 2)
Shared versioned cache schema interface for Swift and Python.

Ensures:
1. Ordered and bounded cue markers: 0.0 <= startTrim <= vocalEntry <= mixOut <= endTrim <= duration
2. Invalidation check against source file fingerprint & analyzer version
3. Preservation of manual overrides during re-analysis (manual provenance protection)
4. Atomic serialization via temporary file write and POSIX rename
"""

import os
import sys
import json
import tempfile
from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional, Any

SCHEMA_VERSION = "1.0.0"
CURRENT_ANALYZER_VERSION = "accelerate-dsp-v1.0"


@dataclass
class CueMarkers:
    startTrimCue: float
    vocalEntryCue: float
    mixOutCue: float
    endTrimCue: float

    def validate(self, duration: float) -> bool:
        """Enforce: 0.0 <= startTrimCue <= vocalEntryCue <= mixOutCue <= endTrimCue <= duration"""
        return (
            0.0 <= self.startTrimCue
            and self.startTrimCue <= self.vocalEntryCue
            and self.vocalEntryCue <= self.mixOutCue
            and self.mixOutCue <= self.endTrimCue
            and self.endTrimCue <= duration
        )


@dataclass
class ManualOverrides:
    isManual: bool = False
    overriddenFields: List[str] = field(default_factory=list)
    updatedAt: Optional[str] = None
    author: Optional[str] = None
    notes: Optional[str] = None


@dataclass
class WaveformMetadata:
    sampleCount: int
    downsampleFactor: int
    peakValues: List[float]
    lowBandPeaks: List[float]
    midBandPeaks: List[float]
    highBandPeaks: List[float]


@dataclass
class BeatGrid:
    firstBeatOffsetSeconds: float
    beatIntervalSeconds: float
    beatTimestamps: List[float]


@dataclass
class StructureSection:
    name: str
    startSeconds: float
    endSeconds: float
    energyLevel: float


@dataclass
class VocalSegment:
    startSeconds: float
    endSeconds: float
    confidence: float


@dataclass
class TrackStructure:
    sections: List[StructureSection]
    vocalSegments: List[VocalSegment]


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
        """
        if not self.manualOverrides.isManual:
            return new_analysis

        merged = new_analysis
        merged.manualOverrides = self.manualOverrides
        merged.aiTrimBypass = self.aiTrimBypass

        if "cueMarkers" in self.manualOverrides.overriddenFields:
            merged.cueMarkers = self.cueMarkers
        if "bpm" in self.manualOverrides.overriddenFields:
            merged.bpm = self.bpm
        if "musicalKey" in self.manualOverrides.overriddenFields:
            merged.musicalKey = self.musicalKey

        return merged


@dataclass
class PulseDeckLibraryCache:
    schemaVersion: str = SCHEMA_VERSION
    generatedAt: Optional[str] = None
    libraryRoot: str = "PulseDeck_Library"
    tracks: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def load(cls, file_path: str) -> "PulseDeckLibraryCache":
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return cls(
            schemaVersion=data.get("schemaVersion", SCHEMA_VERSION),
            generatedAt=data.get("generatedAt"),
            libraryRoot=data.get("libraryRoot", "PulseDeck_Library"),
            tracks=data.get("tracks", {}),
        )

    def save_atomic(self, file_path: str) -> None:
        """
        Serialize atomically: writes to temporary file in destination directory,
        flushes, and POSIX renames to target.
        """
        target_dir = os.path.dirname(os.path.abspath(file_path))
        os.makedirs(target_dir, exist_ok=True)
        temp_fd, temp_path = tempfile.mkstemp(dir=target_dir, prefix=".cache_tmp_")
        try:
            with open(temp_fd, "w", encoding="utf-8") as f:
                json.dump(asdict(self), f, indent=2)
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

    cache = PulseDeckLibraryCache.load(cache_path)
    print(f"Schema Version: {cache.schemaVersion}")
    print(f"Library Root: {cache.libraryRoot}")
    print(f"Track Count: {len(cache.tracks)}")
    return True


if __name__ == "__main__":
    default_cache = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "PulseDeck_Library",
        ".pulsedeck_ai_cache.json"
    )
    target = sys.argv[1] if len(sys.argv) > 1 else default_cache
    if validate_cache_file(target):
        print("PulseDeck Cache validation: SUCCESS")
        sys.exit(0)
    else:
        print("PulseDeck Cache validation: FAILED")
        sys.exit(1)
