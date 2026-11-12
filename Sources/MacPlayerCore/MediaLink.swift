import Foundation

/// A web link someone pasted to watch (0.15): is it a link straight to a video, a stream or a photo, a watch page of a site
/// (YouTube, Facebook, TikTok…) that MacPlayer cannot play, or not a web link at all. Pure text rules, no network: the app
/// asks the server only when the person opens the link, and only when the address alone does not say what it is.
public enum MediaLink {
    /// What the address points to.
    public enum Kind: String, Equatable, Sendable {
        /// A video or sound file (MP4, MOV, M4V, M4A, MP3…): played as it downloads; can be saved.
        case video
        /// An HLS stream (`.m3u8`): played as it comes, cannot be saved as one file; may be live.
        case stream
        /// A picture (JPG, PNG, HEIC, GIF, WebP…): fetched once, then shown like a photo on the Mac.
        case photo
        /// The address does not say; the server is asked (its `Content-Type`).
        case unknown
    }

    /// Sites whose links open a page with their own player, not a file.
    public enum Site: String, CaseIterable, Equatable, Sendable {
        case youtube, facebook, tiktok, instagram, vimeo, x, googleDrive, oneDrive

        public var name: String {
            switch self {
            case .youtube: return "YouTube"
            case .facebook: return "Facebook"
            case .tiktok: return "TikTok"
            case .instagram: return "Instagram"
            case .vimeo: return "Vimeo"
            case .x: return "X (Twitter)"
            case .googleDrive: return "Google Drive"
            case .oneDrive: return "OneDrive"
            }
        }

        /// Host names (and their subdomains) of the site.
        var hosts: [String] {
            switch self {
            case .youtube: return ["youtube.com", "youtu.be", "youtube-nocookie.com"]
            case .facebook: return ["facebook.com", "fb.watch", "fb.com"]
            case .tiktok: return ["tiktok.com"]
            case .instagram: return ["instagram.com"]
            case .vimeo: return ["vimeo.com"]
            case .x: return ["x.com", "twitter.com"]
            case .googleDrive: return ["drive.google.com", "docs.google.com"]
            case .oneDrive: return ["onedrive.live.com", "1drv.ms"]
            }
        }
    }

    public enum Problem: Equatable, Sendable {
        /// Not an http(s) address (a file path, ftp, mailto…).
        case notWeb
        /// Cannot be read as an address.
        case malformed
        /// A format this Mac cannot play (MKV, WebM, AVI, FLV, WMV…), by its extension.
        case unsupported(String)
    }

    /// Something worth telling about a link that can be opened.
    public enum Note: Equatable, Sendable {
        /// A Dropbox share link was changed to its direct form (`raw=1`).
        case dropboxMadeDirect
        /// `http://`: what is downloaded is not encrypted.
        case notEncrypted
    }

    public enum Verdict: Equatable, Sendable {
        case empty
        case problem(Problem)
        /// A watch page of a site: it cannot be played here.
        case page(Site)
        case ok(Link)
    }

    public struct Link: Equatable, Sendable {
        public var url: URL
        public var kind: Kind
        public var notes: [Note]
        /// A short name to show: the file's name without its extension, else the host.
        public var displayName: String { MediaLink.displayName(of: url) }
        public init(url: URL, kind: Kind, notes: [Note] = []) { self.url = url; self.kind = kind; self.notes = notes }
    }

    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp", "3g2", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "ts"]
    public static let streamExtensions: Set<String> = ["m3u8", "m3u"]
    public static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif"]
    public static let unsupportedExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "rm", "rmvb", "ogv", "mpd"]

    /// Reads what someone typed or pasted.
    public static func check(_ text: String) -> Verdict {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted with quotes or angle brackets around it.
        while let f = s.first, let l = s.last, s.count >= 2, (f == "<" && l == ">") || (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return .empty }
        // Only the first line of several.
        if let nl = s.firstIndex(where: \.isNewline) { s = String(s[..<nl]) }
        let lower = s.lowercased()
        if lower.hasPrefix("/") || lower.hasPrefix("~") || lower.hasPrefix("file:") { return .problem(.notWeb) }
        if let colon = lower.firstIndex(of: ":"), !lower.hasPrefix("http://"), !lower.hasPrefix("https://") {
            // "ftp://…", "mailto:…" — but not "example.com:8080/a.mp4".
            let scheme = lower[..<colon]
            if scheme.allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }), !scheme.contains(".") { return .problem(.notWeb) }
        }
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            // "example.com/video.mp4": a web address without its scheme.
            guard let firstPart = lower.split(separator: "/").first, firstPart.contains("."), !firstPart.contains(" ") else { return .problem(.malformed) }
            s = "https://" + s
        }
        // Spaces and letters with accents pasted inside an address (what a browser shows) are escaped; escapes already there stay.
        var allowed = CharacterSet.urlQueryAllowed; allowed.insert(charactersIn: "#%")
        s = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        guard var comps = URLComponents(string: s), let host = comps.host?.lowercased(), !host.isEmpty, host.contains(".") || host == "localhost" || isIPAddress(host)
        else { return .problem(.malformed) }
        comps.host = host
        var notes: [Note] = []
        if comps.scheme?.lowercased() == "http" { notes.append(.notEncrypted) }
        comps.scheme = comps.scheme?.lowercased()

        // Dropbox share links open a page; `raw=1` gives the file itself.
        if matches(host, ["dropbox.com"]), comps.path.hasPrefix("/s/") || comps.path.hasPrefix("/scl/") {
            var items = (comps.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }
            items.append(URLQueryItem(name: "raw", value: "1"))
            comps.queryItems = items
            notes.append(.dropboxMadeDirect)
        }
        guard let url = comps.url else { return .problem(.malformed) }
        let ext = (comps.path as NSString).pathExtension.lowercased()
        if let site = Site.allCases.first(where: { matches(host, $0.hosts) }) {
            // A file the site itself serves under its own name is still a file (rare); everything else is a page.
            if !(videoExtensions.contains(ext) || photoExtensions.contains(ext) || streamExtensions.contains(ext)) { return .page(site) }
        }
        if unsupportedExtensions.contains(ext) { return .problem(.unsupported(ext.uppercased())) }
        return .ok(Link(url: url, kind: kind(ofExtension: ext), notes: notes))
    }

    public static func kind(ofExtension ext: String) -> Kind {
        let e = ext.lowercased()
        if videoExtensions.contains(e) { return .video }
        if streamExtensions.contains(e) { return .stream }
        if photoExtensions.contains(e) { return .photo }
        return .unknown
    }

    /// What a server said it sends (`Content-Type`), for a link whose address does not say. Nil: not something MacPlayer shows
    /// (a web page, a document…).
    public static func kind(ofContentType type: String) -> Kind? {
        let t = type.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if t.contains("mpegurl") { return .stream }
        if t.hasPrefix("video/") || t.hasPrefix("audio/") { return unsupportedTypes.contains(t) ? nil : .video }
        if t.hasPrefix("image/") { return t == "image/svg+xml" ? nil : .photo }
        if t == "application/octet-stream" || t == "binary/octet-stream" { return .unknown }
        return nil
    }

    static let unsupportedTypes: Set<String> = ["video/webm", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "audio/webm", "audio/ogg", "video/ogg"]

    /// What the first bytes of a file say it is, for a server that only says "some bytes" (`application/octet-stream`):
    /// the kind and the type to tell the player.
    public static func sniff(_ b: [UInt8]) -> (kind: Kind, mime: String)? {
        func at(_ i: Int, _ s: String) -> Bool { let u = Array(s.utf8); return b.count >= i + u.count && Array(b[i..<(i + u.count)]) == u }
        if at(4, "ftyp") { return (.video, at(8, "qt  ") ? "video/quicktime" : "video/mp4") }
        if at(4, "moov") || at(4, "mdat") || at(4, "wide") || at(4, "free") { return (.video, "video/quicktime") }
        if at(0, "#EXTM3U") { return (.stream, "application/vnd.apple.mpegurl") }
        if at(0, "ID3") || (b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return (.video, "audio/mpeg") }
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return (.photo, "image/jpeg") }
        if b.count >= 4 && b[0] == 0x89 && at(1, "PNG") { return (.photo, "image/png") }
        if at(0, "GIF8") { return (.photo, "image/gif") }
        if at(0, "RIFF") && at(8, "WEBP") { return (.photo, "image/webp") }
        if b.count >= 1 && b[0] == 0x47 && (b.count < 189 || b[188] == 0x47) && b.count >= 188 { return (.video, "video/mp2t") }
        if at(0, "<!DOCTYPE") || at(0, "<!doctype") || at(0, "<html") || at(0, "<HTML") { return nil }
        return nil
    }

    /// The file's name as the person would read it (percent escapes decoded, extension kept off), else the host.
    public static func displayName(of url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" {
            let name = (last as NSString).deletingPathExtension
            let decoded = name.removingPercentEncoding ?? name
            if !decoded.isEmpty, decoded.lowercased() != "index", decoded.lowercased() != "playlist", decoded.lowercased() != "master" { return decoded }
        }
        return url.host ?? url.absoluteString
    }

    /// A file name for saving what the link points to: the link's own name, else "<host> video", with an extension.
    public static func suggestedFileName(for url: URL, kind: Kind, contentType: String? = nil) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        let stem = (last as NSString).deletingPathExtension
        let safeStem = String(stem.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        let base = safeStem.isEmpty || last == "/" ? (url.host ?? "video") : safeStem
        if !ext.isEmpty, kind != .unknown || videoExtensions.contains(ext) || photoExtensions.contains(ext) { return base + "." + ext }
        let fromType: String? = contentType.flatMap { t in
            let m: [String: String] = ["video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                                       "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/heic": "heic", "image/webp": "webp", "image/tiff": "tiff"]
            return m[t.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""]
        }
        return base + "." + (fromType ?? (kind == .photo ? "jpg" : "mp4"))
    }

    static func matches(_ host: String, _ hosts: [String]) -> Bool {
        hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }
        return host.hasPrefix("[") && host.hasSuffix("]")
    }
}

/// The links opened lately (newest first), kept on this Mac only.
public enum RecentLinks {
    public static let limit = 12

    public static func adding(_ link: String, to list: [String]) -> [String] {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return list }
        return Array(([l] + list.filter { $0 != l }).prefix(limit))
    }

    public static func removing(_ link: String, from list: [String]) -> [String] { list.filter { $0 != link } }
}

/// How big a window that only plays one video or photo opens: the picture at its own shape, as large as fits comfortably on the
/// screen (never larger than the picture itself, never smaller than the window's minimum), with the bars above and below.
public enum PlayerWindowSizing {
    /// - Parameters:
    ///   - media: the picture's size in pixels (nil or zero: a 16:9 picture).
    ///   - chrome: the height of the bars above and below the picture, in points.
    ///   - screen: the usable part of the screen, in points.
    ///   - minimum: the window's smallest content size.
    public static func contentSize(media: CGSize?, chrome: CGFloat, screen: CGSize, minimum: CGSize) -> CGSize {
        // Nothing known yet (a link still connecting): a middling 16:9 picture, refitted once its size arrives.
        let m = (media.map { $0.width > 1 && $0.height > 1 ? $0 : nil } ?? nil) ?? CGSize(width: 960, height: 540)
        let aspect = m.width / m.height
        // A pixel of the picture is a point on screen (as QuickTime Player opens a file); a small picture grows to a useful size.
        var pic = m
        if pic.width < 640 && pic.height < 480 { let s = min(640 / pic.width, 480 / pic.height); pic = CGSize(width: pic.width * s, height: pic.height * s) }
        // At most 80% of the screen wide and 85% high.
        let maxW = max(minimum.width, screen.width * 0.8)
        let maxH = max(minimum.height - chrome, screen.height * 0.85 - chrome)
        let fit = min(1, maxW / pic.width, maxH / pic.height)
        pic = CGSize(width: pic.width * fit, height: pic.height * fit)
        // Never below the window's minimum, keeping the picture's shape where it can.
        if pic.width < minimum.width { pic = CGSize(width: minimum.width, height: minimum.width / aspect) }
        if pic.height + chrome < minimum.height { pic.height = minimum.height - chrome; pic.width = max(minimum.width, pic.height * aspect) }
        let w = min(pic.width.rounded(), max(minimum.width, screen.width))
        let h = min((pic.height + chrome).rounded(), max(minimum.height, screen.height))
        return CGSize(width: w, height: h)
    }
}
