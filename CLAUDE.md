# CLAUDE.md — MacPlayer: guide for AI agents

Read this file first. It is meant to let a new AI agent (or a new conversation) understand the whole project and keep developing it right away.
It is kept in the repository on purpose, at the maintainer's request. When you change the project, **update this file in the same change**.

## 1. What this is

**MacPlayer** (formerly *MacVideo*; old project files `.macvideo` still open) is a free (MIT) macOS app to **play, organise and edit videos and photos**,
all on the Mac: no account, no network code, no telemetry. It is built with **SwiftPM only (no Xcode project, no Xcode installation, only the
Command Line Tools)**, Swift 6 toolchain with `swiftLanguageVersions: [.v5]`, macOS 15+, arm64 tested (Intel is not tested). No third-party libraries
(Apple frameworks only: AVFoundation, AVKit, CoreImage, Vision, Speech, SwiftUI, AppKit).

- Remote: `git@github.com-dat98it:Dat98it/MacPlayer.git`, branch `main`.
- The current version is in `Resources/Info.plist` (`CFBundleShortVersionString`, plus `CFBundleVersion`). Installed copy: `/Applications/MacPlayer.app`.
- UI languages: English (the string keys) and Vietnamese (`Resources/vi.lproj/Localizable.strings`). The maintainer writes Vietnamese.
- Human docs (Vietnamese): `README.md` (features, build, tests), `docs/bao-cao-ban-giao.md` (handover report: what was built, tested, not done),
  `MacPlayer-Cai-dat-va-chia-se.md` + `docs/huong-dan-cai-dat.md` (install and sharing), `docs/*.md` (format matrix, benchmark, real-video test logs).

## 2. Standing rules from the maintainer (obey them)

1. **Talk to the maintainer in Vietnamese.** State a short plan before editing code. Report outcomes honestly: failing tests, skipped steps and
   things you could not verify must be said plainly. Never claim "tested" for what was only compiled.
2. **Never modify or delete the user's originals.** The app itself never writes over a video or photo (0.8.0 removed "replace original" for good);
   only the Playlists side renames / moves to the Trash, when the person asks. Trash only (Finder, recoverable), with confirmation. Rename/trash
   tests run only on copies you made. The user's real photo folder (`/Volumes/SS 990 pro/Folder/Ảnh`) is **read-only**.
3. **Never read, print, copy, index or commit secrets** (keys, tokens, credentials). Never fake signing, notarization, payment or any external info.
4. **No git commit/push and no git config changes unless asked.** When asked: `git add -A`, commit with per-command identity
   (`git -c user.name="Dat98it" -c user.email="dat98.it@gmail.com" commit ...`), **no** `Co-Authored-By` trailer, no `--force`.
5. **Every change to the app = a new version.** Bump `CFBundleShortVersionString` and `CFBundleVersion`, run `Scripts/make_release.sh`, update version
   and SHA-256 lines in `MacPlayer-Cai-dat-va-chia-se.md` (+ the version in `README.md`'s status line), copy `LICENSE` and the guide into `dist/`, move the
   old `/Applications/MacPlayer.app` to the Trash through Finder (`osascript -e 'tell application "Finder" to delete POSIX file "..."'`), `ditto` the new
   `build/MacPlayer.app` in, `codesign --verify --deep --strict`, and tell the maintainer to quit (⌘Q) and reopen the running copy. Patch step for fixes,
   minor step for features.
6. **Do not touch other apps** of the maintainer (AppClean, Mac-clean, ShelfDrop). `Apps Example/CapCut.app` exists only as a *feature reference*:
   take ideas, **never copy its code, assets or effects**, and skip anything that needs a network or cloud AI.
7. **UI testing without clicking by screen coordinates.** Capture only the MacPlayer window (`--snapshot`, or `screencapture -l <windowID>`).
   Do not drive the real mouse over the user's desktop.
8. Features must be **easy to use** (the maintainer's explicit requirement): sensible defaults, short Vietnamese captions, a Reset per group,
   no clutter, nothing destructive without confirmation.
9. Do not add AI "notes" files elsewhere in the repo; this `CLAUDE.md` is the one allowed exception.

## 3. Build, test, run

```bash
swift build                                  # debug build (output is very noisy with warnings; filter it, see below)
Scripts/test.sh                              # all tests (needs the TestingMacros plugin path; the script handles it)
Scripts/test.sh --filter ColorGradeTests     # one suite
Scripts/build_app.sh                         # build/MacPlayer.app (release, ad-hoc signed)
Scripts/make_release.sh                      # dist/MacPlayer-<version>.dmg/.zip/SHA256SUMS.txt (runs build_app.sh)
python3 Scripts/check_localization.py        # must end with "0 missing, 0 with wrong placeholders"
```

Useful filter for compiler output (BSD `sed`/zsh: no `\b`, quote globs, use `perl -pi -e` for word-boundary edits):

```bash
swift build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "\.swift:[0-9]+:[0-9]+: error|Build complete|^error:" | cut -c1-300
```

Run the app against throw-away data and take a picture of its window (the video layer itself is not captured):

```bash
BIN=$(swift build --show-bin-path)/MacPlayer
mkdir -p /tmp/sb && MACPLAYER_START_TAB=color MACPLAYER_DEV_COLOR=curves,wheels "$BIN" --sandbox /tmp/sb --snapshot /tmp/out.png /path/to/photo-or-video
```

Other launch flags: `--selftest <dir with demo.mp4>` (real-app flows A–N, prints PASS/FAIL; needs `--sandbox <dir>`), `--real-media`, `--library`, `--real-photos`,
`--project-demo`, `--report-session`, `--fullscreen-check`, `--crash-export <src> <dir> copy|batch`, `--crash-autosave <src> <dir> x`, `--recover-check`.
`--snapshot` of a screen: `MACPLAYER_START_ROUTE=home|playlist|projects` (sandbox only); a project file on the command line opens the editor. Dev-only environment variables (read only in sandbox/dev paths):

| Variable | Effect |
|---|---|
| `MACPLAYER_START_TAB=<tab>` | open an inspector tab: `clips picture color mask effects timing transitions layers audio text subtitles export` |
| `MACPLAYER_DEV_COLOR=basic,curves,wheels,hsl,lut,blue` | put a sample grade on the picture and open those cards |
| `MACPLAYER_DEV_MASK=1` | sample heart mask on a blue backdrop |
| `MACPLAYER_DEV_TREE=<folder>` | playlist "Demo" from a folder, shown as tree (`MACPLAYER_DEV_SIDEBAR=list\|grid\|select\|play\|time\|rename`) |
| `MACPLAYER_DEV_ADD=a.mp4\|b.mp4`, `MACPLAYER_DEV_AUTOPLAY=1` | with a project file on the command line: add these videos, then start playing (sandbox only; to watch playback in a real window and capture it with `screencapture -l`) |
| `MACPLAYER_ONLY_THREE=<n>`, `MACPLAYER_THREE_PORTRAIT=1` | `--selftest`: run only flow G0 (new project of three videos, played in a window) n times; portrait = the maintainer's 1080×1918/1920 phone videos |
| `MACPLAYER_LAYOUT=list\|grid\|tree`, `MACPLAYER_TREE_FILES=list\|grid`, `MACPLAYER_PREVIEW_SCALE=0.75…3` | start with that sidebar setup (sandbox only) |
| `MACPLAYER_DEV_CROP`, `MACPLAYER_OPEN_POPOVER`, `MACPLAYER_TREE_SPEED_ONLY`, `MACPLAYER_LIBRARY_ONLY`, `MACPLAYER_KEEP_OUTPUT`, `MACPLAYER_DEBUG_*`, `MACPLAYER_AX_DEBUG`, `MACPLAYER_WAIT_ACTIVE` | self-test / debugging aids |

`macplayer-probe gen <out> [codec] [s] [fps] [gop] [WxH]` makes synthetic test videos. `macplayer-probe` (a CLI in `Sources/macplayer-probe`) measures and verifies media without modifying inputs (`matrix`, `bench`, `realcheck`, `cut`, `rpu`…).

## 4. Architecture

Four SwiftPM targets, dependencies only flow downwards:

```
MacPlayer (app, AppKit/SwiftUI)  ──►  MacPlayerMedia (AVFoundation / Core Image / Vision)  ──►  MacPlayerCore (pure Foundation)
macplayer-probe (CLI)            ──►  both
```

- **`Sources/MacPlayerCore`** — every *decision* and all value types. Foundation only, **no direct file I/O** (it goes through the `FileSystem` protocol; tests use
  an in-memory `FakeFileSystem`). Rational time (`MediaTime`), playlists/cursor/sort/layout/tree, selections, `Project` + `VideoLook` + overlays/sounds,
  safe-save planning, export planning/queue, subtitles, batch rename, colour math, masks, easing, sound FX model, preferences.
- **`Sources/MacPlayerMedia`** — AVFoundation/Core Image/Vision. **One renderer** (`CompositionBuilder` + `RecipeCompositor`) draws both the preview and the
  export, so what is seen is what is written. Also probing, thumbnails, exporters, noise reduction, sound FX, transitions, masks, stabiliser, speech.
- **`Sources/MacPlayer`** — a thin app layer. `AppDelegate` (opening/routing every file, menus, new project), `MainWindow` (each window has a
  `WindowRoute`: home / playlist / projects / editor), `EditorSession` (+ extensions) = one open thing: a **viewer** (role `.viewer`, watching a file
  from the playlist side, never edited or saved) or an **editor** (role `.editor`, a project file with undo history, autosave into the file via
  `ProjectFileWriter`, and every action); `NavigationViews` (Home, project list, editor header, empty states), `ProjectsController` (registry +
  card pictures), `ProjectActions` (rename/trash a project); `Inspector*.swift` = the right-hand tool panels; `PlaylistSidebar` + `PlaylistModel` = left panel; `TimelineView`; `SelfTest*.swift` (in-app self-test).
- **Tests:** `Tests/MacPlayerCoreTests` (≈378 tests, fast, pure) and `Tests/MacPlayerMediaTests` (≈216, real AVFoundation/Core Image on synthetic media made
  by `SyntheticMedia`/`Fixtures`; pixel-level checks).

### Key files by area

| Area | Files |
|---|---|
| Project model, undo | `Core/Project.swift` (`Project` with `kind` video/photo, `VideoLook`, `ColorAdjust`, `TimelineClip`, `AudioSettings`, `TextOverlay`), `ProjectRules.swift` (what may go into each kind; `ProjectUpgrade` for 0.7 files), `ProjectStore.swift` (JSON, `schemaVersion` 3, migrations, safe project-file writes, recovery), `ProjectRegistry.swift` (list of projects), `History.swift` |
| Playback | `App/PlayerController.swift`, `Core/PlaylistCursor.swift`, `App/TransportBar.swift` |
| Playlist UI | `App/PlaylistSidebar.swift` (list / grid / **tree** layouts, selection, batch tools), `PlaylistModel.swift`, `Core/FolderTree.swift`, `PlaylistLayout.swift` (`PlaylistLayout`, `TreeFiles`, `PreviewSize`, `ItemSelection`), `Core/BatchRename.swift`, `App/BatchRenameSheet.swift`, `FileActions.swift` |
| Render pipeline | `Media/CompositionBuilder.swift` (assembles AVComposition/AudioMix/VideoComposition), `Media/RecipeCompositor.swift` (`mainPicture`, `render`), `LookEffectsRenderer.swift`, `ColorGradeRenderer.swift`, `MaskRenderer.swift` (+`SubjectMasker`), `TransitionRenderer.swift`, `OverlayRenderer.swift`, `PhotoRenderer.swift` |
| Export | `Core/ExportQueue.swift` (`ExportJob`, `needsReencode`), `ExportOptions.swift`, `Media/ExportRunner.swift`, `ClipExporter.swift` (fast cut), `ReencodeExporter.swift` (exact), `Core/SafeSave.swift` |
| Colour | `Core/ColorGrade.swift` (curves, wheels, HSL, `LutRef`), `ColorGrading.swift` (math + cube), `CubeLUT.swift`, `Histogram.swift`, `App/InspectorColor.swift`, `EditorSession+Color.swift` |
| Cut-out | `Core/MaskAndBlend.swift` (`MaskSpec`, `MaskShape`, `LayerBlend`, `MaskGeometry`), `LookEffects.swift` (`ChromaKey`), `App/InspectorMask.swift` |
| Layers / animation | `Core/Overlays.swift` (`OverlayClip`, `OverlayTransform`, `OverlayKeyframe`, animation maths), `Easing.swift`, `Motion.swift`, `Elements.swift` (text/shape/sticker + `ElementAnimator`), `Transition.swift`, `App/InspectorLayers.swift`, `InspectorTransitions.swift`, `InspectorAnimation.swift`, `OverlayManipulator.swift` |
| Audio | `Core/SoundClips.swift`, `VolumeEnvelope.swift` (+`VolumeCurve`), `SoundFX.swift`, `Media/NoiseReducer.swift`, `SoundFXRenderer.swift`, `AudioAnalysis.swift`, `App/InspectorAudio.swift`, `EditorSession+Sounds.swift`, `VoiceRecorder.swift` |
| Time tools | `Core/SpeedRamp.swift`, `App/EditorSession+Timing.swift` (speed ramps, freeze frame, reverse via `ReverseRenderer`) |
| Photos | `Media/PhotoLoader.swift`, `PhotoRenderer.swift`, `App/EditorSession+Photo.swift`, `PhotoHostView.swift`, `PhotoCropOverlay.swift`, `InspectorPhotoExport.swift` |
| Subtitles / speech | `Core/Subtitles.swift`, `SubtitleBuilder.swift`, `Media/SpeechTranscriber.swift` (on-device) |
| Localisation | `App/Support.swift` (`L()`, `LF()`), `Resources/{en,vi}.lproj/Localizable.strings`, `Scripts/check_localization.py` |

## 5. Feature map (by release)

0.2.0 base: player, playlists, selections, fast/exact export, safe save + journal + crash recovery, project mode (timeline, 3 overlay lanes, keyframes,
transitions, speed ramps, freeze, reverse, stabiliser), text/shape/sticker elements with animations, subtitles (SRT/VTT, speech recognition), sound clips
(music/voice-over/effects, ducking, noise reduction), photos (crop/colour/effects/text, slideshow, export formats).
Then: **0.2.1** tree files as grid; **0.3.0** adjustable preview size + green "open" / accent "chosen" borders; multi-select, batch rename/trash, folder tree;
**0.4.0 Colour** (exposure/highlights/shadows/vibrance/tint, curves, 3 colour wheels, HSL by 8 ranges, `.cube` LUT, histogram, compare/copy/paste, apply to all clips);
**0.5.0 Cut-out** (subject removal via Vision, chroma key on the main picture, 6 mask shapes with feather/invert, backdrop colour, 10 blend modes for layers);
**0.6.0 Motion** (8 new transitions → 17 total, 6 easings per keyframe, rotation for layers and "zoom and move", arrive/leave animations for layers);
**0.7.1 Fixes** from running the app on real footage: AAC encoder bit rate now fits the sample rate (exact cuts of 22.05/24 kHz videos used to fail with -12651); shape and subject masks sit on the picture when it has bars; a delayed sound follows the clip's speed and ends with the clip; one `Project.allowsFastCut` for the Export panel and the plan; joined ranges honour "burn subtitles in"; cutting a zoom-and-move animation keeps its turn; freeze frames of any length (`VideoLook.minimumSpeed`); jobs restored after a crash start when asked and never block new jobs; audio-track picker shows the playing track; undo names are translated; speech error messages.
**0.8.0 Two sides** — Home with **Playlists** (watch only: play, rename, Trash; no inspector) and **Editing** (list of projects, new project asks the kind
and always where to save). Two project kinds: **video** (timeline) and **photo** (exactly one photo, plus text and logos). Quick mode removed (old
`.quick` files upgrade on opening, schema 3; the old file is copied to Recovery first). **"Replace original" removed** (code, UI, tests); old replace
journals are still recovered at launch and old queue jobs of that kind fail instead of running. Autosave writes the project file itself. Projects can be
renamed (the file) and moved to the Trash from the list.
**0.8.1 Fix**: the timeline strip of a project that started empty kept a near-zero width after videos were added (it looked frozen and flickered
while playing); the visible range is now `Core/TimelineViewport.swift` and follows the project's length. Self-test flow G0 covers it.
**0.7.0 Sound** (8 voice presets + manual bass/mid/treble/pitch/room/echo through an offline AVAudioEngine render, hand-drawn volume curve per sound clip).

## 6. Rendering and data-flow rules that are easy to break

- **Preview = export.** Anything visual must live in `RecipeCompositor` / the `*Renderer` helpers so both paths draw it. `mainPicture` order: stabiliser → crop →
  rotate/flip → fit/fill placement → *cut-out* (chroma key → subject mask → shape mask, shown over the backdrop: `look.backdropHex`, else blurred copy, else black)
  → colour (`ColorGradeRenderer`: basic CIColorControls/temperature, then one `CIColorCube`) → zoom/move (+rotation) → effects (filter, sharpen, blur, vignette). `render` then
  composites layers (lane order; chroma → subject → mask → placement → border → rotation → opacity → blend), then text/subtitles; clip transitions blend two `mainPicture`s.
- All `CIContext`s here use **no colour management** (`workingColorSpace: NSNull()`), so values are the stored, gamma-encoded ones. Use `CIColorCube`, not `…WithColorSpace`.
  CGImage → CIImage keeps row 0 at the top (do not flip masks drawn into bitmaps).
- **Live preview overrides** (`EffectsLive`, `ColorLive`, `LayerLive`, keyed by clip id, read only when `plan.liveKey != nil`) let sliders update without rebuilding the preview.
  The first edit that needs the compositor still rebuilds. Exports never read them. `PiecePlan.subjectMode` is `.previewVideo` in previews, `.exportVideo` otherwise, `.photo` for photos.
- **Audio pipeline** (`CompositionBuilder`): source → noise-reduced copy (`NoiseReducer`, cached) → FX copy (`SoundFXRenderer`, cached, made when the effect is chosen
  — `make:false` in previews, `make:true` when exporting) → composition track → `AVAudioMix` ramps from `VolumeEnvelope.points` (gain × fades × ducking × hand-drawn curve).
  Cached copies live in the temp folder (`macplayer-denoised`, `macplayer-soundfx`).
- **Backward compatibility is mandatory.** New fields on saved types (`Project`, `VideoLook`, `ColorAdjust`, `OverlayTransform`, keyframes, `SoundClip`, `AudioSettings`) must open old
  files: optional properties, or custom `init(from:)` with `decodeIfPresent`. Add a test that decodes an old JSON string. Bump `ProjectStore`'s schema only for structural migrations.
- Fast cut is decided in one place: `Project.allowsFastCut` (Core). Do not copy that test elsewhere.
- Speed is never clamped to a different minimum in different places: use `VideoLook.minimumSpeed`.
- Audio sync offset (`AudioSettings.offsetSeconds`) is counted in seconds of the *finished picture*: a delay is made after the clip's speed is applied (see `CompositionBuilder`).
- A mask on the main picture is made as big as the placed picture (`mainPicture`), because `MaskRenderer.apply` puts a mask on the picture's own corner.
- `ExportJob.needsReencode` must include any new setting that changes picture or sound, or a "fast cut" would silently drop it.
- **Project kinds:** a photo project uses the top-level `look`, `overlays` and logos in `overlayClips` (image kind, no time); a video project keeps
  `look`/`audio` neutral and edits each `TimelineClip`. Every way of adding media asks `ProjectRules.canAdd` first. `Project.mode` exists only to
  read 0.7 files (never written). Paths are compared with `PathUtil.same` (file names arrive in either Unicode form).
- **Autosave** goes through `ProjectFileWriter` (one write at a time, older writes dropped, crash copy first, then the project file checked against its
  last fingerprint so a change made elsewhere is never overwritten). `ProjectStore` only ever writes `.macplayer`/`.macvideo` files and its own folder.
- **Safe save** (never weaken): export to a temp file next to the target, verify (opens, duration, tracks, first frame decodes), then move into place;
  always a NEW file, never the source (compared with `PathUtil.same`), never over an existing file unless confirmed (and never over media: `OriginalGuard`,
  `StillExporter` refuses existing files). There is no "replace original" any more; `SafeSaver.recoverLegacyReplaceJournals` only finishes what 0.7 left.
- Fast cut (passthrough) is only valid when nothing changes picture or sound; exact cut uses `AVAssetReader → AVAssetWriter`.

## 7. Conventions and gotchas

- **SwiftUI `@State`/`@StateObject` macros: `@State` does not compile here** (no SwiftUI macro plugin). Use `@StateObject private var x = Box<T>(initial)` (`Box` is defined in `InspectorText.swift`)
  for local view state, and `ObservableObject`s.
- **Big lists:** a SwiftUI `List` of thousands of mixed rows froze the app (`OutlineListCoordinator.diffRows`); the tree uses `ScrollView` + `LazyVStack`. `.contextMenu` content is built at *every*
  redraw: keep it cheap (resolve lists lazily inside button actions). `.focusable()` on a `ScrollView` swallows plain clicks. Nested `func` in a `ViewBuilder` is an error; move helpers to methods. Thumbnails in lazy rows need `.clipped()`.
- Use `onGeometryChange(... in: .named(space))`, not `.global` (title bar offsets). Closing the last window quits the app (tests set `quitWhenLastWindowCloses = false`).
- `BlendMode` is taken by SwiftUI: the layer enum is `LayerBlend`. A raw string literal containing `"#` needs `##"..."##`.
- Core code must stay Foundation-only; put anything needing AVFoundation/CoreImage in Media; put AppKit/SwiftUI in the app.
- Localise every user-visible string with `L("English text")` / `LF("… %@ …", args)`, then add the Vietnamese line to `Resources/vi.lproj/Localizable.strings`
  and run `check_localization.py`. Placeholders must match. Keep captions short and plain.
- Style: small value types, comments explain *why*, pure functions with tests. Keep selection/edit logic in Core so it can be tested without a window.
- Undo: every edit goes through `EditorSession.edit(label, coalesce:)` (one undo step; `coalesce` merges a slider drag; call `endCoalescing()` on release).
- Never use a force-quit or `kill -9` on the maintainer's running MacPlayer to "update" it; replace the bundle and ask them to relaunch.

## 8. Testing guidance

- Write Core tests for every model/math change (Swift Testing: `@Test`, `#expect`). Write Media tests that check **real pixels or samples** (see `ColorGradeTests`, `MaskTests`,
  `SoundFXTests`, `Support.swift` helpers `frame(_:at:)`, `Pixels`, `Fixtures.shared.source()` = 320×180 video with red/green/blue corner markers).
- Vision cannot be tested on synthetic pictures: tests replace `SubjectMasker.provider`. Audio effects are tested with generated tones (zero-crossing counts, RMS).
- Always run the whole suite before a release. **Known flaky:** `StabilizerTests.anExportedVideoIsSteadierThanTheOneItCameFrom` fails about half of the runs on the maintainer's machine, also before the
  0.4.0–0.7.0 work (verified on the older commit); do not "fix" other code for it.
- `Scripts/crash_test.py` modes: `copy`, `batch`, `autosave` (kill while the project is written over and over: the file must always decode).
- The in-app self-test (`--selftest`) had 2 failing checks on the current macOS 27 setup even before the 0.4–0.7 work (window size kept through photo slideshow; a duplicate-shortcut check that sees the
  system's "Emoji & Symbols"/"Enter Full Screen" items). Injected mouse events in the self-test are flaky; the click flows run only with `MACPLAYER_TREE_SPEED_ONLY=1`.
- Never run tests against the maintainer's real media except through the read-only paths documented in `docs/kiem-thu-video-that.md`.

## 9. How to add a feature (checklist)

1. State a short plan; read the neighbouring code (use the table above; `codegraph_*` MCP tools may be available, but grep/read works).
2. **Core**: value types + math + `Codable` compatibility + tests.
3. **Media**: render in `RecipeCompositor`/renderer (both preview and export), heavy work cached; tests with real pixels/samples; include it in `needsReencode`/`previewNeeded`.
4. **App**: an inspector card (reuse `ToolCard`, `SliderRow`, `PanelButton`, `EasingMenu`, `MaskControls`…), editing through `session.edit`/`editColor`/`updateOverlay`/…; add the tab to `InspectorTab` if new.
5. Strings → Vietnamese; `check_localization.py` clean. Screenshot the UI with `--snapshot` and look at it.
6. Docs: `README.md` section, `docs/bao-cao-ban-giao.md` (what was done and what was *not* verified), this file.
7. Version bump + release + install (rule 5 above). Commit and push only when the maintainer asks.

## 10. Known limits and ideas not done

Not done / not verified: keyframes for colour and crop; Intel Macs; other players reading fast-cut files; real VoiceOver/Reduce Motion audit; Vision on real people (only stubbed in tests);
UI flows with a real mouse; notarization and Developer ID (needs a paid account: never fake it); tags/collections for the library; picture-in-picture window; custom shortcuts;
undo for playlist operations. HDR video: colour changes apply to the stored HDR values without tone mapping (the UI warns). Voice-effect copies are made when an effect is chosen
(not live while a slider moves).
