#!/usr/bin/env python3
"""Offline batch estimates for PulseDeck audio libraries; never changes audio files."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from pulsedeck_cache import (
    BeatGrid,
    CueMarkers,
    ManualOverrides,
    PulseDeckLibraryCache,
    TrackCacheEntry,
    TrackStructure,
    WaveformMetadata,
)

ANALYZER_VERSION = "librosa-offline-v1.0"
AUDIO_EXTENSIONS = {".aif", ".aiff", ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav"}
WAVEFORM_BUCKETS = 128


class DependencyError(RuntimeError):
    pass


def _load_dependencies() -> tuple[Any, Any, Any]:
    try:
        librosa = importlib.import_module("librosa")
        numpy = importlib.import_module("numpy")
        soundfile = importlib.import_module("soundfile")
    except ImportError as error:
        raise DependencyError(
            "Offline analysis needs optional packages. Install with: "
            "python3 -m pip install -r requirements-analysis.txt"
        ) from error
    return librosa, numpy, soundfile


def _iso_utc(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _fingerprint(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as audio_file:
        for block in iter(lambda: audio_file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _finite_float(value: Any, *, fallback: float = 0.0) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return fallback
    return number if math.isfinite(number) else fallback


def estimate_beat_grid(
    bpm: Any,
    confidence: Any,
    timestamps: Iterable[Any],
    duration: float,
) -> BeatGrid:
    """Discard uncertain/out-of-bounds beats; unknown tempo uses schema's 1s sentinel."""
    tempo = _finite_float(bpm)
    certainty = min(1.0, max(0.0, _finite_float(confidence)))
    valid_times = [
        time for raw in timestamps
        if (time := _finite_float(raw, fallback=float("nan"))) >= 0
        and time <= duration
    ]
    known = 30.0 <= tempo <= 300.0 and certainty >= 0.15 and bool(valid_times)
    if not known:
        return BeatGrid(firstBeatOffsetSeconds=0.0, beatIntervalSeconds=1.0, beatTimestamps=[])
    ordered = sorted(set(valid_times))
    return BeatGrid(
        firstBeatOffsetSeconds=ordered[0],
        beatIntervalSeconds=60.0 / tempo,
        beatTimestamps=ordered,
    )


def _waveform(samples: Any, sample_rate: int, librosa: Any, numpy: Any) -> WaveformMetadata:
    channels = samples if getattr(samples, "ndim", 0) == 2 else numpy.expand_dims(samples, axis=0)
    mono = numpy.mean(channels, axis=0)
    stft = numpy.abs(librosa.stft(mono, n_fft=2048, hop_length=512))
    if stft.ndim != 2 or stft.shape[1] == 0:
        raise ValueError("Decoded audio has no analyzable samples")

    frequencies = librosa.fft_frequencies(sr=sample_rate, n_fft=2048)
    band_masks = (frequencies < 250, (frequencies >= 250) & (frequencies < 3_500), frequencies >= 3_500)
    overall = numpy.max(stft, axis=0)
    bands = [numpy.max(stft[mask], axis=0) if numpy.any(mask) else numpy.zeros_like(overall) for mask in band_masks]
    peak = float(numpy.max(overall))
    scale = peak if math.isfinite(peak) and peak > 0 else 1.0
    indices = numpy.linspace(0, max(0, stft.shape[1] - 1), WAVEFORM_BUCKETS + 1, dtype=int)

    def reduce_buckets(values: Any) -> list[float]:
        result = []
        for index in range(WAVEFORM_BUCKETS):
            start, end = int(indices[index]), int(indices[index + 1])
            bucket = values[start:max(start + 1, end + 1)]
            value = _finite_float(numpy.max(bucket)) / scale
            result.append(min(1.0, max(0.0, value)))
        return result

    peaks = reduce_buckets(overall)
    return WaveformMetadata(
        sampleCount=int(samples.shape[-1]),
        downsampleFactor=max(1, math.ceil(int(samples.shape[-1]) / WAVEFORM_BUCKETS)),
        peakValues=peaks,
        lowBandPeaks=reduce_buckets(bands[0]),
        midBandPeaks=reduce_buckets(bands[1]),
        highBandPeaks=reduce_buckets(bands[2]),
    )


def _tempo(samples: Any, sample_rate: int, duration: float, librosa: Any, numpy: Any) -> tuple[float, float, list[float]]:
    mono = numpy.mean(samples, axis=0) if getattr(samples, "ndim", 0) == 2 else samples
    raw_tempo, beat_times = librosa.beat.beat_track(y=mono, sr=sample_rate, units="time", trim=True)
    tempo = _finite_float(numpy.asarray(raw_tempo).reshape(-1)[0] if numpy.asarray(raw_tempo).size else 0)
    times = [_finite_float(value, fallback=float("nan")) for value in numpy.asarray(beat_times).reshape(-1)]
    times = [value for value in times if math.isfinite(value) and 0 <= value <= duration]
    confidence = 0.0
    if 30 <= tempo <= 300 and times:
        onset = librosa.onset.onset_strength(y=mono, sr=sample_rate)
        lag = round(sample_rate * 60 / tempo / 512)
        autocorrelation = librosa.autocorrelate(onset, max_size=lag + 1)
        if 0 < lag < autocorrelation.size and autocorrelation[0] > 0:
            confidence = min(1.0, max(0.0, _finite_float(autocorrelation[lag] / autocorrelation[0])))
    return tempo, confidence, times


def analyze_track(path: Path, library_root: Path, librosa: Any, numpy: Any, soundfile: Any) -> TrackCacheEntry:
    info = soundfile.info(str(path))
    if not math.isfinite(float(info.samplerate)) or info.samplerate <= 0 or info.channels <= 0 or info.frames <= 0:
        raise ValueError("Audio metadata has invalid sample rate, channel count, or frame count")
    original_rate = int(info.samplerate)
    duration = float(info.frames) / original_rate
    samples, decoded_rate = librosa.load(str(path), sr=None, mono=False, dtype=numpy.float32)
    samples = numpy.asarray(samples)
    if samples.ndim == 1:
        decoded_channels = 1
    elif samples.ndim == 2:
        decoded_channels = int(samples.shape[0])
    else:
        raise ValueError("Decoder returned unsupported channel layout")
    if decoded_channels != int(info.channels) or int(decoded_rate) != original_rate:
        raise ValueError("Decoded audio format does not match source channel metadata")
    if samples.shape[-1] < 1 or not bool(numpy.all(numpy.isfinite(samples))):
        raise ValueError("Decoded audio contains no samples or non-finite PCM")

    bpm, confidence, timestamps = _tempo(samples, int(decoded_rate), duration, librosa, numpy)
    beat_grid = estimate_beat_grid(bpm, confidence, timestamps, duration)
    if not beat_grid.beatTimestamps:
        bpm = 0.0
        confidence = 0.0
    stat = path.stat()
    relative_path = path.relative_to(library_root).as_posix()
    return TrackCacheEntry(
        relativePath=relative_path,
        fileFingerprint=_fingerprint(path),
        fileSizeBytes=stat.st_size,
        fileModificationTime=_iso_utc(stat.st_mtime),
        duration=duration,
        sampleRate=float(original_rate),
        channels=decoded_channels,
        bitDepth=int(samples.dtype.itemsize * 8),
        bpm=bpm,
        musicalKey="Unknown",
        confidence=confidence,
        waveformMetadata=_waveform(samples, int(decoded_rate), librosa, numpy),
        beatGrid=beat_grid,
        structure=TrackStructure(sections=[], vocalSegments=[]),
        cueMarkers=CueMarkers(startTrimCue=0.0, vocalEntryCue=0.0, mixOutCue=duration, endTrimCue=duration),
        aiTrimBypass=False,
        manualOverrides=ManualOverrides(),
        analyzerVersion=ANALYZER_VERSION,
        analysisTimestamp=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    )


def audio_paths(library_root: Path) -> Iterable[Path]:
    for path in sorted(library_root.rglob("*")):
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS:
            yield path


def run(args: argparse.Namespace, *, dependency_loader=_load_dependencies) -> int:
    library_root = args.library_root.expanduser().resolve()
    cache_path = args.cache.expanduser().resolve()
    if args.dry_run and args.output_cache is not None:
        print("Choose --dry-run or --output-cache, not both", file=sys.stderr)
        return 2
    if not library_root.is_dir():
        print(f"Library directory not found: {library_root}", file=sys.stderr)
        return 2
    if args.output_cache is not None:
        output_path = args.output_cache.expanduser().resolve()
        if output_path == cache_path or output_path.suffix.lower() != ".json":
            print("Output cache must be a separate .json file", file=sys.stderr)
            return 2
        if output_path == library_root or library_root in output_path.parents:
            print("Output cache must stay outside the audio library", file=sys.stderr)
            return 2
    else:
        output_path = None

    try:
        librosa, numpy, soundfile = dependency_loader()
        cache = PulseDeckLibraryCache.load(str(cache_path)) if cache_path.exists() else PulseDeckLibraryCache(libraryRoot=library_root.name)
        failures = 0
        analyzed = 0
        for path in audio_paths(library_root):
            try:
                entry = analyze_track(path, library_root, librosa, numpy, soundfile)
                previous = cache.tracks.get(entry.relativePath)
                cache.tracks[entry.relativePath] = previous.merge_preserving_overrides(entry) if previous else entry
                analyzed += 1
            except (OSError, ValueError, RuntimeError) as error:
                failures += 1
                print(f"Skipped {path.relative_to(library_root).as_posix()}: {error}", file=sys.stderr)
        cache.generatedAt = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        cache.validate()
        if output_path is None:
            print(f"Dry run: analyzed {analyzed}, skipped {failures}, cache tracks {len(cache.tracks)}; no files written")
        else:
            cache.save_atomic(str(output_path))
            verified = PulseDeckLibraryCache.load(str(output_path))
            verified.validate()
            print(f"Wrote and verified {output_path}: analyzed {analyzed}, skipped {failures}, cache tracks {len(verified.tracks)}")
        return 1 if failures else 0
    except DependencyError as error:
        print(str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError) as error:
        print(f"Analysis failed: {error}", file=sys.stderr)
        return 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library-root", type=Path, required=True, help="Audio library directory; scanned read-only")
    parser.add_argument("--cache", type=Path, required=True, help="Existing cache input, read-only")
    parser.add_argument("--dry-run", action="store_true", help="Analyze and validate in memory; never write a cache")
    parser.add_argument("--output-cache", type=Path, help="Write verified schema 1 cache copy here; must differ from --cache")
    return parser


def main() -> int:
    return run(build_parser().parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
