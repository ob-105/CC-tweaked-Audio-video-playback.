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
    python convert.py <input_file> [--fps 5] [--width 51] [--height 19] [--monitors-x 3] [--monitors-y 2]

Output goes into ./output/<media_name>/
    audio.dfpwm       - audio track
    frames/0001.nfp   - video frames (NFP format for CC:T)
    manifest.lua      - tells the player how many frames, fps, etc.
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


def main():
    parser = argparse.ArgumentParser(description="Convert MP3/MP4 for CC:Tweaked playback")
    parser.add_argument("input", help="Input MP3 or MP4 file")
    parser.add_argument("--fps", type=int, default=5, help="Video frames per second (default: 5)")
    parser.add_argument("--width", type=int, default=None, help="Frame width in CC characters")
    parser.add_argument("--height", type=int, default=None, help="Frame height in CC characters")
    parser.add_argument("--monitors-x", type=int, default=3, help="Number of monitors wide (default: 3)")
    parser.add_argument("--monitors-y", type=int, default=2, help="Number of monitors tall (default: 2)")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Error: file not found: {args.input}")
        sys.exit(1)

    # Check ffmpeg
    if shutil.which("ffmpeg") is None:
        print("Error: ffmpeg not found on PATH.")
        print("Download from https://ffmpeg.org/download.html and add to PATH.")
        sys.exit(1)

    # Each CC:T monitor is 51 chars wide × 19 chars tall (standard size)
    monitor_w = 51
    monitor_h = 19
    width = args.width or monitor_w * args.monitors_x
    height = args.height or monitor_h * args.monitors_y

    ext = os.path.splitext(args.input)[1].lower()
    is_video = ext == ".mp4"

    media_name = os.path.splitext(os.path.basename(args.input))[0]
    output_dir = os.path.join("output", media_name)
    os.makedirs(output_dir, exist_ok=True)

    print(f"\n=== CC:Tweaked Media Converter ===")
    print(f"Input:  {args.input}")
    print(f"Output: {output_dir}/")
    print(f"Type:   {'Video + Audio' if is_video else 'Audio only'}")
    if is_video:
        print(f"Frame:  {width}x{height} @ {args.fps} FPS")
    print()

    manifest = {
        "name": media_name,
        "has_audio": "true",
        "has_video": "true" if is_video else "false",
        "fps": args.fps,
        "frame_count": 0,
        "width": width,
        "height": height,
        "monitors_x": args.monitors_x,
        "monitors_y": args.monitors_y,
    }

    # Convert audio
    audio_path = os.path.join(output_dir, "audio.dfpwm")
    duration = convert_audio_to_dfpwm(args.input, audio_path)
    manifest["duration"] = round(duration, 2)

    # Convert video frames
    if is_video:
        frames_dir = os.path.join(output_dir, "frames")
        frame_count = extract_frames(args.input, frames_dir, args.fps, width, height)
        manifest["frame_count"] = frame_count
    else:
        manifest["has_video"] = "false"

    # Write manifest
    manifest_path = os.path.join(output_dir, "manifest.lua")
    write_manifest(manifest_path, manifest)

    print(f"\nDone! Output in: {output_dir}/")
    print(f"Upload the '{media_name}' folder to your GitHub repo under output/")
    print(f"Then in CC:T run:  wget <raw_url>/player.lua player.lua  and follow prompts.")


if __name__ == "__main__":
    main()
