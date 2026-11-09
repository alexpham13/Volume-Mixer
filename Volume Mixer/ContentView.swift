import SwiftUI
import AppKit

struct ContentView: View {
    let audioManager: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Volume Mixer").font(.title.bold())
                Label(audioManager.output, systemImage: "hifispeaker")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if audioManager.rows.isEmpty {
                ContentUnavailableView("No active applications", systemImage: "waveform",
                                       description: Text(audioManager.issue ?? "Play audio on the selected macOS output."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(audioManager.rows) { row in
                            appRow(row)
                        }
                    }.padding(16)
                }
            }
        }
        .frame(minWidth: 430, minHeight: 280)
        .task {
            while !Task.isCancelled {
                await audioManager.refresh()
                do { try await Task.sleep(for: .milliseconds(650)) } catch { break }
            }
        }
    }

    private func appRow(_ row: MixerRow) -> some View {
        let level = audioManager.appVolumes[row.id] ?? 1
        let muted = audioManager.muted.contains(row.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let path = row.iconURL?.path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
                } else { Image(systemName: "app") }
                Text(row.name).font(.headline)
                Spacer()
                Text(muted ? "Muted" : "\(Int((level * 100).rounded()))%").monospacedDigit()
                Menu {
                    Button(row.failed ? "Retry signal check" : "Check input signal") { audioManager.monitor(row.id) }
                    Button("Restore direct playback") { audioManager.bypass(row.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Playback options for \(row.name)")
            }
            HStack {
                Button { audioManager.toggleMute(row.id) } label: {
                    Image(systemName: muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22)
                }.buttonStyle(.borderless).accessibilityLabel(muted ? "Unmute \(row.name)" : "Mute \(row.name)")
                // Gives each app an independent slider
                Slider(value: Binding(get: { level }, set: { audioManager.setVolume($0, for: row.id) }), in: 0...1)
                    .accessibilityLabel("\(row.name) volume")
            }
            Text(row.status).foregroundStyle(row.failed ? Color.orange : Color.secondary)
                .font(.caption).textSelection(.enabled)
            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PID \(row.pids.map { String($0) }.joined(separator: ", ")) • HAL \(row.processes.map { String($0) }.joined(separator: ", "))")
                    if !row.details.isEmpty { Text(row.details) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}
