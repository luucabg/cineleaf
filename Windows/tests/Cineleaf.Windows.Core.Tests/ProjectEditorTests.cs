using Cineleaf.Core;

namespace Cineleaf.Windows.Core.Tests;

public sealed class ProjectEditorTests
{
    [Fact]
    public void SplitPreservesSourceAndTimelineRanges()
    {
        var project = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        var original = project.Timeline.Tracks[0].Clips[0];
        var editor = new ProjectEditor(project);

        var rightId = editor.Split(original.Id, new RationalTime(4, 1));

        var clips = editor.Project.Timeline.Tracks[0].Clips;
        Assert.Equal(new RationalTime(4, 1), clips[0].Duration);
        Assert.Equal(new RationalTime(4, 1), clips[1].TimelineStart);
        Assert.Equal(new RationalTime(4, 1), clips[1].SourceStart);
        Assert.Equal(rightId, clips[1].Id);
    }

    [Fact]
    public void RippleDeleteClosesDeletedRange()
    {
        var project = ProjectFixtures.ThreeClipProject();
        var editor = new ProjectEditor(project);
        var middle = project.Timeline.Tracks[0].Clips[1];

        editor.Delete(new[] { middle.Id }, ripple: true);

        Assert.Equal(new RationalTime(10, 1), editor.Project.Timeline.Tracks[0].Clips[1].TimelineStart);
    }

    [Fact]
    public void UndoRedoRestoresACommittedEdit()
    {
        var project = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        var editor = new ProjectEditor(project);
        var clipId = project.Timeline.Tracks[0].Clips[0].Id;

        editor.Move(clipId, new RationalTime(3, 1));
        Assert.Equal(new RationalTime(3, 1), editor.Project.Timeline.Tracks[0].Clips[0].TimelineStart);
        Assert.True(editor.Undo());
        Assert.Equal(RationalTime.Zero, editor.Project.Timeline.Tracks[0].Clips[0].TimelineStart);
        Assert.True(editor.Redo());
        Assert.Equal(new RationalTime(3, 1), editor.Project.Timeline.Tracks[0].Clips[0].TimelineStart);
    }

    [Fact]
    public void InvalidOverlapDoesNotMutateProject()
    {
        var project = ProjectFixtures.ThreeClipProject();
        var editor = new ProjectEditor(project);
        var last = project.Timeline.Tracks[0].Clips[2];

        Assert.Throws<InvalidEditException>(() => editor.Move(last.Id, new RationalTime(5, 1)));
        Assert.Equal(new RationalTime(20, 1), editor.Project.Timeline.Tracks[0].Clips[2].TimelineStart);
    }

    [Fact]
    public void InsertGapSplitsSpanningClipsAndMovesMarkers()
    {
        var project = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        project.Timeline.Markers.Add(new TimelineMarker { Time = new RationalTime(4, 1), Name = "Cut" });
        var editor = new ProjectEditor(project);

        editor.InsertGap(new RationalTime(4, 1), new RationalTime(2, 1));

        var clips = editor.Project.Timeline.Tracks[0].Clips;
        Assert.Equal(2, clips.Count);
        Assert.Equal(new RationalTime(4, 1), clips[0].Duration);
        Assert.Equal(new RationalTime(6, 1), clips[1].TimelineStart);
        Assert.Equal(new RationalTime(6, 1), clips[1].Duration);
        Assert.Equal(new RationalTime(4, 1), clips[1].SourceStart);
        Assert.Equal(new RationalTime(6, 1), editor.Project.Timeline.Markers[0].Time);
    }

    [Fact]
    public void DetachAudioUsesAFreeTrackAndMutesTheVideoAudio()
    {
        var project = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        var source = project.Timeline.Tracks[0].Clips[0];
        project.Timeline.Tracks[1].Clips.Add(new TimelineClip
        {
            Name = "Existing audio", Kind = ClipKind.Audio, AssetId = source.AssetId, Duration = source.Duration
        });
        var editor = new ProjectEditor(project);

        var detachedId = editor.DetachAudio(source.Id);

        Assert.Equal(2, editor.Project.Timeline.Tracks.Count(track => track.Kind == TrackKind.Audio));
        Assert.Equal(0, editor.Project.Timeline.Tracks[0].Clips[0].AudioVolume);
        var detached = editor.Project.Timeline.Tracks.SelectMany(track => track.Clips).Single(clip => clip.Id == detachedId);
        Assert.Equal(ClipKind.Audio, detached.Kind);
        Assert.Null(detached.GroupId);
        Assert.Null(detached.LinkGroupId);
    }

    [Fact]
    public void GapAndDetachFailuresLeaveTheProjectUnchanged()
    {
        var locked = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        locked.Timeline.Tracks[0].IsLocked = true;
        var lockedEditor = new ProjectEditor(locked);
        Assert.Throws<InvalidEditException>(() => lockedEditor.InsertGap(new RationalTime(4, 1), new RationalTime(1, 1)));
        Assert.Single(lockedEditor.Project.Timeline.Tracks[0].Clips);
        Assert.Equal(new RationalTime(10, 1), lockedEditor.Project.Timeline.Duration);

        var silent = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        silent.Assets[0].Metadata.HasAudio = false;
        var silentEditor = new ProjectEditor(silent);
        Assert.Throws<InvalidEditException>(() => silentEditor.DetachAudio(silent.Timeline.Tracks[0].Clips[0].Id));
        Assert.Equal(1, silentEditor.Project.Timeline.Tracks[0].Clips[0].AudioVolume);
        Assert.Empty(silentEditor.Project.Timeline.Tracks[1].Clips);
    }

    [Fact]
    public void InsertGapRejectsAPositionWithoutLaterTimelineContent()
    {
        var project = ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow);
        var editor = new ProjectEditor(project);
        var before = ProjectCodec.Encode(editor.Project);

        Assert.Throws<InvalidEditException>(() => editor.InsertGap(project.Timeline.Duration, new RationalTime(1, 1)));
        Assert.Equal(before, ProjectCodec.Encode(editor.Project));
    }

    [Fact]
    public void DuplicateAppendsWithoutOverlappingANeighbour()
    {
        var project = ProjectFixtures.ThreeClipProject();
        var editor = new ProjectEditor(project);
        var first = project.Timeline.Tracks[0].Clips[0];

        var duplicateId = editor.Duplicate(first.Id);
        var duplicate = editor.Project.Timeline.Tracks[0].Clips.Single(clip => clip.Id == duplicateId);

        Assert.Equal(new RationalTime(30, 1), duplicate.TimelineStart);
    }

    [Fact]
    public void UpdatesCanvasAndFrameRateAsOneUndoableEdit()
    {
        var editor = new ProjectEditor(ProjectFixtures.SimpleProject(DateTimeOffset.UtcNow));

        editor.UpdateProjectSettings("Vertical", CanvasPreset.Vertical9x16, ProjectFrameRate.Fps60);

        Assert.Equal("Vertical", editor.Project.Name);
        Assert.Equal(new Resolution(1080, 1920), editor.Project.Canvas);
        Assert.Equal(ProjectFrameRate.Fps60, editor.Project.FrameRate);
        Assert.Equal(ProjectFrameRate.Fps60, editor.Project.ExportPreferences.FrameRate);
        Assert.True(editor.Undo());
        Assert.Equal(new Resolution(1920, 1080), editor.Project.Canvas);
    }
}
