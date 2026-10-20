import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Set by the app delegate: whether the current shortcut could be registered.
    let hotKeyStatus: () -> Bool

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var hotKeyAvailable = true

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Capture area") {
                    HotKeyRecorder(combo: $settings.hotKey, isRecording: $settings.isRecordingHotKey)
                }
                if !hotKeyAvailable {
                    Label("This shortcut is used by another app or by macOS. Pick a different one.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Text("While selecting: drag for an area, click a window to capture it, click the desktop for the full screen. Hold Shift for a square, hold Space to move the selection, Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After capture") {
                Toggle("Open the editor", isOn: $settings.openEditorAfterCapture)
                Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                Toggle("Play sound", isOn: $settings.playSound)
            }

            Section("Saving") {
                Toggle("Also save a PNG file", isOn: $settings.saveToFolder)
                LabeledContent("Folder") {
                    HStack {
                        Text((settings.saveFolderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                .disabled(!settings.saveToFolder)
            }

            Section("History") {
                Stepper(value: $settings.historyLimit, in: 10...2000, step: 10) {
                    LabeledContent("Keep the last", value: "\(settings.historyLimit) screenshots")
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Screen Recording") {
                    if ScreenRecordingPermission.isGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") { ScreenRecordingPermission.openSystemSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hotKeyAvailable = hotKeyStatus() }
        .onChange(of: settings.hotKey) { _, _ in
            DispatchQueue.main.async { hotKeyAvailable = hotKeyStatus() }
        }
        .onChange(of: settings.historyLimit) { _, _ in HistoryStore.shared.prune() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolderURL
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Click, then press the new key combination. Esc cancels.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @Binding var isRecording: Bool
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Type shortcut…" : combo.displayString)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            if let newCombo = KeyCombo(event: event) {
                combo = newCombo
                stopRecording()
            } else {
                NSSound.beep() // needs at least one of ⌘ ⌃ ⌥, or a function key
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
