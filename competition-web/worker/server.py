#!/usr/bin/env python3
"""Cloud Run HTTP task handler. Cloud Run IAM protects production ingress."""
import hashlib
import hmac
import json
import os
import re
import tempfile
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from process import ProcessingError, process


PORT = int(os.environ.get("PORT", "8080"))
MAX_ATTEMPTS = int(os.environ.get("MEDIA_TASK_MAX_ATTEMPTS", "5"))
MAX_BODY = 32_768


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


HTTP = urllib.request.build_opener(NoRedirect)


class Handler(BaseHTTPRequestHandler):
    server_version = "OSTMediaWorker"
    sys_version = ""

    def log_message(self, _format, *_args):
        # Request bodies and paths contain short-lived media capabilities.
        return

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/process":
            self.send_error(404)
            return
        local_token = os.environ.get("MEDIA_WORKER_LOCAL_TOKEN")
        if os.environ.get("NODE_ENV") != "production":
            if not local_token:
                self.send_error(503)
                return
            if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {local_token}"):
                self.send_error(401)
                return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > MAX_BODY:
                self.send_error(413)
                return
            raw = self.rfile.read(length)
            task = json.loads(raw)
            validate_task(task)
        except (ValueError, TypeError, json.JSONDecodeError):
            self.send_error(400)
            return

        attempt = max(0, int(self.headers.get("X-CloudTasks-TaskRetryCount", "0")))
        try:
            try:
                result = execute(task)
            except ProcessingError:
                raise
            except Exception as error:
                print(json.dumps({"event": "media_worker_failed", "stage": "process_or_storage", "http_status": getattr(error, "code", None)}), flush=True)
                raise RuntimeError("media_stage_failed") from None
            try:
                post_result(task["callbackUrl"], {
                    "uploadId": task["uploadId"], "status": "complete", "audioKey": task["audioKey"],
                    "originalSeconds": result["original_seconds"], "audioSeconds": result["audio_seconds"],
                    "durationMismatch": result["duration_mismatch"], "attempt": attempt,
                })
            except Exception as error:
                print(json.dumps({"event": "media_worker_failed", "stage": "result_callback", "http_status": getattr(error, "code", None)}), flush=True)
                raise RuntimeError("media_callback_failed") from None
            self.respond(200, b"processed")
        except ProcessingError as error:
            try:
                post_result(task["callbackUrl"], {
                    "uploadId": task["uploadId"], "status": "failed", "errorCode": error.code,
                    "attempt": attempt,
                })
                self.respond(200, b"rejected")
            except Exception:
                self.respond(503, b"retry")
        except Exception:
            if attempt + 1 >= MAX_ATTEMPTS:
                try:
                    post_result(task["callbackUrl"], {
                        "uploadId": task["uploadId"], "status": "failed",
                        "errorCode": "worker_retries_exhausted", "attempt": attempt,
                    })
                    self.respond(200, b"failed")
                except Exception:
                    self.respond(503, b"retry")
            else:
                self.send_response(503)
                self.send_header("Retry-After", "10")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(b"retry")

    def respond(self, status, body):
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def validate_task(task):
    if not isinstance(task, dict):
        raise ValueError("invalid task")
    if not re.fullmatch(r"[0-9a-f-]{36}", str(task.get("uploadId", "")), re.I):
        raise ValueError("invalid upload")
    if not re.fullmatch(r"[a-f0-9]{32}/[a-f0-9]{32}\.m4a", str(task.get("audioKey", ""))):
        raise ValueError("invalid output key")
    if not isinstance(task.get("normalize"), bool):
        raise ValueError("invalid normalization setting")
    for name in ("minClipSeconds", "maxClipSeconds"):
        if not isinstance(task.get(name), (int, float)) or task[name] <= 0:
            raise ValueError("invalid duration setting")
    max_bytes = task.get("maxUploadBytes")
    if not isinstance(max_bytes, int) or not 1 <= max_bytes <= 524_288_000:
        raise ValueError("invalid file limit")
    storage_origin = os.environ["MEDIA_ALLOWED_STORAGE_ORIGIN"].rstrip("/")
    callback_origin = os.environ["MEDIA_CALLBACK_ORIGIN"].rstrip("/")
    source = validate_url(task.get("sourceUrl"), storage_origin, "/storage/v1/object/sign/")
    destination = validate_url(task.get("destinationUrl"), storage_origin, "/storage/v1/object/upload/sign/")
    callback = validate_url(task.get("callbackUrl"), callback_origin, "/api/internal/media-worker/result")
    if callback.path != "/api/internal/media-worker/result":
        raise ValueError("invalid callback path")
    return source, destination, callback


def validate_url(value, origin, path_fragment):
    if not isinstance(value, str):
        raise ValueError("invalid URL")
    parsed = urlparse(value)
    expected_scheme = "https" if os.environ.get("NODE_ENV") == "production" else parsed.scheme
    if parsed.scheme != expected_scheme or f"{parsed.scheme}://{parsed.netloc}" != origin:
        raise ValueError("unapproved URL origin")
    if parsed.username or parsed.password or path_fragment not in parsed.path:
        raise ValueError("unapproved URL path")
    return parsed


def execute(task):
    source, destination, _callback = validate_task(task)
    with tempfile.TemporaryDirectory(prefix="ost-media-cloud-") as folder:
        root = Path(folder)
        input_path = root / "original.video"
        output_path = root / "processed.m4a"
        request = urllib.request.Request(task["sourceUrl"], headers={"Cache-Control": "no-store"})
        with HTTP.open(request, timeout=900) as response, input_path.open("xb") as target:
            declared = int(response.headers.get("Content-Length", "0"))
            if declared > task["maxUploadBytes"]:
                raise ProcessingError("file_size_invalid")
            received = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                received += len(chunk)
                if received > task["maxUploadBytes"]:
                    raise ProcessingError("file_size_invalid")
                target.write(chunk)
        result = process(
            input_path, output_path, task["normalize"], task["maxUploadBytes"],
            float(task["minClipSeconds"]), float(task["maxClipSeconds"]), 900,
        )
        if output_path.stat().st_size > 64 * 1024 * 1024:
            raise ProcessingError("transcode_failed")
        upload = urllib.request.Request(
            task["destinationUrl"], data=output_path.read_bytes(), method="PUT",
            headers={"Content-Type": "audio/mp4", "Cache-Control": "max-age=0", "x-upsert": "true"},
        )
        with HTTP.open(upload, timeout=90) as response:
            if response.status not in (200, 201):
                raise RuntimeError("audio_storage_write_failed")
        return result


def post_result(callback_url, result):
    raw = json.dumps(result, separators=(",", ":")).encode("utf-8")
    timestamp = str(int(__import__("time").time()))
    signature = hmac.new(
        os.environ["MEDIA_WORKER_CALLBACK_SECRET"].encode("utf-8"),
        timestamp.encode("ascii") + b"." + raw,
        hashlib.sha256,
    ).hexdigest()
    request = urllib.request.Request(
        callback_url, data=raw, method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Ost-Worker-Timestamp": timestamp,
            "X-Ost-Worker-Signature": signature,
        },
    )
    with HTTP.open(request, timeout=15) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError("result_callback_failed")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
