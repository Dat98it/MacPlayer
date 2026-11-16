import AppKit
import AVFoundation
import MacPlayerCore
import MacPlayerMedia

extension SelfTest {
    /// Exercises the inspector's actual bindings on a copy of a real project; the original and its media are only read.
    static func clipCanvasFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G10: a selected clip's frame stays independent")
        guard let input = ProcessInfo.processInfo.environment["MACPLAYER_CANVAS_PROJECT"] else {
            check(false, "MACPLAYER_CANVAS_PROJECT names a project to read"); return
        }
        let fm = FileManager.default
        let path = work.appendingPathComponent("clip-canvas.macplayer")
        do {
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: input))
            try originalBytes.write(to: path)
            let session = try await EditorSession.openProject(path: path.path)
            app.quitWhenLastWindowCloses = false
            let window = MainWindowController(playlists: app.playlists); app.adopt(window)
            window.setSession(session, fromPlaylist: false); window.showWindow(nil)
            defer { window.closeVideo(); window.window?.orderOut(nil) }
            let original = session.project
            guard original.timeline.count > 1, session.missingSourceIDs.isEmpty else {
                check(false, "several real clips and all their media are available"); return
            }
            let starts = TimelineEditor.starts(original.timeline)
            let times = original.timeline.map { (starts[$0.id] ?? .zero) + MediaTime(seconds: min(0.2, $0.duration.seconds / 2)) }
            func images() async throws -> [CGImage] {
                guard let item = session.player.player.currentItem else { throw CompositionBuilder.BuildError.noPieces }
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = item.videoComposition
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                var images: [CGImage] = []
                for time in times { images.append(try await generator.image(at: time.cmTime).image) }
                return images
            }
            let baseline = try await images()
            let pane = PicturePane(session: session)
            for selected in [original.timeline.count - 1, 0] {
                session.select(.clip(original.timeline[selected].id))
                session.activeTool = .picture; session.paneTabs["picture"] = "canvas"
                let loads = session.previewLoads
                pane.canvasShapeBinding.wrappedValue = .portrait9x16
                pane.canvasFitBinding.wrappedValue = .fill
                await waitFor(15) { session.previewLoads > loads }
                try? await Task.sleep(nanoseconds: 700_000_000)
                check(session.project.timeline.indices.filter { session.project.timeline[$0].look != original.timeline[$0].look } == [selected], "clip \(selected + 1): both inspector pickers change only the selected clip")
                check(session.project.frameShape == original.frameShape, "clip \(selected + 1): the finished video's frame is unchanged")
                let edited = try await images()
                for i in original.timeline.indices {
                    let same = edited[i].width == baseline[i].width && edited[i].height == baseline[i].height
                        && (edited[i].dataProvider?.data as Data?) == (baseline[i].dataProvider?.data as Data?)
                    check(i == selected ? !same : same, "clip \(selected + 1) edited: preview of clip \(i + 1) \(i == selected ? "changes" : "stays identical")")
                }
                let other = selected == 0 ? 1 : 0
                session.select(.clip(original.timeline[other].id))
                check(pane.canvasShapeBinding.wrappedValue == original.timeline[other].look.canvas && pane.canvasFitBinding.wrappedValue == original.timeline[other].look.fit, "selecting another clip shows its own frame and fit")
                session.select(.clip(original.timeline[selected].id))
                check(session.saveNow(), "the edited project copy saves")
                let saved = try ProjectCodec.decode(Data(contentsOf: path))
                check(saved.timeline == session.project.timeline, "all clip frames survive saving and decoding")
                session.undo(); session.undo()
                check(session.project.timeline == original.timeline, "undo restores the two clip settings")
                session.redo(); session.redo()
                check(session.project.timeline[selected].look.clipCanvas == .portrait9x16 && session.project.timeline[selected].look.fit == .fill, "redo restores the selected clip's frame")
                session.undo(); session.undo()
                await session.loadPlayer(at: original.playhead)
            }
            check(try Data(contentsOf: URL(fileURLWithPath: input)) == originalBytes, "the real project file stays byte-for-byte unchanged")
            _ = session.saveNow()
        } catch { check(false, "clip canvas flow: \(error)") }
    }
}
