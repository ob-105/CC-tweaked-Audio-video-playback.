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


def nearest_cc_colour(r, g, b):
    """Return the index of the nearest CC:T palette colour."""
    best = 0
    best_dist = float("inf")
    for i, (pr, pg, pb) in enumerate(CC_PALETTE):
        dist = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if dist < best_dist:
            best_dist = dist
            best = i
    return best


def image_to_nfp(img, width, height):
    """Convert a PIL Image to an NFP string."""
    img = img.resize((width, height), Image.LANCZOS).convert("RGB")
    pixels = np.array(img)
    lines = []
    for row in pixels:
        line = ""
        for r, g, b in row:
            line += NFP_CHARS[nearest_cc_colour(int(r), int(g), int(b))]
        lines.append(line)
    return "\n".join(lines)


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
    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        # Extract audio as raw signed 8-bit mono 48000 Hz PCM
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", input_path,
                "-ar", "48000",
                "-ac", "1",
                "-f", "u8",   # unsigned 8-bit
                tmp_path,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        with open(tmp_path, "rb") as f:
            pcm_data = f.read()

        dfpwm_data = pcm_to_dfpwm(pcm_data)

        with open(output_path, "wb") as f:
            f.write(dfpwm_data)

        duration_seconds = len(pcm_data) / 48000
        print(f"  Audio: {len(dfpwm_data):,} bytes, {duration_seconds:.1f}s")
        return duration_seconds

    finally:
        os.unlink(tmp_path)


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
        print(f"  Converting {total} frames to NFP...")

        for idx, png_file in enumerate(png_files):
            img = Image.open(os.path.join(tmp_dir, png_file))
            nfp = image_to_nfp(img, width, height)
            nfp_path = os.path.join(frames_dir, f"{idx + 1:06d}.nfp")
            with open(nfp_path, "w") as f:
                f.write(nfp)

            if (idx + 1) % 10 == 0 or (idx + 1) == total:
                print(f"    {idx + 1}/{total} frames done", end="\r")

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
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Batch convert MP3/MP4 for CC:Tweaked playback")
    parser.add_argument("--fps",         type=int, default=5, help="Video FPS (default: 5)")
    parser.add_argument("--monitors-x",  type=int, default=3, help="Monitors wide (default: 3)")
    parser.add_argument("--monitors-y",  type=int, default=2, help="Monitors tall (default: 2)")
    parser.add_argument("--no-push",     action="store_true", help="Skip git push")
    args = parser.parse_args()

    # Check ffmpeg
    if shutil.which("ffmpeg") is None:
        print("Error: ffmpeg not found on PATH.")
        print("Download from https://ffmpeg.org/download.html and add to PATH.")
        sys.exit(1)

    input_dir = "input"
    os.makedirs(input_dir, exist_ok=True)

    # Find all MP3/MP4 files in input/
    supported = (".mp3", ".mp4")
    files = [
        os.path.join(input_dir, f)
        for f in os.listdir(input_dir)
        if os.path.splitext(f)[1].lower() in supported
    ]

    if not files:
        print(f"No MP3 or MP4 files found in '{input_dir}/'.")
        print("Drop your files into the 'input' folder and run again.")
        sys.exit(0)

    print(f"\n=== CC:Tweaked Media Converter ===")
    print(f"Found {len(files)} file(s) to convert.\n")

    # Load existing index
    video_list, audio_list = load_index()

    converted = []
    for input_path in files:
        media_name, is_video = convert_file(
            input_path, args.fps, args.monitors_x, args.monitors_y
        )
        # Add to index if not already there
        if is_video:
            if media_name not in video_list:
                video_list.append(media_name)
        else:
            if media_name not in audio_list:
                audio_list.append(media_name)
        converted.append(os.path.basename(input_path))

    # Save updated index
    save_index(video_list, audio_list)
    print(f"\nIndex updated → output/index.lua")
    print(f"  Videos: {video_list}")
    print(f"  Audio:  {audio_list}")

    # Auto git push
    if not args.no_push:
        msg = "Convert: " + ", ".join(converted)
        git_push(msg)

    print("\nAll done! In CC:T run  lua player.lua  to browse and play.")


if __name__ == "__main__":
    main()
