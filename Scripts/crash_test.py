#!/usr/bin/env python3 -I
"""Kills a running MacPlayer with SIGKILL in the middle of an export, at many different moments, then relaunches it the way
a user would and checks the promises of the save flow:
  * the original video is never lost or damaged (byte-identical, or replaced by a complete valid video with a backup);
  * no half-written file is left where a result should be, and no MacPlayer temp files remain after recovery;
  * the crash is recoverable: recovery reports are sane and interrupted queue jobs come back as "queued".

Usage: python3 -I Scripts/crash_test.py <MacPlayer.app> <macplayer-probe> <long-video.mp4> [iterations] [seed]
The long video should take a few seconds to export (a 60 s 640x360 clip does). Works only in a throw-away sandbox
and a throw-away folder: it never touches your own data."""
import hashlib, json, os, random, shutil, signal, subprocess, sys, tempfile, time

app, probe, media = sys.argv[1], sys.argv[2], sys.argv[3]
iterations = int(sys.argv[4]) if len(sys.argv) > 4 else 6
random.seed(int(sys.argv[5]) if len(sys.argv) > 5 else 1)
exe = os.path.join(app, "Contents/MacOS/MacPlayer")

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

def valid_video(p):
    r = subprocess.run([probe, "info", p], capture_output=True, text=True)
    if r.returncode != 0: return False
    try: return json.loads(r.stdout)["duration"]["value"] > 0
    except Exception: return False

def temps(d):
    out = []
    for root, _, files in os.walk(d):
        out += [os.path.join(root, f) for f in files if ".macplayer-" in f]
    return out

failures, rows = [], []
for mode in ("copy", "replace", "batch"):
    for it in range(iterations):
        work = tempfile.mkdtemp(prefix="mv-crash-"); sandbox = os.path.join(work, "sandbox"); os.makedirs(sandbox)
        src = os.path.join(work, "source.mp4"); outdir = os.path.join(work, "out"); os.makedirs(outdir)
        shutil.copy(media, src)
        original = sha(src)
        delay = random.uniform(0.15, 3.0)
        p = subprocess.Popen([exe, "--sandbox", sandbox, "--crash-export", src, outdir, mode], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        started = None
        t0 = time.time()
        while time.time() - t0 < 20:
            line = p.stdout.readline()
            if line.startswith("STARTED"): started = line.strip().split(" ", 1)[1].split("|"); break
            if line.startswith("ERROR") or p.poll() is not None: break
        if not started:
            failures.append(f"{mode}#{it}: the export did not start"); p.kill(); shutil.rmtree(work, ignore_errors=True); continue
        time.sleep(delay)
        killed_running = p.poll() is None
        p.send_signal(signal.SIGKILL); p.wait()
        # What was left on disk at the moment of the crash.
        before_temps = len(temps(work))
        src_exists = os.path.exists(src)
        r = subprocess.run([exe, "--sandbox", sandbox, "--recover-check"], capture_output=True, text=True, timeout=60)
        rec = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
        problems = []
        if not os.path.exists(src): problems.append("THE ORIGINAL IS GONE")
        else:
            same = sha(src) == original
            if mode == "replace":
                if not same:
                    if not valid_video(src): problems.append("original replaced by an INVALID file")
                    backups = [os.path.join(dp, f) for dp, _, fs in os.walk(work) for f in fs if ".original-" in f]
                    if not backups: problems.append("original replaced but NO backup")
                    elif not any(sha(b) == original for b in backups): problems.append("backup differs from the original")
            elif not same: problems.append("source changed by a copy/batch export")
        for out in started:
            if os.path.exists(out) and not valid_video(out): problems.append(f"a result file exists but is not a valid video: {os.path.basename(out)}")
        left = temps(work)
        if left: problems.append(f"temp files remain after recovery: {[os.path.basename(x) for x in left]}")
        if mode != "replace" and rec.get("restoredJobs", 0) == 0 and killed_running and not any(os.path.exists(o) for o in started):
            problems.append("an interrupted job was not offered again")
        rows.append((mode, it, round(delay, 2), killed_running, before_temps, rec.get("journal", []), rec.get("restoredJobs"), "OK" if not problems else "; ".join(problems)))
        failures += [f"{mode}#{it} (kill at {delay:.2f}s): {x}" for x in problems]
        shutil.rmtree(work, ignore_errors=True)

print(f"{'mode':8} {'#':>2} {'kill@':>6} {'running':>7} {'temps':>5} {'journal':>10} {'restored':>8}  result")
for m, i, d, run, bt, j, rj, res in rows:
    print(f"{m:8} {i:>2} {d:>6} {str(run):>7} {bt:>5} {len(j):>10} {str(rj):>8}  {res}")
print()
print("ALL CRASH CHECKS PASSED" if not failures else f"{len(failures)} PROBLEM(S):\n  " + "\n  ".join(failures))
sys.exit(1 if failures else 0)
