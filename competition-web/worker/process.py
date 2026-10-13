#!/usr/bin/env python3
"""Process one already-downloaded clip. This process intentionally has no network code."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ALLOWED_FORMATS = {
    "mov,mp4,m4a,3gp,3g2,mj2",
    "matroska,webm",
    "webm",
    "matroska",
}


class ProcessingError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def probe(path: Path, timeout: int) -> dict:
    command = [
        "ffprobe", "-v", "error", "-protocol_whitelist", "file",
        "-show_format", "-show_streams", "-of", "json", str(path),
    ]
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ProcessingError("probe_timeout") from error
    if result.returncode != 0:
        raise ProcessingError("invalid_media")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ProcessingError("invalid_media") from error


def duration_for(info: dict, streams: list[dict]) -> float:
    values = []
    for stream in streams:
        value = stream.get("duration")
        if value is not None:
            try:
                values.append(float(value))
            except (TypeError, ValueError):
                pass
    format_duration = info.get("duration")
    if format_duration is not None:
        try:
            values.append(float(format_duration))
        except (TypeError, ValueError):
            pass
    if not values:
        raise ProcessingError("duration_unavailable")
    return max(values)


def process(source: Path, output: Path, normalize: bool) -> dict:
    max_bytes = int(os.environ.get("MEDIA_MAX_UPLOAD_BYTES", "524288000"))
    min_seconds = float(os.environ.get("MEDIA_MIN_CLIP_SECONDS", "20"))
    max_seconds = float(os.environ.get("MEDIA_MAX_CLIP_SECONDS", "360"))
    timeout = int(os.environ.get("MEDIA_WORKER_TIMEOUT_SECONDS", "180"))
    if not source.is_file() or source.stat().st_size < 1 or source.stat().st_size > max_bytes:
        raise ProcessingError("file_size_invalid")

    source_info = probe(source, timeout)
    input_format = source_info.get("format", {}).get("format_name", "")
    if input_format not in ALLOWED_FORMATS:
        raise ProcessingError("container_not_allowed")
    audio_streams = [stream for stream in source_info.get("streams", []) if stream.get("codec_type") == "audio"]
    if not audio_streams:
        raise ProcessingError("audio_stream_missing")
    source_duration = duration_for(source_info.get("format", {}), source_info["streams"])
    if source_duration < min_seconds or source_duration > max_seconds:
        raise ProcessingError("duration_out_of_range")

    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-protocol_whitelist", "file",
        "-ignore_editlist", "0", "-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn",
        "-map_metadata", "-1", "-map_chapters", "-1", "-c:a", "aac", "-b:a", "256k",
        "-ar", "48000", "-ac", "2", "-fflags", "+bitexact", "-movflags", "+faststart",
    ]
    if normalize:
        command.extend(["-af", "loudnorm=I=-14:TP=-1.5:LRA=11"])
    command.extend(["-y", str(output)])
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ProcessingError("transcode_timeout") from error
    if result.returncode != 0 or not output.is_file() or output.stat().st_size == 0:
        raise ProcessingError("transcode_failed")

    output_info = probe(output, timeout)
    output_streams = [stream for stream in output_info.get("streams", []) if stream.get("codec_type") == "audio"]
    if len(output_streams) != 1:
        raise ProcessingError("transcode_failed")
    audio_duration = duration_for(output_info.get("format", {}), output_streams)
    return {
        "ok": True,
        "container": "m4a",
        "audio_codec": output_streams[0].get("codec_name"),
        "sample_rate": int(output_streams[0].get("sample_rate", 0)),
        "channels": int(output_streams[0].get("channels", 0)),
        "original_seconds": round(source_duration, 3),
        "audio_seconds": round(audio_duration, 3),
        "duration_mismatch": abs(source_duration - audio_duration) > 0.100,
        "normalization_applied": normalize,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--normalize", action="store_true")
    args = parser.parse_args()
    try:
        result = process(args.input, args.output, args.normalize)
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except ProcessingError as error:
        print(json.dumps({"ok": False, "code": error.code}, separators=(",", ":")))
        return 2
    except Exception:
        # Keep filesystem paths, ffmpeg diagnostics, and Python stack traces out of the response.
        print(json.dumps({"ok": False, "code": "processing_failed"}, separators=(",", ":")))
        return 2


if __name__ == "__main__":
    sys.exit(main())
