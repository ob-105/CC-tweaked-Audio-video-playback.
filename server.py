#!/usr/bin/env python3
"""
CC:Tweaked Media Server
Combines the converter GUI with a local Flask HTTP server exposed via
Cloudflare Quick Tunnel.  The CC:T player fetches frames and audio directly
from this server instead of GitHub — no git push required.

Requirements:
    pip install Pillow numpy flask

cloudflared must be installed and on PATH:
    https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/

ffmpeg must also be on PATH.

Usage:
    python server.py
"""

import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import threading
import queue

# ---------------------------------------------------------------------------
# Import all conversion logic from convert.py (same directory)
# ---------------------------------------------------------------------------
sys.path.insert(0, os.path.dirname(__file__))
from convert import (
    CC_PALETTE, NFP_CHARS, KEY_INTERVAL,
    _dither_to_chars, _frame_worker,
    pcm_to_dfpwm, convert_audio_to_dfpwm,
    extract_frames, write_manifest,
    load_index, save_index, git_push,
    convert_file,
)

# ---------------------------------------------------------------------------
# Flask server
# ---------------------------------------------------------------------------
FLASK_PORT = 8765
_flask_thread = None
_flask_app = None

def _make_flask_app(base_dir):
    """Create the Flask app that serves the output/ directory and player.lua."""
    try:
        from flask import Flask, send_from_directory, abort
    except ImportError:
        return None

    app = Flask(__name__)

    @app.route("/output/<path:filename>")
    def serve_output(filename):
        output_dir = os.path.join(base_dir, "output")
        try:
            return send_from_directory(output_dir, filename)
        except Exception:
            abort(404)

    @app.route("/player.lua")
    def serve_player():
        try:
            return send_from_directory(base_dir, "player.lua")
        except Exception:
            abort(404)

    @app.route("/")
    def index():
        video_list, audio_list = load_index()
        lines = ["<h2>CC:T Media Server</h2>", "<h3>Videos</h3><ul>"]
        for v in video_list:
            lines.append(f'<li>{v}</li>')
        lines.append("</ul><h3>Audio</h3><ul>")
        for a in audio_list:
            lines.append(f'<li>{a}</li>')
        lines.append("</ul>")
        return "\n".join(lines)

    return app


def start_flask(base_dir, log_fn):
    """Start Flask in a daemon thread. Returns True on success."""
    global _flask_thread, _flask_app
    try:
        from flask import Flask
    except ImportError:
        log_fn("[server] Flask not installed. Run: pip install flask")
        return False

    _flask_app = _make_flask_app(base_dir)
    if _flask_app is None:
        return False

    import logging
    log = logging.getLogger("werkzeug")
    log.setLevel(logging.ERROR)  # silence Flask request logs in console

    def _run():
        try:
            _flask_app.run(host="127.0.0.1", port=FLASK_PORT, use_reloader=False, threaded=True)
        except Exception as e:
            log_fn(f"[server] Flask error: {e}")

    _flask_thread = threading.Thread(target=_run, daemon=True)
    _flask_thread.start()
    log_fn(f"[server] Flask running on http://127.0.0.1:{FLASK_PORT}/")
    return True


# ---------------------------------------------------------------------------
# cloudflared manager
# ---------------------------------------------------------------------------
_cf_proc = None

def start_cloudflared(url_callback, log_fn):
    """
    Launch cloudflared quick tunnel pointing at Flask.
    Calls url_callback(url_string) once the tunnel URL is found in output.
    Returns the subprocess.Popen object or None on failure.
    """
    global _cf_proc
    if shutil.which("cloudflared") is None:
        log_fn("[cloudflared] Not found on PATH. Install from: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")
        return None

    try:
        proc = subprocess.Popen(
            ["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{FLASK_PORT}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        _cf_proc = proc
    except Exception as e:
        log_fn(f"[cloudflared] Failed to start: {e}")
        return None

    url_pattern = re.compile(r"https://[a-z0-9\-]+\.trycloudflare\.com")
    found = threading.Event()

    def _reader():
        for line in proc.stdout:
            line = line.rstrip()
            log_fn(f"[cf] {line}")
            if not found.is_set():
                m = url_pattern.search(line)
                if m:
                    found.set()
                    url_callback(m.group(0))

    threading.Thread(target=_reader, daemon=True).start()
    return proc


def stop_cloudflared():
    global _cf_proc
    if _cf_proc and _cf_proc.poll() is None:
        _cf_proc.terminate()
        try:
            _cf_proc.wait(timeout=3)
        except Exception:
            _cf_proc.kill()
    _cf_proc = None


# ---------------------------------------------------------------------------
# Combined GUI
# ---------------------------------------------------------------------------
def launch_gui():
    import tkinter as tk
    from tkinter import ttk, scrolledtext

    MONITOR_W = 51
    MONITOR_H = 19

    log_queue = queue.Queue()

    class QueueWriter:
        def write(self, s):
            if s and s.strip():
                log_queue.put(s.rstrip())
        def flush(self):
            pass

    base_dir = os.path.dirname(os.path.abspath(__file__))

    root = tk.Tk()
    root.title("CC:Tweaked Media Server")
    root.resizable(False, False)

    notebook = ttk.Notebook(root)
    notebook.pack(fill="both", expand=True, padx=8, pady=8)

    # =========================================================
    # TAB 1 — CONVERT
    # =========================================================
    tab_convert = ttk.Frame(notebook)
    notebook.add(tab_convert, text="  Convert  ")

    sf = ttk.LabelFrame(tab_convert, text="Monitor & Quality Settings", padding=10)
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

    var_compress = tk.BooleanVar(value=True)
    cb_compress = ttk.Checkbutton(sf, text="Compress frames with RLE (smaller files, faster downloads)",
                                  variable=var_compress)
    cb_compress.grid(row=3, column=0, columnspan=5, sticky="w", pady=(6, 0))

    var_dither = tk.BooleanVar(value=True)
    ttk.Checkbutton(sf, text="Dithering (Floyd-Steinberg; dramatically improves image quality)",
                    variable=var_dither).grid(row=4, column=0, columnspan=5, sticky="w", pady=(2, 0))

    var_halfblock = tk.BooleanVar(value=False)
    ttk.Checkbutton(sf, text="Half-block rendering \u2584  (2\u00d7 vertical resolution; combinable with RLE)",
                    variable=var_halfblock).grid(row=5, column=0, columnspan=5, sticky="w", pady=(2, 0))

    var_delta = tk.BooleanVar(value=False)
    cb_delta = ttk.Checkbutton(sf,
        text="Delta encoding (only store changed rows; requires \u2584+RLE; best compression)",
        variable=var_delta, state="disabled")
    cb_delta.grid(row=6, column=0, columnspan=5, sticky="w", pady=(2, 0))

    def on_delta_prereq_toggle(*_):
        if var_halfblock.get() and var_compress.get():
            cb_delta.configure(state="normal")
        else:
            var_delta.set(False)
            cb_delta.configure(state="disabled")

    var_halfblock.trace_add("write", on_delta_prereq_toggle)
    var_compress.trace_add("write", on_delta_prereq_toggle)

    var_push = tk.BooleanVar(value=False)  # default off — server makes push less necessary
    ttk.Checkbutton(sf, text="Also push to GitHub after converting",
                    variable=var_push).grid(row=7, column=0, columnspan=5, sticky="w", pady=(2, 0))

    # File list
    ff = ttk.LabelFrame(tab_convert, text="Files in  input/", padding=10)
    ff.grid(row=1, column=0, padx=12, pady=4, sticky="ew")

    lb = tk.Listbox(ff, height=5, width=62, selectmode="extended")
    lb.grid(row=0, column=0, columnspan=2)

    def refresh_files():
        lb.delete(0, tk.END)
        input_dir = os.path.join(base_dir, "input")
        os.makedirs(input_dir, exist_ok=True)
        for f in sorted(os.listdir(input_dir)):
            if os.path.splitext(f)[1].lower() in (".mp3", ".mp4"):
                lb.insert(tk.END, f)

    refresh_files()
    ttk.Button(ff, text="Refresh list", command=refresh_files).grid(row=1, column=0, pady=(6,0), sticky="w")

    # Convert log
    clf = ttk.LabelFrame(tab_convert, text="Log", padding=10)
    clf.grid(row=2, column=0, padx=12, pady=4, sticky="ew")

    convert_log = scrolledtext.ScrolledText(clf, height=10, width=74, state="disabled",
                                            font=("Consolas", 9))
    convert_log.grid(row=0, column=0)

    def append_convert_log(msg):
        convert_log.configure(state="normal")
        convert_log.insert(tk.END, msg + "\n")
        convert_log.see(tk.END)
        convert_log.configure(state="disabled")

    def poll_log():
        while not log_queue.empty():
            append_convert_log(log_queue.get_nowait())
        root.after(100, poll_log)

    root.after(100, poll_log)

    convert_btn = ttk.Button(tab_convert, text="▶  Convert", width=22)
    convert_btn.grid(row=3, column=0, pady=(4, 14))

    def run_conversion():
        convert_btn.configure(state="disabled")
        old_stdout = sys.stdout
        sys.stdout = QueueWriter()
        old_cwd = os.getcwd()
        os.chdir(base_dir)
        try:
            if shutil.which("ffmpeg") is None:
                print("Error: ffmpeg not found on PATH.")
                return

            fps      = var_fps.get()
            mx       = var_mx.get()
            my       = var_my.get()
            compress = var_compress.get()
            halfblock= var_halfblock.get()
            delta    = var_delta.get()
            dither   = var_dither.get()
            do_push  = var_push.get()

            input_dir = os.path.join(base_dir, "input")
            files = [
                os.path.join(input_dir, f)
                for f in os.listdir(input_dir)
                if os.path.splitext(f)[1].lower() in (".mp3", ".mp4")
            ]
            if not files:
                print("No MP3/MP4 files found in input/")
                return

            print(f"=== Converting {len(files)} file(s) ===")
            video_list, audio_list = load_index()
            converted = []
            for input_path in files:
                media_name, is_video = convert_file(
                    input_path, fps, mx, my, compress, halfblock, delta, dither)
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
            print("Done! Start the server, then paste the URL into CC:T.")
        except Exception as e:
            import traceback
            print(f"Error: {e}\n{traceback.format_exc()}")
        finally:
            sys.stdout = old_stdout
            os.chdir(old_cwd)
            root.after(0, lambda: convert_btn.configure(state="normal"))

    convert_btn.configure(command=lambda: threading.Thread(target=run_conversion, daemon=True).start())

    # =========================================================
    # TAB 2 — SERVER
    # =========================================================
    tab_server = ttk.Frame(notebook)
    notebook.add(tab_server, text="  Server  ")

    sf2 = ttk.LabelFrame(tab_server, text="Cloudflare Quick Tunnel", padding=14)
    sf2.pack(fill="x", padx=12, pady=(12, 6))

    status_var = tk.StringVar(value="Stopped")
    status_label = ttk.Label(sf2, textvariable=status_var, foreground="#c00", font=("", 10, "bold"))
    status_label.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 8))

    ttk.Label(sf2, text="Tunnel URL:").grid(row=1, column=0, sticky="w")
    url_var = tk.StringVar(value="")
    url_entry = ttk.Entry(sf2, textvariable=url_var, width=52, state="readonly")
    url_entry.grid(row=1, column=1, padx=(6, 6))

    def copy_url():
        u = url_var.get()
        if u:
            root.clipboard_clear()
            root.clipboard_append(u)
            copy_btn.configure(text="Copied!")
            root.after(1500, lambda: copy_btn.configure(text="Copy"))

    copy_btn = ttk.Button(sf2, text="Copy", command=copy_url, width=7)
    copy_btn.grid(row=1, column=2)

    ttk.Label(sf2, text="Paste this URL into CC:T when prompted at player startup.",
              foreground="#555").grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))

    # Server log
    slf = ttk.LabelFrame(tab_server, text="Server Log", padding=10)
    slf.pack(fill="both", expand=True, padx=12, pady=6)

    server_log = scrolledtext.ScrolledText(slf, height=14, width=74, state="disabled",
                                           font=("Consolas", 9))
    server_log.pack()

    srv_log_queue = queue.Queue()

    def server_log_fn(msg):
        srv_log_queue.put(msg)

    def poll_server_log():
        while not srv_log_queue.empty():
            m = srv_log_queue.get_nowait()
            server_log.configure(state="normal")
            server_log.insert(tk.END, m + "\n")
            server_log.see(tk.END)
            server_log.configure(state="disabled")
        root.after(150, poll_server_log)

    root.after(150, poll_server_log)

    _server_running = threading.Event()

    def start_server():
        if _server_running.is_set():
            return
        _server_running.set()
        start_btn.configure(state="disabled")
        stop_btn.configure(state="normal")
        status_var.set("Starting Flask...")
        status_label.configure(foreground="#a60")

        ok = start_flask(base_dir, server_log_fn)
        if not ok:
            status_var.set("Flask failed — is it installed?")
            status_label.configure(foreground="#c00")
            _server_running.clear()
            start_btn.configure(state="normal")
            stop_btn.configure(state="disabled")
            return

        status_var.set("Starting cloudflared...")

        def on_url(url):
            url_var.set(url)
            root.after(0, lambda: status_var.set("Running ✓"))
            root.after(0, lambda: status_label.configure(foreground="#060"))
            server_log_fn(f"[server] Tunnel URL: {url}")

        proc = start_cloudflared(on_url, server_log_fn)
        if proc is None:
            status_var.set("cloudflared not found")
            status_label.configure(foreground="#c00")

    def stop_server():
        stop_cloudflared()
        url_var.set("")
        status_var.set("Stopped")
        status_label.configure(foreground="#c00")
        _server_running.clear()
        start_btn.configure(state="normal")
        stop_btn.configure(state="disabled")
        server_log_fn("[server] Stopped.")

    btn_frame = ttk.Frame(tab_server)
    btn_frame.pack(pady=(0, 10))
    start_btn = ttk.Button(btn_frame, text="▶  Start Server", width=18, command=lambda: threading.Thread(target=start_server, daemon=True).start())
    start_btn.pack(side="left", padx=6)
    stop_btn = ttk.Button(btn_frame, text="■  Stop Server", width=18, command=stop_server, state="disabled")
    stop_btn.pack(side="left", padx=6)

    def on_close():
        stop_cloudflared()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    multiprocessing.freeze_support()
    launch_gui()
