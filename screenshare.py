#!/usr/bin/env python3
"""
CC:Tweaked Screen Share Server
Captures your PC screen and streams it to a CC:T monitor via HTTP.

Usage:
  1. Run this script:  python screenshare.py
  2. Run screenshare.lua on your CC:T computer and enter the URL shown here.

Resolution: 51x38 half-block pixels  →  51 cols x 19 rows on a monitor at scale 0.5
"""

import time
import threading
import socket
import re
import shutil
import subprocess
import atexit
import numpy as np
from flask import Flask, Response, jsonify
from PIL import Image

try:
    import mss
    _HAVE_MSS = True
except ImportError:
    _HAVE_MSS = False
    from PIL import ImageGrab

# ─────────────────────────────────────────────────────────────────────────────
# CC:Tweaked 16-color palette
# Index = log2(colors.X constant), matching CC:T's blit hex encoding 0-f
# ─────────────────────────────────────────────────────────────────────────────
CC_PALETTE = np.array([
    (240, 240, 240),  # 0  white
    (242, 178,  51),  # 1  orange
    (229, 127, 216),  # 2  magenta
    (153, 178, 242),  # 3  lightBlue
    (222, 222, 108),  # 4  yellow
    (127, 204,  25),  # 5  lime
    (242, 178, 204),  # 6  pink
    ( 76,  76,  76),  # 7  gray
    (153, 153, 153),  # 8  lightGray
    ( 76, 153, 178),  # 9  cyan
    (178, 102, 229),  # 10 purple
    ( 51, 102, 204),  # 11 blue
    (127, 102,  76),  # 12 brown
    ( 87, 166,  78),  # 13 green
    (204,  76,  76),  # 14 red
    ( 17,  17,  17),  # 15 black
], dtype=np.int32)

# Lookup table: palette index → ASCII hex char byte
HEX_CHARS = np.frombuffer(b"0123456789abcdef", dtype=np.uint8)

# Target: 51 wide × 38 tall half-block pixels (fits a standard monitor at scale 0.5)
W, H   = 51, 38
PORT   = 8766

try:
    _RESAMPLE = Image.Resampling.LANCZOS
except AttributeError:
    _RESAMPLE = Image.LANCZOS

# ─────────────────────────────────────────────────────────────────────────────
# Capture & encode
# ─────────────────────────────────────────────────────────────────────────────

def grab_screen() -> Image.Image:
    if _HAVE_MSS:
        with mss.mss() as sct:
            raw = sct.grab(sct.monitors[1])
            return Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
    else:
        return ImageGrab.grab()


def encode_nfp(img: Image.Image) -> bytes:
    """Convert PIL image → NFP bytes (W hex chars per row, rows separated by \\n)."""
    img   = img.resize((W, H), _RESAMPLE)
    arr   = np.array(img, dtype=np.int32)          # (H, W, 3)
    flat  = arr.reshape(-1, 3)                      # (H*W, 3)
    # Squared RGB distance to each of 16 palette colors
    diffs = flat[:, None, :] - CC_PALETTE[None, :, :]   # (H*W, 16, 3)
    dists = (diffs * diffs).sum(axis=2)                  # (H*W, 16)
    idx   = dists.argmin(axis=1).reshape(H, W).astype(np.uint8)  # (H, W)
    # Map indices → ASCII hex chars
    chars = HEX_CHARS[idx]                          # (H, W) uint8
    # Append '\n' after each row and flatten to bytes
    rows  = np.hstack([chars, np.full((H, 1), ord('\n'), dtype=np.uint8)])
    return bytes(rows.ravel())


# ─────────────────────────────────────────────────────────────────────────────
# Background capture thread — keeps latest frame ready for instant serving
# ─────────────────────────────────────────────────────────────────────────────

_lock        = threading.Lock()
_frame_bytes = b""
_fps         = 0.0
_frame_count = 0


def capture_loop():
    global _frame_bytes, _fps, _frame_count
    durations = []
    while True:
        t0 = time.perf_counter()
        try:
            frame = encode_nfp(grab_screen())
            with _lock:
                _frame_bytes  = frame
                _frame_count += 1
        except Exception as e:
            print(f"[screenshare] Capture error: {e}")
            time.sleep(0.5)
            continue
        dt = time.perf_counter() - t0
        durations.append(dt)
        if len(durations) > 30:
            durations.pop(0)
        avg  = sum(durations) / len(durations)
        _fps = 1.0 / avg if avg > 0 else 0.0


# ─────────────────────────────────────────────────────────────────────────────
# Flask endpoints
# ─────────────────────────────────────────────────────────────────────────────

app = Flask(__name__)

@app.route("/frame")
def serve_frame():
    with _lock:
        data = _frame_bytes
    return Response(data, mimetype="text/plain; charset=ascii")

@app.route("/info")
def serve_info():
    return jsonify({"w": W, "h": H, "fps": round(_fps, 1), "frames": _frame_count})

@app.route("/")
def serve_index():
    return (
        f"<h2>CC:T Screen Share</h2>"
        f"<p>Resolution: {W}&times;{H} half-block pixels "
        f"({W} cols &times; {H//2} char rows on monitor at scale&nbsp;0.5)</p>"
        f"<p>Server FPS: <strong>{_fps:.1f}</strong></p>"
        f"<p>Frames served: {_frame_count}</p>"
        f"<p>Endpoints: <code>GET /frame</code> &nbsp; <code>GET /info</code></p>"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Cloudflare quick tunnel
# ─────────────────────────────────────────────────────────────────────────────

_cf_proc = None

def start_cloudflared(port: int, url_callback) -> None:
    """Spawn cloudflared quick tunnel and call url_callback(url) once ready."""
    global _cf_proc
    if shutil.which("cloudflared") is None:
        print("[cloudflared] Not found on PATH — no tunnel started.")
        print("  Install from: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")
        return
    try:
        _cf_proc = subprocess.Popen(
            ["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{port}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except Exception as e:
        print(f"[cloudflared] Failed to start: {e}")
        return

    pat = re.compile(r"https://[a-z0-9\-]+\.trycloudflare\.com")
    found = threading.Event()

    def _reader():
        for line in _cf_proc.stdout:
            line = line.rstrip()
            if not found.is_set():
                m = pat.search(line)
                if m:
                    found.set()
                    url_callback(m.group(0))
    threading.Thread(target=_reader, daemon=True).start()


def stop_cloudflared():
    global _cf_proc
    if _cf_proc and _cf_proc.poll() is None:
        _cf_proc.terminate()
        try:
            _cf_proc.wait(timeout=3)
        except Exception:
            _cf_proc.kill()
    _cf_proc = None


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def get_local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


if __name__ == "__main__":
    ip = get_local_ip()
    sep = "=" * 47
    print(sep)
    print("  CC:Tweaked Screen Share Server")
    print(sep)
    print(f"  Resolution : {W} × {H} half-block pixels")
    print(f"  Monitor    : {W} cols × {H//2} rows  (scale 0.5)")
    print(f"  Backend    : {'mss  (fast — pip install mss)' if _HAVE_MSS else 'PIL.ImageGrab (slower; pip install mss to speed up)'}")
    print(f"  Port       : {PORT}")
    print()
    print(f"  ► Local URL : http://{ip}:{PORT}")
    print()
    print("  Enter the URL above when screenshare.lua asks.")
    print("  (For internet access, run:  cloudflared tunnel --url http://localhost:8766)")
    print(sep)

    t = threading.Thread(target=capture_loop, daemon=True)
    t.start()
    print("[screenshare] Capture thread started.")

    # Start cloudflared tunnel
    _tunnel_ready = threading.Event()
    def _on_tunnel_url(url):
        print()
        print("  ► Tunnel URL : " + url)
        print("  Enter the tunnel URL above in screenshare.lua for remote access.")
        print()
        _tunnel_ready.set()

    print("[cloudflared] Starting quick tunnel...")
    start_cloudflared(PORT, _on_tunnel_url)
    atexit.register(stop_cloudflared)

    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False)
