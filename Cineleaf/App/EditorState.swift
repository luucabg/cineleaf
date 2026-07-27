import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CineleafCore

struct PresentedError: Identifiable {
    let id = UUID()
    var titleKey: String
    var messageKey: String
    var technicalDetail: String
}

enum QuickFilterPreset: String, CaseIterable {
    case vivid
    case warmFilm
    case monochrome
    case softBloom

    var adjustments: ColorAdjustments {
        switch self {
        case .vivid: ColorAdjustments(contrast: 1.12, saturation: 1.25, sharpen: 0.16)
        case .warmFilm: ColorAdjustments(exposure: 0.08, contrast: 1.08, saturation: 0.92, temperature: 0.18, vignette: 0.16)
        case .monochrome: .neutral
        case .softBloom: ColorAdjustments(exposure: 0.06, contrast: 0.94, saturation: 0.9)
        }
    }

    var effects: [VideoEffect] {
        switch self {
        case .vivid, .warmFilm: []
        case .monochrome: [VideoEffect(kind: .monochrome, amount: 1)]
        case .softBloom: [VideoEffect(kind: .bloom, amount: 0.28)]
        }
    }
}

@MainActor
final class EditorState: ObservableObject {
    @Published private(set) var project: CineleafProject?
    @Published private(set) var projectURL: URL?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedAssetID: UUID?
    @Published var timelineZoom: Double = 80
    @Published private(set) var isDirty = false
    @Published private(set) var isImporting = false
    @Published private(set) var isBuildingPreview = false
    @Published private(set) var isGeneratingCaptions = false
    @Published private(set) var isNormalizingAudio = false
    @Published private(set) var isRecordingVoiceover = false
    @Published private(set) var isDetectingSilence = false
    @Published private(set) var isDetectingBeats = false
    @Published private(set) var isCreatingFreezeFrame = false
    @Published private(set) var isExtractingMedia = false
    @Published private(set) var consolidationProgress: Double?
    @Published private(set) var canPasteClipProperties = false
    @Published var pendingSilenceRemoval: SilenceRemovalProposal?
    @Published private(set) var waveforms: [UUID: [Float]] = [:]
    @Published private(set) var mediaAvailability: [UUID: MediaAvailability] = [:]
    @Published private(set) var proxyProgress: [UUID: Double] = [:]
    @Published var presentedError: PresentedError?
    @Published var availableRecovery: CineleafProject?
    @Published var isNewProjectSheetPresented = false
    @Published var isProjectSettingsPresented = false
    @Published var isExportSheetPresented = false

    let playback = PlaybackController()
    let recentProjects = RecentProjectsStore()
    let cache = DerivedDataCache.shared

    private var editor: ProjectEditor?
    private var history = EditHistory(limit: 50)
    private let store = ProjectPackageStore()
    private let accessManager = MediaAccessManager()
    private let inspector = AVMediaInspector()
    private let thumbnailGenerator = AVThumbnailGenerator()
    private let waveformGenerator = AVWaveformGenerator()
    private lazy var compositionBuilder = AVCompositionBuilder(accessManager: accessManager)
    private let exportService = AVExportService()
    private let proxyService = ProxyMediaService()
    private let transcriptionService = OnDeviceTranscriptionService()
    private let audioAnalysis = AudioAnalysisService()
    private let voiceoverRecorder = VoiceoverRecorder()
    private let silenceDetection = SilenceDetectionService()
    private let beatDetection = BeatDetectionService()
    private let freezeFrameService = FreezeFrameService()
    private let mediaUtilityService = MediaUtilityService()
    private let mediaConsolidator = ProjectMediaConsolidator()
    private var voiceoverStart = RationalTime.zero
    private var autosaveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var waveformTasks: [UUID: Task<Void, Never>] = [:]
    private var copiedClipProperties: ClipPropertyBundle?
    @Published private(set) var renderedComposition: RenderedComposition?
    private var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CINELEAF_UI_TESTING"] == "1"
    }

    init() {
        guard !isUITesting else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.availableRecovery = try await self.store.availableRecoveries().first
            } catch {
                self.present(error, messageKey: "error.recovery.load")
            }
        }
    }

    deinit {
        autosaveTask?.cancel()
        previewTask?.cancel()
        waveformTasks.values.forEach { $0.cancel() }
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var selectedClip: TimelineClip? {
        guard selectedClipIDs.count == 1, let selected = selectedClipIDs.first else { return nil }
        return project?.timeline.tracks.flatMap(\.clips).first { $0.id == selected }
    }

    func newProject(name: String, preset: CanvasPreset, frameRate: ProjectFrameRate) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = CineleafProject(
            name: finalName.isEmpty ? String(localized: "project.untitled") : finalName,
            canvasPreset: preset,
            frameRate: frameRate
        )
        install(project, url: nil)
        isDirty = true
        scheduleAutosave()
    }

    func recover(_ project: CineleafProject) {
        install(project, url: nil)
        availableRecovery = nil
        isDirty = true
        schedulePreviewRebuild()
    }

    func discardRecovery() {
        guard let recovery = availableRecovery else { return }
        Task {
            do {
                try await store.discardRecovery(projectID: recovery.id)
                availableRecovery = nil
            } catch {
                present(error, messageKey: "error.recovery.discard")
            }
        }
    }

    func open(_ url: URL) async {
        do {
            let opened = try await LocalDiagnostics.shared.measure("project_open") {
                try await self.store.open(url)
            }
            install(opened, url: url)
            await accessManager.setProjectPackageURL(url)
            recentProjects.add(url)
            await updateMediaAvailability()
            scheduleAllWaveforms()
            schedulePreviewRebuild()
        } catch {
            present(error, messageKey: "error.project.open")
        }
    }

    func save() async -> Bool {
        guard let project else { return true }
        guard let projectURL else { return false }
        do {
            try await LocalDiagnostics.shared.measure("project_save") {
                try await self.store.save(project, to: projectURL)
            }
            try await store.discardRecovery(projectID: project.id)
            recentProjects.add(projectURL)
            isDirty = false
            return true
        } catch {
            present(error, messageKey: "error.project.save")
            return false
        }
    }

    func saveAs(_ url: URL) async -> Bool {
        projectURL = url
        await accessManager.setProjectPackageURL(url)
        let saved = await save()
        if !saved {
            projectURL = nil
            await accessManager.setProjectPackageURL(nil)
        }
        return saved
    }

    func closeProject() async {
        autosaveTask?.cancel()
        previewTask?.cancel()
        waveformTasks.values.forEach { $0.cancel() }
        waveformTasks.removeAll()
        playback.stop()
        voiceoverRecorder.cancel()
        isRecordingVoiceover = false
        renderedComposition = nil
        await compositionBuilder.clearCaches()
        await accessManager.releaseAll()
        await accessManager.setProjectPackageURL(nil)
        project = nil
        projectURL = nil
        editor = nil
        selectedClipIDs = []
        selectedAssetID = nil
        copiedClipProperties = nil
        canPasteClipProperties = false
        waveforms = [:]
        mediaAvailability = [:]
        history.reset()
        isDirty = false
    }

    func importMedia(_ urls: [URL]) async {
        guard !urls.isEmpty, project != nil else { return }
        isImporting = true
        defer { isImporting = false }
        var imported: [MediaAsset] = []
        var failures: [String] = []
        for url in urls {
            do {
                try Task.checkCancellation()
                let reference = try await accessManager.makeReference(for: url)
                let inspection = try await inspector.inspect(url: url)
                imported.append(MediaAsset(
                    displayName: url.lastPathComponent,
                    kind: inspection.kind,
                    reference: reference,
                    metadata: inspection.metadata
                ))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !imported.isEmpty {
            performEdit { editor in
                for asset in imported { try editor.addAsset(asset) }
            }
            selectedAssetID = imported.first?.id
            for asset in imported { scheduleWaveform(for: asset) }
        }
        if !failures.isEmpty {
            presentedError = PresentedError(
                titleKey: "error.import.title",
                messageKey: "error.import.some_files",
                technicalDetail: failures.joined(separator: "\n")
            )
        }
    }

    func relink(assetID: UUID, to url: URL) async {
        guard let asset = project?.assets.first(where: { $0.id == assetID }) else { return }
        do {
            let reference = try await accessManager.makeReference(for: url)
            let inspection = try await inspector.inspect(url: url)
            var updated = asset
            updated.displayName = url.lastPathComponent
            updated.kind = inspection.kind
            updated.reference = reference
            updated.metadata = inspection.metadata
            performEdit { try $0.replaceAsset(updated) }
            mediaAvailability[assetID] = .available
            scheduleWaveform(for: updated)
        } catch {
            present(error, messageKey: "error.media.relink")
        }
    }

    func addAssetToTimeline(_ assetID: UUID, trackID: UUID? = nil, at proposedStart: RationalTime? = nil) {
        guard let project, let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        let kind: ClipKind = switch asset.kind {
        case .video: .video
        case .audio: .audio
        case .image: .image
        }
        let compatible = kind.compatibleTrack
        guard let destination = trackID.flatMap({ id in
            project.timeline.tracks.first(where: { $0.id == id && $0.kind == compatible })
        }) ?? project.timeline.tracks.first(where: { $0.kind == compatible && !$0.isLocked }) else {
            present(EditingError.noCompatibleTrack, messageKey: "error.timeline.no_track")
            return
        }
        let appendTime = destination.clips.map(\.timelineEnd).max() ?? .zero
        let start = proposedStart ?? appendTime
        let duration = asset.metadata.duration ?? RationalTime(value: 5, timescale: 1)
        let clip = TimelineClip(
            name: asset.displayName,
            kind: kind,
            assetID: asset.id,
            timelineStart: start,
            duration: duration
        )
        performEdit { try $0.insert(clip, into: destination.id) }
        selectedClipIDs = [clip.id]
    }

    func addTextClip() {
        guard let project,
              let track = project.timeline.tracks.first(where: { $0.kind == .video && !$0.isLocked }) else {
            present(EditingError.noCompatibleTrack, messageKey: "error.timeline.no_track")
            return
        }
        let start = max(playback.currentTime, track.clips.map(\.timelineEnd).max() ?? .zero)
        let clip = TimelineClip(
            name: String(localized: "clip.text.default_name"),
            kind: .text,
            timelineStart: start,
            duration: RationalTime(value: 5, timescale: 1),
            textStyle: TextStyle(text: String(localized: "clip.text.default_content"))
        )
        performEdit { try $0.insert(clip, into: track.id) }
        selectedClipIDs = [clip.id]
    }

    func updateProjectSettings(name: String, preset: CanvasPreset, frameRate: ProjectFrameRate) {
        guard var updated = project, let before = project else { return }
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "project.untitled")
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.canvasPreset = preset
        updated.canvas = preset.resolution
        updated.frameRate = frameRate
        updated.exportPreferences.frameRate = frameRate
        updated.modifiedAt = Date()
        do {
            try ProjectValidator.validate(updated)
            editor = try ProjectEditor(project: updated)
            history.record(before)
            project = updated
            isDirty = true
            scheduleAutosave()
            schedulePreviewRebuild()
        } catch {
            present(error, messageKey: "error.project.settings")
        }
    }

    func updateExportPreferences(_ preferences: ExportPreferences) {
        guard var updated = project, let before = project else { return }
        updated.exportPreferences = preferences
        updated.modifiedAt = Date()
        do {
            try ProjectValidator.validate(updated)
            editor = try ProjectEditor(project: updated)
            history.record(before)
            project = updated
            isDirty = true
            scheduleAutosave()
        } catch {
            present(error, messageKey: "error.export.settings")
        }
    }

    func selectClip(_ id: UUID, extending: Bool) {
        if extending {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) }
        } else {
            selectedClipIDs = [id]
        }
        selectedAssetID = nil
    }

    func moveClip(_ id: UUID, to start: RationalTime, trackID: UUID) {
        performEdit { try $0.moveClip(id, to: start, trackID: trackID) }
    }

    func trimClipStart(_ id: UUID, to start: RationalTime) {
        performEdit { try $0.trimStart(of: id, to: start) }
    }

    func trimClipEnd(_ id: UUID, to end: RationalTime) {
        performEdit { try $0.trimEnd(of: id, to: end) }
    }

    func updateClip(_ id: UUID, mutation: (inout TimelineClip) -> Void) {
        performEdit { try $0.updateClip(id, mutation: mutation) }
    }

    func splitSelection() {
        guard let id = selectedClipIDs.first else { return }
        do {
            var newID: UUID?
            performEdit { newID = try $0.splitClip(id, at: playback.currentTime) }
            if let newID { selectedClipIDs = [newID] }
        }
    }

    func deleteSelection() {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        performEdit { try $0.deleteClips(ids) }
        selectedClipIDs = []
    }

    func rippleDeleteSelection() {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        performEdit { try $0.rippleDelete(ids) }
        selectedClipIDs = []
    }

    func groupSelection() {
        guard selectedClipIDs.count >= 2 else { return }
        let ids = selectedClipIDs
        performEdit { _ = try $0.groupClips(ids) }
    }

    func ungroupSelection() {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        performEdit { try $0.ungroupClips(ids) }
    }

    func linkSelection() {
        guard selectedClipIDs.count >= 2 else { return }
        let ids = selectedClipIDs
        performEdit { _ = try $0.linkClips(ids) }
    }

    func addMarker() {
        performEdit { _ = try $0.addMarker(at: playback.currentTime) }
    }

    func duplicateSelection() {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return }
        var duplicate: UUID?
        performEdit { duplicate = try $0.duplicateClip(id) }
        if let duplicate { selectedClipIDs = [duplicate] }
    }

    func detachAudio() {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return }
        var detached: UUID?
        performEdit { detached = try $0.detachAudio(from: id) }
        if let detached { selectedClipIDs = [detached] }
    }

    func insertGap(durationSeconds: Double) {
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 86_400 else {
            present(EditingError.invalidEdit, messageKey: "error.gap.invalid")
            return
        }
        let duration = RationalTime(seconds: durationSeconds, preferredTimescale: 60_000)
        performEdit { try $0.insertGap(at: playback.currentTime, duration: duration) }
    }

    func extractSelectedAudio(to destination: URL) async {
        guard let project,
              let clip = selectedClip,
              let assetID = clip.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }),
              asset.metadata.hasAudio else {
            present(EditingError.invalidEdit, messageKey: "error.audio.extract")
            return
        }
        isExtractingMedia = true
        defer { isExtractingMedia = false }
        do {
            let source = try await accessManager.resolve(asset.reference)
            let sourceDuration = RationalTime(
                seconds: clip.duration.seconds * clip.playbackRate,
                preferredTimescale: 60_000
            )
            _ = try await mediaUtilityService.extractAudio(
                from: source,
                to: destination,
                start: clip.sourceStart,
                duration: sourceDuration,
                overwrite: true
            )
        } catch {
            present(error, messageKey: "error.audio.extract")
        }
    }

    func saveCurrentFrame(to destination: URL) async {
        guard let project,
              let clip = selectedClip,
              clip.kind == .video || clip.kind == .image,
              let assetID = clip.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }) else {
            present(EditingError.invalidEdit, messageKey: "error.frame.extract")
            return
        }
        isExtractingMedia = true
        defer { isExtractingMedia = false }
        do {
            let source = try await accessManager.resolve(asset.reference)
            let localTime = (playback.currentTime - clip.timelineStart).clamped(to: .zero...clip.duration)
            let sourceDuration = RationalTime(
                seconds: clip.duration.seconds * clip.playbackRate,
                preferredTimescale: 60_000
            )
            var sourceOffset: RationalTime
            if clip.kind == .image {
                sourceOffset = .zero
            } else if clip.isReversed {
                sourceOffset = max(
                    sourceDuration - RationalTime(
                        seconds: localTime.seconds * clip.playbackRate,
                        preferredTimescale: 60_000
                    ) - project.frameRate.value.frameDuration,
                    .zero
                )
            } else {
                sourceOffset = RationalTime(
                    seconds: localTime.seconds * clip.playbackRate,
                    preferredTimescale: 60_000
                )
            }
            if clip.kind == .video {
                sourceOffset = min(
                    sourceOffset,
                    max(sourceDuration - project.frameRate.value.frameDuration, .zero)
                )
            }
            _ = try await mediaUtilityService.extractFrame(
                from: source,
                to: destination,
                at: clip.sourceStart + sourceOffset,
                overwrite: true
            )
        } catch {
            present(error, messageKey: "error.frame.extract")
        }
    }

    func setPlaybackRate(_ rate: Double, for clipID: UUID) {
        performEdit { try $0.setPlaybackRate(clipID, rate: rate, ripple: true) }
    }

    func setReversed(_ reversed: Bool, for clipID: UUID) {
        performEdit { try $0.setReversed(reversed, for: clipID) }
    }

    func addEffect(_ kind: VideoEffectKind, to clipID: UUID) {
        performEdit { try $0.addEffect(VideoEffect(kind: kind), to: clipID) }
    }

    func removeEffect(_ effectID: UUID, from clipID: UUID) {
        performEdit { try $0.removeEffect(effectID, from: clipID) }
    }

    func applyFilterPreset(_ preset: QuickFilterPreset, to clipID: UUID) {
        updateClip(clipID) { clip in
            clip.colorAdjustments = preset.adjustments
            clip.effects = preset.effects
        }
    }

    func copySelectedClipProperties() {
        guard let selectedClip else { return }
        copiedClipProperties = ClipPropertyBundle(clip: selectedClip)
        canPasteClipProperties = true
    }

    func pasteClipProperties() {
        guard let copiedClipProperties, !selectedClipIDs.isEmpty else { return }
        performEdit { try $0.pasteProperties(copiedClipProperties, to: selectedClipIDs) }
    }

    func setTransition(_ kind: TransitionKind?, edge: TransitionEdge, for clipID: UUID) {
        performEdit { editor in
            let clip = editor.project.timeline.tracks.flatMap(\.clips).first { $0.id == clipID }
            let current = edge == .in ? clip?.transitionIn : clip?.transitionOut
            let transition = kind.map { ClipTransition(kind: $0, duration: current?.duration ?? RationalTime(value: 1, timescale: 2)) }
            try editor.setTransition(transition, edge: edge, for: clipID)
        }
    }

    func addKeyframe(_ property: KeyframedProperty, for clipID: UUID) {
        guard let clip = project?.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { return }
        let localTime = (playback.currentTime - clip.timelineStart).clamped(to: .zero...clip.duration)
        let value: Double
        switch property {
        case .positionX: value = clip.transform.positionX
        case .positionY: value = clip.transform.positionY
        case .scale: value = clip.transform.scale
        case .rotationDegrees: value = clip.transform.rotationDegrees
        case .opacity: value = clip.opacity
        case .volume: value = clip.audioVolume
        }
        performEdit { try $0.setKeyframe(property, ScalarKeyframe(time: localTime, value: value), for: clipID) }
    }

    func normalizeAudio(for clipID: UUID) async {
        guard let project,
              let clip = project.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID }),
              let assetID = clip.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        isNormalizingAudio = true
        defer { isNormalizingAudio = false }
        do {
            let url = try await accessManager.resolve(asset.reference)
            let sourceDuration = RationalTime(
                seconds: clip.duration.seconds * clip.playbackRate,
                preferredTimescale: 60_000
            )
            let result = try await audioAnalysis.normalization(
                url: url,
                sourceStart: clip.sourceStart,
                sourceDuration: sourceDuration
            )
            updateClip(clipID) { $0.audioVolume = result.linearGain }
        } catch {
            present(error, messageKey: "error.audio.normalize")
        }
    }

    func toggleVoiceoverRecording() async {
        if isRecordingVoiceover {
            await finishVoiceover()
            return
        }
        guard project != nil else { return }
        if playback.isPlaying { playback.togglePlayback() }
        voiceoverStart = playback.currentTime
        do {
            try await voiceoverRecorder.start()
            isRecordingVoiceover = true
        } catch {
            present(error, messageKey: "error.voiceover.start")
        }
    }

    func detectSilence(for clipID: UUID) async {
        guard let project,
              let clip = project.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID }),
              let assetID = clip.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        isDetectingSilence = true
        defer { isDetectingSilence = false }
        do {
            let url = try await accessManager.resolve(asset.reference)
            let sourceDuration = RationalTime(
                seconds: clip.duration.seconds * clip.playbackRate,
                preferredTimescale: 60_000
            )
            let sourceRanges = try await silenceDetection.detect(
                url: url,
                sourceStart: clip.sourceStart,
                sourceDuration: sourceDuration
            )
            let sourceEnd = clip.sourceStart + sourceDuration
            let timelineRanges = sourceRanges.map { range -> RationalTimeRange in
                let offset: RationalTime
                if clip.isReversed { offset = sourceEnd - range.end }
                else { offset = range.start - clip.sourceStart }
                return RationalTimeRange(
                    start: clip.timelineStart + RationalTime(
                        seconds: offset.seconds / clip.playbackRate,
                        preferredTimescale: 60_000
                    ),
                    duration: RationalTime(
                        seconds: range.duration.seconds / clip.playbackRate,
                        preferredTimescale: 60_000
                    )
                )
            }
            guard !timelineRanges.isEmpty else { throw SilenceDetectionError.noAudio }
            pendingSilenceRemoval = SilenceRemovalProposal(clipID: clipID, ranges: timelineRanges)
        } catch {
            present(error, messageKey: "error.silence.detect")
        }
    }

    func applySilenceRemoval() {
        guard let proposal = pendingSilenceRemoval else { return }
        performEdit { try $0.removeTimelineRanges(proposal.ranges) }
        pendingSilenceRemoval = nil
    }

    func detectBeats(for clipID: UUID) async {
        guard let project,
              let clip = project.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID }),
              let assetID = clip.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        isDetectingBeats = true
        defer { isDetectingBeats = false }
        do {
            let url = try await accessManager.resolve(asset.reference)
            let sourceDuration = RationalTime(
                seconds: clip.duration.seconds * clip.playbackRate,
                preferredTimescale: 60_000
            )
            let sourceOffsets = try await beatDetection.detect(
                url: url,
                sourceStart: clip.sourceStart,
                sourceDuration: sourceDuration
            )
            let timelineTimes = sourceOffsets.compactMap { offset -> RationalTime? in
                let sourceOffset = clip.isReversed ? sourceDuration - offset : offset
                let local = RationalTime(
                    seconds: sourceOffset.seconds / clip.playbackRate,
                    preferredTimescale: 60_000
                )
                guard local >= .zero, local <= clip.duration else { return nil }
                return clip.timelineStart + local
            }
            guard !timelineTimes.isEmpty else { throw BeatDetectionError.noBeats }
            performEdit {
                _ = try $0.addMarkers(at: timelineTimes, namePrefix: String(localized: "beat.marker_name"))
            }
        } catch {
            present(error, messageKey: "error.beat.detect")
        }
    }

    func createFreezeFrame(for clipID: UUID) async {
        guard let project,
              let clip = project.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID }),
              clip.kind == .video,
              let assetID = clip.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }),
              let track = project.timeline.tracks.first(where: { $0.clips.contains { $0.id == clipID } }) else { return }
        isCreatingFreezeFrame = true
        defer { isCreatingFreezeFrame = false }
        do {
            let sourceURL = try await accessManager.resolve(asset.reference)
            let localTime = (playback.currentTime - clip.timelineStart).clamped(to: .zero...clip.duration)
            let sourceDuration = RationalTime(
                seconds: clip.duration.seconds * clip.playbackRate,
                preferredTimescale: 60_000
            )
            var sourceOffset: RationalTime
            if clip.isReversed {
                let oneFrame = project.frameRate.value.frameDuration
                sourceOffset = max(
                    sourceDuration - RationalTime(
                        seconds: localTime.seconds * clip.playbackRate,
                        preferredTimescale: 60_000
                    ) - oneFrame,
                    .zero
                )
            } else {
                sourceOffset = RationalTime(
                    seconds: localTime.seconds * clip.playbackRate,
                    preferredTimescale: 60_000
                )
            }
            sourceOffset = min(
                sourceOffset,
                max(sourceDuration - project.frameRate.value.frameDuration, .zero)
            )
            let imageURL = try await freezeFrameService.create(
                url: sourceURL,
                sourceTime: (clip.sourceStart + sourceOffset).cmTime
            )
            let inspection = try await inspector.inspect(url: imageURL)
            let freezeAsset = MediaAsset(
                displayName: String(localized: "freeze.asset_name"),
                kind: .image,
                reference: MediaReference(lastKnownPath: imageURL.path),
                metadata: inspection.metadata
            )
            let freezeDuration = RationalTime(value: 2, timescale: 1)
            let insertionTime = clip.timelineStart + localTime
            let freezeClip = TimelineClip(
                name: freezeAsset.displayName,
                kind: .image,
                assetID: freezeAsset.id,
                timelineStart: insertionTime,
                duration: freezeDuration,
                transform: clip.transform,
                opacity: clip.opacity,
                colorAdjustments: clip.colorAdjustments,
                effects: clip.effects
            )
            performEdit { editor in
                try editor.addAsset(freezeAsset)
                try editor.insertEdit(freezeClip, into: track.id, at: insertionTime)
            }
            selectedClipIDs = [freezeClip.id]
        } catch {
            present(error, messageKey: "error.freeze.create")
        }
    }

    func consolidateProjectMedia() async {
        guard let project, let packageURL = projectURL else {
            present(ProjectMediaConsolidationError.projectMustBeSaved, messageKey: "error.media.consolidate_save")
            return
        }
        consolidationProgress = 0
        defer { consolidationProgress = nil }
        do {
            var replacements: [MediaAsset] = []
            replacements.reserveCapacity(project.assets.count)
            for (index, asset) in project.assets.enumerated() {
                try Task.checkCancellation()
                let source = try await accessManager.resolve(asset.reference)
                var replacement = asset
                replacement.reference = try await mediaConsolidator.copy(
                    asset: asset,
                    from: source,
                    into: packageURL
                )
                replacements.append(replacement)
                consolidationProgress = Double(index + 1) / Double(max(project.assets.count, 1))
            }
            performEdit { try $0.replaceAssets(replacements) }
            await accessManager.setProjectPackageURL(packageURL)
            _ = await save()
        } catch {
            present(error, messageKey: "error.media.consolidate")
        }
    }

    private func finishVoiceover() async {
        do {
            let url = try voiceoverRecorder.stop()
            isRecordingVoiceover = false
            let inspection = try await inspector.inspect(url: url)
            guard let duration = inspection.metadata.duration, duration > .zero else {
                throw VoiceoverError.cannotRecord
            }
            let asset = MediaAsset(
                displayName: String(localized: "voiceover.name"),
                kind: .audio,
                reference: MediaReference(
                    lastKnownPath: url.path,
                    sourceModificationDate: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                ),
                metadata: inspection.metadata
            )
            var clipID: UUID?
            performEdit { editor in
                try editor.addAsset(asset)
                let voiceoverNumber = editor.project.timeline.tracks.filter { $0.kind == .audio }.count + 1
                let trackID = try editor.addTrack(name: "VO\(voiceoverNumber)", kind: .audio)
                let clip = TimelineClip(
                    name: asset.displayName,
                    kind: .audio,
                    assetID: asset.id,
                    timelineStart: voiceoverStart,
                    duration: duration,
                    role: .voiceover
                )
                try editor.insert(clip, into: trackID)
                clipID = clip.id
            }
            scheduleWaveform(for: asset)
            if let clipID { selectedClipIDs = [clipID] }
        } catch {
            isRecordingVoiceover = false
            present(error, messageKey: "error.voiceover.finish")
        }
    }

    func generateAutomaticCaptions(for assetID: UUID) async {
        guard let project, let asset = project.assets.first(where: { $0.id == assetID }), asset.metadata.hasAudio else {
            present(TranscriptionError.noSpeechDetected, messageKey: "error.captions.no_audio")
            return
        }
        isGeneratingCaptions = true
        defer { isGeneratingCaptions = false }
        do {
            let url = try await accessManager.resolve(asset.reference)
            let sourceCues = try await transcriptionService.transcribe(url: url)
            let cues = mappedCaptions(sourceCues, assetID: assetID, in: project)
            var newIDs: [UUID] = []
            performEdit { editor in
                let trackID = try editor.addTrack(
                    name: String(localized: "captions.track_name"),
                    kind: .video,
                    at: 0
                )
                newIDs = try editor.addSubtitles(cues, to: trackID)
            }
            selectedClipIDs = Set(newIDs)
        } catch {
            present(error, messageKey: "error.captions.automatic")
        }
    }

    func importSubtitles(_ url: URL, format: SubtitleFormat) async {
        do {
            let cues = try await Task.detached(priority: .userInitiated) {
                let contents = try String(contentsOf: url, encoding: .utf8)
                return try SubtitleParser.parse(contents, format: format)
            }.value
            var newIDs: [UUID] = []
            performEdit { editor in
                let trackID = try editor.addTrack(name: String(localized: "captions.track_name"), kind: .video, at: 0)
                newIDs = try editor.addSubtitles(cues, to: trackID)
            }
            selectedClipIDs = Set(newIDs)
        } catch {
            present(error, messageKey: "error.captions.import")
        }
    }

    func exportSubtitles(to url: URL, format: SubtitleFormat) async {
        guard let project else { return }
        let cues = project.timeline.tracks.flatMap(\.clips)
            .filter { $0.role == .subtitle }
            .compactMap { clip -> SubtitleCue? in
                guard let text = clip.textStyle?.text else { return nil }
                return SubtitleCue(start: clip.timelineStart, duration: clip.duration, text: text)
            }
        do {
            let contents = SubtitleParser.serialize(cues, format: format)
            try await Task.detached(priority: .utility) {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch {
            present(error, messageKey: "error.captions.export")
        }
    }

    func setTrackMuted(_ id: UUID, muted: Bool) {
        performEdit { try $0.setTrackMuted(id, muted: muted) }
    }

    func setTrackLocked(_ id: UUID, locked: Bool) {
        performEdit { try $0.setTrackLocked(id, locked: locked) }
    }

    func undo() {
        guard let project, let previous = history.undo(current: project) else { return }
        restoreHistoryState(previous)
    }

    func redo() {
        guard let project, let next = history.redo(current: project) else { return }
        restoreHistoryState(next)
    }

    func nudgePlayhead(frames: Int) {
        guard let project else { return }
        playback.seek(to: playback.currentTime + project.frameRate.value.frameDuration * Int64(frames))
    }

    func goToStart() { playback.seek(to: .zero) }
    func goToEnd() { playback.seek(to: project?.timeline.duration ?? .zero) }
    func zoomIn() { timelineZoom = min(timelineZoom * 1.25, 500) }
    func zoomOut() { timelineZoom = max(timelineZoom / 1.25, 12) }

    func snap(_ time: RationalTime, excluding id: UUID) -> RationalTime {
        guard let editor else { return max(time, .zero) }
        let threshold = RationalTime(seconds: 8 / timelineZoom, preferredTimescale: 6_000)
        return editor.snappedTime(
            proposed: max(time, .zero),
            playhead: playback.currentTime,
            excluding: id,
            threshold: threshold
        ).time
    }

    func thumbnail(for asset: MediaAsset, width: Int, height: Int) async -> CGImage? {
        do {
            let url = try await accessManager.resolve(asset.reference)
            return try await thumbnailGenerator.thumbnail(
                for: ThumbnailRequest(assetID: asset.id, time: .zero, pixelWidth: width, pixelHeight: height),
                url: url
            ).cgImage
        } catch {
            return nil
        }
    }

    func prepareExport() async -> RenderedComposition? {
        guard let project else { return nil }
        do {
            let rendered = try await compositionBuilder.build(project: project, purpose: .export)
            renderedComposition = rendered
            return rendered
        } catch {
            present(error, messageKey: "error.preview.build")
            return nil
        }
    }

    func export(
        rendered: RenderedComposition,
        plan: ExportPlan,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        try await exportService.export(
            rendered: rendered,
            plan: plan,
            destination: destination,
            progress: progress
        )
    }

    func cancelExport() async { await exportService.cancel() }

    func clearCache() async throws {
        await compositionBuilder.clearCaches()
        await thumbnailGenerator.clearCache()
        await waveformGenerator.clearCache()
        await inspector.clearCache()
        try await cache.clear()
        try await MediaDerivativeStore.shared.clear()
    }

    func generateProxy(for assetID: UUID) async {
        guard let asset = project?.assets.first(where: { $0.id == assetID }), asset.kind == .video else { return }
        proxyProgress[assetID] = 0
        do {
            let sourceURL = try await accessManager.resolve(asset.reference)
            let proxyURL = try await proxyService.generate(url: sourceURL) { [weak self] value in
                Task { @MainActor in self?.proxyProgress[assetID] = value }
            }
            var updated = asset
            updated.proxyReference = MediaReference(lastKnownPath: proxyURL.path)
            performEdit { try $0.replaceAsset(updated) }
            proxyProgress.removeValue(forKey: assetID)
        } catch {
            proxyProgress.removeValue(forKey: assetID)
            present(error, messageKey: "error.proxy.generate")
        }
    }

    func cacheSize() async throws -> Int64 {
        let derived = try await cache.size()
        let media = try await MediaDerivativeStore.shared.size()
        return derived + media
    }
    func diagnosticEvents() async -> [DiagnosticEvent] { await LocalDiagnostics.shared.recentEvents() }

    private func install(_ project: CineleafProject, url: URL?) {
        do {
            editor = try ProjectEditor(project: project)
            self.project = project
            projectURL = url
            selectedClipIDs = []
            selectedAssetID = nil
            copiedClipProperties = nil
            canPasteClipProperties = false
            history.reset()
            isDirty = false
        } catch {
            present(error, messageKey: "error.project.invalid")
        }
    }

    private func performEdit(_ operation: (inout ProjectEditor) throws -> Void) {
        guard var editor, let before = project else { return }
        do {
            try operation(&editor)
            history.record(before)
            self.editor = editor
            project = editor.project
            isDirty = true
            scheduleAutosave()
            schedulePreviewRebuild()
        } catch {
            present(error, messageKey: "error.timeline.edit")
        }
    }

    private func restoreHistoryState(_ state: CineleafProject) {
        do {
            editor = try ProjectEditor(project: state)
            project = state
            isDirty = true
            selectedClipIDs = Set(selectedClipIDs.filter { id in
                state.timeline.tracks.flatMap(\.clips).contains { $0.id == id }
            })
            scheduleAutosave()
            schedulePreviewRebuild()
        } catch {
            present(error, messageKey: "error.history.restore")
        }
    }

    private func mappedCaptions(
        _ sourceCues: [SubtitleCue],
        assetID: UUID,
        in project: CineleafProject
    ) -> [SubtitleCue] {
        guard let clip = project.timeline.tracks.flatMap(\.clips).first(where: { $0.assetID == assetID }),
              !clip.isReversed else {
            return sourceCues.map { cue in
                SubtitleCue(
                    start: playback.currentTime + cue.start,
                    duration: cue.duration,
                    text: cue.text
                )
            }
        }
        let sourceEnd = clip.sourceStart + RationalTime(
            seconds: clip.duration.seconds * clip.playbackRate,
            preferredTimescale: 60_000
        )
        return sourceCues.compactMap { cue in
            guard cue.start + cue.duration > clip.sourceStart, cue.start < sourceEnd else { return nil }
            let startOffset = max(cue.start, clip.sourceStart) - clip.sourceStart
            let endOffset = min(cue.start + cue.duration, sourceEnd) - clip.sourceStart
            return SubtitleCue(
                start: clip.timelineStart + RationalTime(
                    seconds: startOffset.seconds / clip.playbackRate,
                    preferredTimescale: 60_000
                ),
                duration: RationalTime(
                    seconds: (endOffset - startOffset).seconds / clip.playbackRate,
                    preferredTimescale: 60_000
                ),
                text: cue.text
            )
        }
    }

    private func scheduleAutosave() {
        guard !isUITesting, let project else { return }
        let url = projectURL
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                try await LocalDiagnostics.shared.measure("autosave") {
                    if let url {
                        try await self.store.save(project, to: url)
                    } else {
                        try await self.store.saveRecovery(project)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.present(error, messageKey: "error.autosave")
            }
        }
    }

    private func schedulePreviewRebuild() {
        guard let project, project.timeline.duration > .zero else {
            renderedComposition = nil
            playback.stop()
            return
        }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            self.isBuildingPreview = true
            defer { self.isBuildingPreview = false }
            do {
                try await Task.sleep(for: .milliseconds(150))
                let rendered = try await self.compositionBuilder.build(project: project)
                guard !Task.isCancelled, self.project?.modifiedAt == rendered.revision else { return }
                self.renderedComposition = rendered
                self.playback.load(rendered)
            } catch is CancellationError {
                return
            } catch CompositionError.emptyTimeline {
                return
            } catch {
                self.present(error, messageKey: "error.preview.build")
            }
        }
    }

    private func scheduleAllWaveforms() {
        guard let project else { return }
        project.assets.forEach(scheduleWaveform)
    }

    private func scheduleWaveform(for asset: MediaAsset) {
        guard asset.kind == .audio || asset.metadata.hasAudio else { return }
        waveformTasks[asset.id]?.cancel()
        waveformTasks[asset.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.accessManager.resolve(asset.reference)
                let peaks = try await self.waveformGenerator.waveform(
                    for: WaveformRequest(assetID: asset.id, sampleCount: 600),
                    url: url
                )
                guard !Task.isCancelled else { return }
                self.waveforms[asset.id] = peaks
            } catch is CancellationError {
                return
            } catch {
                self.present(error, messageKey: "error.waveform.generate")
            }
        }
    }

    private func updateMediaAvailability() async {
        guard let project else { return }
        var values: [UUID: MediaAvailability] = [:]
        for asset in project.assets {
            do {
                _ = try await accessManager.resolve(asset.reference)
                values[asset.id] = .available
            } catch {
                values[asset.id] = .missing(lastKnownPath: asset.reference.lastKnownPath)
            }
        }
        mediaAvailability = values
    }

    private func present(_ error: Error, messageKey: String) {
        presentedError = PresentedError(
            titleKey: "error.title",
            messageKey: messageKey,
            technicalDetail: String(describing: error)
        )
    }
}
