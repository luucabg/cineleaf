import XCTest
@testable import CineleafCore

final class EditingTests: XCTestCase {
    func testSplitPreservesDurationAndSourceContinuity() throws {
        let fixture = TestFixtures.projectWithClip()
        var editor = try ProjectEditor(project: fixture.project)
        let splitTime = RationalTime(value: 4, timescale: 1)

        let secondID = try editor.splitClip(fixture.clip.id, at: splitTime)
        let clips = editor.project.timeline.tracks[0].clips

        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, splitTime)
        XCTAssertEqual(clips[1].id, secondID)
        XCTAssertEqual(clips[1].timelineStart, splitTime)
        XCTAssertEqual(clips[1].sourceStart, splitTime)
        XCTAssertEqual(clips[0].duration + clips[1].duration, fixture.clip.duration)
    }

    func testTrimStartChangesSourceAndKeepsEnd() throws {
        let fixture = TestFixtures.projectWithClip()
        var editor = try ProjectEditor(project: fixture.project)
        let newStart = RationalTime(value: 2, timescale: 1)

        try editor.trimStart(of: fixture.clip.id, to: newStart)
        let clip = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first)

        XCTAssertEqual(clip.timelineStart, newStart)
        XCTAssertEqual(clip.sourceStart, newStart)
        XCTAssertEqual(clip.duration, RationalTime(value: 8, timescale: 1))
        XCTAssertEqual(clip.timelineEnd, RationalTime(value: 10, timescale: 1))
    }

    func testRejectsOverlapAndLockedTrackMutation() throws {
        let fixture = TestFixtures.projectWithClip()
        var editor = try ProjectEditor(project: fixture.project)
        let overlapping = TimelineClip(
            name: "overlap",
            kind: .video,
            assetID: fixture.asset.id,
            timelineStart: RationalTime(value: 9, timescale: 1),
            duration: RationalTime(value: 2, timescale: 1)
        )
        XCTAssertThrowsError(try editor.insert(overlapping, into: fixture.videoTrackID))

        try editor.setTrackLocked(fixture.videoTrackID, locked: true)
        XCTAssertThrowsError(try editor.deleteClips([fixture.clip.id])) { error in
            XCTAssertEqual(error as? EditingError, .trackLocked(fixture.videoTrackID))
        }
    }

    func testSnapsToNearestEdgeWithinThreshold() throws {
        let fixture = TestFixtures.projectWithClip()
        let editor = try ProjectEditor(project: fixture.project)
        let result = editor.snappedTime(
            proposed: RationalTime(value: 101, timescale: 10),
            playhead: RationalTime(value: 5, timescale: 1),
            threshold: RationalTime(value: 1, timescale: 5)
        )
        XCTAssertTrue(result.didSnap)
        XCTAssertEqual(result.time, RationalTime(value: 10, timescale: 1))
    }

    func testDetachAudioCreatesAudioClipAndMutesSourceAudio() throws {
        let fixture = TestFixtures.projectWithClip()
        var editor = try ProjectEditor(project: fixture.project)
        let audioTrackID = editor.project.timeline.tracks[1].id

        let detachedID = try editor.detachAudio(from: fixture.clip.id, to: audioTrackID)

        XCTAssertEqual(editor.project.timeline.tracks[0].clips[0].audioVolume, 0)
        let audio = try XCTUnwrap(editor.project.timeline.tracks[1].clips.first)
        XCTAssertEqual(audio.id, detachedID)
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.assetID, fixture.asset.id)
    }

    func testDetachAudioUsesANonOverlappingTrackAndRejectsSilentVideo() throws {
        var fixture = TestFixtures.projectWithClip()
        let occupied = TimelineClip(
            name: "Existing audio",
            kind: .audio,
            assetID: fixture.asset.id,
            timelineStart: .zero,
            duration: fixture.clip.duration
        )
        fixture.project.timeline.tracks[1].clips = [occupied]
        var editor = try ProjectEditor(project: fixture.project)

        let detachedID = try editor.detachAudio(from: fixture.clip.id)

        XCTAssertEqual(editor.project.timeline.tracks.filter { $0.kind == .audio }.count, 2)
        let detached = try XCTUnwrap(
            editor.project.timeline.tracks.flatMap(\.clips).first { $0.id == detachedID }
        )
        XCTAssertEqual(detached.timelineStart, fixture.clip.timelineStart)
        XCTAssertNil(detached.groupID)
        XCTAssertNil(detached.linkGroupID)

        var silentProject = TestFixtures.projectWithClip().project
        silentProject.assets[0].metadata.hasAudio = false
        var silentEditor = try ProjectEditor(project: silentProject)
        XCTAssertThrowsError(try silentEditor.detachAudio(from: silentProject.timeline.tracks[0].clips[0].id))
    }

    func testInsertGapSplitsSpanningClipsAndMovesMarkers() throws {
        var fixture = TestFixtures.projectWithClip()
        fixture.project.timeline.markers = [TimelineMarker(time: RationalTime(value: 4, timescale: 1), name: "Cut")]
        var editor = try ProjectEditor(project: fixture.project)

        try editor.insertGap(
            at: RationalTime(value: 4, timescale: 1),
            duration: RationalTime(value: 2, timescale: 1)
        )

        let clips = editor.project.timeline.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, RationalTime(value: 4, timescale: 1))
        XCTAssertEqual(clips[1].timelineStart, RationalTime(value: 6, timescale: 1))
        XCTAssertEqual(clips[1].duration, RationalTime(value: 6, timescale: 1))
        XCTAssertEqual(clips[1].sourceStart, RationalTime(value: 4, timescale: 1))
        XCTAssertEqual(editor.project.timeline.markers[0].time, RationalTime(value: 6, timescale: 1))
    }

    func testInsertGapRejectsALockedAffectedTrackWithoutChangingAnything() throws {
        var fixture = TestFixtures.projectWithClip()
        fixture.project.timeline.tracks[0].isLocked = true
        let before = fixture.project
        var editor = try ProjectEditor(project: fixture.project)

        XCTAssertThrowsError(try editor.insertGap(
            at: RationalTime(value: 4, timescale: 1),
            duration: RationalTime(value: 1, timescale: 1)
        ))
        XCTAssertEqual(editor.project, before)
    }

    func testInsertGapRejectsAPositionWithoutLaterTimelineContent() throws {
        let fixture = TestFixtures.projectWithClip()
        var editor = try ProjectEditor(project: fixture.project)

        XCTAssertThrowsError(try editor.insertGap(
            at: fixture.project.timeline.duration,
            duration: RationalTime(value: 1, timescale: 1)
        ))
        XCTAssertEqual(editor.project, fixture.project)
    }

    func testDuplicateAppendsWithoutOverlappingANeighbour() throws {
        var fixture = TestFixtures.projectWithClip()
        let groupID = UUID()
        fixture.project.timeline.tracks[0].clips[0].groupID = groupID
        fixture.project.timeline.tracks[0].clips[0].linkGroupID = groupID
        fixture.clip.groupID = groupID
        fixture.clip.linkGroupID = groupID
        var second = fixture.clip
        second.id = UUID()
        second.timelineStart = fixture.clip.timelineEnd
        fixture.project.timeline.tracks[0].clips.append(second)
        var editor = try ProjectEditor(project: fixture.project)

        let duplicateID = try editor.duplicateClip(fixture.clip.id)
        let duplicate = try XCTUnwrap(editor.project.timeline.tracks[0].clips.first { $0.id == duplicateID })

        XCTAssertEqual(duplicate.timelineStart, second.timelineEnd)
        XCTAssertNil(duplicate.groupID)
        XCTAssertNil(duplicate.linkGroupID)
    }

    func testBoundedUndoAndRedo() throws {
        let first = CineleafProject(name: "First")
        var second = first
        second.name = "Second"
        var third = first
        third.name = "Third"
        var history = EditHistory(limit: 1)
        history.record(first)
        history.record(second)

        XCTAssertEqual(history.undo(current: third)?.name, "Second")
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(current: second)?.name, "Third")
    }
}
