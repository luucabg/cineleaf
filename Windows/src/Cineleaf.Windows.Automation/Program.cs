using System.Text.Json;
using System.Text.Json.Serialization;
using Cineleaf.Core;
using Cineleaf.Media;

var json = new JsonSerializerOptions
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
};
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };

try
{
    var command = args.FirstOrDefault() ?? "capabilities";
    var service = new AutomationBridgeService(command is "capabilities" or "validate-project" ? null : FindToolchain());
    object data = command switch
    {
        "capabilities" when args.Length == 1 || args.Length == 0 => AutomationBridgeService.Capabilities(),
        "inspect-media" when args.Length == 2 => await service.InspectMediaAsync(args[1], cancellation.Token),
        "validate-project" when args.Length == 2 => await AutomationBridgeService.ValidateProjectAsync(args[1], cancellation.Token),
        "render-project" when args.Length == 6 => await Render(service, args, cancellation.Token),
        _ => throw new ArgumentException("Usage: capabilities | inspect-media <path> | validate-project <project.cineleaf> | render-project <project.cineleaf> <output> <p720|p1080|p1440|p2160> <h264|hevc> <compact|balanced|high>")
    };
    Console.Out.WriteLine(JsonSerializer.Serialize(new { ok = true, data }, json));
    return 0;
}
catch (OperationCanceledException)
{
    Console.Out.WriteLine(JsonSerializer.Serialize(new { ok = false, error = new { code = "cancelled", message = "The operation was cancelled." } }, json));
    return 2;
}
catch (Exception error)
{
    Console.Out.WriteLine(JsonSerializer.Serialize(new { ok = false, error = new { code = ErrorCode(error), message = error.Message } }, json));
    return 1;
}

static async Task<RenderResult> Render(AutomationBridgeService service, string[] arguments, CancellationToken cancellationToken)
{
    var resolution = Parse<ExportResolutionPreset>(arguments[3]);
    var codec = Parse<ExportCodec>(arguments[4]);
    var quality = Parse<ExportQuality>(arguments[5]);
    var progress = new Progress<double>(value => Console.Error.WriteLine(JsonSerializer.Serialize(new { type = "progress", progress = value })));
    return await service.RenderProjectAsync(arguments[1], arguments[2], resolution, codec, quality, progress, cancellationToken);
}

static T Parse<T>(string value) where T : struct, Enum =>
    Enum.TryParse<T>(value, ignoreCase: true, out var parsed) ? parsed : throw new ArgumentException($"Unsupported {typeof(T).Name}: {value}.");

static FfmpegToolchain FindToolchain()
{
    var configured = Environment.GetEnvironmentVariable("CINELEAF_FFMPEG_DIR");
    var candidates = new[]
    {
        configured,
        Path.Combine(AppContext.BaseDirectory, "Tools"),
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Tools"))
    };
    foreach (var candidate in candidates.Where(item => !string.IsNullOrWhiteSpace(item)))
    {
        var ffmpeg = Path.Combine(candidate!, "ffmpeg.exe");
        var ffprobe = Path.Combine(candidate!, "ffprobe.exe");
        if (File.Exists(ffmpeg) && File.Exists(ffprobe)) return new FfmpegToolchain(ffmpeg, ffprobe);
    }
    throw new FileNotFoundException("Cineleaf could not find its bundled FFmpeg tools. Set CINELEAF_FFMPEG_DIR if running from source.");
}

static string ErrorCode(Exception error) => error switch
{
    FileNotFoundException => "file_not_found",
    ProjectFormatException or ProjectValidationException => "invalid_project",
    ArgumentException => "invalid_arguments",
    IOException => "io_error",
    _ => "operation_failed"
};
