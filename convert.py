#!/usr/bin/env python3
"""
CC:Tweaked Media Converter
Converts MP3 or MP4 files into:
  - DFPWM audio (.dfpwm) for CC:T speaker playback
  - NFP video frames (.nfp) for CC:T monitor display (MP4 only)

Requirements:
    pip install ffmpeg-python numpy Pillow

You also need ffmpeg installed and on your PATH:
    https://ffmpeg.org/download.html

Usage:
    python convert.py [--fps 5] [--monitors-x 3] [--monitors-y 2]

Drop any MP3 or MP4 files into the  input/  folder, then run this script.
Output goes into  output/<media_name>/  and is auto-pushed to GitHub.
"""

import argparse
import multiprocessing
import os
import shutil
import struct
import subprocess
import sys
import json
import math
import tempfile

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("Missing dependencies. Run:  pip install Pillow numpy")
    sys.exit(1)

# Ensure winget-installed binaries (like ffmpeg) are on PATH even in stale shells
import winreg
def _refresh_path():
    paths = set(os.environ.get("PATH", "").split(os.pathsep))
    for hive, scope in [(winreg.HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"),
                        (winreg.HKEY_CURRENT_USER, "Environment")]:
        try:
            key = winreg.OpenKey(hive, scope)
            val, _ = winreg.QueryValueEx(key, "Path")
            winreg.CloseKey(key)
            for p in val.split(os.pathsep):
                paths.add(os.path.expandvars(p))
        except Exception:
            pass
    os.environ["PATH"] = os.pathsep.join(p for p in paths if p)
_refresh_path()


# ---------------------------------------------------------------------------
# CC:T 16-colour palette (matches the default palette in CC:Tweaked)
# ---------------------------------------------------------------------------
CC_PALETTE = [
    (240, 240, 240),  # 0  white
    (242, 178, 51),   # 1  orange
    (229, 127, 216),  # 2  magenta
    (153, 178, 242),  # 3  light blue
    (222, 222, 108),  # 4  yellow
    (127, 204, 25),   # 5  lime
    (242, 178, 204),  # 6  pink
    (76,  76,  76),   # 7  gray
    (153, 153, 153),  # 8  light gray
    (76,  153, 178),  # 9  cyan
    (178, 102, 229),  # 10 purple
    (51,  102, 204),  # 11 blue
    (102, 76,  51),   # 12 brown
    (87,  166, 78),   # 13 green
    (204, 76,  76),   # 14 red
    (25,  25,  25),   # 15 black
]

# NFP colour characters (index → char)
NFP_CHARS = "0123456789abcdef"

# Precomputed numpy arrays for vectorised colour matching
_CC_PALETTE_NP = np.array(CC_PALETTE, dtype=np.int32)   # (16, 3)
_NFP_CHARS_ARR = np.array(list(NFP_CHARS))               # (16,)


def image_to_nfp(img, width, height):
    """Convert a PIL Image to NFP using vectorised numpy (fast path)."""
    img    = img.resize((width, height), Image.LANCZOS).convert("RGB")
    pixels = np.array(img, dtype=np.int32)                      # (H, W, 3)
    diff   = pixels[:, :, np.newaxis, :] - _CC_PALETTE_NP      # (H, W, 16, 3)
    idx    = (diff ** 2).sum(axis=-1).argmin(axis=-1)          # (H, W)
    chars  = _NFP_CHARS_ARR[idx]                               # (H, W)
    return "\n".join("".join(row) for row in chars)


def _frame_worker(args):
    """Top-level worker used by ProcessPoolExecutor for parallel NFP conversion."""
    png_path, nfp_path, width, height = args
    from PIL import Image as _Img
    import numpy as _np
    _pal  = _np.array(CC_PALETTE, dtype=_np.int32)
    _ch   = _np.array(list(NFP_CHARS))
    img   = _Img.open(png_path).resize((width, height), _Img.LANCZOS).convert("RGB")
    px    = _np.array(img, dtype=_np.int32)
    diff  = px[:, :, _np.newaxis, :] - _pal
    idx   = (diff ** 2).sum(axis=-1).argmin(axis=-1)
    nfp   = "\n".join("".join(row) for row in _ch[idx])
    with open(nfp_path, "w") as f:
        f.write(nfp)
    return nfp_path


# ---------------------------------------------------------------------------
# DFPWM encoder
# ---------------------------------------------------------------------------
def pcm_to_dfpwm(pcm_bytes):
    """
    Encode raw signed 8-bit mono PCM to DFPWM.
    DFPWM encodes 8 samples per byte.
    """
    charge = 0
    strength = 0
    previous_bit = False
    out = bytearray()

    samples = list(pcm_bytes)
    # Pad to multiple of 8
    while len(samples) % 8 != 0:
        samples.append(0)

    for i in range(0, len(samples), 8):
        byte = 0
        for j in range(8):
            sample = samples[i + j]
            # Convert unsigned byte to signed
            if sample > 127:
                sample -= 256

            current_bit = sample > charge or (sample == charge and charge == 127)

            if current_bit:
                byte |= (1 << j)

            target = 127 if current_bit else -128

            # Strength update
            if current_bit == previous_bit:
                strength = min(strength + 1, 127)
            else:
                strength = 0

            previous_bit = current_bit

            # Charge update
            charge_diff = ((target - charge) * (strength + 1) + 128) >> 8
            charge = max(-128, min(127, charge + charge_diff))

        out.append(byte)

    return bytes(out)


def convert_audio_to_dfpwm(input_path, output_path):
    """Use ffmpeg to extract & resample audio, then encode to DFPWM."""
    print(f"  Converting audio → DFPWM...")

    # Get duration first
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", input_path],
        capture_output=True, text=True
    )
    try:
        duration_seconds = float(result.stdout.strip())
    except Exception:
        duration_seconds = 0.0

    # Use ffmpeg's native DFPWM encoder for best quality
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-i", input_path,
            "-af", "aresample=48000,pan=mono|c0=0.5*c0+0.5*c1",
            "-ar", "48000",
            "-ac", "1",
            "-c:a", "dfpwm",
            "-f", "dfpwm",
            output_path,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    size = os.path.getsize(output_path)
    print(f"  Audio: {size:,} bytes, {duration_seconds:.1f}s")
    return duration_seconds


def extract_frames(input_path, frames_dir, fps, width, height):
    """Extract video frames from MP4 and convert to NFP."""
    print(f"  Extracting frames at {fps} FPS ({width}x{height})...")
    os.makedirs(frames_dir, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp_dir:
        # Extract frames as PNG via ffmpeg
        frame_pattern = os.path.join(tmp_dir, "%06d.png")
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", input_path,
                "-vf", f"fps={fps},scale={width}:{height}:flags=lanczos",
                frame_pattern,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        png_files = sorted(f for f in os.listdir(tmp_dir) if f.endswith(".png"))
        total = len(png_files)
        print(f"  Converting {total} frames to NFP (parallel)...")

        worker_args = [
            (
                os.path.join(tmp_dir, pf),
                os.path.join(frames_dir, f"{i + 1:06d}.nfp"),
                width,
                height,
            )
            for i, pf in enumerate(png_files)
        ]

        from concurrent.futures import ProcessPoolExecutor
        cpu = max(1, os.cpu_count() or 1)
        done = 0
        with ProcessPoolExecutor(max_workers=cpu) as pool:
            for _ in pool.map(_frame_worker, worker_args, chunksize=4):
                done += 1
                if done % 10 == 0 or done == total:
                    print(f"    {done}/{total} frames done", end="\r")

        print()
        return total


def write_manifest(manifest_path, data):
    with open(manifest_path, "w") as f:
        f.write("-- Auto-generated by convert.py\n")
        f.write("return {\n")
        for k, v in data.items():
            if isinstance(v, str):
                f.write(f'  {k} = "{v}",\n')
            else:
                f.write(f"  {k} = {v},\n")
        f.write("}\n")


# ---------------------------------------------------------------------------
# Index updater
# ---------------------------------------------------------------------------
def load_index():
    """Load output/index.lua and return (video_list, audio_list)."""
    index_path = os.path.join("output", "index.lua")
    if not os.path.exists(index_path):
        return [], []
    # Simple parser: look for video = {...} and audio = {...}
    with open(index_path, "r") as f:
        content = f.read()
    def extract_list(key):
        import re
        m = re.search(rf'{key}\s*=\s*\{{([^}}]*)\}}', content, re.DOTALL)
        if not m:
            return []
        items = re.findall(r'"([^"]+)"', m.group(1))
        return items
    return extract_list("video"), extract_list("audio")


def save_index(video_list, audio_list):
    index_path = os.path.join("output", "index.lua")
    lines = ["-- Auto-generated by convert.py - do not edit manually\n"]
    lines.append("return {\n")
    lines.append("  video = {\n")
    for v in video_list:
        lines.append(f'    "{v}",\n')
    lines.append("  },\n")
    lines.append("  audio = {\n")
    for a in audio_list:
        lines.append(f'    "{a}",\n')
    lines.append("  },\n")
    lines.append("}\n")
    with open(index_path, "w") as f:
        f.writelines(lines)


# ---------------------------------------------------------------------------
# Git auto-push
# ---------------------------------------------------------------------------
def git_push(message):
    print(f"\n  [git] Committing and pushing: {message}")
    try:
        subprocess.run(["git", "add", "-A"], check=True)
        subprocess.run(["git", "commit", "-m", message], check=True)
        subprocess.run(["git", "push", "origin", "main"], check=True)
        print("  [git] Pushed successfully.")
    except subprocess.CalledProcessError as e:
        print(f"  [git] Warning: git push failed: {e}")


# ---------------------------------------------------------------------------
# Convert a single file
# ---------------------------------------------------------------------------
def convert_file(input_path, fps, monitors_x, monitors_y):
    monitor_w = 51
    monitor_h = 19
    width  = monitor_w * monitors_x
    height = monitor_h * monitors_y

    ext = os.path.splitext(input_path)[1].lower()
    is_video = ext == ".mp4"

    media_name = os.path.splitext(os.path.basename(input_path))[0]
    # Sanitize name for use as a folder/key
    media_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in media_name)
    output_dir = os.path.join("output", media_name)
    os.makedirs(output_dir, exist_ok=True)

    print(f"\n--- Converting: {os.path.basename(input_path)} ---")
    print(f"  Type:   {'Video + Audio' if is_video else 'Audio only'}")
    if is_video:
        print(f"  Frame:  {width}x{height} @ {fps} FPS")

    manifest = {
        "name": media_name,
        "has_audio": "true",
        "has_video": "true" if is_video else "false",
        "fps": fps,
        "frame_count": 0,
        "width": width,
        "height": height,
        "monitors_x": monitors_x,
        "monitors_y": monitors_y,
    }

    audio_path = os.path.join(output_dir, "audio.dfpwm")
    duration = convert_audio_to_dfpwm(input_path, audio_path)
    manifest["duration"] = round(duration, 2)

    if is_video:
        frames_dir = os.path.join(output_dir, "frames")
        frame_count = extract_frames(input_path, frames_dir, fps, width, height)
        manifest["frame_count"] = frame_count
    else:
        manifest["has_video"] = "false"

    manifest_path = os.path.join(output_dir, "manifest.lua")
    write_manifest(manifest_path, manifest)

    print(f"  Done → output/{media_name}/")
    return media_name, is_video


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
def launch_gui():
    import tkinter as tk
    from tkinter import ttk, scrolledtext
    import threading
    import queue

    MONITOR_W = 51  # chars per monitor at text scale 0.5
    MONITOR_H = 19

    log_queue = queue.Queue()

    class QueueWriter:
        """Thread-safe stdout redirect to the log queue."""
        def write(self, s):
            if s and s.strip():
                log_queue.put(s.rstrip())
        def flush(self):
            pass

    root = tk.Tk()
    root.title("CC:Tweaked Media Converter")
    root.resizable(False, False)

    # ── Settings ──────────────────────────────────────────────────────────
    sf = ttk.LabelFrame(root, text="Monitor & Quality Settings", padding=10)
    sf.grid(row=0, column=0, padx=12, pady=(12, 4), sticky="ew")

    ttk.Label(sf, text="Monitors wide:").grid(row=0, column=0, sticky="w", pady=2)
    var_mx = tk.IntVar(value=3)
    ttk.Spinbox(sf, from_=1, to=8, textvariable=var_mx, width=5).grid(row=0, column=1, padx=(6,16), pady=2)

    ttk.Label(sf, text="Monitors tall:").grid(row=0, column=2, sticky="w", pady=2)
    var_my = tk.IntVar(value=2)
    ttk.Spinbox(sf, from_=1, to=8, textvariable=var_my, width=5).grid(row=0, column=3, padx=(6,0), pady=2)

    ttk.Label(sf, text="FPS:").grid(row=1, column=0, sticky="w", pady=2)
    var_fps = tk.IntVar(value=5)
    ttk.Spinbox(sf, from_=1, to=30, textvariable=var_fps, width=5).grid(row=1, column=1, padx=(6,16), pady=2)

    ttk.Label(sf, text="Speakers:").grid(row=1, column=2, sticky="w", pady=2)
    var_spk = tk.IntVar(value=1)
    ttk.Spinbox(sf, from_=1, to=16, textvariable=var_spk, width=5).grid(row=1, column=3, padx=(6,0), pady=2)
    ttk.Label(sf, text="(auto-detected in-game)", foreground="gray").grid(row=1, column=4, sticky="w", padx=6)

    res_label = ttk.Label(sf, foreground="#555")
    res_label.grid(row=2, column=0, columnspan=5, sticky="w", pady=(4, 0))

    def update_res_label(*_):
        w = var_mx.get() * MONITOR_W
        h = var_my.get() * MONITOR_H
        res_label.configure(text=f"→ Video resolution: {w} × {h} chars")

    var_mx.trace_add("write", update_res_label)
    var_my.trace_add("write", update_res_label)
    update_res_label()

    var_push = tk.BooleanVar(value=True)
    ttk.Checkbutton(sf, text="Auto-push to GitHub after converting", variable=var_push).grid(
        row=3, column=0, columnspan=5, sticky="w", pady=(6, 0))

    # ── File list ─────────────────────────────────────────────────────────
    ff = ttk.LabelFrame(root, text="Files in  input/", padding=10)
    ff.grid(row=1, column=0, padx=12, pady=4, sticky="ew")

    lb = tk.Listbox(ff, height=5, width=58, selectmode="extended")
    lb.grid(row=0, column=0, columnspan=2)

    def refresh_files():
        lb.delete(0, tk.END)
        os.makedirs("input", exist_ok=True)
        for f in sorted(os.listdir("input")):
            if os.path.splitext(f)[1].lower() in (".mp3", ".mp4"):
                lb.insert(tk.END, f)

    refresh_files()
    ttk.Button(ff, text="Refresh list", command=refresh_files).grid(row=1, column=0, pady=(6,0), sticky="w")

    # ── Log ───────────────────────────────────────────────────────────────
    lf = ttk.LabelFrame(root, text="Log", padding=10)
    lf.grid(row=2, column=0, padx=12, pady=4, sticky="ew")

    log_box = scrolledtext.ScrolledText(lf, height=12, width=70, state="disabled",
                                        font=("Consolas", 9))
    log_box.grid(row=0, column=0)

    def append_log(msg):
        log_box.configure(state="normal")
        log_box.insert(tk.END, msg + "\n")
        log_box.see(tk.END)
        log_box.configure(state="disabled")

    def poll_log():
        while not log_queue.empty():
            append_log(log_queue.get_nowait())
        root.after(100, poll_log)

    root.after(100, poll_log)

    # ── Convert button ────────────────────────────────────────────────────
    btn = ttk.Button(root, text="▶  Convert & Push", width=22)
    btn.grid(row=3, column=0, pady=(4, 14))

    def run_conversion():
        btn.configure(state="disabled")
        old_stdout = sys.stdout
        sys.stdout = QueueWriter()
        try:
            if shutil.which("ffmpeg") is None:
                print("Error: ffmpeg not found on PATH.")
                return

            fps = var_fps.get()
            mx  = var_mx.get()
            my  = var_my.get()
            do_push = var_push.get()

            supported = (".mp3", ".mp4")
            files = [
                os.path.join("input", f)
                for f in os.listdir("input")
                if os.path.splitext(f)[1].lower() in supported
            ]
            if not files:
                print("No MP3 or MP4 files found in input/")
                return

            print(f"=== Converting {len(files)} file(s) ===")
            video_list, audio_list = load_index()
            converted = []
            for input_path in files:
                media_name, is_video = convert_file(input_path, fps, mx, my)
                if is_video:
                    if media_name not in video_list:
                        video_list.append(media_name)
                else:
                    if media_name not in audio_list:
                        audio_list.append(media_name)
                converted.append(os.path.basename(input_path))

            save_index(video_list, audio_list)
            print(f"Index updated.  Videos: {video_list}  Audio: {audio_list}")

            if do_push:
                git_push("Convert: " + ", ".join(converted))

            print("All done!  In CC:T run  lua player.lua  to play.")
        except Exception as e:
            print(f"Error: {e}")
        finally:
            sys.stdout = old_stdout
            root.after(0, lambda: btn.configure(state="normal"))

    def start():
        threading.Thread(target=run_conversion, daemon=True).start()

    btn.configure(command=start)
    root.mainloop()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    # CLI fallback: python convert.py --no-gui [options]
    if "--no-gui" in sys.argv:
        sys.argv.remove("--no-gui")
        parser = argparse.ArgumentParser(description="CC:Tweaked Media Converter (CLI mode)")
        parser.add_argument("--fps",        type=int, default=5)
        parser.add_argument("--monitors-x", type=int, default=3)
        parser.add_argument("--monitors-y", type=int, default=2)
        parser.add_argument("--no-push",    action="store_true")
        args = parser.parse_args()

        if shutil.which("ffmpeg") is None:
            print("Error: ffmpeg not found on PATH.")
            sys.exit(1)

        os.makedirs("input", exist_ok=True)
        supported = (".mp3", ".mp4")
        files = [
            os.path.join("input", f)
            for f in os.listdir("input")
            if os.path.splitext(f)[1].lower() in supported
        ]
        if not files:
            print("No MP3 or MP4 files found in input/")
            sys.exit(0)

        video_list, audio_list = load_index()
        converted = []
        for input_path in files:
            media_name, is_video = convert_file(input_path, args.fps, args.monitors_x, args.monitors_y)
            if is_video:
                if media_name not in video_list:
                    video_list.append(media_name)
            else:
                if media_name not in audio_list:
                    audio_list.append(media_name)
            converted.append(os.path.basename(input_path))

        save_index(video_list, audio_list)
        if not args.no_push:
            git_push("Convert: " + ", ".join(converted))
        print("All done!")
    else:
        launch_gui()


if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
