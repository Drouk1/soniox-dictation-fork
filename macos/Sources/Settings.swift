import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("hotkey") private var hotkey = 61
    @AppStorage("autoEnter") private var autoEnter = false
    @AppStorage("clapToStart") private var clapToStart = false
    @AppStorage("languages") private var languages = ""
    @AppStorage("vocabulary") private var vocabulary = ""
    @AppStorage("replacements") private var replacements = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var key = ""
    @State private var hasKey = Keychain.read() != nil

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $hotkey) {
                    ForEach(hotKeys, id: \.code) { Text($0.name).tag(Int($0.code)) }
                }
                Toggle(isOn: $clapToStart) {
                    Text("Clap twice to start")
                    Text("Stops after 3 seconds of silence. Keeps the microphone on while idle.")
                }
                Toggle("Press Enter after pasting", isOn: $autoEnter)
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
        .frame(width: 460, height: 680)
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
