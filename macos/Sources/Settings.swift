import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("hotkey") private var hotkey = 61
    @AppStorage("clapToStart") private var clapToStart = false
    @AppStorage("wakeWord") private var wakeWord = false
    @AppStorage("wakeWords") private var wakeWords = ""
    @AppStorage("silenceTimeout") private var silenceTimeout = 3.0
    @AppStorage("enterWords") private var enterWords = ""
    @AppStorage("autoEnter") private var autoEnter = false
    @AppStorage("sounds") private var sounds = true
    @AppStorage("languages") private var languages = ""
    @AppStorage("vocabulary") private var vocabulary = ""
    @AppStorage("replacements") private var replacements = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var key = ""
    @State private var hasKey = Keychain.read() != nil

    var body: some View {
        Form {
            Section {
                Picker("Hold a key", selection: $hotkey) {
                    ForEach(hotKeys, id: \.code) { Text($0.name).tag(Int($0.code)) }
                    Divider()
                    Text("Off").tag(0)
                }
                Toggle(isOn: $clapToStart) {
                    Text("Clap twice")
                    Text("Claps while you type or click are ignored.")
                }
                Toggle(isOn: $wakeWord) {
                    Text("Say its name")
                    Text("Recognised in English on this Mac. Say the name, wait for the sound, then speak.")
                }
                if wakeWord {
                    TextField("Names", text: $wakeWords, prompt: Text("hey claude, hey cloud"))
                }
            } header: {
                Text("Start dictating")
            } footer: {
                if clapToStart || wakeWord {
                    Text("The microphone stays on while Dictation waits, so macOS shows the orange dot.")
                }
            }

            Section {
                LabeledContent("Stop after silence of") {
                    HStack {
                        Slider(value: $silenceTimeout, in: 1...8, step: 0.5)
                        Text("\(silenceTimeout, specifier: "%.1f") s").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                TextField("Enter words", text: $enterWords, prompt: Text("over, enter"))
                Toggle("Always press Enter after pasting", isOn: $autoEnter)
            } header: {
                Text("Finish")
            } footer: {
                Text("The silence timer applies after a clap or the name. End a sentence with an Enter word, like “…see you tomorrow, over”, and Dictation drops the word and presses Enter.")
            }

            Section("General") {
                Toggle("Play sounds", isOn: $sounds)
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            }

            Section {
                editor($vocabulary)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Words you use often, one per line. Soniox will recognise them more easily.")
            }

            Section {
                editor($replacements)
            } header: {
                Text("Replacements")
            } footer: {
                Text("One per line, as heard → written. For example: πούσαρε → push")
            }

            Section("Soniox") {
                TextField("Languages", text: $languages, prompt: Text(languageHints().joined(separator: ", ")))
                HStack {
                    SecureField("API key", text: $key, prompt: Text(hasKey ? "Saved in Keychain" : "From console.soniox.com"))
                    Button("Save") {
                        Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        key = ""
                        hasKey = true
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so without a height the window collapses to its title bar on macOS 14.
        .frame(width: 480, height: 720)
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body)
            .frame(height: 90)
            .scrollContentBackground(.hidden)
    }
}

final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Dictation Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
