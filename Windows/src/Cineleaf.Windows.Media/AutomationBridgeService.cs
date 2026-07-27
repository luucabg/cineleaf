using Cineleaf.Core;

namespace Cineleaf.Media;

public sealed record AutomationCapabilities(
    int ProtocolVersion,
    string Platform,
    IReadOnlyList<string> Commands,
    IReadOnlyList<string> Codecs,
    IReadOnlyList<string> Resolutions,
    int MaxBatchSize,
    int MaxBatchConcurrency);

public sealed record ProjectValidationResult(
    bool Valid,
    Guid ProjectId,
    string Name,
    int AssetCount,
    int ClipCount,
    double DurationSeconds);

public sealed record MediaInspectionResult(
    string Kind,
    double? DurationSeconds,
    int? Width,
    int? Height,
    double? FrameRate,
    bool HasAudio,
    string FileType,
    long FileSize);

public sealed class AutomationBridgeService(FfmpegToolchain? toolchain)
{
    public static AutomationCapabilities Capabilities() => new(
        1,
        "windows",
        ["capabilities", "inspect-media", "validate-project", "render-project"],
        ["h264", "hevc"],
        ["p720", "p1080", "p1440", "p2160"],
        32,
        4);

    public static async Task<ProjectValidationResult> ValidateProjectAsync(string packagePath, CancellationToken cancellationToken = default)
    {
        using var store = new ProjectPackageStore();
        var project = await store.OpenAsync(Path.GetFullPath(packagePath), cancellationToken).ConfigureAwait(false);
        ProjectValidator.Validate(project);
        return new ProjectValidationResult(
            true,
            project.Id,
            project.Name,
            project.Assets.Count,
            project.Timeline.Tracks.Sum(track => track.Clips.Count),
            project.Timeline.Duration.Seconds);
    }

    public async Task<MediaInspectionResult> InspectMediaAsync(string mediaPath, CancellationToken cancellationToken = default)
    {
        var activeToolchain = toolchain ?? throw new InvalidOperationException("FFmpeg tools are unavailable.");
        var metadata = await new MediaInspector(activeToolchain).InspectAsync(Path.GetFullPath(mediaPath), cancellationToken).ConfigureAwait(false);
        var kind = metadata.Resolution is not null ? (metadata.Duration is null ? "image" : "video") : "audio";
        return new MediaInspectionResult(
            kind,
            metadata.Duration?.Seconds,
            metadata.Resolution?.Width,
            metadata.Resolution?.Height,
            metadata.FrameRate?.FramesPerSecond,
            metadata.HasAudio,
            metadata.FileType,
            metadata.FileSize);
    }

    public async Task<RenderResult> RenderProjectAsync(
        string packagePath,
        string outputPath,
        ExportResolutionPreset resolution,
        ExportCodec codec,
        ExportQuality quality,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var activeToolchain = toolchain ?? throw new InvalidOperationException("FFmpeg tools are unavailable.");
        using var store = new ProjectPackageStore();
        var project = await store.OpenAsync(Path.GetFullPath(packagePath), cancellationToken).ConfigureAwait(false);
        var outputResolution = ResolutionFor(resolution, project.Canvas);
        var frameRate = project.FrameRate switch
        {
            ProjectFrameRate.Fps24 => 24,
            ProjectFrameRate.Fps25 => 25,
            ProjectFrameRate.Fps50 => 50,
            ProjectFrameRate.Fps60 => 60,
            _ => 30
        };
        var renderer = new FfmpegRenderService(activeToolchain, new EncoderProbeService(activeToolchain), new MediaInspector(activeToolchain));
        return await renderer.RenderAsync(
            new RenderRequest(project, Path.GetFullPath(outputPath), outputResolution, frameRate, codec, quality, Preview: false),
            progress,
            cancellationToken).ConfigureAwait(false);
    }

    private static Resolution ResolutionFor(ExportResolutionPreset preset, Resolution canvas)
    {
        var longEdge = preset switch
        {
            ExportResolutionPreset.P720 => 1280,
            ExportResolutionPreset.P1440 => 2560,
            ExportResolutionPreset.P2160 => 3840,
            _ => 1920
        };
        var ratio = (double)canvas.Width / canvas.Height;
        var landscape = canvas.Width >= canvas.Height;
        var width = landscape ? longEdge : (int)Math.Round(longEdge * ratio);
        var height = landscape ? (int)Math.Round(longEdge / ratio) : longEdge;
        return new Resolution(Math.Max(2, width / 2 * 2), Math.Max(2, height / 2 * 2));
    }
}
