using Cineleaf.Core;
using Cineleaf.Media;

namespace Cineleaf.Windows.Media.IntegrationTests;

public sealed class RenderIntegrationTests : IAsyncLifetime
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "CineleafMediaTests", Guid.NewGuid().ToString("N"));
    private readonly FfmpegToolchain _toolchain = FfmpegToolchain.Locate();

    public Task InitializeAsync()
    {
        Directory.CreateDirectory(_root);
        return Task.CompletedTask;
    }

    [Fact]
    public async Task ImportsRendersAndValidatesSyntheticTimeline()
    {
        var source = Path.Combine(_root, "source.mp4");
        await MediaProcessRunner.RunAsync(_toolchain.FfmpegPath,
        [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
            "-c:v", "libopenh264", "-b:v", "1000000", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source
        ]);
        var inspector = new MediaInspector(_toolchain);
        var metadata = await inspector.InspectAsync(source);
        var asset = new MediaAsset
        {
            DisplayName = "source.mp4",
            Kind = MediaKind.Video,
            Reference = new MediaReference { LastKnownPath = source },
            Metadata = metadata
        };
        var project = new CineleafProject
        {
            Name = "Integration",
            Assets = [asset],
            Canvas = new Resolution(640, 360),
            Timeline = new Timeline
            {
                Tracks =
                [
                    new TimelineTrack
                    {
                        Name = "V1", Kind = TrackKind.Video, Clips = [new TimelineClip
                        {
                            Name = "source", Kind = ClipKind.Video, AssetId = asset.Id,
                            Duration = new RationalTime(2, 1), Fades = new ClipFades { VideoIn = new RationalTime(1, 4) }
                        }]
                    },
                    new TimelineTrack { Name = "A1", Kind = TrackKind.Audio },
                    new TimelineTrack
                    {
                        Name = "Titles", Kind = TrackKind.Video, Clips = [new TimelineClip
                        {
                            Name = "Title", Kind = ClipKind.Text, TimelineStart = new RationalTime(1, 2),
                            Duration = new RationalTime(1, 1), TextStyle = new TextStyle { Text = "Cineleaf", FontSize = 40 }
                        }]
                    }
                ]
            }
        };
        var output = Path.Combine(_root, "export.mp4");
        using var probe = new EncoderProbeService(_toolchain);
        var renderer = new FfmpegRenderService(_toolchain, probe, inspector);

        var result = await renderer.RenderAsync(new RenderRequest(project, output, new Resolution(640, 360), 30,
            ExportCodec.H264, ExportQuality.Compact, Preview: false));

        Assert.True(File.Exists(output));
        Assert.Equal(new Resolution(640, 360), result.Resolution);
        Assert.InRange(result.Duration.Seconds, 1.9, 2.1);
        Assert.True(result.HasAudio);
        Assert.NotEmpty(result.Encoder);
    }

    [Fact]
    public async Task MediaProcessCancellationStopsWork()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
        var output = Path.Combine(_root, "cancelled.mp4");

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => MediaProcessRunner.RunAsync(_toolchain.FfmpegPath,
        [
            "-hide_banner", "-loglevel", "error", "-y", "-re", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=30",
            "-c:v", "libopenh264", output
        ], cancellationToken: cancellation.Token));
    }

    [Fact]
    public async Task ExtractsAndVerifiesAudioAndAnExactFrame()
    {
        var source = Path.Combine(_root, "utility-source.mp4");
        await MediaProcessRunner.RunAsync(_toolchain.FfmpegPath,
        [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-c:v", "libopenh264", "-b:v", "600000", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source
        ]);
        var inspector = new MediaInspector(_toolchain);
        var service = new MediaUtilityService(_toolchain, inspector);
        var audioPath = Path.Combine(_root, "extracted.m4a");
        var framePath = Path.Combine(_root, "frame.png");

        var audio = await service.ExtractAudioAsync(source, audioPath, TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1));
        var frame = await service.ExtractFrameAsync(source, framePath, TimeSpan.FromSeconds(1));

        Assert.True(audio.HasAudio);
        Assert.InRange(audio.DurationSeconds, 0.9, 1.1);
        Assert.Equal(320, frame.Width);
        Assert.Equal(180, frame.Height);
        Assert.True(File.Exists(audioPath));
        Assert.True(File.Exists(framePath));
    }

    public Task DisposeAsync()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
        return Task.CompletedTask;
    }
}
