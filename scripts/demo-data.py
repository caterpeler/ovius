#!/usr/bin/env python3
"""Writes made-up pipeline results for a demo, and imports them into a library: two clusters, a run a day, a folder per
camera (report.csv, events.csv, review.json) whose figures, as metrics.py works them out, are those asked for. Stdlib
only.

    python3 scripts/demo-data.py OUT                                  # the folders, OUT/<run>/camera-<k>__demo
    python3 scripts/demo-data.py OUT --app Ovius --library LIB  # and each run imported into LIB, in date order

Section B's last run is the team's slide: its Recording Overview row for row. Its earlier runs are ordinary days drawn
around it, and days on which something went wrong, each for a flag to show:
    4 Nov  long queues: fewer trucks loaded, and they waited long        (unusual queue time, truck use, cycles/h)
    5 Nov  no run: nobody analysed the day's footage                    (a gap in the calendar)
    6 Nov  camera 3's view of the trucks is blocked: no load seen       (no load cycles)
    7 Nov  camera 5's video could not be read                          (a camera failed)
    8 Nov  camera 2's recorder stopped after 4 h                         (footage under half the longest)
    9 Nov  the PTZ cameras kept moving and cut most loads short          (most cycles estimated)
Section A: ordinary days of another section, so that what is usual across all clusters is not Section B's alone.

Each camera: its cycles (one truck each, waited for), load and queue times drawn and scaled to the row's mean and
standard deviation; four excavators whose idle times give the idle mean and standard deviation, their working time
the excavator utilisation; the trucks' spotting the dump truck utilisation. The draws are seeded: the same runs give
the same folders. Volume is cycles × the volume of a load (Settings), as always.
"""

import argparse
import csv
import json
import math
import os
import random
import statistics
import subprocess
from pathlib import Path

# A camera's row of the Recording Overview: load cycles; load, queue and (excavator) idle time, mean and standard
# deviation; excavator and dump truck utilisation (%).
SLIDE = [
    (165, 173.0, 11.2, 180.8, 65.7, 77.5, 80.9, 89.3, 64.6),
    (402, 61.2, 10.6, 146.3, 138.1, 84.2, 69.0, 92.9, 31.4),
    (239, 105.8, 18.4, 39.8, 24.5, 45.5, 28.6, 84.8, 76.7),
    (175, 170.1, 27.9, 157.0, 147.3, 83.9, 74.0, 93.6, 62.0),
    (351, 80.7, 16.2, 26.4, 11.9, 8.3, 8.7, 96.0, 83.5),
]
SECTION_A = [
    (210, 95.0, 14.0, 70.0, 40.0, 50.0, 30.0, 88.0, 70.0),
    (280, 72.0, 12.0, 55.0, 35.0, 35.0, 25.0, 91.0, 74.0),
    (190, 120.0, 20.0, 90.0, 60.0, 60.0, 40.0, 86.0, 66.0),
]
HOURS = 12.0  # a day shift
FPS = 10  # review.json's frames: a tenth of a second each
POINTS = 4  # excavators (loading points) per camera


def r1(x):
    return round(x + 0.0, 1)


def stats(values):
    return r1(statistics.mean(values)), r1(statistics.stdev(values))


def drawn(n, mean, sd, seed):
    """n values to a tenth, all above zero, whose mean and sample standard deviation round to `mean` and `sd`: a
    normal draw, or a lognormal one when a normal would go below zero, scaled to them."""
    for attempt in range(2000):
        rng = random.Random(seed * 1000 + attempt)
        if mean - 3.5 * sd > 0:
            raw = [rng.gauss(0, 1) for _ in range(n)]
        else:
            sigma = math.sqrt(math.log(1 + (1.3 * sd / mean) ** 2))
            raw = [rng.lognormvariate(0, sigma) for _ in range(n)]
        m, s = statistics.mean(raw), statistics.stdev(raw)
        values = [r1(mean + sd * (v - m) / s) for v in raw]
        if min(values) > 0.5 and stats(values) == (mean, sd):
            return values
    raise SystemExit(f"could not draw {n} values of {mean} ± {sd}")


def idle_times(mean, sd):
    """Four excavators' idle seconds, to a tenth, with this mean and standard deviation: three alike, one apart."""
    base = [mean - 0.5 * sd] * 3 + [mean + 1.5 * sd]
    for k in range(4000):
        rng = random.Random(k)
        values = [r1(v + (rng.randint(-3, 3) / 10 if k else 0)) for v in base]
        if min(values) >= 0 and stats(values) == (mean, sd):
            return values
    raise SystemExit(f"could not make idle times of {mean} ± {sd}")


def nearest(start, good, limit=50):
    """The value nearest `start`, in tenths, that `good` takes."""
    for step in [0] + [d / 10 for j in range(1, limit * 10) for d in (j, -j)]:
        if good(r1(start + step)):
            return r1(start + step)
    return None


def write(folder, events, points, working, idles, loads_at, duration):
    """The three files the Productivity report and --review write: events, report and review.json."""
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / "events.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kind", "point", "truck", "start", "end", "start_s", "end_s", "duration_s", "spot_s", "complete"])
        for kind, point, truck, s, e, d, sp, whole in sorted(events, key=lambda ev: (ev[3], ev[0])):
            w.writerow([kind, point, truck, "", "", s, e, d, sp, whole])
    with open(folder / "report.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["loading_point", "excavator_ids", "working_pct", "loads"])
        for p, point in enumerate(points):
            seen = working[p] + idles[p]
            w.writerow([point, f"E{p + 1}", r1(100 * working[p] / seen) if seen else "", loads_at[p]])
        w.writerow(["all", " ".join(f"E{p + 1}" for p in range(len(points))), "", sum(loads_at)])
    # Each excavator's frames: working, then idle; a tenth of a second each.
    frame, ids, activity = [], [], []
    for p in range(len(points)):
        on, off = round(working[p] * FPS), round(idles[p] * FPS)
        frame += list(range(on + off))
        ids += [p + 1] * (on + off)
        activity += [0] * on + [1] * off
    review = {"video_fps": FPS, "every": 1, "count": int(duration * FPS), "width": 1920, "height": 1080,
              "names": ["excavator", "dumptruck"], "roles": ["excavator", "truck"], "activities": ["working", "idle", "unknown"],
              "frame": frame, "id": ids, "activity": activity, "events": []}
    (folder / "review.json").write_text(json.dumps(review, separators=(",", ":")))


def camera(folder, row, seed, hours=HOURS, cut=0.0):
    """A camera whose figures are `row`, over `hours`. `cut`: the share of its loads a camera move cut short, seen
    only in part (the app estimates the rest)."""
    n, load_m, load_sd, queue_m, queue_sd, idle_m, idle_sd, exc_util, truck_util = row
    loads = drawn(n, load_m, load_sd, seed=10 * seed + 1)
    waits = drawn(n, queue_m, queue_sd, seed=10 * seed + 2)

    # Spotting, the same for each truck: spotting and loading over waiting, spotting and loading is the truck use. A
    # use lower than loading alone gives is raised to it.
    least = 100 * sum(loads) / (sum(loads) + sum(waits))
    truck_util = r1(max(truck_util, math.ceil(least * 10) / 10 + 0.1))

    def use(s):
        busy = n * s + sum(loads)
        return s >= 0 and r1(100 * busy / (busy + sum(waits))) == truck_util

    spot = nearest(max(0.0, (truck_util / (100 - truck_util) * sum(waits) - sum(loads)) / n), use)
    if spot is None:
        raise SystemExit(f"{folder.name}: no spotting gives {truck_util}% dump truck use")

    # The excavators: idle times as asked, working time so that working over time in view is the excavator use.
    idles = idle_times(idle_m, idle_sd)
    working = nearest(sum(idles) * exc_util / (100 - exc_util) / POINTS,
                      lambda w: r1(100 * POINTS * w / (POINTS * w + sum(idles))) == exc_util)
    if working is None:
        raise SystemExit(f"{folder.name}: no working time gives {exc_util}% excavator use")

    duration = hours * 3600
    rng = random.Random(seed)
    # Each point's loads spread over the footage, one after another; each truck waits, then spots, then is loaded.
    lead = max(w + spot for w in waits) + 60
    points = [f"LP{p + 1}" for p in range(POINTS)]
    per_point = [[j for j in range(n) if j % POINTS == p] for p in range(POINTS)]
    events = []
    for p, mine in enumerate(per_point):
        gap = (duration - lead - 300) / max(1, len(mine))
        for i, j in enumerate(mine):
            start = r1(lead + i * gap + p * 7)
            whole = rng.random() >= cut
            seen = loads[j] if whole else r1(loads[j] * rng.uniform(0.35, 0.7))
            arrive = r1(start - spot - waits[j])
            truck = f"T{seed % 1000}{j + 1:04d}"
            events.append(("loading", points[p], truck, start, r1(start + seen), seen, 0.0, whole))
            events.append(("queue", points[p], truck, arrive, start, r1(start - arrive), spot, True))
    write(folder, events, points, [working] * POINTS, idles, [len(m) for m in per_point], duration)


def blocked(folder, hours=HOURS):
    """A camera that sees its excavators at work, as on any day, but no truck loaded: its view of them is blocked."""
    idles = [40.2, 45.6, 50.1, 47.3]
    write(folder, [], [f"LP{p + 1}" for p in range(POINTS)], [400.0] * POINTS, idles, [0] * POINTS, hours * 3600)


def failed(folder):
    """A camera whose video the pipeline could not read: not one frame analysed."""
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "events.csv").write_text("kind,point,truck,start,end,start_s,end_s,duration_s,spot_s,complete\n")
    (folder / "report.csv").write_text("loading_point,excavator_ids,working_pct,loads\nall,,,0\n")
    (folder / "review.json").write_text(json.dumps({"video_fps": FPS, "every": 1, "count": 0, "activities": ["unknown"],
                                                    "frame": [], "id": [], "activity": [], "events": []}))


def ordinary(rows, seed):
    """A day like the ones these rows are of: each figure a little up or down."""
    rng = random.Random(seed)
    out = []
    for n, lm, ls, qm, qs, im, isd, eu, tu in rows:
        im2 = r1(im * rng.uniform(0.85, 1.15))
        out.append((round(n * rng.uniform(0.9, 1.1)), r1(lm * rng.uniform(0.95, 1.05)), r1(ls * rng.uniform(0.85, 1.15)),
                    r1(qm * rng.uniform(0.9, 1.1)), r1(qs * rng.uniform(0.85, 1.15)), im2, r1(min(isd * rng.uniform(0.85, 1.15), 1.9 * im2)),
                    r1(min(98.5, eu + rng.uniform(-2, 2))), r1(min(95.0, tu + rng.uniform(-3, 3)))))
    return out


def runs():
    """Every run: its cluster, its cameras' clock at the start, and how each camera's folder is made."""
    out = []
    for k, day in enumerate(["05", "06", "07", "08", "09"]):
        rows = ordinary(SECTION_A, seed=100 + k)
        out.append(("Section A", f"2026-11-{day} 06:00:00", "ordinary",
                    [(f"Camera {c + 1}", lambda f, row=row, s=1000 + 10 * k + c: camera(f, row, s)) for c, row in enumerate(rows)]))

    def section_b(day, story, rows, special=None):
        cams = []
        for c, row in enumerate(rows):
            s = 2000 + 10 * int(day) + c
            make = (special or {}).get(c + 1) or (lambda f, row=row, s=s: camera(f, row, s))
            cams.append((f"Camera {c + 1}", make))
        out.append(("Section B", f"2026-11-{day} 06:00:00", story, cams))

    for day in ["02", "03"]:
        section_b(day, "ordinary", ordinary(SLIDE, seed=int(day)))
    # Long queues: fewer trucks loaded; they waited long, and the excavators stood idle more.
    queues = [(round(n * 0.7), lm, ls, r1(qm * 2.3 + 60), r1(qs * 1.6), r1(im * 1.8), r1(isd * 1.5), r1(eu - 12), r1(tu * 0.55))
              for n, lm, ls, qm, qs, im, isd, eu, tu in ordinary(SLIDE, seed=4)]
    section_b("04", "long queues", queues)
    section_b("06", "camera 3's view of the trucks blocked", ordinary(SLIDE, seed=6), {3: blocked})
    section_b("07", "camera 5's video could not be read", ordinary(SLIDE, seed=17), {5: failed})
    stopped = ordinary(SLIDE, seed=8)
    n, *rest = stopped[1]
    section_b("08", "camera 2's recorder stopped after 4 h", stopped,
              {2: lambda f, row=(round(n / 3), *rest): camera(f, row, 2082, hours=4.0)})
    moving = ordinary(SLIDE, seed=9)
    section_b("09", "cameras kept moving: most loads cut short", moving,
              {c + 1: (lambda f, row=row, s=2090 + c: camera(f, row, s, cut=0.7)) for c, row in enumerate(moving)})
    section_b("10", "the team's slide", SLIDE)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("out", type=Path)
    parser.add_argument("--app", help="the app's executable, to import each run with")
    parser.add_argument("--library", help="the library to import into (OVIUS_LIBRARY)")
    a = parser.parse_args()
    for k, (cluster, start, story, cams) in enumerate(runs(), 1):
        folder = a.out / f"run-{k:02d}"
        args = ["--cluster", cluster]
        for c, (name, make) in enumerate(cams, 1):
            make(folder / f"camera-{c}__demo")
            args += ["--import-results", str(folder / f"camera-{c}__demo"), "--camera", name, "--start", start,
                     "--video", f"camera-{c}.mp4"]
        print(f"{cluster}, {start[:10]}: {story}")
        if a.app:
            env = dict(os.environ, OVIUS_LIBRARY=a.library)
            done = subprocess.run([a.app, *args], env=env, capture_output=True, text=True)
            if done.returncode != 0:
                raise SystemExit(f"importing {folder} failed: {done.stderr.strip()}")


if __name__ == "__main__":
    main()
