"""The team's figures (the Recording Overview of mining_productivity_dashboard.xlsx) from what a labeler pipeline
wrote: report.csv and events.csv (its Loading events and Productivity report nodes) and review.json. Stdlib only,
Python 3.9 or newer.

    python metrics.py OUTPUT_DIR SETTINGS.json METRICS.json     one camera's video: its cycles and excavators
    python metrics.py --cluster INPUT.json METRICS.json          a cluster's batch, once every camera is done
    python metrics.py --rows INPUT.json METRICS.json             the figures of cycles already complete (tests)

A cycle is a loading event: a truck that came close to an excavator, stayed, and left. One the video's start or end
(or a big camera move) cut short is completed by imputation in the cluster step, and counted as estimated."""

import csv
import json
import random
import re
import sys
from pathlib import Path
from statistics import NormalDist, mean, median, stdev

VERSION = 2
# Imputed load times are drawn within this many standard deviations of the mean.
SPREAD = 0.45


def rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def num(v, default=None):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return default
    return x if x == x else default


def r1(x):
    return None if x is None else round(x, 1)


def spread(values):
    """Mean and sample standard deviation (0 for one value); None for none, as a blank cell."""
    values = [v for v in values if v is not None]
    if not values:
        return None, None
    return r1(mean(values)), r1(stdev(values)) if len(values) > 1 else 0.0


# MARK: One camera


def camera(out_dir, s):
    """One video's loading points (an excavator each) and cycles, as seen: nothing is imputed here."""
    out_dir = Path(out_dir)
    review = json.loads((out_dir / "review.json").read_text())
    # A video none of whose frames were analysed is a camera that failed, not one that saw nothing.
    if not review.get("count"):
        raise SystemExit("No frame of the video was analysed: it may be unreadable, or empty.")
    report = [r for r in rows(out_dir / s.get("report_file", "report.csv")) if r["loading_point"] != "all"]
    events = rows(out_dir / s.get("events_file", "events.csv"))
    fps, every = float(review["video_fps"]), int(review["every"])
    step = every / fps
    activities = review["activities"]

    # Every machine's frames and its coarse state: working, idle or unknown for an excavator. A state model's own
    # states (state:...) count as working unless idle.
    coarse_of = review.get("coarse")
    by_id = {}
    for k, (f, i, a) in enumerate(zip(review["frame"], review["id"], review["activity"])):
        state = activities[coarse_of[k]] if coarse_of is not None else activities[a]
        if state.startswith("state:"):
            state = "idle" if state[6:].lower() == "idle" else "working"
        # The state model's own state (digging, swinging…), where it judged this machine.
        own = activities[a][6:] if activities[a].startswith("state:") else None
        by_id.setdefault(i, []).append((f / fps, state, own))

    loads = [e for e in events if e["kind"] == "loading"]
    waits = [e for e in events if e["kind"] == "queue"]
    excavators, seen_frames = [], set()
    for r in report:
        name = r["loading_point"]
        ids = [int(x) for x in re.findall(r"\d+", r["excavator_ids"])]
        frames, own = {}, {}
        for i in ids:
            for t, state, detail in by_id.get(i, []):
                if state != "unknown":
                    frames[t] = frames.get(t, False) or state == "working"
                if detail and t not in own:
                    own[t] = detail
        seen_s = len(frames) * step
        served = sum(1 for e in loads if e["point"] == name)
        # A point seen only briefly, with no loads, is a box the detector saw for a moment, not an excavator.
        if seen_s / 60 < float(s.get("min_point_minutes", 5)) and not served:
            continue
        seen_frames.update(round(t, 3) for t in frames)
        working_s = sum(1 for w in frames.values() if w) * step
        excavator = {"point": name, "ids": r["excavator_ids"], "seen_s": r1(seen_s), "working_s": r1(working_s),
                     "idle_s": r1(seen_s - working_s), "loads": served}
        if own:
            counts = {}
            for detail in own.values():
                counts[detail] = counts.get(detail, 0) + 1
            excavator["states"] = [{"state": k, "s": r1(n * step)} for k, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
        excavators.append(excavator)

    # Each load and the wait just before it: the same truck at the same point, ending as the load starts.
    used, cycles = set(), []
    for e in sorted(loads, key=lambda e: num(e["start_s"], 0)):
        start, end = num(e["start_s"], 0), num(e["end_s"], 0)
        truck = e["truck"].split("+")[0]
        match = [k for k, q in enumerate(waits) if k not in used and q["point"] == e["point"] and q["truck"] == truck
                 and abs(num(q["end_s"], 0) - start) <= step + 0.01]
        q = waits[match[0]] if match else None
        if q is not None:
            used.add(match[0])
        # A truck is not waiting for a load while it is being loaded: a wait starts no earlier than the same truck's
        # last load there ended (the tracker gives two trucks one ID now and then).
        before = [c["load_end_s"] for c in cycles if c["point"] == e["point"] and truck in c["truck"].split("+") and c["load_end_s"] <= start]
        arrive = max([num(q["start_s"], 0)] + before) if q else None
        spot = min(num(q.get("spot_s"), 0.0), start - arrive) if q else 0.0
        cycles.append({
            "point": e["point"], "truck": e["truck"],
            # On the video's clock, in seconds: when it came into the loading area (unknown without a wait), began
            # moving into place, and was loaded.
            "arrive_s": arrive,
            "spot_at_s": r1(start - spot) if q else None,
            "load_start_s": start, "load_end_s": end,
            # Standing in the area before spotting, the spotting, and the loading (as seen).
            "wait_s": r1(max(0.0, start - arrive - spot)) if q else 0.0,
            "spot_s": r1(spot),
            "load_s": num(e["duration_s"]),
            "complete": e["complete"] == "True",
        })
    return {
        "version": VERSION,
        "video": {"fps": fps, "every": every, "duration_s": r1(review["count"] * step), "start": s.get("start")},
        "observed_h": round(len(seen_frames) * step / 3600, 3),
        "excavators": excavators,
        "cycles": cycles,
    }


# MARK: Imputation


def prior(own, cluster, seen):
    """What an incomplete cycle's load time is drawn from: this camera's complete loads (two or more, not all the
    same), else the cluster's complete loads (two or more), else every load the cluster's cameras saw, complete or
    not (the seen part of a load cut short)."""
    enough = {"camera": lambda v: len(v) >= 2 and stdev(v) > 0, "cluster": lambda v: len(v) >= 2, "seen": lambda v: len(v) >= 1}
    for basis, values in (("camera", own), ("cluster", cluster), ("seen", seen)):
        if enough[basis](values):
            sd = stdev(values) if len(values) > 1 else 0.0
            m = mean(values)
            return {"basis": basis, "n": len(values), "mean": r1(m), "stdev": r1(sd), "low": r1(m - SPREAD * sd), "high": r1(m + SPREAD * sd)}
    return {"basis": "none", "n": 0, "mean": None, "stdev": None, "low": None, "high": None}


def draw(rng, p, seen):
    """A load time from a Gaussian truncated to the prior's ±0.45 σ, and at least the part that was seen; the part
    seen when it is already longer than that."""
    if p["mean"] is None:
        return seen
    lo, hi = max(p["mean"] - SPREAD * p["stdev"], seen or 0.0), p["mean"] + SPREAD * p["stdev"]
    if p["stdev"] == 0:
        return max(p["mean"], seen or 0.0)
    if lo >= hi:
        return seen
    dist = NormalDist(p["mean"], p["stdev"])
    a, b = dist.cdf(lo), dist.cdf(hi)
    return round(min(hi, max(lo, dist.inv_cdf(a + rng.random() * (b - a)))), 1)


def impute(cameras):
    """Completes each camera's incomplete cycles in place, with a seed of its own (its analysis), so the same batch
    always gives the same figures. Returns each camera's prior."""
    every_complete = [c["load_s"] for cam in cameras for c in cam["cycles"] if c["complete"] and c["load_s"]]
    every_seen = [c["load_s"] for cam in cameras for c in cam["cycles"] if c["load_s"]]
    priors = []
    for cam in cameras:
        own = [c["load_s"] for c in cam["cycles"] if c["complete"] and c["load_s"]]
        p = prior(own, every_complete, every_seen)
        rng = random.Random(int(cam["seed"]))
        for c in sorted(cam["cycles"], key=lambda c: c["load_start_s"]):
            c["seen_load_s"] = c["load_s"]
            c["estimated"] = not c["complete"]
            if c["estimated"]:
                c["load_s"] = draw(rng, p, c["load_s"])
        priors.append(p)
    return priors


# MARK: The team's figures


def figures(cycles, excavators, duration_s, s):
    """One camera's row of the Recording Overview, from complete cycles (wait, spot and load times, and whether
    estimated) and its excavators (seconds working, in view, and idle)."""
    m3, struck, heaped = (float(s.get(k, d)) for k, d in (("m3_per_load", 51.1), ("m3_struck", 42.1), ("m3_heaped", 60.1)))
    n = len(cycles)
    load_mean, load_sd = spread([c["load_s"] for c in cycles])
    # Queue time: the trucks that stood waiting. Truck idle: every cycle's wait, none counting as 0.
    queue_mean, queue_sd = spread([c["wait_s"] for c in cycles if c["wait_s"]])
    truck_mean, truck_sd = spread([c["wait_s"] or 0.0 for c in cycles])
    idle_mean, idle_sd = spread([e["idle_s"] for e in excavators])
    seen = sum(e["seen_s"] for e in excavators)
    timed = [c for c in cycles if c["load_s"] is not None]
    busy = sum(c["spot_s"] + c["load_s"] for c in timed)
    there = busy + sum(c["wait_s"] or 0.0 for c in timed)
    return {
        "duration_h": round(duration_s / 3600, 4),
        "cycles": n,
        "observed": sum(1 for c in cycles if not c["estimated"]),
        "estimated": sum(1 for c in cycles if c["estimated"]),
        "load_s_mean": load_mean, "load_s_stdev": load_sd,
        "queue_s_mean": queue_mean, "queue_s_stdev": queue_sd,
        "excavator_idle_s_mean": idle_mean, "excavator_idle_s_stdev": idle_sd,
        "truck_idle_s_mean": truck_mean, "truck_idle_s_stdev": truck_sd,
        "volume_m3": round(n * m3, 1), "volume_struck_m3": round(n * struck, 1), "volume_heaped_m3": round(n * heaped, 1),
        # Working (loading, digging, clearing the face) over the time in view, each excavator's added up.
        "excavator_util_pct": r1(100 * sum(e["working_s"] for e in excavators) / seen) if seen else None,
        # Spotting and loading over the time in the loading area (waiting, spotting and loading).
        "truck_util_pct": r1(100 * busy / there) if there else None,
        "excavators": len(excavators),
        "trucks": len({c.get("truck") for c in cycles if c.get("truck")}) or n,
    }


def total(rows_):
    """The TOTAL row, by the sheet's own formulas: sums for counts and volume, the mean load time of the cameras with
    cycles, and plain averages (blanks left out) for the rest. Its hours are the longest camera's: they cover the
    same period."""
    def avg(key, only=None):
        v = [r[key] for r in rows_ if r[key] is not None and (only is None or only(r))]
        return r1(mean(v)) if v else None

    t = {k: sum(r[k] for r in rows_) for k in ("cycles", "observed", "estimated", "excavators", "trucks")}
    t.update({k: round(sum(r[k] for r in rows_), 1) for k in ("volume_m3", "volume_struck_m3", "volume_heaped_m3")})
    t["duration_h"] = max((r["duration_h"] for r in rows_), default=0.0)
    for k in ("load_s_mean", "load_s_stdev"):
        t[k] = avg(k, lambda r: r["cycles"] > 0)
    for k in ("queue_s_mean", "queue_s_stdev", "excavator_idle_s_mean", "excavator_idle_s_stdev", "truck_idle_s_mean",
              "truck_idle_s_stdev", "excavator_util_pct", "truck_util_pct"):
        t[k] = avg(k)
    return t


def summary(cameras, s):
    """The Executive Summary's cards, over every cycle of the cluster together."""
    cycles = [c for cam in cameras for c in cam["cycles"]]
    excavators = [e for cam in cameras for e in cam["excavators"]]
    loads = [c["load_s"] for c in cycles if c["load_s"] is not None]
    waits = [c["wait_s"] for c in cycles if c["wait_s"]]
    seen = sum(e["seen_s"] for e in excavators)
    m3 = float(s.get("m3_per_load", 51.1))
    observed = sum(1 for c in cycles if not c["estimated"])
    load_mean, load_sd = spread(loads)
    return {
        "cycles": len(cycles), "observed": observed, "estimated": len(cycles) - observed,
        "volume_m3": round(len(cycles) * m3, 1), "volume_observed_m3": round(observed * m3, 1),
        "volume_struck_m3": round(len(cycles) * float(s.get("m3_struck", 42.1)), 1),
        "volume_heaped_m3": round(len(cycles) * float(s.get("m3_heaped", 60.1)), 1),
        "m3_per_load": m3,
        "load_s_mean": load_mean, "load_s_stdev": load_sd, "load_s_median": r1(median(loads)) if loads else None,
        "queue_total_s": r1(sum(waits)), "queued_trucks": len(waits),
        "excavator_util_pct": r1(100 * sum(e["working_s"] for e in excavators) / seen) if seen else None,
        # Hours of footage, every camera's added up.
        "camera_h": round(sum(cam["duration_s"] for cam in cameras) / 3600, 4),
    }


def report(cameras, s, priors=None):
    out = []
    for k, cam in enumerate(cameras):
        row = figures(cam["cycles"], cam["excavators"], cam["duration_s"], s)
        out.append({"name": cam.get("name"), "analysis": cam.get("analysis", k + 1), "figures": row, "prior": priors[k] if priors else None,
                    "cycles": cam["cycles"], "excavators": cam["excavators"]})
    return {
        "version": VERSION,
        "settings": {k: s[k] for k in ("m3_per_load", "m3_struck", "m3_heaped") if k in s},
        "spread": SPREAD,
        "cameras": out,
        "total": total([c["figures"] for c in out]),
        "summary": summary(cameras, s),
    }


def cluster(input_path):
    """A batch: each camera's metrics.json (written by the step above) completed and put together."""
    spec = json.loads(Path(input_path).read_text())
    s = spec["settings"]
    cameras = []
    for cam in spec["cameras"]:
        m = json.loads(Path(cam["metrics"]).read_text())
        cameras.append({"name": cam["name"], "analysis": cam["analysis"], "seed": cam.get("seed", cam["analysis"]),
                        "duration_s": m["video"]["duration_s"], "cycles": m["cycles"], "excavators": [dict(e) for e in m["excavators"]]})
    priors = impute(cameras)
    # An excavator is busy for the whole of an estimated load, and in view for it: what was not seen of it counts
    # towards both its working time and its time in view.
    for cam in cameras:
        for e in cam["excavators"]:
            extra = sum(max(0.0, c["load_s"] - (c["seen_load_s"] or 0.0)) for c in cam["cycles"]
                        if c["estimated"] and c["load_s"] is not None and c["point"] == e["point"])
            e["working_s"], e["seen_s"] = r1(e["working_s"] + extra), r1(e["seen_s"] + extra)
    return report(cameras, s, priors)


def given(input_path):
    """Cycles already complete (as the team's sheet has them), put together as the cluster step does."""
    spec = json.loads(Path(input_path).read_text())
    return report(spec["cameras"], spec["settings"])


if __name__ == "__main__":
    if sys.argv[1] == "--cluster":
        result = cluster(sys.argv[2])
    elif sys.argv[1] == "--rows":
        result = given(sys.argv[2])
    else:
        result = camera(sys.argv[1], json.loads(Path(sys.argv[2]).read_text()))
    Path(sys.argv[3]).write_text(json.dumps(result, indent=1))
