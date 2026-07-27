import Foundation
import Darwin
import CineleafCore

private struct Envelope<T: Encodable>: Encodable {
    var ok = true
    var data: T
}

private struct ErrorEnvelope: Encodable {
    struct Body: Encodable { var code: String; var message: String }
    var ok = false
    var error: Body
}

private struct Capabilities: Encodable {
    var protocolVersion = 1
    var platform = "macos"
    var commands = ["capabilities", "inspect-media", "validate-project", "render-project", "extract-audio", "extract-frame"]
    var codecs = ["h264", "hevc"]
    var resolutions = ["p720", "p1080", "p1440", "p2160"]
    var maxBatchSize = 32
    var maxBatchConcurrency = 4
}

private struct ValidationResult: Encodable {
    var valid = true
    var projectId: UUID
    var name: String
    var assetCount: Int
    var clipCount: Int
    var durationSeconds: Double
}

private struct InspectionResult: Encodable {
    var kind: String
    var durationSeconds: Double?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var hasAudio: Bool
    var fileType: String
    var fileSize: Int64
}

private struct RenderResultBody: Encodable {
    var path: String
    var durationSeconds: Double
    var width: Int
    var height: Int
    var hasAudio: Bool
    var encoder: String
}

private struct AudioExtractionBody: Encodable {
    var path: String
    var durationSeconds: Double
    var hasAudio: Bool
    var format = "m4a"
}

private struct FrameExtractionBody: Encodable {
    var path: String
    var width: Int
    var height: Int
    var atSeconds: Double
}

@main
enum CineleafAutomationCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let command = arguments.first ?? "capabilities"
            switch command {
            case "capabilities" where arguments.count <= 1:
                try write(Envelope(data: Capabilities()))
            case "inspect-media" where arguments.count == 2:
                try await inspect(path: arguments[1])
            case "validate-project" where arguments.count == 2:
                try await validate(path: arguments[1])
            case "render-project" where arguments.count == 6:
                try await render(arguments: arguments)
            case "extract-audio" where arguments.count == 5:
                try await extractAudio(arguments: arguments)
            case "extract-frame" where arguments.count == 4:
                try await extractFrame(arguments: arguments)
            default:
                throw CLIError.invalidArguments
            }
        } catch {
            try? write(ErrorEnvelope(error: .init(code: code(for: error), message: message(for: error))))
            Darwin.exit(error is CancellationError ? 2 : 1)
        }
    }

    private static func inspect(path: String) async throws {
        let inspection = try await AVMediaInspector().inspect(url: URL(fileURLWithPath: path).standardizedFileURL)
        try write(Envelope(data: InspectionResult(
            kind: inspection.kind.rawValue,
            durationSeconds: inspection.metadata.duration?.seconds,
            width: inspection.metadata.resolution?.width,
            height: inspection.metadata.resolution?.height,
            frameRate: inspection.metadata.frameRate?.framesPerSecond,
            hasAudio: inspection.metadata.hasAudio,
            fileType: inspection.metadata.fileType,
            fileSize: inspection.metadata.fileSize
        )))
    }

    private static func validate(path: String) async throws {
        let project = try await ProjectPackageStore().open(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        try ProjectValidator.validate(project)
        try write(Envelope(data: ValidationResult(
            projectId: project.id,
            name: project.name,
            assetCount: project.assets.count,
            clipCount: project.timeline.tracks.reduce(0) { $0 + $1.clips.count },
            durationSeconds: project.timeline.duration.seconds
        )))
    }

    private static func render(arguments: [String]) async throws {
        let projectURL = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let destination = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard let resolution = ExportResolutionPreset(rawValue: arguments[3]),
              let codec = ExportCodec(rawValue: arguments[4]),
              let quality = ExportQuality(rawValue: arguments[5]) else { throw CLIError.invalidArguments }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var project = try await ProjectPackageStore().open(projectURL)
        let preferences = ExportPreferences(
            resolution: resolution,
            frameRate: project.frameRate,
            quality: quality,
            codec: codec,
            container: .mp4
        )
        project.exportPreferences = preferences
        let access = MediaAccessManager()
        await access.setProjectPackageURL(projectURL)
        let result: ExportResult
        do {
            let rendered = try await AVCompositionBuilder(accessManager: access).build(project: project, purpose: .export)
            let plan = try ExportPlan(filename: destination.lastPathComponent, project: project, preferences: preferences)
            result = try await AVExportService().export(rendered: rendered, plan: plan, destination: destination) { progress in
                writeProgress(progress)
            }
            await access.releaseAll()
        } catch {
            await access.releaseAll()
            throw error
        }
        try write(Envelope(data: RenderResultBody(
            path: result.url.path,
            durationSeconds: result.duration.seconds,
            width: result.resolution.width,
            height: result.resolution.height,
            hasAudio: result.hasAudio,
            encoder: codec.rawValue
        )))
    }

    private static func extractAudio(arguments: [String]) async throws {
        guard let start = Double(arguments[3]), start >= 0 else { throw CLIError.invalidArguments }
        let duration: Double?
        if arguments[4].lowercased() == "all" { duration = nil }
        else if let parsed = Double(arguments[4]), parsed > 0 { duration = parsed }
        else { throw CLIError.invalidArguments }
        let result = try await MediaUtilityService().extractAudio(
            from: URL(fileURLWithPath: arguments[1]),
            to: URL(fileURLWithPath: arguments[2]),
            start: RationalTime(seconds: start, preferredTimescale: 60_000),
            duration: duration.map { RationalTime(seconds: $0, preferredTimescale: 60_000) }
        )
        try write(Envelope(data: AudioExtractionBody(
            path: result.url.path,
            durationSeconds: result.duration.seconds,
            hasAudio: result.hasAudio
        )))
    }

    private static func extractFrame(arguments: [String]) async throws {
        guard let time = Double(arguments[3]), time >= 0 else { throw CLIError.invalidArguments }
        let result = try await MediaUtilityService().extractFrame(
            from: URL(fileURLWithPath: arguments[1]),
            to: URL(fileURLWithPath: arguments[2]),
            at: RationalTime(seconds: time, preferredTimescale: 60_000)
        )
        try write(Envelope(data: FrameExtractionBody(
            path: result.url.path,
            width: result.resolution.width,
            height: result.resolution.height,
            atSeconds: result.at.seconds
        )))
    }

    private static func write<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeProgress(_ value: Double) {
        let line = "{\"type\":\"progress\",\"progress\":\(min(max(value, 0), 1))}\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func code(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if case CLIError.invalidArguments = error { return "invalid_arguments" }
        if let persistence = error as? ProjectPersistenceError {
            switch persistence {
            case .malformedDocument, .missingProjectFile, .unsupportedFutureVersion, .migrationFailed:
                return "invalid_project"
            default: break
            }
        }
        if (error as NSError).code == NSFileNoSuchFileError { return "file_not_found" }
        return "operation_failed"
    }

    private static func message(for error: Error) -> String {
        if case CLIError.invalidArguments = error {
            return "Usage: capabilities | inspect-media <path> | validate-project <project.cineleaf> | render-project <project.cineleaf> <output> <p720|p1080|p1440|p2160> <h264|hevc> <compact|balanced|high> | extract-audio <source> <output.m4a> <start-seconds> <duration-seconds|all> | extract-frame <source> <output.png> <at-seconds>"
        }
        return error.localizedDescription
    }
}

private enum CLIError: Error { case invalidArguments }
