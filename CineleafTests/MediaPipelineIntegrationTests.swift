import AVFoundation
import CineleafCore
import XCTest
@testable import Cineleaf

final class MediaPipelineIntegrationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testSyntheticImportThumbnailAndWaveform() async throws {
        let videoURL = temporaryDirectory.appendingPathComponent("video.mov")
        let audioURL = temporaryDirectory.appendingPathComponent("audio.caf")
        try await SyntheticMediaFactory.makeVideo(at: videoURL)
        try SyntheticMediaFactory.makeAudio(at: audioURL)

        let inspector = AVMediaInspector()
        let video = try await inspector.inspect(url: videoURL)
        let audio = try await inspector.inspect(url: audioURL)
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.metadata.resolution, Resolution(width: 320, height: 180))
        XCTAssertEqual(audio.kind, .audio)

        let thumbnail = try await AVThumbnailGenerator().thumbnail(
            for: ThumbnailRequest(assetID: UUID(), time: .zero, pixelWidth: 160, pixelHeight: 90),
            url: videoURL
        )
        XCTAssertGreaterThan(thumbnail.cgImage.width, 0)
        XCTAssertGreaterThan(thumbnail.cgImage.height, 0)

        let peaks = try await AVWaveformGenerator().waveform(
            for: WaveformRequest(assetID: UUID(), sampleCount: 100),
            url: audioURL
        )
        XCTAssertEqual(peaks.count, 100)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0)
    }

    func testCompositionAndExportHaveExpectedTracksDurationAndDimensions() async throws {
        let videoURL = temporaryDirectory.appendingPathComponent("video.mov")
        let audioURL = temporaryDirectory.appendingPathComponent("audio.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("export.mp4")
        try await SyntheticMediaFactory.makeVideo(at: videoURL)
        try SyntheticMediaFactory.makeAudio(at: audioURL)

        let videoAsset = MediaAsset(
            displayName: "video.mov",
            kind: .video,
            reference: MediaReference(lastKnownPath: videoURL.path),
            metadata: MediaMetadata(
                duration: RationalTime(value: 1, timescale: 1),
                resolution: Resolution(width: 320, height: 180),
                frameRate: RationalRate(numerator: 30),
                fileType: "mov",
                hasAudio: false,
                fileSize: 1
            )
        )
        let audioAsset = MediaAsset(
            displayName: "audio.caf",
            kind: .audio,
            reference: MediaReference(lastKnownPath: audioURL.path),
            metadata: MediaMetadata(
                duration: RationalTime(value: 1, timescale: 1),
                fileType: "caf",
                hasAudio: true,
                fileSize: 1
            )
        )
        var project = CineleafProject(name: "Export")
        project.assets = [videoAsset, audioAsset]
        project.timeline.tracks[0].clips = [TimelineClip(
            name: videoAsset.displayName,
            kind: .video,
            assetID: videoAsset.id,
            timelineStart: .zero,
            duration: RationalTime(value: 1, timescale: 1)
        )]
        project.timeline.tracks[1].clips = [TimelineClip(
            name: audioAsset.displayName,
            kind: .audio,
            assetID: audioAsset.id,
            timelineStart: .zero,
            duration: RationalTime(value: 1, timescale: 1)
        )]

        let access = MediaAccessManager()
        let rendered = try await AVCompositionBuilder(accessManager: access).build(project: project)
        let preferences = ExportPreferences(resolution: .p720, frameRate: .fps30, quality: .high)
        let plan = try ExportPlan(filename: "export", project: project, preferences: preferences)
        let result = try await AVExportService().export(
            rendered: rendered,
            plan: plan,
            destination: outputURL,
            progress: { _ in }
        )

        XCTAssertTrue(result.hasVideo)
        XCTAssertTrue(result.hasAudio)
        XCTAssertEqual(result.resolution, Resolution(width: 1280, height: 720))
        XCTAssertEqual(result.duration.seconds, 1, accuracy: 0.08)
        await access.releaseAll()
    }

    func testCancelledWaveformDoesNotPublishResult() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("long-audio.caf")
        try SyntheticMediaFactory.makeAudio(at: audioURL, seconds: 10)
        let generator = AVWaveformGenerator()
        let task = Task {
            try await generator.waveform(
                for: WaveformRequest(assetID: UUID(), sampleCount: 10_000),
                url: audioURL
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testPlaybackRateAndReverseRenderWithoutChangingTimelineDuration() async throws {
        let videoURL = temporaryDirectory.appendingPathComponent("speed.mov")
        try await SyntheticMediaFactory.makeVideo(at: videoURL, seconds: 2)
        let asset = MediaAsset(
            displayName: "speed.mov",
            kind: .video,
            reference: MediaReference(lastKnownPath: videoURL.path),
            metadata: MediaMetadata(
                duration: RationalTime(value: 2, timescale: 1),
                resolution: Resolution(width: 320, height: 180),
                frameRate: RationalRate(numerator: 30),
                fileType: "mov",
                hasAudio: false,
                fileSize: 1
            )
        )
        var project = CineleafProject(name: "Speed", assets: [asset])
        project.timeline.tracks[0].clips = [TimelineClip(
            name: asset.displayName,
            kind: .video,
            assetID: asset.id,
            timelineStart: .zero,
            duration: RationalTime(value: 1, timescale: 1),
            playbackRate: 2,
            isReversed: true
        )]

        let access = MediaAccessManager()
        let rendered = try await AVCompositionBuilder(accessManager: access).build(project: project)

        XCTAssertEqual(rendered.composition.duration.seconds, 1, accuracy: 0.02)
        XCTAssertEqual(rendered.duration.seconds, 1, accuracy: 0.001)
        await access.releaseAll()
    }

    func testCoreImageEffectRendersThroughCustomCompositor() async throws {
        let videoURL = temporaryDirectory.appendingPathComponent("effect.mov")
        try await SyntheticMediaFactory.makeVideo(at: videoURL)
        let asset = MediaAsset(
            displayName: "effect.mov",
            kind: .video,
            reference: MediaReference(lastKnownPath: videoURL.path),
            metadata: MediaMetadata(
                duration: RationalTime(value: 1, timescale: 1),
                resolution: Resolution(width: 320, height: 180),
                frameRate: RationalRate(numerator: 30),
                fileType: "mov",
                hasAudio: false,
                fileSize: 1
            )
        )
        var project = CineleafProject(name: "Effect", assets: [asset])
        project.timeline.tracks[0].clips = [TimelineClip(
            name: asset.displayName,
            kind: .video,
            assetID: asset.id,
            timelineStart: .zero,
            duration: RationalTime(value: 1, timescale: 1),
            colorAdjustments: ColorAdjustments(exposure: 0.25, saturation: 0.7),
            effects: [VideoEffect(kind: .sepia, amount: 0.6)]
        )]

        let access = MediaAccessManager()
        let rendered = try await AVCompositionBuilder(accessManager: access).build(project: project)
        let generator = AVAssetImageGenerator(asset: rendered.composition)
        generator.videoComposition = try XCTUnwrap(rendered.videoComposition)
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image

        XCTAssertEqual(frame.width, project.canvas.width)
        XCTAssertEqual(frame.height, project.canvas.height)
        await access.releaseAll()
    }

    func testAudioNormalizationMeasuresAndCapsGain() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("normalize.caf")
        try SyntheticMediaFactory.makeAudio(at: audioURL)

        let result = try await AudioAnalysisService().normalization(
            url: audioURL,
            sourceStart: .zero,
            sourceDuration: RationalTime(value: 1, timescale: 1)
        )

        XCTAssertLessThan(result.rmsDecibels, 0)
        XCTAssertLessThanOrEqual(result.linearGain, 2)
        XCTAssertGreaterThan(result.linearGain, 0)
    }

    func testSilenceDetectionFindsLeadingSilenceWithoutLoadingWholeFile() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("silence.caf")
        try SyntheticMediaFactory.makeAudioWithLeadingSilence(at: audioURL)

        let ranges = try await SilenceDetectionService().detect(
            url: audioURL,
            sourceStart: .zero,
            sourceDuration: RationalTime(value: 2, timescale: 1)
        )

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start.seconds, 0, accuracy: 0.01)
        XCTAssertEqual(ranges[0].duration.seconds, 1, accuracy: 0.12)
    }

    func testBeatDetectionFindsLocalAudioPulses() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("beats.caf")
        try SyntheticMediaFactory.makeAudioWithBeats(at: audioURL)

        let beats = try await BeatDetectionService().detect(
            url: audioURL,
            sourceStart: .zero,
            sourceDuration: RationalTime(value: 2, timescale: 1)
        )

        XCTAssertEqual(beats.count, 3)
        XCTAssertEqual(beats[0].seconds, 0.5, accuracy: 0.08)
        XCTAssertEqual(beats[1].seconds, 1.0, accuracy: 0.08)
        XCTAssertEqual(beats[2].seconds, 1.5, accuracy: 0.08)
    }

    func testFreezeFrameCreatesARealImage() async throws {
        let videoURL = temporaryDirectory.appendingPathComponent("freeze.mov")
        let freezeDirectory = temporaryDirectory.appendingPathComponent("frames", isDirectory: true)
        try await SyntheticMediaFactory.makeVideo(at: videoURL)

        let imageURL = try await FreezeFrameService(directory: freezeDirectory).create(
            url: videoURL,
            sourceTime: CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        let inspection = try await AVMediaInspector().inspect(url: imageURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(inspection.kind, .image)
        XCTAssertEqual(inspection.metadata.resolution, Resolution(width: 320, height: 180))
    }

    func testMediaUtilitiesExtractVerifiedAudioAndFrameFiles() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("source.caf")
        let videoURL = temporaryDirectory.appendingPathComponent("source.mov")
        let extractedAudio = temporaryDirectory.appendingPathComponent("audio.m4a")
        let extractedFrame = temporaryDirectory.appendingPathComponent("frame.png")
        try SyntheticMediaFactory.makeAudio(at: audioURL)
        try await SyntheticMediaFactory.makeVideo(at: videoURL)
        let service = MediaUtilityService()

        let audio = try await service.extractAudio(from: audioURL, to: extractedAudio)
        let frame = try await service.extractFrame(
            from: videoURL,
            to: extractedFrame,
            at: RationalTime(value: 1, timescale: 2)
        )

        XCTAssertTrue(audio.hasAudio)
        XCTAssertEqual(audio.duration.seconds, 1, accuracy: 0.08)
        XCTAssertEqual(frame.resolution, Resolution(width: 320, height: 180))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFrame.path))
    }

    func testConsolidatedMediaResolvesRelativeToMovedProject() async throws {
        let source = temporaryDirectory.appendingPathComponent("source.dat")
        let originalPackage = temporaryDirectory.appendingPathComponent("Original.cineleaf", isDirectory: true)
        let movedPackage = temporaryDirectory.appendingPathComponent("Moved.cineleaf", isDirectory: true)
        try Data("cineleaf-media".utf8).write(to: source)
        try FileManager.default.createDirectory(at: originalPackage, withIntermediateDirectories: true)
        let asset = MediaAsset(
            displayName: "source.dat",
            kind: .audio,
            reference: MediaReference(lastKnownPath: source.path),
            metadata: MediaMetadata(fileType: "dat", hasAudio: true, fileSize: 14)
        )

        let reference = try await ProjectMediaConsolidator().copy(
            asset: asset,
            from: source,
            into: originalPackage
        )
        try FileManager.default.moveItem(at: originalPackage, to: movedPackage)
        let access = MediaAccessManager()
        await access.setProjectPackageURL(movedPackage)
        let resolved = try await access.resolve(reference)

        XCTAssertEqual(try Data(contentsOf: resolved), Data("cineleaf-media".utf8))
        XCTAssertTrue(resolved.path.hasPrefix(movedPackage.path))
        await access.releaseAll()
    }

    @MainActor
    func testSavedExportPresetPersistsAndCanBeDeleted() throws {
        let suite = "org.cineleaf.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ExportPreferences(
            resolution: .p2160,
            frameRate: .fps60,
            quality: .high,
            codec: .hevc,
            container: .mov
        )

        let store = ExportPresetStore(defaults: defaults)
        store.save(name: "Master", preferences: preferences)
        let reloaded = ExportPresetStore(defaults: defaults)

        XCTAssertEqual(reloaded.presets.first?.name, "Master")
        XCTAssertEqual(reloaded.presets.first?.preferences, preferences)
        reloaded.delete(try XCTUnwrap(reloaded.presets.first?.id))
        XCTAssertTrue(ExportPresetStore(defaults: defaults).presets.isEmpty)
    }
}
