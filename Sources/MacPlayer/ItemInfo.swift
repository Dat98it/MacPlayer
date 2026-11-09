import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// The text shown when the pointer rests on a video in a playlist (name, size, dates, length, picture and sound). It is read when the
/// pointer arrives (not for the whole list at once), kept for a minute, and read again after that in case the file changed.
@MainActor
final class ItemInfoStore: ObservableObject {
    static let shared = ItemInfoStore()

    @Published private(set) var tips: [String: String] = [:]
    private var readAt: [String: Date] = [:]
    private var reading = Set<String>()

    /// The text to show now. Until the picture and sound have been read it is what the file system tells at once (name, folder, size, dates and the
    /// length if the playlist knows it); the full text replaces it as soon as it is ready.
    func tip(for item: PlaylistItem) -> String {
        if let t = tips[item.path] { return t }
        let quick = Self.text(for: Self.attributes(path: item.path, knownDuration: item.duration?.seconds))
        tips[item.path] = quick
        return quick
    }

    func ensure(_ item: PlaylistItem) {
        let path = item.path
        if let t = readAt[path], Date().timeIntervalSince(t) < 60 { return }
        guard reading.insert(path).inserted else { return }
        let known = item.duration?.seconds
        Task {
            let details = await Task.detached { await Self.read(path: path, knownDuration: known) }.value
            self.tips[path] = Self.text(for: details)
            self.readAt[path] = Date()
            self.reading.remove(path)
            if self.hovered == path { HoverTipWindow.shared.update(self.tips[path] ?? "") }
        }
    }

    // MARK: Showing it

    /// The video the pointer is on. Its information appears after a very short rest (the system's own tooltip waits more than a second).
    private(set) var hovered: String?
    private var showTask: Task<Void, Never>?

    func hover(_ item: PlaylistItem, entered: Bool) {
        if entered {
            hovered = item.path
            _ = tip(for: item)              // the quick text is ready before the pause is over
            ensure(item)                    // and the rest is being read meanwhile
            showTask?.cancel()
            let path = item.path
            showTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, self.hovered == path, let text = self.tips[path] else { return }
                HoverTipWindow.shared.show(text)
            }
        } else if hovered == item.path {
            hovered = nil; showTask?.cancel(); HoverTipWindow.shared.hide()
        }
    }

    func cancelHover() { hovered = nil; showTask?.cancel() }

    nonisolated static func attributes(path: String, knownDuration: Double?) -> ItemDetails {
        var d = ItemDetails(name: PathUtil.fileName(of: path), folder: PathUtil.directory(of: path), exists: FileManager.default.fileExists(atPath: path))
        d.duration = knownDuration
        guard d.exists, let a = try? FileManager.default.attributesOfItem(atPath: path) else { return d }
        d.size = (a[.size] as? NSNumber)?.int64Value
        d.created = a[.creationDate] as? Date
        d.modified = a[.modificationDate] as? Date
        return d
    }

    nonisolated static func read(path: String, knownDuration: Double?) async -> ItemDetails {
        var d = ItemDetails(name: PathUtil.fileName(of: path), folder: PathUtil.directory(of: path), exists: FileManager.default.fileExists(atPath: path))
        guard d.exists else { d.duration = knownDuration; return d }
        if ImageFiles.isCandidate(path) {
            d.isImage = true
            if let a = try? FileManager.default.attributesOfItem(atPath: path) {
                d.size = (a[.size] as? NSNumber)?.int64Value; d.created = a[.creationDate] as? Date; d.modified = a[.modificationDate] as? Date
            }
            if let info = try? PhotoLoader.info(url: URL(fileURLWithPath: path)), let v = info.primaryVideo { d.width = v.width; d.height = v.height; d.videoCodec = PathUtil.ext(of: path).uppercased() }
            return d
        }
        if let a = try? FileManager.default.attributesOfItem(atPath: path) {
            d.size = (a[.size] as? NSNumber)?.int64Value
            d.created = a[.creationDate] as? Date
            d.modified = a[.modificationDate] as? Date
        }
        if let info = try? await MediaProbe.probe(url: URL(fileURLWithPath: path)) {
            d.duration = info.duration.seconds
            if let v = info.primaryVideo {
                d.width = v.width; d.height = v.height; d.frameRate = v.frameRate?.framesPerSecond
                d.videoCodec = v.codec; d.bitrate = v.bitrate; d.isHDR = v.isHDR; d.isDolbyVision = v.dolbyVision ?? false
            }
            if let a = info.audio.first { d.audioCodec = a.codec; d.audioChannels = a.channels }
        } else { d.duration = knownDuration }
        return d
    }

    static func text(for d: ItemDetails) -> String {
        var lines = [d.name, ""]
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { lines.append("\(label): \(value)") } }
        let dates = DateFormatter(); dates.dateStyle = .medium; dates.timeStyle = .short
        add(L("Folder"), d.folder)
        guard d.exists else { lines.append(L("This file is not at this place any more.")); return lines.joined(separator: "\n") }
        add(L("File size"), d.size.map { n in "\(Format.bytes(n)) (\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)) \(L("bytes")))" })
        add(L("Created"), d.created.map(dates.string(from:)))
        add(L("Modified"), d.modified.map(dates.string(from:)))
        add(L("Length"), d.duration.map { Format.duration(MediaTime(seconds: $0)) })
        if let w = d.width, let h = d.height {
            var parts = [ItemDetails.resolutionLabel(width: w, height: h)]
            if let c = d.videoCodec { parts.append(ItemDetails.codecName(c)) }
            if let f = d.frameRate { parts.append(ItemDetails.frameRateLabel(f)) }
            if let b = d.bitrate { parts.append(ItemDetails.bitrateLabel(b)) }
            if d.isDolbyVision { parts.append("Dolby Vision") } else if d.isHDR { parts.append("HDR") }
            add(L("Picture"), parts.joined(separator: " · "))
        }
        if let a = d.audioCodec {
            let channels = d.audioChannels.map { $0 == 1 ? "mono" : ($0 == 2 ? "stereo" : LF("%d channels", $0)) }
            add(L("Sound"), ([ItemDetails.codecName(a)] + [channels].compactMap { $0 }).joined(separator: " · "))
        } else if d.width != nil, !d.isImage { add(L("Sound"), L("none")) }
        return lines.joined(separator: "\n")
    }
}

/// The small window that carries a video's information. It never takes the keyboard or the mouse, so the list underneath behaves as usual.
@MainActor
final class HoverTipWindow {
    static let shared = HoverTipWindow()
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var monitor: Any?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true; panel.level = .popUpMenu; panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hidesOnDeactivate = true
        let box = NSVisualEffectView(); box.material = .toolTip; box.state = .active; box.wantsLayer = true
        box.layer?.cornerRadius = 7; box.layer?.masksToBounds = true
        label.isSelectable = false; label.maximumNumberOfLines = 0; label.preferredMaxLayoutWidth = 360
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
                                     label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)])
        panel.contentView = box
    }

    var isVisible: Bool { panel.isVisible }

    private func styled(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            if i == 0 { out.append(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])); continue }
            if let r = line.range(of: ": ") {
                out.append(NSAttributedString(string: String(line[..<r.upperBound]), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                out.append(NSAttributedString(string: String(line[r.upperBound...]), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]))
            } else { out.append(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])) }
        }
        return out
    }

    private func fit() {
        label.attributedStringValue = styled(label.stringValue)
        let size = label.sizeThatFits(NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        let w = min(380, size.width + 20), h = size.height + 16
        var origin = panel.isVisible ? panel.frame.origin : NSEvent.mouseLocation.applying(CGAffineTransform(translationX: 16, y: -16 - h))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(v.minX, origin.x), v.maxX - w); origin.y = min(max(v.minY, origin.y), v.maxY - h)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    }

    func show(_ text: String) {
        label.stringValue = text
        fit()
        panel.orderFrontRegardless()
        // Anything the person does with the list takes it away.
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] e in
                MainActor.assumeIsolated { self?.hide() }
                return e
            }
        }
    }

    func update(_ text: String) { guard panel.isVisible else { return }; label.stringValue = text; fit() }

    func hide() { panel.orderOut(nil); ItemInfoStore.shared.cancelHover() }
}
