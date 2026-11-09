import AVFoundation
import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Music, voice-overs and sound effects laid on the timeline, and the sound tools (noise reduction, volume matching).
extension EditorSession {
    var sounds: [SoundClip] { project.soundClips }
    var selectedSound: SoundClip? { project.soundClips.first { $0.id == selectedSoundID } }
    /// Sounds can be laid under a picture; a file that is only sound has no picture to lay them under.
    var canHaveSounds: Bool { isProject || info?.hasVideo == true }

    /// The sounds with their files found again where they were moved to (through the bookmark taken when they were added).
    func resolvedSounds() -> [SoundClip] {
        project.soundClips.map { c in
            guard !FileManager.default.fileExists(atPath: c.path), let moved = Bookmarks.resolve(c.bookmark), FileManager.default.fileExists(atPath: moved.path) else { return c }
            var n = c; n.path = moved.path; return n
        }
    }
    func isMissing(_ c: SoundClip) -> Bool { !resolvedSounds().contains { $0.id == c.id && FileManager.default.fileExists(atPath: $0.path) } }

    func updateSound(_ id: UUID, _ label: String, coalesce: String? = nil, _ change: @escaping (inout SoundClip) -> Void) {
        edit(label, coalesce: coalesce.map { "\($0)-\(id)" }) { p in
            var all = p.soundClips
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            change(&all[i])
            p.soundClips = all
        }
    }

    func deleteSound(_ id: UUID) {
        edit("Delete sound") { $0.soundClips.removeAll { $0.id == id } }
        if selectedSoundID == id { selectedSoundID = nil }
    }

    func duplicateSound(_ id: UUID) {
        guard let c = sounds.first(where: { $0.id == id }) else { return }
        var n = c; n.id = UUID(); n.start = c.end
        edit("Duplicate sound") { $0.soundClips.append(n) }
        selectedSoundID = n.id
    }

    /// Adds files as sounds starting at `at` (the playhead by default), one after the other.
    func addSounds(urls: [URL], kind: SoundKind, at: MediaTime? = nil) async {
        var position = at ?? player.currentTime
        let hasOwnSound = info?.hasAudio == true || (isProject && infos.values.contains { $0.hasAudio })
        var added: [SoundClip] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty, let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0.05 else {
                flash(LF("“%@” has no sound that can be used.", url.lastPathComponent), error: true); continue
            }
            let length = MediaTime(d)
            var c = SoundClip(name: url.deletingPathExtension().lastPathComponent, path: url.path, bookmark: Bookmarks.make(url), kind: kind, start: position, duration: length, fileDuration: length)
            if kind == .music { c.fadeIn = 0.5; c.fadeOut = 1; if hasOwnSound { c.gainDB = -8 } }
            added.append(c)
            position = c.end
        }
        guard !added.isEmpty else { return }
        edit(kind == .voice ? "Add voice-over" : "Add sound") { $0.soundClips += added }
        selectedSoundID = added.last?.id
        if let last = added.last, last.end > duration { flash(L("The sound is longer than the video. The part after the end of the video is not used.")) }
    }

    func chooseSounds(kind: SoundKind) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = true
        p.message = kind == .music ? L("Choose the music or sound to lay under the video.") : L("Choose the sound effect.")
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        Task { await addSounds(urls: urls, kind: kind) }
    }

    // MARK: Voice-over

    func toggleVoiceRecording() {
        if recorder.isRecording { finishVoiceRecording(); return }
        guard canHaveSounds else { return }
        let startAt = player.currentTime
        Task {
            do {
                voiceStart = startAt
                _ = try await recorder.start(in: env.support.appendingPathComponent("Recordings", isDirectory: true))
                if recordWithPlayback { player.play() }
            } catch {
                flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true)
            }
        }
    }

    func finishVoiceRecording() {
        player.pause()
        guard let url = recorder.stop() else { return }
        let start = voiceStart
        Task {
            await addSounds(urls: [url], kind: .voice, at: start)
            if let id = selectedSoundID { updateSound(id, "Name voice-over") { $0.name = L("Voice-over") + " " + Timecode.format(start) } }
            flash(L("The voice-over was added to the timeline."))
        }
    }

    // MARK: Volume

    /// Brings the video's own sound to a comfortable level (about -18 dBFS on average, the peaks kept clear of the ceiling).
    func normalizeMainVolume() {
        guard let url = activeSourceURL else { return }
        var range: CMTimeRange?
        if isProject, let c = timingClip { range = CMTimeRange(start: c.sourceStart.cmTime, duration: (c.sourceEnd - c.sourceStart).cmTime) }
        flash(L("Measuring the volume…"))
        Task {
            guard let l = try? await AudioAnalysis.loudness(url: url, range: range) else { flash(L("There is no sound to measure here."), error: true); return }
            let g = (LoudnessMatch.gainDB(averageDB: l.averageDB, peakDB: l.peakDB) * 10).rounded() / 10
            edit("Match volume") { $0.activeAudio.gainDB = g }
            flash(LF("Volume set to %+.1f dB.", g))
        }
    }

    func normalizeSoundVolume(_ id: UUID) {
        guard let c = resolvedSounds().first(where: { $0.id == id }) else { return }
        flash(L("Measuring the volume…"))
        let range = CMTimeRange(start: c.sourceStart.cmTime, duration: c.duration.cmTime)
        Task {
            guard let l = try? await AudioAnalysis.loudness(url: URL(fileURLWithPath: c.path), range: range) else { flash(L("There is no sound to measure here."), error: true); return }
            // Music sits under a voice, so it is brought to a lower level than the voice itself.
            let target = c.kind == .music ? -24.0 : -18.0
            let g = (LoudnessMatch.gainDB(averageDB: l.averageDB, peakDB: l.peakDB, target: target) * 10).rounded() / 10
            updateSound(id, "Match volume") { $0.gainDB = g }
            flash(LF("Volume set to %+.1f dB.", g))
        }
    }

    // MARK: Noise reduction

    enum DenoiseTarget: Hashable { case main, sound(UUID) }

    /// Turns noise reduction on at a strength, or off (nil). The cleaned copy is made first (it takes a while for a long sound); the original is not touched.
    func setDenoise(_ strength: Double?, for target: DenoiseTarget) {
        func apply(_ s: Double?) {
            switch target {
            case .main: edit("Noise reduction") { $0.activeAudio.denoise = s }
            case .sound(let id): updateSound(id, "Noise reduction") { $0.denoise = s }
            }
        }
        guard let strength else { apply(nil); return }
        let url: URL?
        switch target {
        case .main: url = activeSourceURL
        case .sound(let id): url = resolvedSounds().first { $0.id == id }.map { URL(fileURLWithPath: $0.path) }
        }
        guard let url else { return }
        if NoiseReducer.cached(for: url, strength: strength) != nil { apply(strength); return }
        denoiseProgress[target] = 0
        flash(L("Cleaning the sound… this can take a little while."))
        Task {
            defer { denoiseProgress[target] = nil }
            do {
                _ = try await NoiseReducer.clean(url, strength: strength) { f in Task { @MainActor in self.denoiseProgress[target] = f } }
                apply(strength)
                flash(L("The background noise was reduced."))
            } catch { flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
        }
    }
}

extension EditorSession {
    /// Changes the filter and effect settings of the clip being edited. When the preview is already drawn by the compositor the new settings are
    /// handed to it directly, so the picture changes at the next frame; building the preview again every time made each click on a filter stall
    /// playback for about half a second. The first change, which has to switch the compositor on, still builds it.
    func editEffects(_ label: String, coalesce: String? = nil, _ change: @escaping (inout LookEffects) -> Void) {
        var probe = project
        change(&probe.activeLook.effects)
        guard probe != project else { return }
        let key = isProject ? project.activeClipID : project.id
        guard previewHasCompositor, let key else { edit(label, coalesce: coalesce) { change(&$0.activeLook.effects) }; return }
        edit(label, coalesce: coalesce, refreshPreview: false) { change(&$0.activeLook.effects) }
        EffectsLive.set(project.activeLook.effects, for: key)
        // Paused: draw the frame on show again with the new settings.
        if !player.isPlaying { Task { await player.seek(to: player.currentTime) } }
    }
}
