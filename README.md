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

**Hands-free:** in Settings, turn on **Clap twice** or **Say its name** (by default “Hey Claude”). Clap twice or say the name, wait for the sound, and speak. When you stop talking for 3 seconds the text is pasted. Claps heard while you type or click are ignored. The name is recognised on your Mac with Apple's on-device speech recognition, in English. While either option is on, the microphone stays open as Dictation waits, so macOS shows the orange mic indicator.

**Enter words:** end with “over” or “enter” (or όβερ / έντερ) and Dictation drops the word and presses Enter. You can change the words in Settings.

The app lives in the menu bar and starts at login. Open **Settings…** from the menu bar icon to change:

- **Start dictating:** hold a key (right Option, right Control, right Command, fn or off), clap twice, or say its name
- **Finish:** how many seconds of silence end hands-free dictation, the Enter words, and whether to always press Enter
- **General:** sounds, launch at login
- **Vocabulary:** words you use often, one per line. Soniox recognises them more easily.
- **Replacements:** fixes applied after transcription, one per line as `heard → written`. For example: `πούσαρε → push`. They ignore case and accents.
- **Languages:** language hints. By default these are your system languages plus English.
- **API key**

Vocabulary and replacements cost nothing extra and add no delay.

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

## Notes

- After rebuilding the app, macOS may ask for Accessibility permission again. If the hotkey stops working, remove Dictation from the Accessibility list and add it again.
- The clipboard is restored after each paste. If Accessibility access is missing, the text stays on the clipboard instead.
- A log of what Dictation did (never what you said) is in `~/Library/Logs/Dictation.log`.

## License

MIT
