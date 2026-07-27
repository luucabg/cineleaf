import Foundation

public enum EditingError: Error, Equatable, Sendable {
    case trackNotFound(UUID)
    case clipNotFound(UUID)
    case trackLocked(UUID)
    case invalidEdit
    case noCompatibleTrack
}

public struct SnapResult: Equatable, Sendable {
    public var time: RationalTime
    public var didSnap: Bool

    public init(time: RationalTime, didSnap: Bool) {
        self.time = time
        self.didSnap = didSnap
    }
}

public struct ProjectEditor: Sendable {
    public private(set) var project: CineleafProject

    public init(project: CineleafProject) throws {
        try ProjectValidator.validate(project)
        self.project = project
    }

    public mutating func addAsset(_ asset: MediaAsset) throws {
        var draft = project
        draft.assets.append(asset)
        try commit(draft)
    }

    public mutating func replaceAsset(_ asset: MediaAsset) throws {
        var draft = project
        guard let index = draft.assets.firstIndex(where: { $0.id == asset.id }) else {
            throw ProjectValidationError.missingAsset(asset.id)
        }
        draft.assets[index] = asset
        try commit(draft)
    }

    public mutating func replaceAssets(_ assets: [MediaAsset]) throws {
        guard !assets.isEmpty else { return }
        let replacements = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var draft = project
        let existingIDs = Set(draft.assets.map(\.id))
        guard replacements.keys.allSatisfy(existingIDs.contains) else {
            throw EditingError.invalidEdit
        }
        for index in draft.assets.indices {
            if let replacement = replacements[draft.assets[index].id] {
                draft.assets[index] = replacement
            }
        }
        try commit(draft)
    }

    @discardableResult
    public mutating func addTrack(name: String, kind: TrackKind, at index: Int? = nil) throws -> UUID {
        var draft = project
        let track = TimelineTrack(name: name, kind: kind)
        let insertionIndex = min(max(index ?? draft.timeline.tracks.count, 0), draft.timeline.tracks.count)
        draft.timeline.tracks.insert(track, at: insertionIndex)
        try commit(draft)
        return track.id
    }

    public mutating func setTrackMuted(_ trackID: UUID, muted: Bool) throws {
        var draft = project
        let index = try trackIndex(trackID, in: draft)
        draft.timeline.tracks[index].isMuted = muted
        try commit(draft)
    }

    public mutating func setTrackLocked(_ trackID: UUID, locked: Bool) throws {
        var draft = project
        let index = try trackIndex(trackID, in: draft)
        draft.timeline.tracks[index].isLocked = locked
        try commit(draft)
    }

    public mutating func insert(_ clip: TimelineClip, into trackID: UUID) throws {
        var draft = project
        let index = try editableTrackIndex(trackID, in: draft)
        draft.timeline.tracks[index].clips.append(clip)
        draft.timeline.tracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    public mutating func updateClip(_ clipID: UUID, mutation: (inout TimelineClip) -> Void) throws {
        var draft = project
        let location = try clipLocation(clipID, in: draft)
        guard !draft.timeline.tracks[location.track].isLocked else {
            throw EditingError.trackLocked(draft.timeline.tracks[location.track].id)
        }
        mutation(&draft.timeline.tracks[location.track].clips[location.clip])
        draft.timeline.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    public mutating func moveClip(_ clipID: UUID, to start: RationalTime, trackID: UUID? = nil) throws {
        guard start >= .zero else { throw EditingError.invalidEdit }
        var draft = project
        let source = try clipLocation(clipID, in: draft)
        let sourceTrack = draft.timeline.tracks[source.track]
        guard !sourceTrack.isLocked else { throw EditingError.trackLocked(sourceTrack.id) }
        var clip = sourceTrack.clips[source.clip]

        let allClips = draft.timeline.tracks.flatMap(\.clips)
        let companionIDs = Set(allClips.filter { candidate in
            candidate.id == clip.id
                || (clip.groupID != nil && candidate.groupID == clip.groupID)
                || (clip.linkGroupID != nil && candidate.linkGroupID == clip.linkGroupID)
        }.map(\.id))
        if companionIDs.count > 1 {
            guard trackID == nil || trackID == sourceTrack.id else { throw EditingError.invalidEdit }
            let delta = start - clip.timelineStart
            for trackIndex in draft.timeline.tracks.indices {
                let affected = draft.timeline.tracks[trackIndex].clips.contains { companionIDs.contains($0.id) }
                if affected && draft.timeline.tracks[trackIndex].isLocked {
                    throw EditingError.trackLocked(draft.timeline.tracks[trackIndex].id)
                }
                for clipIndex in draft.timeline.tracks[trackIndex].clips.indices
                    where companionIDs.contains(draft.timeline.tracks[trackIndex].clips[clipIndex].id) {
                    let newStart = draft.timeline.tracks[trackIndex].clips[clipIndex].timelineStart + delta
                    guard newStart >= .zero else { throw EditingError.invalidEdit }
                    draft.timeline.tracks[trackIndex].clips[clipIndex].timelineStart = newStart
                }
                draft.timeline.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
            }
            try commit(draft)
            return
        }

        draft.timeline.tracks[source.track].clips.remove(at: source.clip)

        let destinationID = trackID ?? sourceTrack.id
        let destination = try editableTrackIndex(destinationID, in: draft)
        clip.timelineStart = start
        draft.timeline.tracks[destination].clips.append(clip)
        draft.timeline.tracks[destination].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    public mutating func trimStart(of clipID: UUID, to newStart: RationalTime) throws {
        var draft = project
        let location = try clipLocation(clipID, in: draft)
        let track = draft.timeline.tracks[location.track]
        guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
        var clip = track.clips[location.clip]
        let delta = newStart - clip.timelineStart
        guard newStart >= .zero, delta < clip.duration, clip.sourceStart + delta >= .zero else {
            throw EditingError.invalidEdit
        }
        clip.timelineStart = newStart
        clip.duration = clip.duration - delta
        if clip.kind != .text, !clip.isReversed {
            clip.sourceStart = clip.sourceStart + Self.scaled(delta, by: clip.playbackRate)
        }
        clip.fades = Self.clampedFades(clip.fades, duration: clip.duration)
        draft.timeline.tracks[location.track].clips[location.clip] = clip
        draft.timeline.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
    }

    public mutating func trimEnd(of clipID: UUID, to newEnd: RationalTime) throws {
        try updateClip(clipID) { clip in
            let oldDuration = clip.duration
            clip.duration = newEnd - clip.timelineStart
            if clip.kind != .text, clip.isReversed, clip.duration < oldDuration {
                clip.sourceStart = clip.sourceStart + Self.scaled(oldDuration - clip.duration, by: clip.playbackRate)
            }
            clip.fades = Self.clampedFades(clip.fades, duration: clip.duration)
        }
    }

    @discardableResult
    public mutating func splitClip(_ clipID: UUID, at time: RationalTime) throws -> UUID {
        var draft = project
        let location = try clipLocation(clipID, in: draft)
        let track = draft.timeline.tracks[location.track]
        guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
        var first = track.clips[location.clip]
        guard time > first.timelineStart, time < first.timelineEnd else { throw EditingError.invalidEdit }

        let leftDuration = time - first.timelineStart
        var second = first
        second.id = UUID()
        second.timelineStart = time
        second.duration = first.duration - leftDuration
        if second.kind != .text {
            let leftSourceDuration = Self.scaled(leftDuration, by: first.playbackRate)
            if first.isReversed {
                first.sourceStart = first.sourceStart + Self.scaled(first.duration, by: first.playbackRate) - leftSourceDuration
            } else {
                second.sourceStart = first.sourceStart + leftSourceDuration
            }
        }
        first.duration = leftDuration
        draft.timeline.tracks[location.track].clips[location.clip] = first
        draft.timeline.tracks[location.track].clips.insert(second, at: location.clip + 1)
        try commit(draft)
        return second.id
    }

    public mutating func deleteClips(_ clipIDs: Set<UUID>) throws {
        var draft = project
        let selected = draft.timeline.tracks.flatMap(\.clips).filter { clipIDs.contains($0.id) }
        let groupIDs = Set(selected.compactMap(\.groupID))
        let linkIDs = Set(selected.compactMap(\.linkGroupID))
        let expandedIDs = clipIDs.union(draft.timeline.tracks.flatMap(\.clips).filter { clip in
            (clip.groupID.map(groupIDs.contains) ?? false) || (clip.linkGroupID.map(linkIDs.contains) ?? false)
        }.map(\.id))
        for index in draft.timeline.tracks.indices {
            let affected = draft.timeline.tracks[index].clips.contains { expandedIDs.contains($0.id) }
            if affected && draft.timeline.tracks[index].isLocked {
                throw EditingError.trackLocked(draft.timeline.tracks[index].id)
            }
            draft.timeline.tracks[index].clips.removeAll { expandedIDs.contains($0.id) }
        }
        try commit(draft)
    }

    @discardableResult
    public mutating func duplicateClip(_ clipID: UUID, at start: RationalTime? = nil) throws -> UUID {
        var draft = project
        let location = try clipLocation(clipID, in: draft)
        let track = draft.timeline.tracks[location.track]
        guard !track.isLocked else { throw EditingError.trackLocked(track.id) }
        var duplicate = track.clips[location.clip]
        let originalID = duplicate.id
        duplicate.id = UUID()
        duplicate.timelineStart = start ?? Self.firstAvailableStart(
            in: track.clips,
            after: duplicate.timelineEnd,
            duration: duplicate.duration,
            excluding: originalID
        )
        duplicate.groupID = nil
        duplicate.linkGroupID = nil
        draft.timeline.tracks[location.track].clips.append(duplicate)
        draft.timeline.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
        return duplicate.id
    }

    @discardableResult
    public mutating func detachAudio(from clipID: UUID, to audioTrackID: UUID? = nil) throws -> UUID {
        var draft = project
        let location = try clipLocation(clipID, in: draft)
        let sourceTrack = draft.timeline.tracks[location.track]
        guard !sourceTrack.isLocked else { throw EditingError.trackLocked(sourceTrack.id) }
        var source = sourceTrack.clips[location.clip]
        guard source.kind == .video,
              let assetID = source.assetID,
              draft.assets.first(where: { $0.id == assetID })?.metadata.hasAudio == true else {
            throw EditingError.invalidEdit
        }

        let destinationIndex: Int
        if let audioTrackID {
            destinationIndex = try editableTrackIndex(audioTrackID, in: draft)
        } else if let existing = draft.timeline.tracks.firstIndex(where: { track in
            track.kind == .audio && !track.isLocked && track.clips.allSatisfy { !$0.timeRange.intersects(source.timeRange) }
        }) {
            destinationIndex = existing
        } else {
            draft.timeline.tracks.append(TimelineTrack(name: "A\(draft.timeline.tracks.filter { $0.kind == .audio }.count + 1)", kind: .audio))
            destinationIndex = draft.timeline.tracks.count - 1
        }
        guard draft.timeline.tracks[destinationIndex].kind == .audio else { throw EditingError.invalidEdit }
        guard draft.timeline.tracks[destinationIndex].clips.allSatisfy({ !$0.timeRange.intersects(source.timeRange) }) else {
            throw EditingError.invalidEdit
        }

        var audio = source
        audio.id = UUID()
        audio.kind = .audio
        audio.isVideoMuted = true
        audio.transform = ClipTransform()
        audio.opacity = 1
        audio.groupID = nil
        audio.linkGroupID = nil
        source.audioVolume = 0
        draft.timeline.tracks[location.track].clips[location.clip] = source
        draft.timeline.tracks[destinationIndex].clips.append(audio)
        draft.timeline.tracks[destinationIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        try commit(draft)
        return audio.id
    }

    public func snappedTime(
        proposed: RationalTime,
        playhead: RationalTime,
        excluding clipID: UUID? = nil,
        threshold: RationalTime
    ) -> SnapResult {
        var candidates = [RationalTime.zero, playhead]
        candidates += project.timeline.tracks
            .flatMap(\.clips)
            .filter { $0.id != clipID }
            .flatMap { [$0.timelineStart, $0.timelineEnd] }

        let closest = candidates.min {
            RationalTime.absolute($0 - proposed) < RationalTime.absolute($1 - proposed)
        }
        guard let closest, RationalTime.absolute(closest - proposed) <= threshold else {
            return SnapResult(time: proposed, didSnap: false)
        }
        return SnapResult(time: closest, didSnap: true)
    }

    mutating func commit(_ draft: CineleafProject) throws {
        var updated = draft
        updated.modifiedAt = Date()
        try ProjectValidator.validate(updated)
        project = updated
    }

    func trackIndex(_ id: UUID, in project: CineleafProject) throws -> Int {
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) else {
            throw EditingError.trackNotFound(id)
        }
        return index
    }

    func editableTrackIndex(_ id: UUID, in project: CineleafProject) throws -> Int {
        let index = try trackIndex(id, in: project)
        guard !project.timeline.tracks[index].isLocked else { throw EditingError.trackLocked(id) }
        return index
    }

    func clipLocation(_ id: UUID, in project: CineleafProject) throws -> (track: Int, clip: Int) {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                return (trackIndex, clipIndex)
            }
        }
        throw EditingError.clipNotFound(id)
    }

    private static func clampedFades(_ fades: ClipFades, duration: RationalTime) -> ClipFades {
        let half = RationalTime(seconds: max(duration.seconds / 2, 0), preferredTimescale: 6_000)
        return ClipFades(
            videoIn: min(fades.videoIn, half),
            videoOut: min(fades.videoOut, half),
            audioIn: min(fades.audioIn, half),
            audioOut: min(fades.audioOut, half)
        )
    }

    static func scaled(_ time: RationalTime, by factor: Double) -> RationalTime {
        RationalTime(seconds: time.seconds * factor, preferredTimescale: 60_000)
    }

    private static func firstAvailableStart(
        in clips: [TimelineClip],
        after start: RationalTime,
        duration: RationalTime,
        excluding clipID: UUID
    ) -> RationalTime {
        var candidate = start
        for clip in clips.filter({ $0.id != clipID }).sorted(by: { $0.timelineStart < $1.timelineStart }) {
            if clip.timelineEnd <= candidate { continue }
            if candidate + duration <= clip.timelineStart { return candidate }
            candidate = clip.timelineEnd
        }
        return candidate
    }
}

public struct EditHistory: Sendable {
    public let limit: Int
    private var past: [CineleafProject] = []
    private var future: [CineleafProject] = []

    public init(limit: Int = 50) {
        precondition(limit > 0, "Undo limit must be positive")
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public mutating func record(_ stateBeforeEdit: CineleafProject) {
        past.append(stateBeforeEdit)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll(keepingCapacity: true)
    }

    public mutating func undo(current: CineleafProject) -> CineleafProject? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    public mutating func redo(current: CineleafProject) -> CineleafProject? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    public mutating func reset() {
        past.removeAll(keepingCapacity: false)
        future.removeAll(keepingCapacity: false)
    }
}
