using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows;
using Cineleaf.Core;
using Cineleaf.Media;

namespace Cineleaf.Windows;

public sealed class EditorViewModel : IDisposable
{
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
        { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp", ".tif", ".tiff" };
    private readonly FfmpegToolchain _toolchain;
    private readonly MediaInspector _inspector;
    private readonly EncoderProbeService _encoderProbe;
    private readonly FfmpegRenderService _renderer;
    private readonly PreviewCacheService _previewCache;
    private readonly OnDeviceCaptionService _captions;
    private readonly WaveformService _waveforms;
    private readonly MediaUtilityService _mediaUtilities;
    private readonly ProjectPackageStore _store = new();
    private ProjectEditor _editor;
    private CancellationTokenSource? _previewCancellation;
    private bool _isDirty;
    private bool _disposed;

    public EditorViewModel()
    {
        _toolchain = FfmpegToolchain.Locate();
        _inspector = new MediaInspector(_toolchain);
        _encoderProbe = new EncoderProbeService(_toolchain);
        _renderer = new FfmpegRenderService(_toolchain, _encoderProbe, _inspector);
        var cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cineleaf", "Cache");
        _previewCache = new PreviewCacheService(_renderer, Path.Combine(cache, "Preview"));
        _captions = new OnDeviceCaptionService(_toolchain);
        _waveforms = new WaveformService(_toolchain);
        _mediaUtilities = new MediaUtilityService(_toolchain, _inspector);
        _editor = new ProjectEditor(CreateProject("Untitled", CanvasPreset.Landscape16x9, ProjectFrameRate.Fps30));
        RefreshCollections();
    }

    public event EventHandler? ProjectChanged;
    public event EventHandler<string>? PreviewReady;
    public event EventHandler<Exception>? Error;
    public event EventHandler<string>? StatusChanged;
    public event EventHandler<double>? ProgressChanged;

    public CineleafProject Project => _editor.Project;
    public ObservableCollection<MediaAsset> Assets { get; } = [];
    public Guid? SelectedClipId { get; private set; }
    public MediaAsset? SelectedAsset { get; set; }
    public RationalTime Playhead { get; set; } = RationalTime.Zero;
    public string? ProjectPath { get; private set; }
    public bool IsDirty => _isDirty;

    public TimelineClip? SelectedClip => SelectedClipId is { } id
        ? Project.Timeline.Tracks.SelectMany(track => track.Clips).FirstOrDefault(clip => clip.Id == id) : null;

    public void NewProject(string name, CanvasPreset canvas, ProjectFrameRate frameRate)
    {
        _previewCancellation?.Cancel();
        _editor = new ProjectEditor(CreateProject(string.IsNullOrWhiteSpace(name) ? "Untitled" : name.Trim(), canvas, frameRate));
        ProjectPath = null;
        SelectedClipId = null;
        Playhead = RationalTime.Zero;
        _isDirty = false;
        NotifyProjectChanged(renderPreview: false);
    }

    public void UpdateProjectSettings(string name, CanvasPreset canvas, ProjectFrameRate frameRate)
    {
        _editor.UpdateProjectSettings(name, canvas, frameRate);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public async Task OpenAsync(string packagePath, CancellationToken cancellationToken = default)
    {
        SetStatus("Working");
        var project = await _store.OpenAsync(packagePath, cancellationToken);
        _previewCancellation?.Cancel();
        _editor = new ProjectEditor(project);
        ProjectPath = packagePath;
        SelectedClipId = null;
        Playhead = RationalTime.Zero;
        _isDirty = false;
        NotifyProjectChanged(renderPreview: true);
        SetStatus("Ready");
    }

    public async Task SaveAsync(string? packagePath = null, CancellationToken cancellationToken = default)
    {
        var path = packagePath ?? ProjectPath ?? throw new InvalidOperationException("Choose where to save the project first.");
        SetStatus("Working");
        await _store.SaveAsync(Project, path, cancellationToken);
        ProjectPath = path;
        _isDirty = false;
        SetStatus("Ready");
    }

    public async Task AutosaveAsync(CancellationToken cancellationToken = default)
    {
        if (!_isDirty) return;
        await _store.SaveRecoveryAsync(Project, cancellationToken);
    }

    public async Task ImportAsync(IEnumerable<string> paths, CancellationToken cancellationToken = default)
    {
        var distinct = paths.Where(File.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (distinct.Length == 0) return;
        SetStatus("Working");
        using var concurrency = new SemaphoreSlim(2, 2);
        var tasks = distinct.Select(async path =>
        {
            await concurrency.WaitAsync(cancellationToken);
            try
            {
                var metadata = await _inspector.InspectAsync(path, cancellationToken);
                var kind = ImageExtensions.Contains(Path.GetExtension(path)) ? MediaKind.Image
                    : metadata.Resolution is null ? MediaKind.Audio : MediaKind.Video;
                return new MediaAsset
                {
                    DisplayName = Path.GetFileName(path),
                    Kind = kind,
                    Reference = new MediaReference
                    {
                        LastKnownPath = Path.GetFullPath(path),
                        SourceModificationDate = File.GetLastWriteTimeUtc(path)
                    },
                    Metadata = metadata
                };
            }
            finally { concurrency.Release(); }
        }).ToArray();
        var imported = await Task.WhenAll(tasks);
        foreach (var asset in imported) _editor.AddAsset(asset);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: false);
        SetStatus("Ready");
    }

    public void AddAssetToTimeline(Guid assetId, Guid? targetTrackId = null, RationalTime? start = null)
    {
        var asset = Project.Assets.FirstOrDefault(item => item.Id == assetId)
            ?? throw new InvalidEditException("The selected media item no longer exists.");
        var targetKind = asset.Kind == MediaKind.Audio ? TrackKind.Audio : TrackKind.Video;
        var track = targetTrackId is { } requested ? Project.Timeline.Tracks.FirstOrDefault(item => item.Id == requested) : null;
        if (track?.Kind != targetKind) track = Project.Timeline.Tracks.FirstOrDefault(item => item.Kind == targetKind && !item.IsLocked);
        if (track is null)
        {
            var id = _editor.AddTrack(targetKind);
            track = Project.Timeline.Tracks.First(item => item.Id == id);
        }
        var duration = asset.Kind == MediaKind.Image ? new RationalTime(5, 1) : asset.Metadata.Duration ?? new RationalTime(5, 1);
        var timelineStart = start ?? track.Clips.Select(clip => clip.TimelineEnd).DefaultIfEmpty(RationalTime.Zero).Max();
        _editor.AddClip(new TimelineClip
        {
            Name = Path.GetFileNameWithoutExtension(asset.DisplayName),
            Kind = asset.Kind switch { MediaKind.Audio => ClipKind.Audio, MediaKind.Image => ClipKind.Image, _ => ClipKind.Video },
            AssetId = asset.Id,
            TimelineStart = timelineStart,
            Duration = duration
        }, track.Id);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void AddText(string text = "Text")
    {
        var track = Project.Timeline.Tracks.FirstOrDefault(item => item.Kind == TrackKind.Video && !item.IsLocked && item.Clips.Count == 0);
        if (track is null)
        {
            var trackId = _editor.AddTrack(TrackKind.Video, "Titles");
            track = Project.Timeline.Tracks.First(item => item.Id == trackId);
        }
        var clip = new TimelineClip
        {
            Name = text,
            Kind = ClipKind.Text,
            TimelineStart = Playhead,
            Duration = new RationalTime(3, 1),
            TextStyle = new TextStyle { Text = text, FontName = "Segoe UI" }
        };
        _editor.AddClip(clip, track.Id);
        SelectClip(clip.Id);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void ImportSubtitles(string content, SubtitleFormat format)
    {
        var cues = SubtitleCodec.Parse(content, format);
        AddSubtitleCues(cues, RationalTime.Zero, RationalTime.Zero, playbackRate: 1);
    }

    public async Task GenerateCaptionsAsync(CultureInfo culture, CancellationToken cancellationToken = default)
    {
        var selected = SelectedClip;
        var asset = selected?.AssetId is { } assetId ? Project.Assets.FirstOrDefault(item => item.Id == assetId) : SelectedAsset;
        if (asset is null || asset.Kind == MediaKind.Image) throw new InvalidOperationException("Select a video or audio item first.");
        SetStatus("Working");
        var cues = await _captions.TranscribeAsync(asset.Reference.LastKnownPath, culture, cancellationToken);
        if (selected is null) AddSubtitleCues(cues, RationalTime.Zero, RationalTime.Zero, 1);
        else AddSubtitleCues(cues, selected.TimelineStart, selected.SourceStart, selected.PlaybackRate, selected.Duration);
        SetStatus("Ready");
    }

    public async Task<int> FindBeatsAsync(CancellationToken cancellationToken = default)
    {
        var (asset, clip) = SelectedAudioSource();
        SetStatus("Working");
        var peaks = await _waveforms.GenerateAsync(asset.Reference.LastKnownPath, cancellationToken);
        var duration = asset.Metadata.Duration?.Seconds ?? throw new InvalidOperationException("This audio item has no readable duration.");
        var detected = AudioInsights.DetectBeats(peaks, peaks.Count / duration);
        var mapped = clip is null ? detected : detected
            .Where(time => time >= clip.SourceStart && time < clip.SourceStart + RationalTime.FromSeconds(clip.Duration.Seconds * clip.PlaybackRate))
            .Select(time => clip.TimelineStart + RationalTime.FromSeconds((time - clip.SourceStart).Seconds / clip.PlaybackRate)).ToArray();
        var ids = _editor.AddMarkers(mapped, "Beat");
        _isDirty = true;
        NotifyProjectChanged(renderPreview: false);
        SetStatus("Ready");
        return ids.Count;
    }

    public async Task<IReadOnlyList<RationalTimeRange>> DetectSilenceAsync(CancellationToken cancellationToken = default)
    {
        var (asset, clip) = SelectedAudioSource();
        SetStatus("Working");
        var peaks = await _waveforms.GenerateAsync(asset.Reference.LastKnownPath, cancellationToken);
        var duration = asset.Metadata.Duration?.Seconds ?? throw new InvalidOperationException("This audio item has no readable duration.");
        var detected = AudioInsights.DetectSilence(peaks, peaks.Count / duration);
        SetStatus("Ready");
        if (clip is null) return detected;
        var sourceEnd = clip.SourceStart + RationalTime.FromSeconds(clip.Duration.Seconds * clip.PlaybackRate);
        var mapped = new List<RationalTimeRange>();
        foreach (var range in detected)
        {
            var start = range.Start > clip.SourceStart ? range.Start : clip.SourceStart;
            var end = range.End < sourceEnd ? range.End : sourceEnd;
            if (end <= start) continue;
            mapped.Add(new RationalTimeRange(
                clip.TimelineStart + RationalTime.FromSeconds((start - clip.SourceStart).Seconds / clip.PlaybackRate),
                RationalTime.FromSeconds((end - start).Seconds / clip.PlaybackRate)));
        }
        return mapped;
    }

    public void RemoveSilence(IReadOnlyList<RationalTimeRange> ranges)
    {
        _editor.RemoveTimelineRanges(ranges);
        _isDirty = true;
        Reselect();
        NotifyProjectChanged(renderPreview: true);
    }

    public async Task<RenderResult> ExportAsync(
        string destination,
        Resolution resolution,
        ExportCodec codec,
        ExportQuality quality,
        CancellationToken cancellationToken = default)
    {
        SetStatus("Working");
        var frameRate = FrameRateValue(Project.FrameRate);
        var progress = new Progress<double>(value => ProgressChanged?.Invoke(this, value));
        var result = await _renderer.RenderAsync(new RenderRequest(Project, destination, resolution, frameRate, codec, quality, Preview: false),
            progress, cancellationToken);
        SetStatus("Ready");
        return result;
    }

    public void SelectClip(Guid? clipId)
    {
        SelectedClipId = clipId;
        ProjectChanged?.Invoke(this, EventArgs.Empty);
    }

    public void MoveSelected(RationalTime start)
    {
        if (SelectedClipId is not { } id) return;
        _editor.Move(id, start);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void SplitSelected()
    {
        if (SelectedClipId is not { } id) return;
        var right = _editor.Split(id, Playhead);
        SelectedClipId = right;
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void DeleteSelected(bool ripple)
    {
        if (SelectedClipId is not { } id) return;
        _editor.Delete([id], ripple);
        SelectedClipId = null;
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void DuplicateSelected()
    {
        if (SelectedClipId is not { } id) return;
        SelectedClipId = _editor.Duplicate(id);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void DetachSelectedAudio()
    {
        if (SelectedClipId is not { } id) return;
        SelectedClipId = _editor.DetachAudio(id);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void InsertGap(double durationSeconds)
    {
        _editor.InsertGap(Playhead, RationalTime.FromSeconds(durationSeconds));
        _isDirty = true;
        Reselect();
        NotifyProjectChanged(renderPreview: true);
    }

    public async Task<AudioExtractionResult> ExtractSelectedAudioAsync(
        string destination,
        CancellationToken cancellationToken = default)
    {
        var (asset, clip) = SelectedAudioSource();
        SetStatus("Working");
        try
        {
            var start = TimeSpan.FromSeconds(clip?.SourceStart.Seconds ?? 0);
            TimeSpan? duration = clip is null ? null : TimeSpan.FromSeconds(clip.Duration.Seconds * clip.PlaybackRate);
            return await _mediaUtilities.ExtractAudioAsync(
                asset.Reference.LastKnownPath, destination, start, duration, overwrite: true, cancellationToken);
        }
        finally { SetStatus("Ready"); }
    }

    public async Task<FrameExtractionResult> ExtractCurrentFrameAsync(
        string destination,
        CancellationToken cancellationToken = default)
    {
        var clip = SelectedClip ?? throw new InvalidOperationException("Select a video or image clip first.");
        if (clip.Kind is not ClipKind.Video and not ClipKind.Image || clip.AssetId is not { } assetId)
            throw new InvalidOperationException("Select a video or image clip first.");
        var asset = Project.Assets.First(item => item.Id == assetId);
        var local = Math.Clamp(Playhead.Seconds - clip.TimelineStart.Seconds, 0, clip.Duration.Seconds);
        var sourceDuration = clip.Duration.Seconds * clip.PlaybackRate;
        var sourceOffset = clip.Kind == ClipKind.Image ? 0 : clip.IsReversed
            ? Math.Max(0, sourceDuration - local * clip.PlaybackRate - 1d / FrameRateValue(Project.FrameRate))
            : local * clip.PlaybackRate;
        if (clip.Kind == ClipKind.Video)
            sourceOffset = Math.Min(sourceOffset, Math.Max(0, sourceDuration - 1d / FrameRateValue(Project.FrameRate)));
        SetStatus("Working");
        try
        {
            return await _mediaUtilities.ExtractFrameAsync(
                asset.Reference.LastKnownPath,
                destination,
                TimeSpan.FromSeconds(clip.SourceStart.Seconds + sourceOffset),
                overwrite: true,
                cancellationToken);
        }
        finally { SetStatus("Ready"); }
    }

    public void ApplySelectedClip(
        string name,
        double start,
        double duration,
        double speed,
        double opacity,
        double volume,
        double scale,
        double rotation,
        string? text,
        ContentMode contentMode,
        bool enabled,
        bool reversed,
        bool hideVideo,
        double fadeIn,
        double fadeOut,
        double cropTop,
        double cropBottom,
        double cropLeft,
        double cropRight,
        TransitionKind? transitionIn,
        TransitionKind? transitionOut)
    {
        if (SelectedClipId is not { } id) return;
        _editor.UpdateClip(id, clip =>
        {
            clip.Name = string.IsNullOrWhiteSpace(name) ? clip.Name : name.Trim();
            clip.TimelineStart = RationalTime.FromSeconds(Math.Max(0, start));
            clip.Duration = RationalTime.FromSeconds(Math.Max(1d / FrameRateValue(Project.FrameRate), duration));
            clip.PlaybackRate = Math.Clamp(speed, 0.25, 4);
            clip.Opacity = Math.Clamp(opacity, 0, 1);
            clip.AudioVolume = Math.Clamp(volume, 0, 2);
            clip.Transform.Scale = Math.Clamp(scale, 0.05, 8);
            clip.Transform.RotationDegrees = Math.Clamp(rotation, -360, 360);
            clip.Transform.ContentMode = contentMode;
            clip.IsEnabled = enabled;
            clip.IsVideoMuted = hideVideo;
            if (clip.Kind is ClipKind.Video or ClipKind.Audio) clip.IsReversed = reversed;
            var half = clip.Duration.Seconds / 2;
            var safeFadeIn = RationalTime.FromSeconds(Math.Clamp(fadeIn, 0, half));
            var safeFadeOut = RationalTime.FromSeconds(Math.Clamp(fadeOut, 0, half));
            clip.Fades.VideoIn = safeFadeIn;
            clip.Fades.VideoOut = safeFadeOut;
            clip.Fades.AudioIn = safeFadeIn;
            clip.Fades.AudioOut = safeFadeOut;
            (clip.Transform.CropTop, clip.Transform.CropBottom) = NormalizeCropPair(cropTop, cropBottom);
            (clip.Transform.CropLeading, clip.Transform.CropTrailing) = NormalizeCropPair(cropLeft, cropRight);
            if (clip.Kind is ClipKind.Video or ClipKind.Image)
            {
                var transitionDuration = RationalTime.FromSeconds(Math.Min(0.5, clip.Duration.Seconds));
                clip.TransitionIn = transitionIn is { } incoming ? new ClipTransition { Kind = incoming, Duration = transitionDuration } : null;
                clip.TransitionOut = transitionOut is { } outgoing ? new ClipTransition { Kind = outgoing, Duration = transitionDuration } : null;
            }
            if (clip.TextStyle is not null && text is not null) clip.TextStyle.Text = text;
        });
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void AddEffect(VideoEffectKind kind)
    {
        if (SelectedClipId is not { } id) return;
        _editor.UpdateClip(id, clip => clip.Effects.Add(new VideoEffect { Kind = kind }));
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    public void AddMarker()
    {
        _editor.AddMarker(Playhead);
        _isDirty = true;
        NotifyProjectChanged(renderPreview: false);
    }

    public bool Undo()
    {
        var result = _editor.Undo();
        if (result) { _isDirty = true; Reselect(); NotifyProjectChanged(renderPreview: true); }
        return result;
    }

    public bool Redo()
    {
        var result = _editor.Redo();
        if (result) { _isDirty = true; Reselect(); NotifyProjectChanged(renderPreview: true); }
        return result;
    }

    public void RequestPreview() => SchedulePreview();

    private void AddSubtitleCues(
        IEnumerable<SubtitleCue> cues,
        RationalTime timelineOffset,
        RationalTime sourceOffset,
        double playbackRate,
        RationalTime? maximumTimelineDuration = null)
    {
        var subtitleTrackId = _editor.AddTrack(TrackKind.Video, "Subtitles");
        var added = 0;
        foreach (var cue in cues)
        {
            if (cue.Start < sourceOffset) continue;
            var relativeStart = RationalTime.FromSeconds((cue.Start - sourceOffset).Seconds / playbackRate);
            if (maximumTimelineDuration is { } maximum && relativeStart >= maximum) continue;
            var duration = RationalTime.FromSeconds(cue.Duration.Seconds / playbackRate);
            if (maximumTimelineDuration is { } limit && relativeStart + duration > limit) duration = limit - relativeStart;
            if (duration <= RationalTime.Zero) continue;
            _editor.AddClip(new TimelineClip
            {
                Name = cue.Text,
                Kind = ClipKind.Text,
                Role = ClipRole.Subtitle,
                TimelineStart = timelineOffset + relativeStart,
                Duration = duration,
                TextStyle = new TextStyle
                {
                    Text = cue.Text,
                    FontName = "Segoe UI Semibold",
                    FontSize = 52,
                    BackgroundHex = "#000000A6",
                    ShadowOpacity = 0.5
                },
                Transform = new ClipTransform { PositionY = 330 }
            }, subtitleTrackId);
            added++;
        }
        if (added == 0) throw new InvalidOperationException("No usable subtitle cues were found in the selected range.");
        _isDirty = true;
        NotifyProjectChanged(renderPreview: true);
    }

    private void NotifyProjectChanged(bool renderPreview)
    {
        RefreshCollections();
        ProjectChanged?.Invoke(this, EventArgs.Empty);
        if (renderPreview) SchedulePreview();
    }

    private void RefreshCollections()
    {
        Assets.Clear();
        foreach (var asset in Project.Assets) Assets.Add(asset);
    }

    private void SchedulePreview()
    {
        _previewCancellation?.Cancel();
        _previewCancellation?.Dispose();
        if (Project.Timeline.Duration <= RationalTime.Zero) return;
        _previewCancellation = new CancellationTokenSource();
        var token = _previewCancellation.Token;
        var snapshot = ProjectCodec.Clone(Project);
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(350, token);
                SetStatus("PreparingPreview");
                var resolution = PreviewResolution(snapshot.Canvas);
                var path = await _previewCache.GetOrRenderAsync(snapshot, resolution, Math.Min(30, FrameRateValue(snapshot.FrameRate)), token);
                PreviewReady?.Invoke(this, path);
                SetStatus("Ready");
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { Error?.Invoke(this, error); SetStatus("Ready"); }
        }, token);
    }

    private void Reselect()
    {
        if (SelectedClipId is { } id && Project.Timeline.Tracks.SelectMany(track => track.Clips).All(clip => clip.Id != id))
            SelectedClipId = null;
    }

    private (MediaAsset Asset, TimelineClip? Clip) SelectedAudioSource()
    {
        var clip = SelectedClip;
        var asset = clip?.AssetId is { } assetId ? Project.Assets.FirstOrDefault(item => item.Id == assetId) : SelectedAsset;
        if (asset is null || asset.Kind == MediaKind.Image || !asset.Metadata.HasAudio)
            throw new InvalidOperationException("Select a video or audio item with sound first.");
        return (asset, clip);
    }

    private void SetStatus(string resourceKey) => StatusChanged?.Invoke(this, resourceKey);

    private static CineleafProject CreateProject(string name, CanvasPreset preset, ProjectFrameRate frameRate) => new()
    {
        Name = name,
        CanvasPreset = preset,
        Canvas = preset switch
        {
            CanvasPreset.Vertical9x16 => new Resolution(1080, 1920),
            CanvasPreset.Square1x1 => new Resolution(1080, 1080),
            CanvasPreset.Portrait4x5 => new Resolution(1080, 1350),
            _ => new Resolution(1920, 1080)
        },
        FrameRate = frameRate,
        ExportPreferences = new ExportPreferences { FrameRate = frameRate }
    };

    private static int FrameRateValue(ProjectFrameRate frameRate) => frameRate switch
    { ProjectFrameRate.Fps24 => 24, ProjectFrameRate.Fps25 => 25, ProjectFrameRate.Fps50 => 50, ProjectFrameRate.Fps60 => 60, _ => 30 };

    private static Resolution PreviewResolution(Resolution canvas)
    {
        var scale = Math.Min(1, 960d / Math.Max(canvas.Width, canvas.Height));
        var width = Math.Max(2, (int)Math.Round(canvas.Width * scale / 2) * 2);
        var height = Math.Max(2, (int)Math.Round(canvas.Height * scale / 2) * 2);
        return new Resolution(width, height);
    }

    private static (double First, double Second) NormalizeCropPair(double first, double second)
    {
        first = Math.Clamp(first, 0, 0.95);
        second = Math.Clamp(second, 0, 0.95);
        var total = first + second;
        if (total < 0.95) return (first, second);
        var scale = 0.95 / total;
        return (first * scale, second * scale);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _previewCancellation?.Cancel();
        _previewCancellation?.Dispose();
        _encoderProbe.Dispose();
        _store.Dispose();
    }
}
