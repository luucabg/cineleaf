import Foundation

public struct ClipPropertyBundle: Codable, Hashable, Sendable {
    public var transform: ClipTransform
    public var opacity: Double
    public var audioVolume: Double
    public var fades: ClipFades
    public var colorAdjustments: ColorAdjustments
    public var effects: [VideoEffect]
    public var keyframes: ClipKeyframes

    public init(clip: TimelineClip) {
        transform = clip.transform
        opacity = clip.opacity
        audioVolume = clip.audioVolume
        fades = clip.fades
        colorAdjustments = clip.colorAdjustments
        effects = clip.effects
        keyframes = clip.keyframes
    }
}

public extension ProjectEditor {
    mutating func insertGap(at time: RationalTime, duration: RationalTime) throws {
        guard time >= .zero, project.timeline.duration > time, duration > .zero else {
            throw EditingError.invalidEdit
        }
        var draft = project
        for trackIndex in draft.timeline.tracks.indices {
            let track = draft.timeline.tracks[trackIndex]
            let affected = track.clips.contains { $0.timelineEnd > time }
            if affected && track.isLocked { throw EditingError.trackLocked(track.id) }
            var edited: [TimelineClip] = []
            for clip in track.clips {
                if clip.timelineStart >= time {
                    var shifted = clip
                    shifted.timelineStart = shifted.timelineStart + duration
                    edited.append(shifted)
                } else if clip.timelineEnd > time {
                    let leftDuration = time - clip.timelineStart
                    let rightDuration = clip.timelineEnd - time
                    edited.append(Self.segment(of: clip, offset: .zero, duration: leftDuration, preserveID: true))
                    var right = Self.segment(of: clip, offset: leftDuration, duration: rightDuration, preserveID: false)
                    right.timelineStart = time + duration
                    edited.append(right)
                } else {
                    edited.append(clip)
                }
            }
            draft.timeline.tracks[trackIndex].clips = edited.sorted { $0.timelineStart < $1.timelineStart }
        }
        draft.timeline.markers = draft.timeline.markers.map { marker in
            var shifted = marker
            if shifted.time >= time { shifted.time = shifted.time + duration }
            return shifted
        }.sorted { $0.time < $1.time }
        try commit(draft)
    }

    mutating func insertEdit(_ clip: TimelineClip, into trackID: UUID, at time: RationalTime) throws {
        guard time >= .zero else { throw EditingError.invalidEdit }
        var draft = project
        let trackIndex = try editableTrackIndex(trackID, in: draft)
        guard clip.kind.compatibleTrack == draft.timeline.tracks[trackIndex].kind else { throw EditingError.invalidEdit }
        var inserted = clip
        inserted.timelineStart = time
        var edited: [TimelineClip] = []
        for existing in draft.timeline.tracks[trackIndex].clips {
            if existing.timelineStart >= time {
                var shifted = existing
                shifted.timelineStart = shifted.timelineStart + inserted.duration
                edited.append(shifted)
            } else if existing.timelineEnd > time {
                let leftDuration = time - existing.timelineStart
                let rightDuration = existing.timelineEnd - time
                edited.append(Self.segment(of: existing, offset: .zero, duration: leftDuration, preserveID: true))
                var right = Self.segment(of: existing, offset: leftDuration, duration: rightDuration, preserveID: false)
                right.timelineStart = time + inserted.duration
                edited.append(right)
            } else {
                edited.append(existing)
            }
        }
        edited.append(inserted)
        draft.timeline.tracks[trackIndex].clips = edited.sorted { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    mutating func overwriteEdit(_ clip: TimelineClip, into trackID: UUID, at time: RationalTime) throws {
        guard time >= .zero else { throw EditingError.invalidEdit }
        var draft = project
        let trackIndex = try editableTrackIndex(trackID, in: draft)
        guard clip.kind.compatibleTrack == draft.timeline.tracks[trackIndex].kind else { throw EditingError.invalidEdit }
        var inserted = clip
        inserted.timelineStart = time
        let overwriteRange = RationalTimeRange(start: time, duration: inserted.duration)
        var edited: [TimelineClip] = []
        for existing in draft.timeline.tracks[trackIndex].clips {
            guard existing.timeRange.intersects(overwriteRange) else {
                edited.append(existing)
                continue
            }
            if existing.timelineStart < overwriteRange.start {
                edited.append(Self.segment(
                    of: existing,
                    offset: .zero,
                    duration: overwriteRange.start - existing.timelineStart,
                    preserveID: true
                ))
            }
            if existing.timelineEnd > overwriteRange.end {
                let offset = overwriteRange.end - existing.timelineStart
                edited.append(Self.segment(
                    of: existing,
                    offset: offset,
                    duration: existing.timelineEnd - overwriteRange.end,
                    preserveID: false
                ))
            }
        }
        edited.append(inserted)
        draft.timeline.tracks[trackIndex].clips = edited.sorted { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    mutating func removeTimelineRanges(_ ranges: [RationalTimeRange]) throws {
        let ordered = ranges.filter { $0.start >= .zero && $0.duration > .zero }
            .sorted { $0.start > $1.start }
        guard !ordered.isEmpty else { return }
        var draft = project
        for range in ordered {
            for trackIndex in draft.timeline.tracks.indices {
                let track = draft.timeline.tracks[trackIndex]
                let affected = track.clips.contains { $0.timelineEnd > range.start }
                if affected && track.isLocked { throw EditingError.trackLocked(track.id) }
                var edited: [TimelineClip] = []
                for clip in track.clips {
                    if clip.timelineEnd <= range.start {
                        edited.append(clip)
                    } else if clip.timelineStart >= range.end {
                        var shifted = clip
                        shifted.timelineStart = shifted.timelineStart - range.duration
                        edited.append(shifted)
                    } else {
                        if clip.timelineStart < range.start {
                            edited.append(Self.segment(
                                of: clip,
                                offset: .zero,
                                duration: range.start - clip.timelineStart,
                                preserveID: true
                            ))
                        }
                        if clip.timelineEnd > range.end {
                            let offset = range.end - clip.timelineStart
                            var right = Self.segment(
                                of: clip,
                                offset: offset,
                                duration: clip.timelineEnd - range.end,
                                preserveID: false
                            )
                            right.timelineStart = range.start
                            edited.append(right)
                        }
                    }
                }
                draft.timeline.tracks[trackIndex].clips = edited.sorted { $0.timelineStart < $1.timelineStart }
            }
            draft.timeline.markers = draft.timeline.markers.compactMap { marker in
                if range.start <= marker.time && marker.time < range.end { return nil }
                var shifted = marker
                if shifted.time >= range.end { shifted.time = shifted.time - range.duration }
                return shifted
            }
        }
        try commit(draft)
    }

    mutating func rippleDelete(_ clipIDs: Set<UUID>) throws {
        guard !clipIDs.isEmpty else { return }
        var draft = project
        let expandedIDs = linkedClipIDs(for: clipIDs, in: draft)

        for trackIndex in draft.timeline.tracks.indices {
            let track = draft.timeline.tracks[trackIndex]
            let deleted = track.clips.filter { expandedIDs.contains($0.id) }.sorted { $0.timelineStart < $1.timelineStart }
            guard !deleted.isEmpty else { continue }
            guard !track.isLocked else { throw EditingError.trackLocked(track.id) }

            draft.timeline.tracks[trackIndex].clips = track.clips.compactMap { original in
                guard !expandedIDs.contains(original.id) else { return nil }
                var clip = original
                let shift = deleted
                    .filter { $0.timelineEnd <= original.timelineStart }
                    .reduce(RationalTime.zero) { $0 + $1.duration }
                clip.timelineStart = clip.timelineStart - shift
                return clip
            }.sorted { $0.timelineStart < $1.timelineStart }
        }
        try commit(draft)
    }

    @discardableResult
    mutating func groupClips(_ clipIDs: Set<UUID>) throws -> UUID {
        try assignSharedIdentifier(clipIDs, keyPath: \.groupID)
    }

    mutating func ungroupClips(_ clipIDs: Set<UUID>) throws {
        try clearSharedIdentifier(clipIDs, keyPath: \.groupID)
    }

    @discardableResult
    mutating func linkClips(_ clipIDs: Set<UUID>) throws -> UUID {
        try assignSharedIdentifier(clipIDs, keyPath: \.linkGroupID)
    }

    mutating func unlinkClips(_ clipIDs: Set<UUID>) throws {
        try clearSharedIdentifier(clipIDs, keyPath: \.linkGroupID)
    }

    mutating func setPlaybackRate(_ clipID: UUID, rate: Double, ripple: Bool) throws {
        guard rate.isFinite, (0.25...4).contains(rate) else { throw EditingError.invalidEdit }
        var draft = project
        let location = try clipLocation(clipID, in: draft)
        let track = draft.timeline.tracks[location.track]
        guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
        var clip = track.clips[location.clip]
        guard clip.kind == .video || clip.kind == .audio else { throw EditingError.invalidEdit }

        let oldDuration = clip.duration
        let sourceDuration = Self.scaled(oldDuration, by: clip.playbackRate)
        let newDuration = Self.scaled(sourceDuration, by: 1 / rate)
        guard newDuration > .zero else { throw EditingError.invalidEdit }
        clip.playbackRate = rate
        clip.duration = newDuration
        clip.fades = Self.clampedFadesForAdvancedEditing(clip.fades, duration: newDuration)
        draft.timeline.tracks[location.track].clips[location.clip] = clip

        if ripple {
            let delta = newDuration - oldDuration
            for index in draft.timeline.tracks[location.track].clips.indices where index != location.clip {
                if draft.timeline.tracks[location.track].clips[index].timelineStart >= clip.timelineStart + oldDuration {
                    draft.timeline.tracks[location.track].clips[index].timelineStart =
                        draft.timeline.tracks[location.track].clips[index].timelineStart + delta
                }
            }
        }
        draft.timeline.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    mutating func setReversed(_ reversed: Bool, for clipID: UUID) throws {
        try updateClip(clipID) { clip in
            guard clip.kind == .video || clip.kind == .audio else { return }
            clip.isReversed = reversed
        }
    }

    mutating func setColorAdjustments(_ adjustments: ColorAdjustments, for clipID: UUID) throws {
        try updateClip(clipID) { $0.colorAdjustments = adjustments }
    }

    mutating func addEffect(_ effect: VideoEffect, to clipID: UUID) throws {
        try updateClip(clipID) { $0.effects.append(effect) }
    }

    mutating func updateEffect(_ effect: VideoEffect, on clipID: UUID) throws {
        try updateClip(clipID) { clip in
            guard let index = clip.effects.firstIndex(where: { $0.id == effect.id }) else { return }
            clip.effects[index] = effect
        }
    }

    mutating func removeEffect(_ effectID: UUID, from clipID: UUID) throws {
        try updateClip(clipID) { $0.effects.removeAll { $0.id == effectID } }
    }

    mutating func setTransition(_ transition: ClipTransition?, edge: TransitionEdge, for clipID: UUID) throws {
        try updateClip(clipID) { clip in
            switch edge {
            case .in: clip.transitionIn = transition
            case .out: clip.transitionOut = transition
            }
        }
    }

    mutating func setKeyframe(_ property: KeyframedProperty, _ keyframe: ScalarKeyframe, for clipID: UUID) throws {
        try updateClip(clipID) { clip in
            var frames = clip.keyframes[property]
            frames.removeAll { $0.time == keyframe.time }
            frames.append(keyframe)
            frames.sort { $0.time < $1.time }
            clip.keyframes[property] = frames
        }
    }

    mutating func removeKeyframe(_ property: KeyframedProperty, at time: RationalTime, from clipID: UUID) throws {
        try updateClip(clipID) { $0.keyframes[property].removeAll { $0.time == time } }
    }

    mutating func pasteProperties(_ properties: ClipPropertyBundle, to clipIDs: Set<UUID>) throws {
        var draft = project
        for clipID in clipIDs {
            let location = try clipLocation(clipID, in: draft)
            let track = draft.timeline.tracks[location.track]
            guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
            draft.timeline.tracks[location.track].clips[location.clip].transform = properties.transform
            draft.timeline.tracks[location.track].clips[location.clip].opacity = properties.opacity
            draft.timeline.tracks[location.track].clips[location.clip].audioVolume = properties.audioVolume
            let duration = draft.timeline.tracks[location.track].clips[location.clip].duration
            draft.timeline.tracks[location.track].clips[location.clip].fades = Self.clampedFadesForAdvancedEditing(
                properties.fades,
                duration: duration
            )
            draft.timeline.tracks[location.track].clips[location.clip].colorAdjustments = properties.colorAdjustments
            draft.timeline.tracks[location.track].clips[location.clip].effects = properties.effects.map { effect in
                var copy = effect
                copy.id = UUID()
                return copy
            }
            var keyframes = properties.keyframes
            for property in KeyframedProperty.allCases {
                keyframes[property] = keyframes[property].filter { $0.time <= duration }
            }
            draft.timeline.tracks[location.track].clips[location.clip].keyframes = keyframes
        }
        try commit(draft)
    }

    @discardableResult
    mutating func addMarker(at time: RationalTime, name: String = "Marker") throws -> UUID {
        guard time >= .zero else { throw EditingError.invalidEdit }
        var draft = project
        let marker = TimelineMarker(time: time, name: name)
        draft.timeline.markers.append(marker)
        draft.timeline.markers.sort { $0.time < $1.time }
        try commit(draft)
        return marker.id
    }

    mutating func removeMarker(_ markerID: UUID) throws {
        var draft = project
        draft.timeline.markers.removeAll { $0.id == markerID }
        try commit(draft)
    }

    @discardableResult
    mutating func addMarkers(at times: [RationalTime], namePrefix: String) throws -> [UUID] {
        let uniqueTimes = Array(Set(times.filter { $0 >= .zero })).sorted()
        guard !uniqueTimes.isEmpty else { return [] }
        var draft = project
        let markers = uniqueTimes.enumerated().map { index, time in
            TimelineMarker(time: time, name: "\(namePrefix) \(index + 1)", colorHex: "#EF8A47FF")
        }
        draft.timeline.markers.append(contentsOf: markers)
        draft.timeline.markers.sort { $0.time < $1.time }
        try commit(draft)
        return markers.map(\.id)
    }

    @discardableResult
    mutating func addSubtitles(
        _ cues: [SubtitleCue],
        to trackID: UUID,
        style: TextStyle = TextStyle(fontSize: 54, fontWeight: 0.5)
    ) throws -> [UUID] {
        var draft = project
        let trackIndex = try editableTrackIndex(trackID, in: draft)
        guard draft.timeline.tracks[trackIndex].kind == .video else { throw EditingError.invalidEdit }
        let clips = cues.map { cue -> TimelineClip in
            var cueStyle = style
            cueStyle.text = cue.text
            return TimelineClip(
                name: cue.text,
                kind: .text,
                timelineStart: cue.start,
                duration: cue.duration,
                textStyle: cueStyle,
                role: .subtitle
            )
        }
        draft.timeline.tracks[trackIndex].clips.append(contentsOf: clips)
        draft.timeline.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
        return clips.map(\.id)
    }

    private func linkedClipIDs(for clipIDs: Set<UUID>, in project: CineleafProject) -> Set<UUID> {
        let allClips = project.timeline.tracks.flatMap(\.clips)
        let linkGroups = Set(allClips.filter { clipIDs.contains($0.id) }.compactMap(\.linkGroupID))
        return clipIDs.union(allClips.filter { clip in
            guard let groupID = clip.linkGroupID else { return false }
            return linkGroups.contains(groupID)
        }.map(\.id))
    }

    private mutating func assignSharedIdentifier(
        _ clipIDs: Set<UUID>,
        keyPath: WritableKeyPath<TimelineClip, UUID?>
    ) throws -> UUID {
        guard clipIDs.count >= 2 else { throw EditingError.invalidEdit }
        var draft = project
        let identifier = UUID()
        for clipID in clipIDs {
            let location = try clipLocation(clipID, in: draft)
            let track = draft.timeline.tracks[location.track]
            guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
            draft.timeline.tracks[location.track].clips[location.clip][keyPath: keyPath] = identifier
        }
        try commit(draft)
        return identifier
    }

    private mutating func clearSharedIdentifier(
        _ clipIDs: Set<UUID>,
        keyPath: WritableKeyPath<TimelineClip, UUID?>
    ) throws {
        var draft = project
        for clipID in clipIDs {
            let location = try clipLocation(clipID, in: draft)
            let track = draft.timeline.tracks[location.track]
            guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
            draft.timeline.tracks[location.track].clips[location.clip][keyPath: keyPath] = nil
        }
        try commit(draft)
    }

    private static func clampedFadesForAdvancedEditing(_ fades: ClipFades, duration: RationalTime) -> ClipFades {
        let half = RationalTime(seconds: max(duration.seconds / 2, 0), preferredTimescale: 60_000)
        return ClipFades(
            videoIn: min(fades.videoIn, half), videoOut: min(fades.videoOut, half),
            audioIn: min(fades.audioIn, half), audioOut: min(fades.audioOut, half)
        )
    }

    static func segment(
        of original: TimelineClip,
        offset: RationalTime,
        duration: RationalTime,
        preserveID: Bool
    ) -> TimelineClip {
        var segment = original
        if !preserveID { segment.id = UUID() }
        segment.timelineStart = original.timelineStart + offset
        segment.duration = duration
        if original.kind != .text && original.kind != .image {
            if original.isReversed {
                let trailingDuration = original.duration - offset - duration
                segment.sourceStart = original.sourceStart + scaled(trailingDuration, by: original.playbackRate)
            } else {
                segment.sourceStart = original.sourceStart + scaled(offset, by: original.playbackRate)
            }
        }
        if offset > .zero { segment.transitionIn = nil }
        if offset + duration < original.duration { segment.transitionOut = nil }
        segment.fades = clampedFadesForAdvancedEditing(segment.fades, duration: duration)
        for property in KeyframedProperty.allCases {
            segment.keyframes[property] = original.keyframes[property].compactMap { frame in
                guard frame.time >= offset, frame.time <= offset + duration else { return nil }
                var rebased = frame
                rebased.time = frame.time - offset
                return rebased
            }
        }
        return segment
    }
}
