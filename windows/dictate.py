"""Push-to-talk dictation with Soniox for Windows. Hold right Ctrl, speak, release."""
import array
import asyncio
import ctypes
import json
import math
import os
import queue
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import simpledialog

import keyring
import sounddevice as sd
from pynput import keyboard
from websockets.asyncio.client import connect

ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket"
MODEL = "stt-rt-v5"
RATE = 16_000
HOTKEY = keyboard.Key.ctrl_r
MIN_HOLD = 0.25
AUTO_ENTER = os.environ.get("DICTATION_AUTO_ENTER") == "1"
LANGUAGES = [l for l in os.environ.get("DICTATION_LANGUAGES", "").split(",") if l]
TERMS = [t for t in os.environ.get("DICTATION_TERMS", "").split(",") if t]


def language_hints():
    if LANGUAGES:
        return LANGUAGES
    name = ctypes.create_unicode_buffer(85)
    if hasattr(ctypes, "windll"):
        ctypes.windll.kernel32.GetUserDefaultLocaleName(name, 85)
    return list(dict.fromkeys([name.value.split("-")[0] or "en", "en"]))


def api_key(root, ask=False):
    key = os.environ.get("SONIOX_API_KEY") or (None if ask else keyring.get_password("soniox-dictation", "api-key"))
    if not key:
        key = simpledialog.askstring("Dictation", "Soniox API key (console.soniox.com):", show="•", parent=root)
        if not key:
            sys.exit("No Soniox API key")
        keyring.set_password("soniox-dictation", "api-key", key.strip())
    return key.strip()


def install_startup():
    folder = Path(os.environ["APPDATA"], "Microsoft/Windows/Start Menu/Programs/Startup")
    pythonw = Path(sys.executable).with_name("pythonw.exe")
    (folder / "Dictation.cmd").write_text(f'@start "" "{pythonw}" "{Path(__file__).resolve()}"\n')
    print(f"Added to {folder}")


class Session:
    def __init__(self, loop, key, on_level):
        self.loop = loop
        self.key = key
        self.audio = asyncio.Queue()
        self.stream = sd.RawInputStream(samplerate=RATE, channels=1, dtype="int16", blocksize=RATE // 10,
                                        callback=self._on_audio)
        self.on_level = on_level
        self.started = time.monotonic()
        self.stream.start()

    def _on_audio(self, data, *_):
        samples = array.array("h", bytes(data))
        self.on_level(math.sqrt(sum(s * s for s in samples) / max(len(samples), 1)) / 32768)
        self.loop.call_soon_threadsafe(self.audio.put_nowait, bytes(data))

    def stop(self):
        self.stream.stop()
        self.stream.close()
        self.loop.call_soon_threadsafe(self.audio.put_nowait, None)

    async def transcribe(self):
        config = {"model": MODEL, "audio_format": "pcm_s16le", "sample_rate": RATE, "num_channels": 1,
                  "language_hints": language_hints(), "enable_language_identification": True}
        if TERMS:
            config["context"] = {"terms": TERMS}
        text = []
        async with connect(ENDPOINT, additional_headers={"Authorization": f"Bearer {self.key}"}) as ws:
            await ws.send(json.dumps(config))

            async def sender():
                while (chunk := await self.audio.get()) is not None:
                    await ws.send(chunk)
                await ws.send("")

            send_task = asyncio.create_task(sender())
            async for message in ws:
                res = json.loads(message)
                if res.get("error_code"):
                    raise RuntimeError(f"Soniox {res['error_code']}: {res.get('error_message')}")
                text += [t["text"] for t in res.get("tokens", []) if t.get("is_final") and not t["text"].startswith("<")]
                if res.get("finished"):
                    break
            await send_task
        return "".join(text).strip()


class Overlay:
    W, H, BARS = 54, 24, (0.55, 0.85, 1.0, 0.8, 0.6)

    def __init__(self, root):
        self.win = tk.Toplevel(root)
        self.win.overrideredirect(True)
        self.win.attributes("-topmost", True, "-transparentcolor", "#010101")
        self.canvas = tk.Canvas(self.win, width=self.W, height=self.H, bg="#010101", highlightthickness=0)
        self.canvas.pack()
        self.win.withdraw()
        self.mode, self.level, self.smoothed, self.visible = "listening", 0.0, 0.0, False

    def show(self, mode):
        self.mode = mode
        if not self.visible:
            x = (self.win.winfo_screenwidth() - self.W) // 2
            y = self.win.winfo_screenheight() - self.H - 70
            self.win.geometry(f"+{x}+{y}")
            self.win.deiconify()
            self.visible = True
            self._draw()

    def hide(self):
        self.visible = False
        self.level = 0.0
        self.win.withdraw()

    def _draw(self):
        if not self.visible:
            return
        c, t, r = self.canvas, time.monotonic(), self.H / 2
        c.delete("all")
        c.create_oval(0, 0, self.H, self.H, fill="#141414", width=0)
        c.create_oval(self.W - self.H, 0, self.W, self.H, fill="#141414", width=0)
        c.create_rectangle(r, 0, self.W - r, self.H, fill="#141414", width=0)
        db = 20 * math.log10(max(self.level, 1e-6))
        target = min(max((db + 52) / 38, 0), 1)
        self.smoothed += (target - self.smoothed) * (0.45 if target > self.smoothed else 0.15)
        color = {"listening": "#ffffff", "working": "#8c8c8c", "error": "#ff453a"}[self.mode]
        x = (self.W - len(self.BARS) * 6 + 3) / 2
        for i, weight in enumerate(self.BARS):
            if self.mode == "listening":
                h = 3 + (self.H - 13) * self.smoothed * weight * (0.75 + 0.25 * math.sin(t * 9 + i * 1.3))
            elif self.mode == "working":
                h = 3 + (self.H - 10) * 0.35 * (0.5 + 0.5 * math.sin(t * 6 - i * 0.8))
            else:
                h = 5
            c.create_rectangle(x, (self.H - h) / 2, x + 3, (self.H + h) / 2, fill=color, width=0)
            x += 6
        self.win.after(16, self._draw)


class App:
    def __init__(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self.key = api_key(self.root, ask="--set-key" in sys.argv)
        self.overlay = Overlay(self.root)
        self.events = queue.Queue()
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()
        self.session = None
        self.keys = keyboard.Controller()

    def run(self):
        keyboard.Listener(on_press=lambda k: k == HOTKEY and self.events.put("down"),
                          on_release=lambda k: k == HOTKEY and self.events.put("up")).start()
        self._poll()
        self.root.mainloop()

    def _poll(self):
        while not self.events.empty():
            if self.events.get() == "down":
                self._begin()
            else:
                self._end()
        self.root.after(15, self._poll)

    def _begin(self):
        if self.session:
            return
        try:
            self.session = Session(self.loop, self.key, lambda level: setattr(self.overlay, "level", level))
        except Exception as err:
            return self._fail(err)
        self.overlay.show("listening")

    def _end(self):
        session, self.session = self.session, None
        if not session:
            return
        session.stop()
        if time.monotonic() - session.started < MIN_HOLD:
            return self.overlay.hide()
        self.overlay.show("working")
        future = asyncio.run_coroutine_threadsafe(session.transcribe(), self.loop)
        future.add_done_callback(lambda f: self.root.after(0, self._done, f))

    def _done(self, future):
        if future.exception():
            return self._fail(future.exception())
        self.overlay.hide()
        if text := future.result():
            self._paste(text)

    def _paste(self, text):
        try:
            previous = self.root.clipboard_get()
        except tk.TclError:
            previous = None
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.root.update()
        with self.keys.pressed(keyboard.Key.ctrl):
            self.keys.tap("v")
        if AUTO_ENTER:
            self.root.after(150, lambda: self.keys.tap(keyboard.Key.enter))
        if previous is not None:
            self.root.after(600, lambda: (self.root.clipboard_clear(), self.root.clipboard_append(previous)))

    def _fail(self, err):
        print(f"Dictation: {err}", file=sys.stderr)
        self.overlay.show("error")
        self.root.after(800, self.overlay.hide)


if __name__ == "__main__":
    if "--autostart" in sys.argv:
        install_startup()
    else:
        App().run()
