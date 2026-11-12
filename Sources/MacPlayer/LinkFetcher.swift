import AppKit
import Combine
import Foundation
import MacPlayerCore

/// What a link opened from the web is (0.15). Kept by the session that shows it; the link is never treated as a file on the Mac
/// (no rename, no Trash, no "remember where I stopped", no project made from it until it is saved).
struct RemoteSource: Equatable {
    var link: URL
    /// What it turned out to be: video, stream or photo (never `.unknown` once opened).
    var kind: MediaLink.Kind
    var contentType: String?
    /// Its size in bytes, when the server said.
    var byteCount: Int64?
    /// The type to tell the player when neither the address nor the server say it (read from the file's first bytes).
    var playbackMIME: String? = nil
    var host: String { link.host ?? link.absoluteString }
    var displayName: String { MediaLink.displayName(of: link) }
    /// A stream comes in pieces and cannot be kept as one file.
    var canSave: Bool { kind != .stream }
}

/// Why a link could not be opened, in words a person can act on.
struct LinkError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ text: String) { description = text }
}

enum LinkErrors {
    static func message(code: Int) -> String {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return L("This Mac is not connected to the Internet.")
        case NSURLErrorTimedOut: return L("The server took too long to answer. Try again later.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return L("The server of this link cannot be found. Check the address.")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return L("The server cannot be reached right now. Try again later.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
            return L("A secure connection to this server could not be made (its certificate is not valid).")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: return L("This server only offers an unencrypted (http://) connection, which macOS does not allow here. Use an https:// link.")
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return L("This is not a valid link.")
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return L("This link needs a sign-in. MacPlayer only opens links that anyone can open.")
        case NSURLErrorCancelled: return L("Cancelled.")
        case NSURLErrorDataLengthExceedsMaximum: return L("This file is too large to show as a photo.")
        default: return LF("The link could not be opened (error %d).", code)
        }
    }

    static func http(_ status: Int) -> String {
        switch status {
        case 401, 407: return L("This link needs a sign-in (error 401). MacPlayer only opens links that anyone can open.")
        case 403: return L("The server does not allow this file to be opened (error 403). The link may have expired or be private.")
        case 404, 410: return L("There is no file at this link (error 404). It may have been moved or deleted.")
        case 429: return L("The server is getting too many requests (error 429). Try again in a moment.")
        case 500...599: return LF("The server has a problem right now (error %d). Try again later.", status)
        default: return LF("The server refused the link (error %d).", status)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LinkError { return e.description }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return message(code: ns.code) }
        return ns.localizedDescription
    }
}

/// The network side of links: asking a server what a link is, fetching a photo, saving a file. Nothing is sent but the request for
/// the link itself; no cookies or cache are kept (an ephemeral session).
@MainActor
enum LinkFetcher {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "MacPlayer/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")"]
        return URLSession(configuration: c)
    }()

    /// Photos larger than this are not shown from a link (they would be fetched whole into memory and the cache).
    static let photoByteLimit: Int64 = 150 * 1024 * 1024

    struct Head: Equatable {
        var kind: MediaLink.Kind
        var contentType: String?
        var byteCount: Int64?
        /// Read from the first bytes when the server only said "some bytes".
        var sniffedMIME: String? = nil
    }

    /// What the link is, by asking the server (HEAD; a server that refuses HEAD is asked for its first byte instead).
    /// `kind` comes from the address when it says; the server's answer decides otherwise.
    static func inspect(_ link: MediaLink.Link) async throws -> Head {
        var request = URLRequest(url: link.url); request.httpMethod = "HEAD"
        var response: HTTPURLResponse?
        do {
            let (_, r) = try await session.data(for: request)
            response = r as? HTTPURLResponse
        } catch { throw LinkError(LinkErrors.describe(error)) }
        if let r = response, [400, 403, 405, 501].contains(r.statusCode) || (r.statusCode == 200 && r.mimeType == nil) {
            // Some servers (and signed links) answer only GET.
            var get = URLRequest(url: link.url); get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            do {
                let (_, r2) = try await session.data(for: get)
                if let h = r2 as? HTTPURLResponse { response = h }
            } catch { throw LinkError(LinkErrors.describe(error)) }
        }
        guard let r = response else { throw LinkError(L("The server did not answer.")) }
        guard (200..<300).contains(r.statusCode) else { throw LinkError(LinkErrors.http(r.statusCode)) }
        let type = r.value(forHTTPHeaderField: "Content-Type")
        var size: Int64? = r.expectedContentLength > 0 && r.statusCode != 206 ? r.expectedContentLength : nil
        if r.statusCode == 206, let range = r.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) { size = total }
        var kind = link.kind
        if let t = type {
            switch MediaLink.kind(ofContentType: t) {
            case nil:
                // The address said video or photo but the server sends a web page: say so instead of failing later.
                if t.lowercased().contains("text/html") { throw LinkError(L("This link opens a web page, not a video or photo file. Use a link that ends in the file itself (such as .mp4 or .jpg).")) }
                if kind == .unknown { throw LinkError(LF("The server sends “%@”, which is not a video or photo MacPlayer can show.", t)) }
            case .unknown?: break
            case let k?: if kind == .unknown || (kind == .video && k == .stream) { kind = k }
            }
        }
        // Neither the address nor the server say what it is: its first bytes do.
        var sniffed: String?
        if kind == .unknown {
            var get = URLRequest(url: link.url); get.setValue("bytes=0-511", forHTTPHeaderField: "Range")
            if let (data, r) = try? await session.data(for: get), let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode) {
                if let found = MediaLink.sniff(Array(data.prefix(512))) { kind = found.kind; sniffed = found.mime }
                else if kind == .unknown, String(decoding: data.prefix(512), as: UTF8.self).lowercased().contains("<html") {
                    throw LinkError(L("This link opens a web page, not a video or photo file. Use a link that ends in the file itself (such as .mp4 or .jpg)."))
                }
            }
        }
        // Nothing says what it is: try it as a video (the player tells if it is not).
        if kind == .unknown { kind = .video }
        return Head(kind: kind, contentType: type, byteCount: size, sniffedMIME: sniffed)
    }

    /// Where photos fetched from links are kept while shown (emptied at launch).
    static var cacheFolder: URL { AppEnvironment.shared.support.appendingPathComponent("LinkCache", isDirectory: true) }

    static func clearCache() { try? FileManager.default.removeItem(at: cacheFolder) }

    /// Fetches a photo into the cache, under a name that keeps its extension (the photo reader goes by it).
    static func fetchPhoto(_ url: URL, contentType: String?, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let name = MediaLink.suggestedFileName(for: url, kind: .photo, contentType: contentType)
        let ext = (name as NSString).pathExtension
        let dest = cacheFolder.appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "jpg" : ext))
        let d = Download(url: url, to: dest, limit: photoByteLimit, onProgress: progress)
        return try await d.run()
    }
}

/// One file fetched from a link to a place on the Mac, with its progress. Written to a temporary name first, so a stopped download
/// never leaves half a file under the real name.
@MainActor
final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let url: URL
    let destination: URL
    private let limit: Int64?
    private let onProgress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var urlSession: URLSession?
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0

    init(url: URL, to destination: URL, limit: Int64? = nil, onProgress: @escaping @MainActor (Double) -> Void) {
        self.url = url; self.destination = destination; self.limit = limit; self.onProgress = onProgress
    }

    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            continuation = c
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            urlSession = s
            let t = s.downloadTask(with: url)
            task = t
            t.resume()
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        urlSession?.finishTasksAndInvalidate(); urlSession = nil
        c.resume(with: result)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            received = totalBytesWritten; expected = max(0, totalBytesExpectedToWrite)
            if let limit, totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
                downloadTask.cancel()
                finish(.failure(LinkError(LinkErrors.message(code: NSURLErrorDataLengthExceedsMaximum))))
                return
            }
            onProgress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : -1)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone when this returns: it is moved now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let moved: Result<URL, Error>
        if !(200..<300).contains(status) {
            moved = .failure(LinkError(LinkErrors.http(status)))
        } else {
            let fm = FileManager.default
            let dest = MainActor.assumeIsolated { destination }
            let partial = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".download")
            do {
                try? fm.removeItem(at: partial)
                try fm.moveItem(at: location, to: partial)
                try fm.moveItem(at: partial, to: dest)
                moved = .success(dest)
            } catch {
                try? fm.removeItem(at: partial)
                moved = .failure(LinkError(LF("The file could not be written: %@", error.localizedDescription)))
            }
        }
        MainActor.assumeIsolated { finish(moved) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let message = LinkErrors.describe(error)
        MainActor.assumeIsolated { finish(.failure(LinkError(message))) }
    }
}

/// Saving what a link shows into a file on the Mac ("Download…"), with its progress for the header (0.15).
@MainActor
final class LinkSave: ObservableObject {
    enum State: Equatable {
        case idle
        /// Fraction done, or -1 when the server did not say the size.
        case saving(Double)
        case saved(URL)
        case failed(String)
    }
    @Published private(set) var state = State.idle
    private var download: Download?

    var isSaving: Bool { if case .saving = state { return true }; return false }

    func start(_ source: RemoteSource, to destination: URL) {
        guard !isSaving else { return }
        state = .saving(0)
        let d = Download(url: source.link, to: destination) { [weak self] f in self?.state = .saving(f) }
        download = d
        Task {
            do {
                let file = try await d.run()
                state = .saved(file)
            } catch let e as LinkError where e.description == L("Cancelled.") {
                state = .idle
            } catch {
                state = .failed(LinkErrors.describe(error))
            }
            download = nil
        }
    }

    func cancel() { download?.cancel() }
    func setSaved(_ url: URL) { if !isSaving { state = .saved(url) } }
    func reset() { if !isSaving { state = .idle } }
}
