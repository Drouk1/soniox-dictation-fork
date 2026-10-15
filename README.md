# Soniox Dictation

Hold a key, speak, release. Your words are typed wherever the cursor is.

Uses [Soniox](https://soniox.com) real-time speech-to-text. It handles mixed languages well, for example Greek with English terms. Costs about $0.12 per hour of speech. You only pay while you hold the key.

## macOS

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/harabalos/soniox-dictation.git
cd soniox-dictation/macos
./build.sh
```

This installs `Dictation.app` to `~/Applications` and starts it. On first launch:

1. Paste your Soniox API key from [console.soniox.com](https://console.soniox.com). The key is stored in the macOS Keychain.
2. Allow **Microphone** access.
3. Enable **Dictation** in System Settings → Privacy & Security → **Accessibility**. Dictation needs this to detect the hotkey and paste text.

**Usage:** hold **right Option (⌥)** and speak. A small waveform shows at the bottom of the screen while it listens. Release the key, and the text is pasted.

No right Option key on your keyboard? Pick another hotkey from the menu bar icon → **Hotkey**: right Control, right Command or fn.

The app lives in the menu bar and starts at login. You can change these settings from the menu bar icon:
- Hotkey
- Press Enter after pasting
- Launch at login
- Set the API key

## Windows

Requires Python 3.10+ from [python.org](https://www.python.org/downloads/). When installing, tick "Add Python to PATH".

```bash
git clone https://github.com/harabalos/soniox-dictation.git
cd soniox-dictation\windows
pip install -r requirements.txt
pythonw dictate.py
```

On first run it asks for your Soniox API key. The key is stored in Windows Credential Manager.

**Usage:** hold **right Ctrl** and speak. Release the key, and the text is pasted.

To start Dictation at login, run this once:

```bash
python dictate.py --autostart
```

Settings are environment variables:

| Variable | Example | Effect |
|---|---|---|
| `DICTATION_AUTO_ENTER` | `1` | Press Enter after pasting |
| `DICTATION_LANGUAGES` | `el,en` | Language hints |
| `DICTATION_TERMS` | `Kubernetes,Soniox` | Words to spell correctly |

To change the key later, run `python dictate.py --set-key`.

## Options (macOS)

Language hints come from your system languages plus English. To override them, or to add words that should always be spelled correctly, run:

```bash
defaults write io.github.harabalos.dictation languages -array el en
defaults write io.github.harabalos.dictation terms -array "Kubernetes" "Soniox"
```

Then restart the app.

## Notes

- After rebuilding the app, macOS may ask for Accessibility permission again. If the hotkey stops working, remove Dictation from the Accessibility list and add it again.
- The clipboard is restored after each paste.

## License

MIT
