#!/usr/bin/env python3
"""Small self-hosted, memory-only relay for LopLop Player Discord cover art."""

from __future__ import annotations

import hmac
import json
import os
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

MAX_IMAGE_BYTES = 512 * 1024
IMAGE_TTL_SECONDS = 10 * 60
MAX_CACHED_IMAGES = 128
TOKEN = os.environ.get("DISCORD_COVER_TOKEN", "")
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8787"))

images: dict[str, tuple[bytes, str, float]] = {}
images_lock = threading.Lock()


def valid_image_type(data: bytes) -> str | None:
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "LopLopCoverRelay/1"

    def log_message(self, _format: str, *_args: object) -> None:
        # Generated cover URLs are bearer links. Never put request paths in logs.
        return

    def send_bytes(self, status: int, data: bytes, content_type: str, extra_headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_json(self, status: int, value: dict[str, str]) -> None:
        self.send_bytes(status, json.dumps(value).encode("utf-8"), "application/json; charset=utf-8")

    def do_POST(self) -> None:
        if self.path != "/v1/covers":
            self.send_json(404, {"error": "not found"})
            return
        if not TOKEN or not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {TOKEN}"):
            self.send_json(401, {"error": "unauthorized"})
            return
        if not PUBLIC_BASE_URL.startswith("https://"):
            self.send_json(503, {"error": "relay HTTPS URL is not configured"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_IMAGE_BYTES:
            self.send_json(413, {"error": "image must be between 1 byte and 512 KiB"})
            return
        image = self.rfile.read(length)
        image_type = valid_image_type(image)
        if len(image) != length or image_type is None:
            self.send_json(415, {"error": "unsupported image; use JPEG, PNG, or WebP"})
            return

        now = time.time()
        image_id = secrets.token_urlsafe(32)
        with images_lock:
            for key in [key for key, (_data, _kind, expires) in images.items() if expires <= now]:
                images.pop(key, None)
            while len(images) >= MAX_CACHED_IMAGES:
                oldest = min(images, key=lambda key: images[key][2])
                images.pop(oldest, None)
            images[image_id] = (image, image_type, now + IMAGE_TTL_SECONDS)

        image_url = f"{PUBLIC_BASE_URL}/c/{image_id}"
        self.send_json(201, {"url": image_url})

    def do_GET(self) -> None:
        match = re.fullmatch(r"/c/([A-Za-z0-9_-]{40,48})", urlsplit(self.path).path)
        if not match:
            self.send_json(404, {"error": "not found"})
            return
        with images_lock:
            item = images.get(match.group(1))
            if item is not None and item[2] <= time.time():
                images.pop(match.group(1), None)
                item = None
        if item is None:
            self.send_json(404, {"error": "image expired"})
            return
        data, image_type, _expires = item
        self.send_bytes(200, data, image_type, {"Cache-Control": "public, max-age=60"})

    def do_HEAD(self) -> None:
        self.do_GET()


def main() -> None:
    parsed_url = urlsplit(PUBLIC_BASE_URL)
    if len(TOKEN) < 32:
        raise SystemExit("Set DISCORD_COVER_TOKEN to a random secret of at least 32 characters.")
    if parsed_url.scheme != "https" or not parsed_url.netloc:
        raise SystemExit("Set PUBLIC_BASE_URL to the public HTTPS address of this relay.")
    server = ThreadingHTTPServer((BIND_HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"LopLop cover relay listening on {BIND_HOST}:{PORT}; public URL: {PUBLIC_BASE_URL}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        with images_lock:
            images.clear()


if __name__ == "__main__":
    main()
