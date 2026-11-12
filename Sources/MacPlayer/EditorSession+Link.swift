import AppKit
import Combine
import Foundation
import MacPlayerCore

extension EditorSession {
    /// A video, a stream or a photo opened from a web link (0.15), to watch only. A photo is fetched first (`photoFile`).
    static func openRemote(_ source: RemoteSource, photoFile: URL? = nil) async throws -> EditorSession {
        if source.kind == .photo {
            guard let file = photoFile else { throw LinkError(L("The photo could not be fetched.")) }
            let s = try await openPhoto(url: file)
            s.remote = source
            s.mutateQuietly { $0.name = source.displayName }
            if var i = s.info, let n = source.byteCount { i.fileSize = n; s.info = i }
            return s
        }
        let ext = source.link.pathExtension.lowercased()
        let info = MediaInfo(duration: .zero, fileExtension: ext.isEmpty ? (source.kind == .stream ? "m3u8" : "") : ext, fileSize: source.byteCount ?? 0, video: [], audio: [])
        let project = Project(name: source.displayName, kind: .video, sources: [SourceRef(path: source.link.absoluteString, info: info)])
        let s = EditorSession(project: project, projectPath: nil, role: .viewer)
        s.remote = source
        await s.attachRemote(info: info)
        return s
    }

    /// Plays the link. What is known about the picture (its size, its length) arrives from the player as it connects.
    func attachRemote(info: MediaInfo) async {
        guard let r = remote else { return }
        sourceURL = r.link
        self.info = info
        if let id = project.sources.first?.id { sourceURLs[id] = r.link; infos[id] = info }
        remoteBag.removeAll()
        player.$presentationSize.receive(on: DispatchQueue.main).sink { [weak self] size in
            guard let self, size.width > 0, var i = self.info else { return }
            let track = MediaInfo.VideoTrack(trackID: 1, codec: i.primaryVideo?.codec ?? "", width: Int(size.width.rounded()), height: Int(size.height.rounded()))
            if i.video.first?.width != track.width || i.video.first?.height != track.height { i.video = [track]; self.info = i }
        }.store(in: &remoteBag)
        player.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
            guard let self, d > .zero, var i = self.info, i.duration != d else { return }
            i.duration = d; self.info = i
        }.store(in: &remoteBag)
        await loadPlayer(at: nil)
    }

    /// Tries the link again after it failed (the network came back, the server answered again).
    func retryRemote() async {
        guard let r = remote, r.kind != .photo, let i = info else { return }
        let at = player.currentTime
        await attachRemote(info: i)
        if at > .zero, !player.isLive { await player.seek(to: at) }
        player.play()
    }

    /// A line about what is shown: size, rate, length and file size for a file; the server and the kind for a link.
    var mediaSummary: String {
        var parts: [String] = []
        if let r = remote { parts.append(r.host) }
        if let v = info?.primaryVideo, v.width > 0 {
            parts.append("\(v.width) × \(v.height)")
            if let fr = v.frameRate, !isPhoto { parts.append(String(format: "%g fps", (fr.framesPerSecond * 100).rounded() / 100)) }
        }
        if remote?.kind == .stream { parts.append(player.isLive ? L("Live stream") : L("HLS stream")) }
        if !isPhoto, !player.isLive, let d = info?.duration, d > .zero { parts.append(Format.duration(d)) }
        // A stream's "size" is only its list of pieces.
        if remote?.kind != .stream, let n = info?.fileSize, n > 0 { parts.append(Format.bytes(n)) }
        return parts.joined(separator: " · ")
    }
}
