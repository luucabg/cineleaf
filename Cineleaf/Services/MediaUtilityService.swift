import AVFoundation
import CineleafCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaUtilityError: LocalizedError {
    case invalidDestination
    case outputExists
    case outputMatchesSource
    case noAudio
    case noVideo
    case invalidRange
    case cannotCreateExporter
    case unsupportedOutput
    case cannotWriteFrame
    case outputValidationFailed

    var errorDescription: String? {
        switch self {
        case .invalidDestination: "The output folder is invalid."
        case .outputExists: "The output file already exists."
        case .outputMatchesSource: "The output cannot replace its source media."
        case .noAudio: "The source media does not contain an audio track."
        case .noVideo: "The source media does not contain a video frame."
        case .invalidRange: "The requested range is outside the source media."
        case .cannotCreateExporter: "The audio exporter is unavailable for this media."
        case .unsupportedOutput: "This system cannot create an M4A file from the selected media."
        case .cannotWriteFrame: "The PNG frame could not be written."
        case .outputValidationFailed: "The generated media could not be verified."
        }
    }
}

struct AudioExtractionResult: Sendable {
    var url: URL
    var duration: RationalTime
    var hasAudio: Bool
}

struct FrameExtractionResult: Sendable {
    var url: URL
    var resolution: Resolution
    var at: RationalTime
}

private final class MediaUtilityExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

actor MediaUtilityService {
    private var activeExport: AVAssetExportSession?

    func extractAudio(
        from source: URL,
        to destination: URL,
        start: RationalTime = .zero,
        duration requestedDuration: RationalTime? = nil,
        overwrite: Bool = false
    ) async throws -> AudioExtractionResult {
        try Task.checkCancellation()
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        try Self.validateDestination(destination, source: source, requiredExtension: "m4a", overwrite: overwrite)
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw MediaUtilityError.noAudio }
        let assetDuration = try await asset.load(.duration)
        let range = try Self.sourceRange(start: start, requestedDuration: requestedDuration, assetDuration: assetDuration)

        let composition = AVMutableComposition()
        var insertedAudio = false
        for sourceTrack in audioTracks {
            guard let target = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try target.insertTimeRange(range, of: sourceTrack, at: .zero)
            insertedAudio = true
        }
        guard insertedAudio,
              let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaUtilityError.cannotCreateExporter
        }
        guard session.supportedFileTypes.contains(.m4a) else { throw MediaUtilityError.unsupportedOutput }
        let temporary = try Self.temporaryOutput(for: destination)
        session.outputURL = temporary
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = true
        activeExport = session
        defer { activeExport = nil }
        do {
            try await Self.run(session)
            try Task.checkCancellation()
            let output = AVURLAsset(url: temporary)
            let outputDuration = try await output.load(.duration)
            let outputTracks = try await output.loadTracks(withMediaType: .audio)
            guard outputDuration.isNumeric, outputDuration > .zero, !outputTracks.isEmpty else {
                throw MediaUtilityError.outputValidationFailed
            }
            try Self.promote(temporary, to: destination, overwrite: overwrite)
            return AudioExtractionResult(url: destination, duration: RationalTime(outputDuration), hasAudio: true)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func extractFrame(
        from source: URL,
        to destination: URL,
        at time: RationalTime,
        overwrite: Bool = false
    ) async throws -> FrameExtractionResult {
        try Task.checkCancellation()
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        try Self.validateDestination(destination, source: source, requiredExtension: "png", overwrite: overwrite)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw MediaUtilityError.noVideo }
        let assetDuration = try await asset.load(.duration)
        if assetDuration.isNumeric, assetDuration > .zero {
            guard time >= .zero, time < RationalTime(assetDuration) else { throw MediaUtilityError.invalidRange }
        } else if time != .zero {
            throw MediaUtilityError.invalidRange
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time.cmTime).image
        try Task.checkCancellation()

        let temporary = try Self.temporaryOutput(for: destination)
        do {
            guard let writer = CGImageDestinationCreateWithURL(
                temporary as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { throw MediaUtilityError.cannotWriteFrame }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw MediaUtilityError.cannotWriteFrame }
            guard let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
                  CGImageSourceGetCount(source) == 1,
                  let verifiedImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  verifiedImage.width > 0,
                  verifiedImage.height > 0 else {
                throw MediaUtilityError.outputValidationFailed
            }
            try Self.promote(temporary, to: destination, overwrite: overwrite)
            return FrameExtractionResult(
                url: destination,
                resolution: Resolution(width: verifiedImage.width, height: verifiedImage.height),
                at: time
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func cancel() { activeExport?.cancelExport() }

    private static func run(_ session: AVAssetExportSession) async throws {
        let box = MediaUtilityExportBox(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.session.exportAsynchronously {
                    switch box.session.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .failed: continuation.resume(throwing: box.session.error ?? MediaUtilityError.outputValidationFailed)
                    default: continuation.resume(throwing: MediaUtilityError.outputValidationFailed)
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    private static func sourceRange(
        start: RationalTime,
        requestedDuration: RationalTime?,
        assetDuration: CMTime
    ) throws -> CMTimeRange {
        guard start >= .zero, assetDuration.isNumeric, assetDuration > .zero else { throw MediaUtilityError.invalidRange }
        let available = RationalTime(assetDuration)
        guard start < available else { throw MediaUtilityError.invalidRange }
        let duration = requestedDuration ?? (available - start)
        guard duration > .zero, start + duration <= available else { throw MediaUtilityError.invalidRange }
        return CMTimeRange(start: start.cmTime, duration: duration.cmTime)
    }

    private static func validateDestination(
        _ destination: URL,
        source: URL,
        requiredExtension: String,
        overwrite: Bool
    ) throws {
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == requiredExtension else {
            throw MediaUtilityError.invalidDestination
        }
        guard destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else {
            throw MediaUtilityError.outputMatchesSource
        }
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MediaUtilityError.invalidDestination
        }
        if FileManager.default.fileExists(atPath: destination.path), !overwrite { throw MediaUtilityError.outputExists }
    }

    private static func temporaryOutput(for destination: URL) throws -> URL {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).tmp-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        return temporary
    }

    private static func promote(_ temporary: URL, to destination: URL, overwrite: Bool) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: temporary.path) else { throw MediaUtilityError.outputValidationFailed }
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: temporary, to: destination)
            return
        }
        guard overwrite else { throw MediaUtilityError.outputExists }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).backup-\(UUID().uuidString)")
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            if !fileManager.fileExists(atPath: destination.path) { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }
}
