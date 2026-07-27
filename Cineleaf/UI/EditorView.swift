import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var state: EditorState

    var body: some View {
        VSplitView {
            HSplitView {
                SidebarView()
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
                PreviewView()
                    .frame(minWidth: 440)
                InspectorView()
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
            }
            .frame(minHeight: 360)
            TimelineView()
                .frame(minHeight: 190, idealHeight: 260, maxHeight: 430)
        }
        .navigationTitle(state.project?.name ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { importPanel() } label: {
                    Label("media.import", systemImage: "plus.rectangle.on.folder")
                }
                .help("media.import.help")
                .disabled(state.isImporting)
                Button { state.undo() } label: {
                    Label("edit.undo", systemImage: "arrow.uturn.backward")
                }
                .help("edit.undo.help")
                .disabled(!state.canUndo)
                Button { state.redo() } label: {
                    Label("edit.redo", systemImage: "arrow.uturn.forward")
                }
                .help("edit.redo.help")
                .disabled(!state.canRedo)
            }
            ToolbarItem(placement: .principal) {
                Button { state.playback.togglePlayback() } label: {
                    Label(
                        state.playback.isPlaying ? "playback.pause" : "playback.play",
                        systemImage: state.playback.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .help("playback.toggle.help")
                .disabled(state.project?.timeline.duration == .zero)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let progress = state.consolidationProgress {
                    ProgressView(value: progress)
                        .frame(width: 70)
                        .help("media.consolidating")
                }
                if state.isExtractingMedia {
                    ProgressView()
                        .controlSize(.small)
                        .help("media.extracting")
                }
                Button { state.isProjectSettingsPresented = true } label: {
                    Label("project.settings", systemImage: "slider.horizontal.3")
                }
                .help("project.settings.help")
                Button { state.isExportSheetPresented = true } label: {
                    Label("export.action", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .help("export.help")
                .disabled(state.project?.timeline.duration == .zero)
            }
        }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "media.import")
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await state.importMedia(panel.urls) }
    }
}
