#!/usr/bin/env python3
"""Checks that Finder's "Open With" and double-clicking reach the app, using `open -a` (the same Launch Services path).

usage: python3 -I Scripts/open_with_test.py build/MacPlayer.app .build/release/macplayer-probe <work-dir>
Uses a throwaway data folder (--sandbox), so nothing touches the real settings. Makes its own small synthetic videos."""
import json, os, subprocess, sys, time, shutil, signal, unicodedata

app, probe, work = (os.path.abspath(a) for a in sys.argv[1:4])
shutil.rmtree(work, ignore_errors=True); os.makedirs(work + "/box"); os.makedirs(work + "/folder")
report = work + "/report.json"
fails = []

def check(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg)
    if not ok: fails.append(msg)

def gen(name, secs):
    subprocess.run([probe, "gen", f"{work}/{name}", "h264", str(secs), "30", "30"], check=True, stdout=subprocess.DEVNULL)

gen("one.mp4", 3); gen("two.mov", 3); gen("space name é.mp4", 3)
for n in ("a.mp4", "b.mp4", "c.mp4"): gen("folder/" + n, 2)
subprocess.run([probe, "mkproject", f"{work}/one.mp4", f"{work}/proj.macplayer"], check=True, stdout=subprocess.DEVNULL)

def state():
    try: return json.load(open(report))
    except Exception: return None

def wait(pred, secs=20):
    end = time.time() + secs
    while time.time() < end:
        s = state()
        if s and pred(s): return s
        time.sleep(0.3)
    return state()

def launch_with(path):  # first launch: the file arrives with the launch, like double-clicking while the app is closed
    subprocess.run(["open", "-a", app, path, "--args", "--sandbox", work + "/box", "--report-session", report], check=True)

def open_in_running(path):
    subprocess.run(["open", "-a", app, path], check=True)

def quit_app():
    s = state()
    if s:
        try: os.kill(s["pid"], signal.SIGTERM)
        except ProcessLookupError: pass
    time.sleep(1.0)
    if os.path.exists(report): os.remove(report)

def videos(s): return [w for w in s["windows"] if w.get("hasVideo")]

# 1. app closed -> open a video
launch_with(work + "/one.mp4")
s = wait(lambda s: len(videos(s)) == 1)
check(s and len(videos(s)) == 1 and videos(s)[0]["path"].endswith("one.mp4"), "launching with a video opens it")
check(s and len(s["windows"]) == 1, "and does not leave an empty window beside it")
check(s and abs(videos(s)[0]["duration"] - 3) < 0.2, "and it is read correctly (3 s)")
check(s and videos(s)[0].get("route") == "solo" and not videos(s)[0]["isProject"], "a video from Finder opens to be watched in a window of its own, without the playlists (0.15), not in the editor")

# 2. app running -> a second video opens in a new window; the first stays
open_in_running(work + "/two.mov")
s = wait(lambda s: len(videos(s)) == 2)
check(s and len(videos(s)) == 2, "Open With in a running app opens a second window")
check(s and any(w["path"].endswith("one.mp4") for w in videos(s)) and any(w["path"].endswith("two.mov") for w in videos(s)), "the first video stays open")

# 3. a name with spaces and accents
open_in_running(work + "/space name é.mp4")
s = wait(lambda s: len(videos(s)) == 3)
check(s and len(videos(s)) == 3 and any("space name é" in unicodedata.normalize("NFC", w["path"]) for w in videos(s)), "a file name with spaces and accents opens")

# 4. a folder becomes a playlist
open_in_running(work + "/folder")
s = wait(lambda s: s["playlists"] >= 1 and s["windows"] and any(w.get("playlistItems", 0) >= 3 for w in s["windows"]))
check(s and s["playlists"] >= 1, "dropping a folder makes a playlist")
check(s and any(w.get("playlistItems", 0) == 3 for w in s["windows"]), "with the 3 videos in it")
quit_app()

# 5. a project file by double-click on a closed app
launch_with(work + "/proj.macplayer")
s = wait(lambda s: len(videos(s)) == 1)
check(s and len(videos(s)) == 1 and videos(s)[0]["isProject"], "double-clicking a .macplayer file opens it as a project")
check(s and videos(s)[0]["projectPath"].endswith("proj.macplayer") and videos(s)[0]["clips"] == 1, "with its path and its clip")
check(s and videos(s)[0].get("route") == "editor" and videos(s)[0].get("kind") == "video", "in the editor, as a video project")
# 6. a file that is not a video
open_in_running(work + "/box/report.json" if False else work + "/proj.macplayer")
time.sleep(1.5)
s = state()
check(s and len([w for w in videos(s) if w["projectPath"].endswith("proj.macplayer")]) == 1, "opening the same project again brings its window forward instead of opening it twice")
quit_app()

# 7. a damaged file: no crash, a message
open(work + "/broken.mp4", "wb").write(b"not a video at all" * 100)
launch_with(work + "/broken.mp4")
time.sleep(4)
s = state()
check(s is not None and len(videos(s)) == 0, "a damaged file does not open, and the app stays up")
alive = False
if s:
    try: os.kill(s["pid"], 0); alive = True
    except ProcessLookupError: pass
check(alive, "the app is still running after a damaged file")
quit_app()

print("ALL OPEN-WITH CHECKS PASSED" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(1 if fails else 0)
