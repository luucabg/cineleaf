using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Cineleaf.Core;

namespace Cineleaf.Media;

public sealed class ThumbnailService(FfmpegToolchain toolchain, string cacheDirectory)
{
    public async Task<string> GenerateAsync(string mediaPath, TimeSpan time, int width, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(cacheDirectory);
        var identity = $"{Path.GetFullPath(mediaPath)}|{File.GetLastWriteTimeUtc(mediaPath).Ticks}|{time.TotalMilliseconds:0}|{width}";
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();
        var output = Path.Combine(cacheDirectory, $"{key}.jpg");
        if (File.Exists(output)) return output;
        var temporary = output + ".tmp.jpg";
        try
        {
            await MediaProcessRunner.RunAsync(toolchain.FfmpegPath,
            [
                "-hide_banner", "-loglevel", "error", "-y", "-ss", time.TotalSeconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture),
                "-i", mediaPath, "-frames:v", "1", "-vf", $"scale={Math.Max(16, width)}:-2", "-q:v", "4", temporary
            ], cancellationToken: cancellationToken).ConfigureAwait(false);
            File.Move(temporary, output, overwrite: true);
            return output;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public sealed class WaveformService(FfmpegToolchain toolchain)
{
    public async Task<IReadOnlyList<float>> GenerateAsync(string mediaPath, CancellationToken cancellationToken = default)
    {
        var info = MediaProcessRunner.CreateStartInfo(toolchain.FfmpegPath,
        [
            "-hide_banner", "-loglevel", "error", "-i", mediaPath, "-vn", "-ac", "1", "-ar", "8000", "-f", "f32le", "pipe:1"
        ]);
        using var process = new Process { StartInfo = info };
        if (!process.Start()) throw new InvalidOperationException("Could not start audio analysis.");
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
        });
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        var peaks = new List<float>();
        var buffer = new byte[4 * 800];
        while (await process.StandardOutput.BaseStream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false) is var count && count > 0)
        {
            var peak = 0f;
            for (var index = 0; index + 3 < count; index += 4)
                peak = Math.Max(peak, Math.Abs(BitConverter.ToSingle(buffer, index)));
            peaks.Add(Math.Clamp(peak, 0, 1));
        }
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        var error = await errorTask.ConfigureAwait(false);
        if (process.ExitCode != 0) throw new MediaProcessException(toolchain.FfmpegPath, process.ExitCode, error);
        return Downsample(peaks, 5_000);
    }

    private static IReadOnlyList<float> Downsample(List<float> values, int maximum)
    {
        if (values.Count <= maximum) return values;
        var result = new float[maximum];
        for (var bucket = 0; bucket < maximum; bucket++)
        {
            var start = (int)((long)bucket * values.Count / maximum);
            var end = Math.Max(start + 1, (int)((long)(bucket + 1) * values.Count / maximum));
            var peak = 0f;
            for (var index = start; index < end; index++) peak = Math.Max(peak, values[index]);
            result[bucket] = peak;
        }
        return result;
    }
}

public sealed record AudioExtractionResult(string Path, double DurationSeconds, bool HasAudio, string Format);
public sealed record FrameExtractionResult(string Path, int Width, int Height, double AtSeconds);

public sealed class MediaUtilityService(FfmpegToolchain toolchain, MediaInspector inspector)
{
    public async Task<AudioExtractionResult> ExtractAudioAsync(
        string sourcePath,
        string destination,
        TimeSpan start,
        TimeSpan? duration,
        bool overwrite = false,
        CancellationToken cancellationToken = default)
    {
        sourcePath = Path.GetFullPath(sourcePath);
        destination = Path.GetFullPath(destination);
        if (string.Equals(sourcePath, destination, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The extracted audio cannot replace its source file.");
        if (!Path.GetExtension(destination).Equals(".m4a", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Extracted audio must use the .m4a extension.", nameof(destination));
        var metadata = await inspector.InspectAsync(sourcePath, cancellationToken).ConfigureAwait(false);
        if (!metadata.HasAudio) throw new InvalidOperationException("The source media does not contain an audio track.");
        ValidateRange(metadata.Duration?.Seconds, start.TotalSeconds, duration?.TotalSeconds);

        MediaMetadata? verified = null;
        await WriteAtomicallyAsync(destination, overwrite, async temporary =>
        {
            var arguments = new List<string> { "-hide_banner", "-loglevel", "error", "-y" };
            if (start > TimeSpan.Zero) { arguments.Add("-ss"); arguments.Add(F(start.TotalSeconds)); }
            arguments.Add("-i"); arguments.Add(sourcePath);
            if (duration is { } length) { arguments.Add("-t"); arguments.Add(F(length.TotalSeconds)); }
            arguments.AddRange(["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192000", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", temporary]);
            await MediaProcessRunner.RunAsync(toolchain.FfmpegPath, arguments, cancellationToken: cancellationToken).ConfigureAwait(false);
            verified = await inspector.InspectAsync(temporary, cancellationToken).ConfigureAwait(false);
            if (!verified.HasAudio || verified.Duration is null)
                throw new InvalidOperationException("The extracted audio could not be verified.");
        }, cancellationToken).ConfigureAwait(false);

        return new AudioExtractionResult(destination, verified!.Duration!.Value.Seconds, true, "m4a");
    }

    public async Task<FrameExtractionResult> ExtractFrameAsync(
        string sourcePath,
        string destination,
        TimeSpan at,
        bool overwrite = false,
        CancellationToken cancellationToken = default)
    {
        sourcePath = Path.GetFullPath(sourcePath);
        destination = Path.GetFullPath(destination);
        if (string.Equals(sourcePath, destination, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The extracted frame cannot replace its source file.");
        if (!Path.GetExtension(destination).Equals(".png", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Extracted frames must use the .png extension.", nameof(destination));
        var metadata = await inspector.InspectAsync(sourcePath, cancellationToken).ConfigureAwait(false);
        if (metadata.Resolution is null) throw new InvalidOperationException("The source media does not contain a video frame.");
        ValidateRange(metadata.Duration?.Seconds, at.TotalSeconds, null);

        Resolution? resolution = null;
        await WriteAtomicallyAsync(destination, overwrite, async temporary =>
        {
            await MediaProcessRunner.RunAsync(toolchain.FfmpegPath,
            [
                "-hide_banner", "-loglevel", "error", "-y", "-ss", F(at.TotalSeconds), "-i", sourcePath,
                "-map", "0:v:0", "-frames:v", "1", "-c:v", "png", temporary
            ], cancellationToken: cancellationToken).ConfigureAwait(false);
            var output = await inspector.InspectAsync(temporary, cancellationToken).ConfigureAwait(false);
            resolution = output.Resolution ?? throw new InvalidOperationException("The extracted frame could not be verified.");
        }, cancellationToken).ConfigureAwait(false);

        return new FrameExtractionResult(destination, resolution!.Width, resolution.Height, at.TotalSeconds);
    }

    private static async Task WriteAtomicallyAsync(
        string destination,
        bool overwrite,
        Func<string, Task> write,
        CancellationToken cancellationToken)
    {
        if (File.Exists(destination) && !overwrite) throw new IOException("The output file already exists.");
        var parent = Path.GetDirectoryName(destination) ?? throw new IOException("The output folder is invalid.");
        Directory.CreateDirectory(parent);
        var extension = Path.GetExtension(destination);
        var temporary = Path.Combine(parent, $".{Path.GetFileNameWithoutExtension(destination)}.tmp-{Guid.NewGuid():N}{extension}");
        var backup = destination + $".backup-{Guid.NewGuid():N}";
        var backedUp = false;
        try
        {
            await write(temporary).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (!File.Exists(temporary)) throw new IOException("The media engine did not create the output file.");
            if (File.Exists(destination)) { File.Move(destination, backup); backedUp = true; }
            File.Move(temporary, destination);
        }
        catch
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            if (backedUp && !File.Exists(destination)) File.Move(backup, destination);
            throw;
        }
        if (backedUp)
        {
            try { File.Delete(backup); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void ValidateRange(double? sourceDuration, double start, double? duration)
    {
        if (start < 0 || duration is <= 0) throw new ArgumentOutOfRangeException(nameof(start));
        if (sourceDuration is { } available && (start >= available || duration is { } length && start + length > available + 0.0001))
            throw new ArgumentOutOfRangeException(nameof(duration), "The requested range is outside the source media.");
    }

    private static string F(double value) => value.ToString("0.######", System.Globalization.CultureInfo.InvariantCulture);
}
