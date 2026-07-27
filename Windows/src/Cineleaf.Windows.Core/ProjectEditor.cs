namespace Cineleaf.Core;

public sealed class InvalidEditException(string message, Exception? innerException = null) : Exception(message, innerException);

public sealed class ProjectEditor
{
    private const int HistoryLimit = 100;
    private readonly Stack<CineleafProject> _undo = new();
    private readonly Stack<CineleafProject> _redo = new();

    public ProjectEditor(CineleafProject project)
    {
        ProjectValidator.Validate(project);
        Project = ProjectCodec.Clone(project);
    }

    public CineleafProject Project { get; private set; }
    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    public Guid Split(Guid clipId, RationalTime playhead)
    {
        var rightId = Guid.NewGuid();
        Commit(candidate =>
        {
            var (track, clip) = Find(candidate, clipId);
            if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
            if (playhead <= clip.TimelineStart || playhead >= clip.TimelineEnd)
                throw new InvalidEditException("The playhead must be inside the clip.");
            var leftDuration = playhead - clip.TimelineStart;
            var right = ProjectCodec.Clone(candidate).Timeline.Tracks
                .SelectMany(item => item.Clips).First(item => item.Id == clipId);
            right.Id = rightId;
            right.TimelineStart = playhead;
            right.Duration = clip.Duration - leftDuration;
            right.SourceStart = clip.SourceStart + Scale(leftDuration, clip.PlaybackRate);
            clip.Duration = leftDuration;
            track.Clips.Add(right);
        });
        return rightId;
    }

    public void Move(Guid clipId, RationalTime start) => Commit(candidate =>
    {
        var (track, clip) = Find(candidate, clipId);
        if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
        if (start < RationalTime.Zero) throw new InvalidEditException("A clip cannot start before the timeline.");
        clip.TimelineStart = start;
    });

    public void Trim(Guid clipId, RationalTime newSourceStart, RationalTime newDuration) => Commit(candidate =>
    {
        var (track, clip) = Find(candidate, clipId);
        if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
        if (newSourceStart < RationalTime.Zero || newDuration <= RationalTime.Zero)
            throw new InvalidEditException("Trim values must be positive.");
        clip.SourceStart = newSourceStart;
        clip.Duration = newDuration;
    });

    public void Delete(IEnumerable<Guid> clipIds, bool ripple)
    {
        var selected = clipIds.ToHashSet();
        if (selected.Count == 0) return;
        Commit(candidate =>
        {
            foreach (var track in candidate.Timeline.Tracks)
            {
                var removed = track.Clips.Where(clip => selected.Contains(clip.Id)).OrderBy(clip => clip.TimelineStart).ToList();
                if (removed.Count == 0) continue;
                if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
                track.Clips.RemoveAll(clip => selected.Contains(clip.Id));
                if (!ripple) continue;
                foreach (var clip in track.Clips)
                {
                    var shift = removed.Where(item => item.TimelineEnd <= clip.TimelineStart)
                        .Aggregate(RationalTime.Zero, (total, item) => total + item.Duration);
                    clip.TimelineStart -= shift;
                }
            }
        });
    }

    public Guid Duplicate(Guid clipId)
    {
        var duplicateId = Guid.NewGuid();
        Commit(candidate =>
        {
            var (track, clip) = Find(candidate, clipId);
            if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
            var duplicate = ProjectCodec.Clone(candidate).Timeline.Tracks.SelectMany(item => item.Clips).First(item => item.Id == clipId);
            duplicate.Id = duplicateId;
            duplicate.TimelineStart = FirstAvailableStart(track.Clips, clip.TimelineEnd, clip.Duration, clip.Id);
            duplicate.GroupId = null;
            duplicate.LinkGroupId = null;
            track.Clips.Add(duplicate);
        });
        return duplicateId;
    }

    public Guid DetachAudio(Guid clipId, Guid? audioTrackId = null)
    {
        var detachedId = Guid.NewGuid();
        Commit(candidate =>
        {
            var (sourceTrack, source) = Find(candidate, clipId);
            if (sourceTrack.IsLocked) throw new InvalidEditException($"Track {sourceTrack.Name} is locked.");
            if (source.Kind != ClipKind.Video || source.AssetId is not { } assetId ||
                candidate.Assets.FirstOrDefault(asset => asset.Id == assetId)?.Metadata.HasAudio != true)
                throw new InvalidEditException("The selected video does not contain detachable audio.");

            TimelineTrack? destination = null;
            if (audioTrackId is { } requested)
                destination = candidate.Timeline.Tracks.FirstOrDefault(track => track.Id == requested);
            else
                destination = candidate.Timeline.Tracks.FirstOrDefault(track =>
                    track.Kind == TrackKind.Audio && !track.IsLocked && track.Clips.All(clip => !Intersects(clip, source)));
            if (destination is null && audioTrackId is null)
            {
                destination = new TimelineTrack
                {
                    Name = $"A{candidate.Timeline.Tracks.Count(track => track.Kind == TrackKind.Audio) + 1}",
                    Kind = TrackKind.Audio
                };
                candidate.Timeline.Tracks.Add(destination);
            }
            if (destination is null || destination.Kind != TrackKind.Audio || destination.IsLocked ||
                destination.Clips.Any(clip => Intersects(clip, source)))
                throw new InvalidEditException("Choose an unlocked audio track without another clip in that range.");

            var detached = CloneClip(candidate, source.Id);
            detached.Id = detachedId;
            detached.Kind = ClipKind.Audio;
            detached.IsVideoMuted = true;
            detached.Transform = new ClipTransform();
            detached.Opacity = 1;
            detached.GroupId = null;
            detached.LinkGroupId = null;
            source.AudioVolume = 0;
            destination.Clips.Add(detached);
            destination.Clips = destination.Clips.OrderBy(clip => clip.TimelineStart).ToList();
        });
        return detachedId;
    }

    public void InsertGap(RationalTime time, RationalTime duration)
    {
        if (time < RationalTime.Zero || time >= Project.Timeline.Duration || duration <= RationalTime.Zero)
            throw new InvalidEditException("A pause needs a valid position and positive duration.");
        Commit(candidate =>
        {
            foreach (var track in candidate.Timeline.Tracks)
            {
                if (track.IsLocked && track.Clips.Any(clip => clip.TimelineEnd > time))
                    throw new InvalidEditException($"Track {track.Name} is locked.");
                var edited = new List<TimelineClip>();
                foreach (var clip in track.Clips)
                {
                    if (clip.TimelineStart >= time)
                    {
                        clip.TimelineStart += duration;
                        edited.Add(clip);
                    }
                    else if (clip.TimelineEnd > time)
                    {
                        var leftDuration = time - clip.TimelineStart;
                        var rightDuration = clip.TimelineEnd - time;
                        edited.Add(Segment(candidate, clip, RationalTime.Zero, leftDuration, preserveId: true));
                        var right = Segment(candidate, clip, leftDuration, rightDuration, preserveId: false);
                        right.TimelineStart = time + duration;
                        edited.Add(right);
                    }
                    else edited.Add(clip);
                }
                track.Clips = edited.OrderBy(clip => clip.TimelineStart).ToList();
            }
            foreach (var marker in candidate.Timeline.Markers.Where(marker => marker.Time >= time)) marker.Time += duration;
            candidate.Timeline.Markers = candidate.Timeline.Markers.OrderBy(marker => marker.Time).ToList();
        });
    }

    public void UpdateProjectSettings(string name, CanvasPreset preset, ProjectFrameRate frameRate) => Commit(candidate =>
    {
        candidate.Name = string.IsNullOrWhiteSpace(name) ? "Untitled" : name.Trim();
        candidate.CanvasPreset = preset;
        candidate.Canvas = CanvasResolution(preset);
        candidate.FrameRate = frameRate;
        candidate.ExportPreferences.FrameRate = frameRate;
    });

    public void AddClip(TimelineClip clip, Guid trackId) => Commit(candidate =>
    {
        var track = candidate.Timeline.Tracks.FirstOrDefault(item => item.Id == trackId)
            ?? throw new InvalidEditException("The target track no longer exists.");
        if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
        track.Clips.Add(clip);
    });

    public void AddAsset(MediaAsset asset) => Commit(candidate =>
    {
        if (candidate.Assets.Any(item => item.Id == asset.Id)) throw new InvalidEditException("That media item is already in the project.");
        candidate.Assets.Add(asset);
    });

    public Guid AddTrack(TrackKind kind, string? name = null)
    {
        var id = Guid.NewGuid();
        Commit(candidate => candidate.Timeline.Tracks.Add(new TimelineTrack
        {
            Id = id,
            Kind = kind,
            Name = name ?? $"{(kind == TrackKind.Video ? 'V' : 'A')}{candidate.Timeline.Tracks.Count(track => track.Kind == kind) + 1}"
        }));
        return id;
    }

    public Guid AddMarker(RationalTime time, string? name = null)
    {
        if (time < RationalTime.Zero) throw new InvalidEditException("A marker cannot be placed before the timeline.");
        var id = Guid.NewGuid();
        Commit(candidate => candidate.Timeline.Markers.Add(new TimelineMarker
        {
            Id = id,
            Time = time,
            Name = name ?? $"Marker {candidate.Timeline.Markers.Count + 1}"
        }));
        return id;
    }

    public IReadOnlyList<Guid> AddMarkers(IEnumerable<RationalTime> times, string prefix)
    {
        var ordered = times.Where(time => time >= RationalTime.Zero).Distinct().OrderBy(time => time).ToArray();
        var ids = ordered.Select(_ => Guid.NewGuid()).ToArray();
        Commit(candidate =>
        {
            for (var index = 0; index < ordered.Length; index++)
                candidate.Timeline.Markers.Add(new TimelineMarker { Id = ids[index], Time = ordered[index], Name = $"{prefix} {index + 1}" });
            candidate.Timeline.Markers = candidate.Timeline.Markers.OrderBy(marker => marker.Time).ToList();
        });
        return ids;
    }

    public void RemoveTimelineRanges(IEnumerable<RationalTimeRange> ranges)
    {
        var normalized = MergeRanges(ranges).OrderByDescending(range => range.Start).ToArray();
        if (normalized.Length == 0) return;
        Commit(candidate =>
        {
            foreach (var range in normalized)
                foreach (var track in candidate.Timeline.Tracks)
                {
                    if (track.IsLocked && track.Clips.Any(clip => clip.TimelineEnd > range.Start))
                        throw new InvalidEditException($"Track {track.Name} is locked.");
                    var updated = new List<TimelineClip>();
                    foreach (var clip in track.Clips)
                    {
                        if (clip.TimelineEnd <= range.Start) { updated.Add(clip); continue; }
                        if (clip.TimelineStart >= range.End)
                        {
                            clip.TimelineStart -= range.Duration;
                            updated.Add(clip);
                            continue;
                        }
                        var leftDuration = range.Start > clip.TimelineStart ? range.Start - clip.TimelineStart : RationalTime.Zero;
                        var rightDuration = clip.TimelineEnd > range.End ? clip.TimelineEnd - range.End : RationalTime.Zero;
                        if (leftDuration > RationalTime.Zero)
                        {
                            clip.Duration = leftDuration;
                            updated.Add(clip);
                        }
                        if (rightDuration > RationalTime.Zero)
                        {
                            var right = ProjectCodec.Clone(candidate).Timeline.Tracks.SelectMany(item => item.Clips).First(item => item.Id == clip.Id);
                            if (leftDuration > RationalTime.Zero) right.Id = Guid.NewGuid();
                            right.TimelineStart = range.Start;
                            right.SourceStart += Scale(range.End - clip.TimelineStart, clip.PlaybackRate);
                            right.Duration = rightDuration;
                            updated.Add(right);
                        }
                    }
                    track.Clips = updated.OrderBy(clip => clip.TimelineStart).ToList();
                }
        });
    }

    public void UpdateClip(Guid clipId, Action<TimelineClip> update) => Commit(candidate =>
    {
        var (track, clip) = Find(candidate, clipId);
        if (track.IsLocked) throw new InvalidEditException($"Track {track.Name} is locked.");
        update(clip);
    });

    public bool Undo()
    {
        if (!_undo.TryPop(out var previous)) return false;
        _redo.Push(Project);
        Project = previous;
        return true;
    }

    public bool Redo()
    {
        if (!_redo.TryPop(out var next)) return false;
        _undo.Push(Project);
        Project = next;
        return true;
    }

    private void Commit(Action<CineleafProject> mutation)
    {
        var before = Project;
        var candidate = ProjectCodec.Clone(before);
        try
        {
            mutation(candidate);
            candidate.ModifiedAt = DateTimeOffset.UtcNow;
            ProjectValidator.Validate(candidate);
        }
        catch (InvalidEditException) { throw; }
        catch (Exception error) when (error is ProjectValidationException or ProjectFormatException)
        {
            throw new InvalidEditException("That edit would make the timeline invalid.", error);
        }
        _undo.Push(before);
        while (_undo.Count > HistoryLimit) RemoveOldest(_undo);
        _redo.Clear();
        Project = candidate;
    }

    private static (TimelineTrack Track, TimelineClip Clip) Find(CineleafProject project, Guid clipId)
    {
        foreach (var track in project.Timeline.Tracks)
        {
            var clip = track.Clips.FirstOrDefault(item => item.Id == clipId);
            if (clip is not null) return (track, clip);
        }
        throw new InvalidEditException("The selected clip no longer exists.");
    }

    private static RationalTime Scale(RationalTime time, double factor) => RationalTime.FromSeconds(time.Seconds * factor);

    private static Resolution CanvasResolution(CanvasPreset preset) => preset switch
    {
        CanvasPreset.Vertical9x16 => new Resolution(1080, 1920),
        CanvasPreset.Square1x1 => new Resolution(1080, 1080),
        CanvasPreset.Portrait4x5 => new Resolution(1080, 1350),
        _ => new Resolution(1920, 1080)
    };

    private static bool Intersects(TimelineClip left, TimelineClip right) =>
        left.TimelineStart < right.TimelineEnd && right.TimelineStart < left.TimelineEnd;

    private static TimelineClip CloneClip(CineleafProject project, Guid clipId) => ProjectCodec.Clone(project)
        .Timeline.Tracks.SelectMany(track => track.Clips).First(clip => clip.Id == clipId);

    private static TimelineClip Segment(
        CineleafProject project,
        TimelineClip original,
        RationalTime offset,
        RationalTime duration,
        bool preserveId)
    {
        var segment = CloneClip(project, original.Id);
        if (!preserveId) segment.Id = Guid.NewGuid();
        segment.TimelineStart = original.TimelineStart + offset;
        segment.Duration = duration;
        if (original.Kind is not ClipKind.Text and not ClipKind.Image)
        {
            if (original.IsReversed)
            {
                var trailingDuration = original.Duration - offset - duration;
                segment.SourceStart = original.SourceStart + Scale(trailingDuration, original.PlaybackRate);
            }
            else segment.SourceStart = original.SourceStart + Scale(offset, original.PlaybackRate);
        }
        if (offset > RationalTime.Zero) segment.TransitionIn = null;
        if (offset + duration < original.Duration) segment.TransitionOut = null;
        var half = RationalTime.FromSeconds(duration.Seconds / 2);
        segment.Fades.VideoIn = Min(segment.Fades.VideoIn, half);
        segment.Fades.VideoOut = Min(segment.Fades.VideoOut, half);
        segment.Fades.AudioIn = Min(segment.Fades.AudioIn, half);
        segment.Fades.AudioOut = Min(segment.Fades.AudioOut, half);
        segment.Keyframes.PositionX = Rebase(original.Keyframes.PositionX, offset, duration);
        segment.Keyframes.PositionY = Rebase(original.Keyframes.PositionY, offset, duration);
        segment.Keyframes.Scale = Rebase(original.Keyframes.Scale, offset, duration);
        segment.Keyframes.RotationDegrees = Rebase(original.Keyframes.RotationDegrees, offset, duration);
        segment.Keyframes.Opacity = Rebase(original.Keyframes.Opacity, offset, duration);
        segment.Keyframes.Volume = Rebase(original.Keyframes.Volume, offset, duration);
        return segment;
    }

    private static List<ScalarKeyframe> Rebase(IEnumerable<ScalarKeyframe> frames, RationalTime offset, RationalTime duration) =>
        frames.Where(frame => frame.Time >= offset && frame.Time <= offset + duration)
            .Select(frame => frame with { Time = frame.Time - offset }).ToList();

    private static RationalTime Min(RationalTime left, RationalTime right) => left < right ? left : right;

    private static RationalTime FirstAvailableStart(
        IEnumerable<TimelineClip> clips,
        RationalTime start,
        RationalTime duration,
        Guid excludedId)
    {
        var candidate = start;
        foreach (var clip in clips.Where(clip => clip.Id != excludedId).OrderBy(clip => clip.TimelineStart))
        {
            if (clip.TimelineEnd <= candidate) continue;
            if (candidate + duration <= clip.TimelineStart) return candidate;
            candidate = clip.TimelineEnd;
        }
        return candidate;
    }

    private static List<RationalTimeRange> MergeRanges(IEnumerable<RationalTimeRange> ranges)
    {
        var ordered = ranges.Where(range => range.Start >= RationalTime.Zero && range.Duration > RationalTime.Zero)
            .OrderBy(range => range.Start).ToArray();
        var merged = new List<RationalTimeRange>();
        foreach (var range in ordered)
        {
            if (merged.Count == 0 || merged[^1].End < range.Start) merged.Add(range);
            else
            {
                var previous = merged[^1];
                var end = previous.End > range.End ? previous.End : range.End;
                merged[^1] = new RationalTimeRange(previous.Start, end - previous.Start);
            }
        }
        return merged;
    }

    private static void RemoveOldest(Stack<CineleafProject> stack)
    {
        var keep = stack.Reverse().Skip(1).ToArray();
        stack.Clear();
        foreach (var project in keep) stack.Push(project);
    }
}
