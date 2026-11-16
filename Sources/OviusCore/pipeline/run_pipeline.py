#!/usr/bin/env python3
"""Runs a video pipeline from the labeler on a video: the nodes of pipeline.json, each after what feeds it.

    ./run.sh VIDEO                              # installs requirements.txt the first time, then runs this
    python run_pipeline.py VIDEO                # -> pipeline-output/<video>__<pipeline>/, in an environment of your own
    python run_pipeline.py VIDEO --max-s 60 --device mps

The nodes that look at every frame (Detect, Camera motion) share one pass over the video, and what they find is
cached in the output folder (cache/): a re-run that changes only later nodes takes seconds. --no-cache runs them again.

The nodes are ptz_tracking.py's steps, each with its constants as settings:
  Detect          the model or workflow (through run_workflow.py) on each frame, boxes down to a low confidence,
                  classes merged (excavator_blur counted as excavator) or dropped, one box per machine (NMS across classes).
  Camera motion   optical flow + RANSAC (shift, rotation, zoom) between frames, overlay text masked.
  Still views     big moves (a pan or zoom faster than a share of the picture per second) split the video.
  Track           ByteTrack (or BoT-SORT) whose predicted boxes move with the camera before matching.
  Re-link         IDs lost across a big move given back: SIFT + RANSAC homography, then an optimal assignment.
  Fill gaps       boxes for missed frames inside a view, on a straight line in camera-compensated coordinates.
Then what the machines do: each one's state (moving or stopped; an excavator working or idle), the loads and
queues at the excavators, and a productivity report per excavator on the camera's clock.
Python nodes run the team's own code: on whole tables (run()), or on each frame's picture in the shared pass
(step()). A Branch sends its input one of two ways; the nodes on the way not taken are skipped, with all they
feed, and an Either node joins the ways again. A Filter keeps the rows a condition holds for.
From Python: `from run_pipeline import run; values = run("pipeline.json", "video.mp4")`.
"""

import argparse
import hashlib
import inspect
import json
import linecache
import math
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # run_workflow.py, beside this file
BOX = ["x1", "y1", "x2", "y2"]
A = [f"a{k}" for k in range(6)]  # the 2×3 camera motion from the previous analysed frame, in full-size pixels

NODES = {}


def node(kind, every_frame=False):
    """Registers what runs a kind of node. A node that looks at every frame is a class, stepped through the video
    together with the others like it; any other is a function of the context, its settings and its inputs."""

    def register(f):
        NODES[kind] = SimpleNamespace(run=f, every_frame=every_frame)
        return f

    return register


class Table:
    """Boxes, and the class names of the model that found them."""

    def __init__(self, df, names):
        self.df, self.names = df, names


def analysed(frames):
    """The numbers of the frames analysed."""
    return [i * frames.every for i in range(frames.count)]


def wrote(ctx, name):
    ctx.written.append(ctx.out / name)
    return {}


def with_hidden(trk):
    """Tracks with the column Fill gaps adds, for tracks that were not filled."""
    return trk if "hidden" in trk else trk.assign(hidden=False)


# ---- code of the team's own, and branches ----


class Skipped:
    """What a node on a Branch's way not taken gives: the nodes it feeds are skipped too."""

    def __repr__(self):
        return "skipped"


SKIPPED = Skipped()

# The columns each kind of data has to have, as the nodes it goes into read them.
COLUMNS = {
    "detections": ["frame", "cls", "conf", *BOX],
    "tracks": ["frame", "seg", "id", "cls", "conf", *BOX],
    "states": ["frame", "seg", "id", "cls", "conf", *BOX, "state", "vx", "vy", "vw"],
    "events": ["kind", "point", "truck", "start_frame", "end_frame", "start_s", "end_s", "duration_s", "start_seen", "end_seen",
               "complete", "view"],
}


def where_of(n):
    """A node as code errors name it: <Python python-1>."""
    return f"<{n['label']} {n['id']}>"


def compiled(code, where, mode):
    """Code compiled under the node's name, its lines known to tracebacks: an error shows the line it is on."""
    linecache.cache[where] = (len(code), None, code.splitlines(True), where)
    return compile(code, where, mode)


def load_code(code, n):
    """Runs a node's code as a module of its own and returns its names. numpy, pandas, OpenCV and math are there as
    np, pd, cv2 and math without an import."""
    names = {"__name__": f"node_{n['id'].replace('-', '_')}", "np": np, "pd": pd, "cv2": cv2, "math": math}
    exec(compiled(code, where_of(n), "exec"), names)
    return names


def caller(f):
    """Calls f with those of the arguments given that it names (all of them, if it takes **kwargs)."""
    params = inspect.signature(f).parameters
    if any(q.kind == q.VAR_KEYWORD for q in params.values()):
        return lambda args: f(**args)
    return lambda args: f(**{k: v for k, v in args.items() if k in params})


def node_ctx(ctx, n):
    """What code is told of the video: frames analysed per second (fps), the video's own rate, its frames, and
    path(name), a file in the output folder that is listed with the outputs."""
    frames = ctx.frames

    def path(name):
        ctx.written.append(ctx.out / name)
        return ctx.out / name

    return SimpleNamespace(video=ctx.video, out=ctx.out, frames=frames, fps=frames.vfps / frames.every, video_fps=frames.vfps,
                           every=frames.every, node=n["id"], path=path)


def table_of(value):
    """The table in what flows along a wire (detections, tracks and states are tables with a model's class names,
    events with their loading points), or None."""
    if isinstance(value, pd.DataFrame):
        return value
    df = getattr(value, "df", None)
    return df if isinstance(df, pd.DataFrame) else None


def as_data(data, value, like, where):
    """A value code returned (or a Filter kept) as the kind of data `data` it flows on as: None skips what it feeds.
    `like` is what the node was given, for what a bare table lacks: the model's class names, the loading points."""
    if value is None or value is SKIPPED:
        return SKIPPED
    df = table_of(value)
    if df is None:
        try:
            df = pd.DataFrame(value)
        except (TypeError, ValueError):
            raise TypeError(f"{where}: its {data} have to be a table (a pandas DataFrame), not {type(value).__name__}") from None
    if data in ("table", "links"):
        return df
    missing = [c for c in COLUMNS[data] if c not in df]
    if missing:
        raise ValueError(f"{where}: its {data} lack the column{'s' * (len(missing) > 1)} {', '.join(missing)}")
    if data == "events":
        points = getattr(value, "points", None)
        if points is None:
            points = next((v.points for v in like if isinstance(v, Events)), {})
        return Events(df, points)
    names = getattr(value, "names", None) or next((v.names for v in like if isinstance(v, Table)), [])
    return Table(df, list(names) + sorted({str(c) for c in df.cls.unique()} - set(names)))


# ---- the video ----


@node("video")
def video(ctx, p):
    """Which frames of the video are analysed: FPS of them per second, for the first seconds asked for."""
    cap = cv2.VideoCapture(str(ctx.video))
    if not cap.isOpened():
        raise SystemExit(f"{ctx.video} is not a video OpenCV can read")
    vfps, n = cap.get(cv2.CAP_PROP_FPS) or 25, int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    W, H = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    max_s = p["max_seconds"] if ctx.max_s is None else ctx.max_s
    every, last = max(1, round(vfps / p["fps"])), min(n, int(max_s * vfps)) if max_s else n
    return {"frames": SimpleNamespace(video=ctx.video, vfps=vfps, every=every, last=last, width=W, height=H, count=0)}


def frame_pass(frames, workers):
    """Steps each worker through the analysed frames; returns how many there were."""
    cap, count, t0 = cv2.VideoCapture(str(frames.video)), 0, time.time()
    for i in range(frames.last):
        if not cap.grab():
            break
        if i % frames.every:
            continue
        frame = cap.retrieve()[1]
        for w in workers:
            w.step(i, frame)
        count += 1
        if count % 50 == 0:
            print(f"{i / frames.vfps:6.0f} s of video | {count} frames | {count / (time.time() - t0):.1f} frames/s", flush=True)
    cap.release()
    return count


# ---- frame by frame ----


@node("detect", every_frame=True)
class Detect:
    """Boxes per analysed frame: the model or workflow as run_workflow.py runs it (its preprocessing, tiles and rules),
    boxes down to the weakest kept, each class kept, merged into another or dropped, then one box per machine."""

    def __init__(self, ctx, p, frames):
        from run_workflow import Workflow

        self.p, self.rows = p, []
        self.workflow = Workflow(HERE / p["detector"], device=ctx.device)
        names = list(self.workflow.classes)
        merges = p["class_map"]  # {class: the class it becomes, or None when dropped}; classes not named stay as they are

        def becomes(i, name):
            if name not in merges:
                return i
            into = merges[name]
            return names.index(into) if into in names else None

        self.names, self.base = names, [becomes(i, n) for i, n in enumerate(names)]
        # The weakest box each class keeps: its own minimum, or the node's.
        own = p["class_confidence"]
        self.floor = [own.get(n, p["min_confidence"]) for n in names]

    def step(self, index, frame):
        import torch
        import torchvision

        self.last = (index, [])  # this frame's rows, for a Python per frame node that is given them
        boxes = [b for b in self.workflow.detect(frame) if b.conf >= self.floor[b.cls] and self.base[b.cls] is not None]
        if not boxes:
            return
        keep = range(len(boxes))
        if self.p["one_box_iou"] < 1:  # one box per machine: the surest of overlapping ones, whatever their class
            xyxy = torch.tensor([b.xyxy for b in boxes], dtype=torch.float32)
            conf = torch.tensor([b.conf for b in boxes], dtype=torch.float32)
            keep = torchvision.ops.nms(xyxy, conf, self.p["one_box_iou"]).tolist()
        for k in keep:
            b = boxes[k]
            self.rows.append((index, self.names[self.base[b.cls]], round(b.conf, 3), *(round(v) for v in b.xyxy)))
            self.last[1].append(self.rows[-1])

    def result(self):
        return {"detections": Table(pd.DataFrame(self.rows, columns=["frame", "cls", "conf", *BOX]), self.names)}

    @staticmethod
    def save(outputs, path):
        outputs["detections"].df.to_csv(path.with_suffix(".csv"), index=False)
        return {"names": outputs["detections"].names}

    @staticmethod
    def load(path, meta):
        return {"detections": Table(pd.read_csv(path.with_suffix(".csv")), meta["names"])}


def bands(h, w, share):
    """Mask without the top and bottom `share` of the picture, where CCTV overlay text usually is."""
    m = np.full((h, w), 255, np.uint8)
    m[: int(share * h)] = m[h - int(share * h) :] = 0
    return m


def motion(prev, cur, mask, features):
    """Shift, rotation and zoom (2×3) from prev to cur, and its RANSAC inliers; None if it can't be measured."""
    p = cv2.goodFeaturesToTrack(prev, features, 0.01, 7, mask=mask)
    if p is None or len(p) < 10:
        return None, 0
    q, ok, _ = cv2.calcOpticalFlowPyrLK(prev, cur, p, None)
    ok = ok.ravel() == 1
    if ok.sum() < 10:
        return None, 0
    a, inliers = cv2.estimateAffinePartial2D(p[ok], q[ok], method=cv2.RANSAC, ransacReprojThreshold=2.0)
    return (a, int(inliers.sum())) if a is not None else (None, 0)


@node("camera_motion", every_frame=True)
class CameraMotion:
    """The camera motion before each analysed frame, measured on a small grey copy, and the mask of what is
    overlay text, learned while the camera moves."""

    def __init__(self, ctx, p, frames):
        self.p, self.size, self.share = p, p["width"], p["overlay_band_pct"] / 100
        self.s, self.h = self.size / frames.width, round(frames.height * self.size / frames.width)
        self.mask = bands(self.h, self.size, self.share)
        self.static, self.moves, self.prev, self.rows = np.zeros((self.h, self.size), np.int32), 0, None, []

    def step(self, index, frame):
        g = cv2.cvtColor(cv2.resize(frame, (self.size, self.h), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        a, inliers = motion(self.prev, g, self.mask, self.p["features"]) if self.prev is not None else (np.eye(2, 3), 0)
        if self.p["find_overlay"] and a is not None and np.hypot(*a[:, 2]) > 0.02 * self.size:
            # a clear move: sharp pixels that stay put are overlay
            self.static += (cv2.absdiff(self.prev, g) < 6) & (cv2.Canny(g, 50, 150) > 0)
            self.moves += 1
            if self.moves >= 3:
                text = cv2.dilate(((self.static >= 0.75 * self.moves) * 255).astype(np.uint8), np.ones((9, 9), np.uint8))
                self.mask = cv2.bitwise_and(bands(self.h, self.size, self.share), cv2.bitwise_not(text))
        a = np.full((2, 3), np.nan) if a is None else a / [[1, 1, self.s], [1, 1, self.s]]  # translation in full-size pixels
        self.rows.append((index, *a.ravel(), inliers))
        self.prev = g

    def result(self):
        return {"camera": SimpleNamespace(df=pd.DataFrame(self.rows, columns=["frame", *A, "inliers"]), mask=self.mask)}

    @staticmethod
    def save(outputs, path):
        outputs["camera"].df.to_csv(path.with_suffix(".csv"), index=False)
        cv2.imwrite(str(path.with_suffix(".png")), outputs["camera"].mask)
        return {}

    @staticmethod
    def load(path, meta):
        mask = cv2.imread(str(path.with_suffix(".png")), cv2.IMREAD_GRAYSCALE)
        return {"camera": SimpleNamespace(df=pd.read_csv(path.with_suffix(".csv")), mask=mask)}


@node("python_frame", every_frame=True)
class PythonFrame:
    """A table of what the node's step() returns for each analysed frame: its picture, number and time, and its
    boxes when detections are connected."""

    def __init__(self, ctx, p, frames):
        self.where = where_of(ctx.node)
        code = load_code(p["code"], ctx.node)
        if not callable(code.get("step")):
            raise SystemExit(f"{self.where}: its code defines no step()")
        self.call, self.vfps, self.rows = caller(code["step"]), frames.vfps, []
        self.boxes = None  # frame number -> its boxes, once detections are connected

    def step(self, index, frame):
        t = index / self.vfps
        args = dict(frame=frame, index=index, t=t)
        if self.boxes is not None:
            args["detections"] = self.boxes(index)
        try:
            out = self.call(args)
        except Exception:
            print(f"{self.where} failed on frame {index}:", file=sys.stderr)
            raise
        for row in [] if out is None else [out] if isinstance(out, dict) else out:
            self.rows.append({"frame": index, "t": round(t, 3), **row})

    def result(self):
        return {"rows": pd.DataFrame(self.rows)}

    @staticmethod
    def save(outputs, path):
        outputs["rows"].to_pickle(path.with_suffix(".pkl"))
        return {}

    @staticmethod
    def load(path, meta):
        return {"rows": pd.read_pickle(path.with_suffix(".pkl"))}


def boxes_by_frame(source, values, pending):
    """Each frame's boxes, from the Detect node feeding a Python per frame node: as Detect finds them, a step ahead
    in the same pass over the video, or from its cached results."""
    columns = ["cls", "conf", *BOX]
    worker = next((w for n, _, _, w in pending if n["id"] == source[0]), None)
    if worker is not None:
        return lambda i: pd.DataFrame(worker.last[1] if worker.last[0] == i else [], columns=["frame", *columns])[columns]
    by = {f: g[columns].reset_index(drop=True) for f, g in values[tuple(source)].df.groupby("frame")}
    empty = pd.DataFrame(columns=columns)
    return lambda i: by.get(i, empty)


# ---- the camera's views ----


@node("still_views")
def still_views(ctx, p, camera):
    """Adds per frame: pan and zoom speed, paused (a big move), the still view (seg) it belongs to (-1 during a big
    move; split off: one view) and C, the 3×3 map from its pixels to those of its view's first frame."""
    frames = ctx.frames
    fps, W, H = frames.vfps / frames.every, frames.width, frames.height
    cam = camera.df
    a = cam[A].to_numpy().reshape(-1, 2, 3)
    centre = np.array([W / 2, H / 2, 1])
    with np.errstate(all="ignore"):  # an unmeasured step is nan
        cam = cam.assign(pan=np.linalg.norm(a @ centre - centre[:2], axis=1) / W * fps,
                         zoom=np.abs(np.log(np.sqrt(np.abs(np.linalg.det(a[:, :, :2]))))) * fps)
    rate = p["move_rate"]
    big = ~((cam.pan <= rate) & (cam.zoom <= rate)).to_numpy()  # an unmeasured step counts as big
    big[0] = False
    paused = pd.Series(big).rolling(1 + round(p["settle_s"] * fps), min_periods=1).max().astype(bool).to_numpy() & p["split"]
    start = ~paused & np.r_[True, paused[:-1]]
    cam = cam.assign(paused=paused, seg=np.where(paused, -1, np.cumsum(start) - 1))
    C, c = {}, np.eye(3)
    for f, first, step in zip(cam.frame, start, a):
        ok = not np.isnan(step).any()
        c = np.eye(3) if first or not ok else c @ np.linalg.inv(np.vstack([step, [0, 0, 1]]))
        C[f] = c
    return {"views": SimpleNamespace(df=cam, C=C, mask=camera.mask, move_rate=rate)}


# ---- tracking ----


def compensate(tracks, a, xywh):
    """Moves the tracks' Kalman states by the camera motion a (2×3): centre and velocity, and the size by the zoom.
    BoT-SORT's state is x, y, w, h + velocities; ByteTrack's is x, y, aspect, h + velocities."""
    s = np.sqrt(abs(np.linalg.det(a[:, :2])))
    for t in tracks:
        t.mean[:2] = a[:, :2] @ t.mean[:2] + a[:, 2]
        t.mean[4:6] = a[:, :2] @ t.mean[4:6]
        t.mean[[2, 3, 6, 7] if xywh else [3, 7]] *= s


@node("track")
def track(ctx, p, detections, views=None):
    """Tracks with ByteTrack (or BoT-SORT) without ReID. With views: the measured camera motion moves the tracks
    before matching, and with restart_each_view a fresh tracker runs in each still view (nothing tracked during
    big moves); otherwise one tracker runs through the whole video."""
    from ultralytics.engine.results import Boxes
    from ultralytics.trackers.track import TRACKER_MAP

    frames, det, names, kind = ctx.frames, detections.df, detections.names, p["tracker"]
    fps, ix = frames.vfps / frames.every, {n: i for i, n in enumerate(names)}
    cam = views.df if views is not None else pd.DataFrame({"frame": analysed(frames), "seg": 0, **{k: np.nan for k in A}})
    follow, reset = p["follow_camera"] and views is not None, p["restart_each_view"] and views is not None
    cfg = SimpleNamespace(tracker_type=kind, track_high_thresh=p["new_confidence"], track_low_thresh=p["continue_confidence"],
                          new_track_thresh=p["new_confidence"], track_buffer=int(p["keep_s"] * fps), match_thresh=p["match_threshold"],
                          fuse_score=True, gmc_method="none", proximity_thresh=0.5, appearance_thresh=0.8, with_reid=False, model="auto")
    by = dict(list(det.groupby("frame")))
    rows, first_id = [], 0
    for _, g in cam[cam.seg >= 0].groupby("seg") if reset else [(0, cam)]:
        tracker, warp = TRACKER_MAP[kind](cfg), [np.eye(2, 3)]  # a new tracker counts IDs from 1 again
        if follow:  # Ultralytics' hook between the Kalman prediction and the matching
            tracker._pre_first_associate = lambda pool, unconfirmed, img, high: compensate(pool + unconfirmed, warp[0], kind == "botsort")
        for k, (f, s, a) in enumerate(zip(g.frame, g.seg, g[A].to_numpy())):
            warp[0] = np.eye(2, 3) if k == 0 or np.isnan(a).any() else a.reshape(2, 3)
            d = by.get(f)
            data = np.zeros((0, 6), np.float32) if d is None else np.c_[d[[*BOX, "conf"]], d.cls.map(ix)].astype(np.float32)
            for x1, y1, x2, y2, tid, conf, c, _ in tracker.update(Boxes(data, (frames.height, frames.width))):
                rows.append((f, s, first_id + int(tid), names[int(c)], round(float(conf), 3), round(x1), round(y1), round(x2), round(y2)))
        first_id = max([first_id, *(r[2] for r in rows)])  # so IDs stay unique across views
    return {"tracks": Table(pd.DataFrame(rows, columns=["frame", "seg", "id", "cls", "conf", *BOX]), names)}


def warp_box(M, b):
    """The box around box b's corners mapped by the 3×3 transform M."""
    p = np.array([[b[0], b[1], 1], [b[2], b[1], 1], [b[0], b[3], 1], [b[2], b[3], 1]], float) @ M.T
    p = p[:, :2] / p[:, 2:]
    return np.r_[p.min(0), p.max(0)]


@node("relink")
def relink(ctx, p, tracks, views):
    """After each big move, gives the machines that appear in the new view the IDs they had before it. Returns the
    renamed tracks and one row per lost ID that was or could have been linked."""
    from ultralytics.trackers.utils.matching import linear_assignment

    frames, cam, C = ctx.frames, views.df, views.C
    W, H, vfps = frames.width, frames.height, frames.vfps
    near, back, least, far = p["window_s"], p["look_back_s"], p["min_matches"], p["max_cost"]
    k = p["match_width"] / W
    sift, seen = cv2.SIFT_create(p["sift_features"]), {}
    mask = cv2.resize(views.mask, (p["match_width"], round(H * k)), interpolation=cv2.INTER_NEAREST)
    # Views are compared by their first and last frames only: those are read in one pass straight through the video.
    # Jumping to a frame is unreliable in some files, and some OpenCV builds fail on it outright.
    span = cam[cam.seg >= 0].groupby("seg").frame.agg(["min", "max"])
    wanted, small = {int(f) for f in np.r_[span["min"].to_numpy(), span["max"].to_numpy()]}, {}
    cap = cv2.VideoCapture(str(frames.video))
    for i in range(max(wanted, default=-1) + 1):
        if not cap.grab():
            break
        if i in wanted:
            try:
                ok, img = cap.retrieve()
            except cv2.error:
                ok = False
            if ok:
                small[i] = cv2.cvtColor(cv2.resize(img, mask.shape[::-1], interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
    cap.release()

    def view(f):  # SIFT points of frame f at match_width, overlay masked; none for a frame the file would not give
        if f not in seen:
            if f not in small:
                print(f"Re-link: frame {f} could not be read; the views around it are not matched", flush=True)
            seen[f] = sift.detectAndCompute(small[f], mask) if f in small else (None, None)
        return seen[f]

    def homography(fa, fb):  # full-size pixels of frame fa -> frame fb, or None when the views don't match
        (pa, da), (pb, db) = view(fa), view(fb)
        if da is None or db is None or len(da) < least or len(db) < least:
            return None, 0
        good = [m[0] for m in cv2.BFMatcher().knnMatch(da, db, k=2) if len(m) == 2 and m[0].distance < 0.75 * m[1].distance]
        if len(good) < least:
            return None, 0
        Hm, inl = cv2.findHomography(np.float32([pa[m.queryIdx].pt for m in good]), np.float32([pb[m.trainIdx].pt for m in good]), cv2.RANSAC, 4.0)
        if Hm is None or inl.sum() < least or not 0.2 < np.sqrt(abs(np.linalg.det(Hm[:2, :2] / Hm[2, 2]))) < 5:
            return None, int(inl.sum()) if inl is not None else 0
        S = np.diag([k, k, 1.0])
        return np.linalg.inv(S) @ Hm @ S, int(inl.sum())

    trk, rows, unmatched = tracks.df.copy(), [], max(9.0, 9 * far)
    for s in span.index[1:]:
        f_new = span.at[s, "min"]
        usual = trk.groupby("id").cls.agg(lambda c: c.mode()[0])  # an ID's usual class (one box may flip)
        g = trk[trk.seg == s]
        first = g.groupby("id").head(1)
        earlier = trk[(trk.seg >= 0) & (trk.seg < s)]
        first = first[(first.frame <= f_new + near * vfps) & ~first.id.isin(earlier.id)]  # IDs the tracker kept need no link
        targets = {r.id: (usual[r.id], warp_box(C[r.frame], [r.x1, r.y1, r.x2, r.y2])) for r in first.itertuples()}  # in f_new pixels
        before = earlier.groupby("id").tail(1)  # each earlier ID's last box in a still view
        before = before[~before.id.isin(g.id)]
        for o in span.index[span.index < s][::-1]:
            f_old = span.at[o, "max"]
            if (f_new - f_old) / vfps > back or not targets:
                break
            src = before[(before.seg == o) & (before.frame >= f_old - near * vfps)]
            if src.empty:
                continue
            Hm, inliers = homography(f_old, f_new)
            ids, tids = list(src.id), list(targets)
            if Hm is None:
                rows += [dict(t=round(f_new / vfps, 1), seg=s, id=i, cls=usual[i], result="views don't match", inliers=inliers)
                         for i in src.id]
                before = before[~before.id.isin(ids)]
                continue
            cost = np.full((len(ids), len(tids)), unmatched)
            for a, r in enumerate(src.itertuples()):
                m = warp_box(Hm @ np.linalg.inv(C[f_old]) @ C[r.frame], [r.x1, r.y1, r.x2, r.y2])  # its box in f_new pixels
                for b, (c, t) in enumerate(targets.values()):
                    dm, dt = np.hypot(*(m[2:] - m[:2])), np.hypot(*(t[2:] - t[:2]))
                    if c == usual[r.id] and 0.5 < dm / dt < 2:
                        cost[a, b] = np.hypot(*((m[:2] + m[2:] - t[:2] - t[2:]) / 2)) / dt  # centre distance in box sizes
            matches = linear_assignment(cost, thresh=far)[0]
            pairs = {ids[a]: tids[b] for a, b in matches}
            for a, r in enumerate(src.itertuples()):
                j = pairs.get(r.id)
                rows.append(dict(t=round(f_new / vfps, 1), seg=s, id=r.id, cls=usual[r.id], new_id=j, inliers=inliers,
                                 cost=round(cost[a, tids.index(j)], 2) if j else None,
                                 result="same ID" if j else "not found in the new view"))
                if j:
                    trk.loc[trk.id == j, "id"] = r.id
                    del targets[j]
            before = before[~before.id.isin(ids)]
    return {"tracks": Table(trk, tracks.names), "links": pd.DataFrame(rows)}


@node("fill")
def fill(ctx, p, tracks, views=None):
    """Boxes for an ID's missing frames inside a view, on a straight line in camera-compensated pixels (without
    views, in the frame's own); their conf is interpolated too (an estimate: the model saw nothing there)."""
    trk = tracks.df
    if views is not None:
        frames, C = views.df.groupby("seg").frame.apply(np.array), views.C
    else:
        every = np.array(analysed(ctx.frames))
        frames, C = {s: every for s in trk.seg.unique()}, {f: np.eye(3) for f in every}
    longest = p["max_gap_s"] * ctx.frames.vfps
    out = [trk.assign(hidden=trk.hidden if "hidden" in trk else False)]
    for (i, s), g in trk[trk.seg >= 0].groupby(["id", "seg"]):
        gap = [f for f in frames[s] if g.frame.min() < f < g.frame.max() and f not in set(g.frame)]
        if longest:  # only gaps no longer than that, between the frames either side
            seen = np.sort(g.frame.to_numpy())
            gap = [f for f in gap if seen[np.searchsorted(seen, f)] - seen[np.searchsorted(seen, f) - 1] <= longest]
        if not gap:
            continue
        ref = np.array([warp_box(C[f], b) for f, b in zip(g.frame, g[BOX].to_numpy())])
        mid = np.array([np.interp(gap, g.frame, ref[:, j]) for j in range(4)]).T
        boxes = np.array([warp_box(np.linalg.inv(C[f]), b) for f, b in zip(gap, mid)]).round().astype(int)
        conf = np.interp(gap, g.frame, g.conf).round(3)
        out.append(pd.DataFrame(dict(frame=gap, seg=s, id=i, cls=g.cls.mode()[0], conf=conf, hidden=True, **dict(zip(BOX, boxes.T)))))
    return {"tracks": Table(pd.concat(out).sort_values(["frame", "id"], ignore_index=True), tracks.names)}


@node("link_tracks")
def link_tracks(ctx, p, tracks, views=None):
    """Joins tracks broken inside a still view: each that ends to the one that starts after it, within max_gap_s, nearest
    where it stood (or the way it was going, if it was moving), at about its size, in camera-compensated pixels. One
    to one, by an optimal assignment; never two tracks seen at the same time, nor across another machine that stood at
    the spot and drove off in the gap. Returns the joined tracks, and a row per join (and per join refused for that)."""
    from ultralytics.trackers.utils.matching import linear_assignment

    trk, frames = with_hidden(tracks.df).copy(), ctx.frames
    vfps, C = frames.vfps, views.C if views is not None else {}
    window = max(2, int(round(2 * vfps / frames.every)))  # boxes over about two seconds
    usual = trk.groupby("id").cls.agg(lambda c: c.mode()[0])
    span = trk.groupby("id").frame.agg(["min", "max"])  # every box, filled ones too: two IDs never overlap
    paths = {}  # id -> frames, views, centres and widths of the boxes the model saw, in their view's pixels
    for i, g in trk[(trk.seg >= 0) & ~trk.hidden].groupby("id"):
        g = g.sort_values("frame")
        b = np.array([warp_box(C[f], box) if f in C else box for f, box in zip(g.frame, g[BOX].to_numpy(float))])
        paths[i] = (g.frame.to_numpy(), g.seg.to_numpy(), (b[:, :2] + b[:, 2:]) / 2, np.maximum(b[:, 2] - b[:, 0], 1))
    ends, starts = {}, {}
    for i, (f, s, c, w) in paths.items():
        tail = np.flatnonzero(s == s[-1])[-window:]
        dt = (f[tail[-1]] - f[tail[0]]) / vfps
        velocity = (c[tail[-1]] - c[tail[0]]) / dt if dt > 0 else np.zeros(2)
        ends[i] = dict(frame=f[-1], seg=s[-1], at=c[-1], w=w[-1], velocity=velocity)
        starts[i] = dict(frame=f[0], seg=s[0], at=c[0], w=w[0])

    def drove_off(a, b, fa, fb):
        """Another machine of a's class that stood at a's spot during the gap (2 s or more) and drove off from it."""
        spot, w, seg = ends[a]["at"], ends[a]["w"], ends[a]["seg"]
        for x, (f, s, c, _) in paths.items():
            if x in (a, b) or usual[x] != usual[a]:
                continue
            inside = (f > fa) & (f < fb) & (s == seg)
            if inside.sum() < 2:
                continue
            fx, d = f[inside], np.hypot(*(c[inside] - spot).T) / w
            near = np.flatnonzero(d <= 0.5)
            if len(near) and (fx[near[-1]] - fx[near[0]]) / vfps >= 2 and (d[near[-1]:] > 1.5).any():
                return x
        return None

    rows, ids_a, ids_b = [], list(ends), list(starts)
    big = 1e6
    cost = np.full((len(ids_a), len(ids_b)), big)
    for ia, a in enumerate(ids_a):
        e = ends[a]
        for ib, b in enumerate(ids_b):
            s = starts[b]
            if a == b or s["seg"] != e["seg"] or usual[a] != usual[b] or span.at[b, "min"] <= span.at[a, "max"]:
                continue
            gap = (s["frame"] - e["frame"]) / vfps
            size = s["w"] / e["w"]
            if gap > p["max_gap_s"] or not 1 / (1 + p["max_size_change"]) <= size <= 1 + p["max_size_change"]:
                continue
            # Where it would be: where it stood, or anywhere along the way it was going over the gap.
            way = e["velocity"] * gap if np.hypot(*e["velocity"]) / e["w"] > p["still_speed"] else np.zeros(2)
            t = np.clip(np.dot(s["at"] - e["at"], way) / max(np.dot(way, way), 1e-9), 0, 1)
            jump = np.hypot(*(s["at"] - (e["at"] + t * way))) / e["w"]
            if jump > p["max_jump"]:
                continue
            row = dict(id=a, joined_id=b, cls=usual[a], end_frame=int(e["frame"]), start_frame=int(s["frame"]), end_s=round(e["frame"] / vfps, 2),
                       start_s=round(s["frame"] / vfps, 2), gap_s=round(gap, 1), jump=round(jump, 2), size_change=round(size - 1, 2))
            leaver = drove_off(a, b, e["frame"], s["frame"]) if p["not_after_leaving"] else None
            if leaver is not None:
                rows.append({**row, "cost": None, "result": f"not joined: {str(usual[leaver])[:1].upper()}{leaver} stood there and drove off"})
                continue
            cost[ia, ib] = jump + abs(math.log(size)) + 0.2 * gap / p["max_gap_s"]
            rows.append({**row, "cost": round(cost[ia, ib], 3), "result": "not joined: another match was better"})
    matches = linear_assignment(cost, thresh=big / 2)[0] if len(ids_a) and len(ids_b) else []
    parent = {}
    for ia, ib in matches:
        parent[ids_b[ib]] = ids_a[ia]
        for r in rows:
            if r["id"] == ids_a[ia] and r["joined_id"] == ids_b[ib]:
                r["result"] = "joined"

    def root(i):
        while i in parent:
            i = parent[i]
        return i

    trk["id"] = trk.id.map(root)
    for r in rows:
        r["id"] = root(r["id"])  # the ID the joined track has now, after the joins before it
    links = pd.DataFrame(rows, columns=["id", "joined_id", "cls", "end_frame", "start_frame", "end_s", "start_s", "gap_s", "jump", "size_change",
                                        "cost", "result"])
    print(f"Link tracks: {len(parent)} joins")
    return {"tracks": Table(trk.sort_values(["frame", "id"], ignore_index=True), tracks.names), "links": links}


@node("clean_tracks")
def clean_tracks(ctx, p, tracks):
    """Drops tracks shorter than min_seconds, first box to last, or less sure on average than min_conf over the boxes the
    model saw."""
    trk, frames = with_hidden(tracks.df), ctx.frames
    g = trk.groupby("id")
    length = (g.frame.max() - g.frame.min() + frames.every) / frames.vfps
    conf = trk[~trk.hidden].groupby("id").conf.mean().reindex(length.index).fillna(0)
    keep = length.index[(length >= p["min_seconds"]) & (conf >= p["min_conf"])]
    print(f"Clean up tracks: {len(length) - len(keep)} of {len(length)} tracks dropped")
    return {"tracks": Table(trk[trk.id.isin(keep)].reset_index(drop=True), tracks.names)}


# ---- what the machines do ----


def class_key(name):
    """Class names compared loosely: dump_truck, dumptruck and Dump truck are one class."""
    return "".join(ch for ch in str(name).lower() if not ch.isspace() and ch not in "_-")


def classes_of(text):
    return {class_key(c) for c in str(text).split(",") if c.strip()}


def steady(states, shortest):
    """States with every run shorter than `shortest` rows taken into the run before it (a first run, into the next)."""
    runs, start = [], 0
    for k in range(1, len(states) + 1):
        if k == len(states) or states[k] != states[start]:
            runs.append([states[start], start, k])
            start = k
    kept = []
    for run in runs:
        if kept and (run[2] - run[1] < shortest or kept[-1][0] == run[0]):
            kept[-1][2] = run[2]
        else:
            kept.append(run)
    if len(kept) > 1 and kept[0][2] - kept[0][1] < shortest:
        kept[1][1] = 0
        kept.pop(0)
    out = np.empty(len(states), dtype=object)
    for state, a, b in kept:
        out[a:b] = state
    return out


@node("machine_state")
def machine_state(ctx, p, tracks, views=None):
    """Per machine and frame: a truck or bulldozer moving or stopped, an excavator working or idle, unknown during
    big camera moves. Boxes are judged in their still view's own pixels (with views), so camera motion is not
    taken for the machine's; speeds are in the machine's own box widths, so a zoom does not change them."""
    trk, frames = with_hidden(tracks.df), ctx.frames
    fps = frames.vfps / frames.every
    C = views.C if views is not None else {}
    excavators = classes_of(p["excavator_classes"])
    half = max(1, int(round(p["window_s"] * fps / 2)))
    smooth = max(1, int(round(fps)))  # a second's median against a box's jitter
    shortest = max(1, int(round(p["min_state_s"] * fps)))
    parts = []
    for (_, seg), g in trk.groupby(["id", "seg"]):
        g = g.sort_values("frame")
        usual = g.cls.mode()[0]
        if seg < 0:
            parts.append(g.assign(cls=usual, state="unknown", vx=np.nan, vy=np.nan, vw=np.nan))
            continue
        b = np.array([warp_box(C[f], box) if f in C else box for f, box in zip(g.frame, g[BOX].to_numpy(float))])
        roll = lambda v: pd.Series(v).rolling(smooth, center=True, min_periods=1).median()
        w, h = roll(b[:, 2] - b[:, 0]).clip(lower=1), roll(b[:, 3] - b[:, 1]).clip(lower=1)
        cx, cy = roll((b[:, 0] + b[:, 2]) / 2).to_numpy(), roll((b[:, 1] + b[:, 3]) / 2).to_numpy()
        n = len(g)
        lo, hi = np.clip(np.arange(n) - half, 0, n - 1), np.clip(np.arange(n) + half, 0, n - 1)
        seconds = (g.frame.to_numpy()[hi] - g.frame.to_numpy()[lo]) / frames.vfps
        with np.errstate(divide="ignore", invalid="ignore"):
            speed = np.where(seconds > 0, np.hypot(cx[hi] - cx[lo], cy[hi] - cy[lo]) / w.to_numpy() / seconds, 0.0)
        window = 2 * half + 1
        change = lambda v: ((v.rolling(window, center=True, min_periods=1).max() - v.rolling(window, center=True, min_periods=1).min())
                            / v.rolling(window, center=True, min_periods=1).median()).to_numpy()
        reshaped = (change(w) + change(h)) / 2
        if class_key(usual) in excavators:
            state = np.where((reshaped > p["working_change"]) | (speed > p["stop_speed"]), "working", "idle")
        else:
            state = np.where(speed > p["stop_speed"], "moving", "stopped")
        # Where it is in its still view's own pixels: an excavator that stays put stays put there.
        parts.append(g.assign(cls=usual, state=steady(list(state), shortest), vx=cx, vy=cy, vw=w.to_numpy()))
    df = pd.concat(parts) if parts else trk.assign(state=pd.Series(dtype=object))
    return {"states": Table(df.sort_values(["frame", "id"], ignore_index=True), tracks.names)}


def coarse(st):
    """States as Loading events and the report go by: a machine's coarse state (`activity`, which a Classify states
    node keeps beside its own states), else its state."""
    return st.assign(state=st["activity"]) if "activity" in st else st


@node("classify_states")
def classify_states(ctx, p, states):
    """Gives the machines of some classes the states of a state model trained on the team's reviews, in place of
    Machine state's: every frame of each one's track, judged from the video. The other machines keep theirs. Beside
    its own states, each frame keeps a coarse one (`activity`): idle for the states named idle, working for the
    others, so that Loading events and the report still count working time. During big camera moves a machine's
    state is unknown."""
    sys.path.insert(0, str(HERE))
    import state_models

    df = states.df.copy()
    frames = ctx.frames
    picked = df.cls.map(class_key).isin(classes_of(p["classes"])) & (df.seg >= 0)
    groups = {int(i): g.sort_values("frame") for i, g in df[picked].groupby("id")}
    print(f"{len(groups)} machine(s) to judge with {p['model_name']}", flush=True)
    found = state_models.classify_tracks(
        HERE / p["model_file"], str(frames.video), {i: (g.frame.to_numpy(), g[BOX].to_numpy(float)) for i, g in groups.items()},
        frames.vfps, every_s=p["every_s"], clip_s=p["clip_s"], padding=p["padding"], device=ctx.device)
    df["activity"] = df["state"]
    # Which states are the model's: the review page shows them as the team's of the same name.
    df["by_model"] = False
    idle = classes_of(p["idle_states"])
    shortest = max(1, int(round(p["min_state_s"] * frames.vfps / frames.every)))
    for i, g in groups.items():
        names, conf = found.get(i, (["unknown"] * len(g), np.zeros(len(g))))
        names = ["unknown" if c < p["min_confidence"] else n for n, c in zip(names, conf)]
        names = list(steady(names, shortest))
        df.loc[g.index, "state"] = names
        df.loc[g.index, "by_model"] = True
        df.loc[g.index, "activity"] = ["unknown" if n == "unknown" else "idle" if class_key(n) in idle else "working" for n in names]
    return {"states": Table(df, states.names)}


class Events:
    """Loads and waits, and the loading points they happened at: {"LP1": [excavator track ids], ...}."""

    def __init__(self, df, points):
        self.df, self.points = df, points


def loading_points(exc):
    """Excavator tracks grouped into loading points: tracks in one still view whose centres sit at the same place in
    its own pixels (within 0.6 of a box width) are one excavator, whose ID changed or doubled as its box changed
    shape with the arm (two excavators cannot stand in one place). Returns {track id: point name}."""
    places = []
    for (i, seg), g in exc[exc.seg >= 0].groupby(["id", "seg"]):
        places.append(dict(id=i, seg=seg, x=g.vx.median(), y=g.vy.median(), w=g.vw.median(), a=g.frame.min(), b=g.frame.max()))
    places.sort(key=lambda p: p["a"])
    points, of = [], {}
    for p in places:
        home = next((q for q in points if q["seg"] == p["seg"] and math.hypot(p["x"] - q["x"], p["y"] - q["y"]) <= 0.6 * max(p["w"], q["w"])), None)
        if home is None:
            home = dict(seg=p["seg"], x=p["x"], y=p["y"], w=p["w"], spans=[], name=f"LP{len(points) + 1}")
            points.append(home)
        home["spans"].append((p["a"], p["b"]))
        of.setdefault(p["id"], home["name"])
    return of


@node("loading_events")
def loading_events(ctx, p, states):
    """Loads and waits: a truck stopped beside a working excavator is being loaded. Each truck is judged against the
    excavator nearest it on the same ground (box bottoms level within an excavator's height: in a view from above, a
    machine far behind sits higher in the picture), by the gap between their boxes in excavator widths. A truck's
    wait is judged by what it did next, not where it stood: from when it came into the loading point's area (within
    `near` of its excavator, and stayed) until its load began, parked in a line, around the excavator or well back
    to leave room; its spot is the moving it did last, into place. A wait whose start was not seen (the truck was
    already there when the view began, or got a new ID) is kept, marked incomplete. An event cut short by a big
    camera move or by the video's ends is kept, marked incomplete: its count is right, its duration is not."""
    st, frames = coarse(states.df), ctx.frames
    vfps, step = frames.vfps, frames.every
    key = st.cls.map(class_key)
    seen = st[st.seg >= 0]
    exc = seen[key.loc[seen.index].isin(classes_of(p["excavator_classes"]))]
    trucks = seen[key.loc[seen.index].isin(classes_of(p["truck_classes"]))]
    point_of = loading_points(exc)
    by_frame = {f: g for f, g in exc.groupby("frame")}
    working = {}  # (point, frame) -> whether any of its excavator tracks works then
    for r in exc.itertuples():
        working[(point_of[r.id], r.frame)] = working.get((point_of[r.id], r.frame), False) or r.state == "working"
    gap = lambda t, e: math.hypot(max(0.0, e[0] - t[2], t[0] - e[2]), max(0.0, e[1] - t[3], t[1] - e[3])) / max(e[2] - e[0], 1)
    marks = {}  # (truck, loading point) -> frames it stood beside the point's excavator
    for t in trucks[trucks.state == "stopped"].itertuples():
        near = by_frame.get(t.frame)
        if near is None:
            continue
        best = None
        for e in near.itertuples():
            if abs(t.y2 - e.y2) > p["same_ground"] * max(e.y2 - e.y1, 1):
                continue
            g = gap((t.x1, t.y1, t.x2, t.y2), (e.x1, e.y1, e.x2, e.y2))
            if best is None or g < best[0]:
                best = (g, e.id)
        if best is not None and best[0] <= p["beside"]:
            marks.setdefault((t.id, point_of[best[1]]), []).append(t.frame)
    spans = seen.groupby("seg").frame.agg(["min", "max"])
    seg_of = dict(zip(seen.frame, seen.seg))
    bridge = p["gap_s"] * vfps + step
    rows = []
    for (truck, point), fs in marks.items():
        fs = sorted(fs)
        runs, run = [], fs[:1]
        for f in fs[1:]:
            if f - run[-1] <= bridge and seg_of.get(f) == seg_of.get(run[-1]):
                run.append(f)
            else:
                runs.append(run)
                run = [f]
        runs += [run] if run else []
        for run in runs:
            a, b = run[0], run[-1]
            duration = (b - a + step) / vfps
            if duration < p["min_loading_s"]:
                continue
            share = np.mean([working[(point, f)] for f in range(a, b + 1, step) if (point, f) in working] or [0.0])
            if share < p["working_share"]:
                continue
            seg = seg_of.get(a, 0)
            lo, hi = spans.loc[seg, "min"], spans.loc[seg, "max"]
            # Seen to start and to end: not cut off by a big camera move or by the video's ends.
            start_seen, end_seen = bool(a - lo > bridge), bool(hi - b > bridge)
            rows.append(dict(kind="loading", point=point, truck=truck, start_frame=a, end_frame=b, start_s=round(a / vfps, 2),
                             end_s=round((b + step) / vfps, 2), duration_s=round(duration, 1), start_seen=start_seen,
                             end_seen=end_seen, complete=start_seen and end_seen, view=seg, spot_s=0.0))
    # Two loads at one point that overlap, or follow closer than a truck exchange can, with the truck in the same
    # place, are one truck whose ID changed (the excavator's arm hides it, and the tracker loses it): one load.
    # A truck loaded again at the point sooner than a load lasts was edging into place, not loaded twice: one load
    # too, even with another truck's load between (an excavator loading trucks on both sides) or a big camera move
    # (the truck kept its ID through it).
    box = {(r.id, r.frame): (r.x1, r.y1, r.x2, r.y2) for r in trucks.itertuples()}
    centre = lambda b: ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)

    def extend(last, r):
        b = max(last["end_frame"], r["end_frame"])
        last.update(end_frame=b, end_s=round((b + step) / vfps, 2), duration_s=round((b - last["start_frame"] + step) / vfps, 1),
                    end_seen=r["end_seen"] if r["end_frame"] >= last["end_frame"] else last["end_seen"])
        last["complete"] = last["start_seen"] and last["end_seen"]
        if r["truck"] not in last.setdefault("trucks", [last["truck"]]):
            last["trucks"].append(r["truck"])

    merged = []
    for r in sorted((r for r in rows if r["kind"] == "loading"), key=lambda r: (r["point"], r["start_frame"])):
        same = next((m for m in reversed(merged) if m["point"] == r["point"] and r["truck"] in m.get("trucks", [m["truck"]])), None)
        if same is not None and r["start_frame"] - same["end_frame"] < p["min_loading_s"] * vfps:
            extend(same, r)
            continue
        last = merged[-1] if merged else None
        if last is not None and last["point"] == r["point"] and last["view"] == r["view"] and r["start_frame"] - last["end_frame"] < p["min_exchange_s"] * vfps:
            was, now = box.get((last["truck"], last["end_frame"])), box.get((r["truck"], r["start_frame"]))
            if was and now and math.hypot(*np.subtract(centre(was), centre(now))) <= 0.5 * max(was[2] - was[0], 1):
                extend(last, r)
                continue
        merged.append(dict(r))
    # Each loading point's excavator as it usually stands in each view: a truck's way into its area is measured to it.
    place = {}
    for (i, seg), g in exc.groupby(["id", "seg"]):
        place.setdefault((point_of[i], seg), []).append(g[BOX].to_numpy(float))
    place = {k: np.median(np.vstack(v), axis=0) for k, v in place.items()}
    path = {i: g.sort_values("frame") for i, g in trucks.groupby("id")}

    def wait(truck, point, view, until):
        """From when `truck` came into `point`'s area and stayed, until frame `until`: the frame it came, whether that
        was seen (not the truck's or the view's first frame), and the seconds of the moving it did last."""
        e, g = place.get((point, view)), path.get(truck)
        if e is None or g is None:
            return until, False, 0.0
        came, seen_coming, spot_from = until, False, None
        for r in g[g.frame < until].iloc[::-1].itertuples():
            if r.seg != view:
                break
            if gap((r.x1, r.y1, r.x2, r.y2), e) > p["near"]:
                seen_coming = True
                break
            came = r.frame
            if spot_from is None and r.state != "moving":
                spot_from = came + step
        spot_from = came if spot_from is None else spot_from
        return came, seen_coming, max(0.0, (until - spot_from) / vfps)

    def waited(truck, point, view, came, until, seen_coming, spot):
        if (until - came) / vfps >= max(p["min_queue_s"], step / vfps):
            rows.append(dict(kind="queue", point=point, truck=truck, start_frame=came, end_frame=until - step, start_s=round(came / vfps, 2),
                             end_s=round(until / vfps, 2), duration_s=round((until - came) / vfps, 1), start_seen=seen_coming,
                             end_seen=True, complete=seen_coming, view=view, spot_s=round(spot, 1)))

    # Only a truck that was loaded waited: one standing in the area that never was, parked or broken down, or still
    # there when the view or video ended, is not taken for a wait.
    for r in merged:
        truck = r.get("trucks", [r["truck"]])[0]
        came, seen_coming, spot = wait(truck, r["point"], r["view"], r["start_frame"])
        waited(truck, r["point"], r["view"], came, r["start_frame"], seen_coming, spot)
    rows = [r for r in rows if r["kind"] != "loading"] + merged
    for r in rows:
        r["truck"] = "+".join(f"T{t}" for t in r.pop("trucks", [r["truck"]]))
    columns = ["kind", "point", "truck", "start_frame", "end_frame", "start_s", "end_s", "duration_s", "start_seen", "end_seen", "complete", "view",
               "spot_s"]
    # Typed even when empty: a table of no events keeps its yes/no columns as such, so a filter on them picks rows.
    df = pd.DataFrame(rows, columns=columns).astype({"start_seen": bool, "end_seen": bool, "complete": bool})
    loading = set(df[df.kind == "loading"].point)
    df = df[(df.kind == "loading") | df.point.isin(loading)]
    points = {}
    for track, name in point_of.items():
        points.setdefault(name, []).append(track)
    return {"events": Events(df.sort_values(["start_frame", "point"], ignore_index=True), points)}


def clock_start(text):
    """The camera's clock at a video's start, from a recorder's file name (or a time typed as such): the first of
    20250115092459, 20250115_092459 or 2024-09-18-09-02-49 that is a real date and time; None without one."""
    pattern = r"(?<!\d)(?:(\d{14})|(\d{8})[-_.: T](\d{6})|(\d{4})[-_.: T](\d{2})[-_.: T](\d{2})[-_.: T](\d{2})[-_.: T](\d{2})[-_.: T](\d{2}))(?!\d)"
    for m in re.finditer(pattern, str(text)):
        digits = m.group(1) or (m.group(2) + m.group(3) if m.group(2) else "".join(m.group(k) for k in range(4, 10)))
        try:
            at = datetime.strptime(digits, "%Y%m%d%H%M%S")
        except ValueError:
            continue
        if 2000 <= at.year < 2100:
            return at
    return None


# ---- code and branches ----


@node("python")
def python(ctx, p, **given):
    """The node's run(), given its inputs by name (and ctx, when it asks for it). What it returns becomes its
    outputs: a dict of them, or the value alone for a node with one; None for one skips what it feeds."""
    n = ctx.node
    where = where_of(n)
    code = load_code(p["code"], n)
    if not callable(code.get("run")):
        raise SystemExit(f"{where}: its code defines no run()")
    args = {q["name"]: given.get(q["name"]) for q in p["inputs"]}
    result = caller(code["run"])({**args, "ctx": node_ctx(ctx, n)})
    outputs = p["outputs"]
    names = {q["name"] for q in outputs}
    if not outputs:
        return {}
    if isinstance(result, dict) and result and set(result) <= names:
        values = result
    elif len(outputs) == 1:
        values = {outputs[0]["name"]: result}
    elif result is None:
        values = {}
    else:
        raise TypeError(f"{where}: run() has to return a dict with a value for each output: {', '.join(sorted(names))}")
    like = list(args.values())
    return {q["name"]: as_data(q["data"], values.get(q["name"]), like, where) for q in outputs}


@node("filter")
def filter_rows(ctx, p, rows):
    """The rows where the condition holds (pandas' query syntax), as the same kind of data."""
    where, df = where_of(ctx.node), table_of(rows)
    try:
        kept = df.query(p["condition"]) if len(df) else df
    except Exception as e:
        raise ValueError(f"{where}: its condition {p['condition']!r} could not be used: {e}") from e
    return {"kept": as_data(p["data"], kept, [rows], where)}


@node("branch")
def branch(ctx, p, value):
    """value on as "then" when the condition holds, as "else" when not: the other way is skipped."""
    n = ctx.node
    where, df = where_of(n), table_of(value)
    names = {"value": value, "df": df, "n": 0 if df is None else len(df), "ctx": node_ctx(ctx, n), "np": np, "pd": pd, "math": math}
    result = eval(compiled(p["condition"], where, "eval"), names)
    try:
        holds = bool(result)
    except ValueError:
        raise ValueError(f"{where}: its condition gives a value per row, not true or false: end it with .any(), .all() or .sum() > 0") from None
    print(f"{n['label']} ({n['id']}): {'then' if holds else 'else'}")
    return {"then": value, "else": SKIPPED} if holds else {"then": SKIPPED, "else": value}


@node("either")
def either(ctx, p, first=None, second=None):
    """Its "first" input, or its "second" when the first was skipped; skipped itself when both were."""
    return {"value": first if first is not None else second if second is not None else SKIPPED}


# ---- outputs ----


@node("save_detections")
def save_detections(ctx, p, detections):
    detections.df.to_csv(ctx.out / p["file"], index=False)
    return wrote(ctx, p["file"])


@node("save_tracks")
def save_tracks(ctx, p, tracks):
    trk = with_hidden(tracks.df)
    trk.assign(t=(trk.frame / ctx.frames.vfps).round(2)).to_csv(ctx.out / p["file"], index=False)
    return wrote(ctx, p["file"])


@node("id_times")
def id_times(ctx, p, tracks):
    """Per ID: first and last seen, seconds seen / hidden (filled in) / not observed (camera away), views."""
    trk, frames = with_hidden(tracks.df), ctx.frames
    step = frames.every / frames.vfps
    t = trk.assign(t=trk.frame / frames.vfps)
    g = t.groupby("id")
    times = pd.DataFrame({"class": g.cls.agg(lambda c: c.mode()[0]), "first seen (s)": g.t.min(), "last seen (s)": g.t.max(),
                          "seen (s)": (g.size() - g.hidden.sum()) * step, "hidden (s)": g.hidden.sum() * step,
                          "views": g.seg.agg(lambda x: x[x >= 0].nunique()), "mean conf": t[~t.hidden].groupby("id").conf.mean()})
    times["not observed (s)"] = (times["last seen (s)"] - times["first seen (s)"] + step - times["seen (s)"] - times["hidden (s)"]).clip(lower=0)
    times.index = [f"{c[0].upper()}{i}" for i, c in times["class"].items()]
    times.sort_values(["class", "first seen (s)"]).round(1).to_csv(ctx.out / p["file"], index_label="ID")
    return wrote(ctx, p["file"])


@node("save_links")
def save_links(ctx, p, links):
    links.to_csv(ctx.out / p["file"], index=False)
    return wrote(ctx, p["file"])


@node("save_table")
def save_table(ctx, p, rows):
    """What it is given, as a CSV file. (p["data"] is the kind of data it takes.)"""
    table_of(rows).to_csv(ctx.out / p["file"], index=False)
    return wrote(ctx, p["file"])


@node("productivity_report")
def productivity_report(ctx, p, events, states):
    """Per loading point (and all together): the excavator's time in view, share of it working, loads and loads per
    observed hour, median loading, truck exchange, wait and spot times, the most trucks waiting at once; and every
    event, on the camera's clock."""
    frames, st, ev = ctx.frames, coarse(states.df), events.df
    vfps, step = frames.vfps, frames.every / frames.vfps
    # The node's own time, else the one the run was given (--start), else the one in the video's file name.
    start = clock_start(p["start_time"] or ctx.start or ctx.video.name)
    clock = (lambda s: (start + timedelta(seconds=float(s))).strftime("%Y-%m-%d %H:%M:%S")) if start else (lambda s: "")
    exc = st[st.cls.map(class_key).isin(classes_of(p["excavator_classes"]))]
    median = lambda v: round(float(np.median(v)), 1) if len(v) else None

    def peak(waits):
        """The most trucks waiting at once."""
        edges = sorted([(a, 1) for a in waits.start_frame] + [(b, -1) for b in waits.end_frame], key=lambda x: (x[0], -x[1]))
        most = now = 0
        for _, d in edges:
            now += d
            most = max(most, now)
        return most

    def figures(name, ids, names):
        seen = exc[exc.id.isin(ids) & (exc.state != "unknown")]
        frames_seen = seen.groupby("frame").state.agg(lambda s: (s == "working").any())  # any of the point's tracks
        mine = ev[ev.point.isin(names)]
        loads, waits = mine[mine.kind == "loading"], mine[mine.kind == "queue"]
        done = loads[loads.complete]
        # A truck exchange: one load seen to end, the next seen to start, at one point and in one view.
        timed = loads.sort_values(["point", "start_frame"])
        exchange = [(b.start_frame - a.end_frame - frames.every) / vfps for a, b in zip(timed.iloc[:-1].itertuples(), timed.iloc[1:].itertuples())
                    if a.view == b.view and a.point == b.point and a.end_seen and b.start_seen and b.start_frame > a.end_frame]
        observed = len(frames_seen) * step / 3600
        return {"loading_point": name, "excavator_ids": " ".join(f"E{i}" for i in sorted(ids)), "observed_h": round(observed, 3),
                "video_h": round(frames.count * step / 3600, 3), "working_pct": round(100 * float(frames_seen.mean()), 1) if len(frames_seen) else None,
                "loads": len(loads), "loads_per_observed_h": round(len(loads) / observed, 1) if observed else None,
                "loading_min_median": median(done.duration_s / 60), "exchange_s_median": median(exchange),
                "queue_min_median": median(waits[waits.complete].duration_s / 60), "spot_s_median": median(waits[waits.end_seen].spot_s),
                "queue_peak": peak(waits),
                "first_seen": clock(seen.frame.min() / vfps) if len(seen) else "", "last_seen": clock((seen.frame.max() + frames.every) / vfps) if len(seen) else ""}

    order = sorted(events.points, key=lambda n: int(n[2:]))
    rows = [figures(n, events.points[n], [n]) for n in order]
    if len(rows) > 1:
        total = figures("all", [i for n in order for i in events.points[n]], order)
        # Working: each point's share, weighted by how long it was observed (not any excavator working at all).
        weights = [(r["working_pct"], r["observed_h"]) for r in rows if r["working_pct"] is not None and r["observed_h"]]
        total["working_pct"] = round(sum(w * h for w, h in weights) / sum(h for _, h in weights), 1) if weights else None
        rows.append(total)
    # With its header even when no loading point was found, so it reads as a report of none.
    columns = ["loading_point", "excavator_ids", "observed_h", "video_h", "working_pct", "loads", "loads_per_observed_h", "loading_min_median",
               "exchange_s_median", "queue_min_median", "spot_s_median", "queue_peak", "first_seen", "last_seen"]
    pd.DataFrame(rows, columns=columns).to_csv(ctx.out / p["file"], index=False)
    listed = ev.assign(start=[clock(s) for s in ev.start_s], end=[clock(s) for s in ev.end_s])
    listed[["kind", "point", "truck", "start", "end", "start_s", "end_s", "duration_s", "spot_s", "complete"]].to_csv(ctx.out / p["events_file"], index=False)
    wrote(ctx, p["file"])
    return wrote(ctx, p["events_file"])


@node("camera_plot")
def camera_plot(ctx, p, views):
    """Pan and zoom speed over time, with the big moves shaded."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cam, frames, rate = views.df, ctx.frames, views.move_rate
    t = cam.frame / frames.vfps
    fig, ax = plt.subplots(figsize=(12, 3))
    ax.plot(t, cam.pan * 100, lw=1, label="pan (% of width per s)")
    ax.plot(t, cam.zoom * 100, lw=1, label="zoom (% per s)")
    ax.axhline(rate * 100, color="grey", ls="--", lw=1, label="big move above")
    for _, q in cam[cam.paused].groupby((~cam.paused).cumsum()):
        ax.axvspan(q.frame.min() / frames.vfps, (q.frame.max() + frames.every) / frames.vfps, color="grey", alpha=0.25, lw=0)
    ax.set(xlabel="video time (s)", ylabel="% per second", ylim=(0, 4 * rate * 100), xlim=(0, t.max()))
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1))
    fig.savefig(ctx.out / p["file"], dpi=80, bbox_inches="tight")
    plt.close(fig)
    return wrote(ctx, p["file"])


def draw(frame, boxes, ix, paused=False, lw=None):
    """One frame with its boxes and IDs ("D7 0.93"; "D7 ~0.93" = filled in, conf estimated) and a banner during a big move."""
    from ultralytics.utils.plotting import Annotator, colors

    H, W = frame.shape[:2]
    a = Annotator(frame, line_width=lw or max(2, round(W / 960)))
    for b in boxes:
        tag = f"{b['cls'][0].upper()}{b['id']}"
        a.box_label([b[c] for c in BOX], f"{tag} {'~' if b['hidden'] else ''}{b['conf']:.2f}", colors(ix[b["cls"]], True))
    if paused:
        text, scale = "CAMERA MOVING", W / 1400
        (tw, th), _ = cv2.getTextSize(text, 0, scale, 2)
        x, y = (W - tw) // 2, int(0.12 * H)
        cv2.rectangle(a.im, (x - 12, y - th - 12), (x + tw + 12, y + 12), (0, 0, 180), -1)
        cv2.putText(a.im, text, (x, y), 0, scale, (255, 255, 255), 2, cv2.LINE_AA)
    return a.result()


@node("annotated_video")
def annotated_video(ctx, p, tracks, views=None):
    """The analysed frames drawn by draw(), as a video."""
    trk, frames, path = with_hidden(tracks.df), ctx.frames, ctx.out / p["file"]
    ix = {n: i for i, n in enumerate(tracks.names)}
    boxes = {f: g.to_dict("records") for f, g in trk.groupby("frame")}
    paused = dict(zip(views.df.frame, views.df.paused)) if views is not None else {}
    end = int(views.df.frame.max()) if views is not None else max(analysed(frames), default=-1)
    cap, raw = cv2.VideoCapture(str(frames.video)), str(path.with_suffix(".raw.mp4"))
    writer = cv2.VideoWriter(raw, cv2.VideoWriter_fourcc(*"mp4v"), frames.vfps / frames.every, (frames.width, frames.height))
    for i in range(end + 1):
        if not cap.grab():
            break
        if i % frames.every == 0:
            writer.write(draw(cap.retrieve()[1], boxes.get(i, []), ix, paused.get(i, False)))
    writer.release()
    cap.release()
    try:
        if not p["h264"]:
            raise ImportError
        import subprocess

        import imageio_ffmpeg

        subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error", "-i", raw, "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path)], check=True)
        Path(raw).unlink()
    except ImportError:
        Path(raw).replace(path)
    return wrote(ctx, p["file"])


# ---- running a pipeline ----


def pick_device():
    import torch

    return "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"


def cache_key(n, frames, ctx, upstream=None):
    """What a frame-by-frame node's results depend on: its settings (its code), its model files, the video and its
    frames, and the results it is given (a Detect node's, by their own key)."""
    key = dict(kind=n["kind"], params=n["params"], video=ctx.video.name, size=ctx.video.stat().st_size,
               every=frames.every, last=frames.last, upstream=upstream)
    if n["kind"] == "detect":
        spec = HERE / n["params"]["detector"]
        key["detector"] = json.loads(spec.read_text())
        key["files"] = [(s["model"], (spec.parent / s["model"]).stat().st_size) for s in key["detector"]["steps"]]
    return hashlib.sha1(json.dumps(key, sort_keys=True, default=str).encode()).hexdigest()[:16]


ACTIVITIES = ["moving", "stopped", "queue", "loading", "working", "idle", "unknown"]


def review_data(ctx, nodes, values):
    """What the labeler's review page shows of a run: every box of the machines followed, with what the pipeline
    says each was doing (its state; loading or queueing while in a load or wait), the class roles, and the events.
    Columns are lists, row for row. None when the pipeline follows no machines."""
    states = [v for (_, port), v in values.items() if port == "states" and isinstance(v, Table)]
    tracks = [v for (_, port), v in values.items() if port == "tracks" and isinstance(v, Table)]
    table = (states or tracks or [None])[-1]
    if table is None:
        return None
    df = with_hidden(table.df).sort_values(["frame", "id"], ignore_index=True)
    activity = (df["state"].astype(str) if "state" in df else pd.Series("unknown", index=df.index)).copy()
    # A state model's states (a Classify states node's) as such: `state:loading` is the team's loading, not the
    # pipeline's (a truck being loaded).
    if "by_model" in df:
        theirs = df["by_model"].fillna(False).astype(bool) & (activity != "unknown")
        activity = activity.where(~theirs, "state:" + activity)
    events = [v for v in values.values() if isinstance(v, Events)]
    ev = events[-1].df if events else pd.DataFrame(columns=["kind", "truck", "start_frame", "end_frame"])
    for e in ev.itertuples():
        ids = [int(t[1:]) for t in str(e.truck).split("+") if t[1:].isdigit()]
        activity[df.id.isin(ids) & df.frame.between(e.start_frame, e.end_frame)] = "loading" if e.kind == "loading" else "queue"
    # A state model's own states are shown too (a Classify states node's), by name; anything else is unknown.
    own = sorted(a for a in set(activity) - set(ACTIVITIES) if 0 < len(a) <= 60 and a != "nan")
    activities = ACTIVITIES + own
    activity = activity.where(activity.isin(activities), "unknown")
    names = list(table.names) + sorted({str(c) for c in df.cls.unique()} - set(table.names))
    said = lambda key: set().union(*[classes_of(n["params"][key]) for n in nodes if key in n["params"]])
    excavators, trucks = said("excavator_classes"), said("truck_classes")
    role = lambda c: "excavator" if class_key(c) in excavators else "truck" if class_key(c) in trucks else "other"
    frames = ctx.frames
    whole = lambda column: [int(round(v)) for v in column]
    return {
        "video_fps": frames.vfps, "every": frames.every, "count": frames.count, "width": frames.width, "height": frames.height,
        "names": names, "roles": [role(c) for c in names], "activities": activities,
        "frame": whole(df.frame), "id": whole(df.id), "cls": [names.index(str(c)) for c in df.cls],
        "conf": [round(float(c), 3) for c in df.conf.fillna(0)], "x1": whole(df.x1), "y1": whole(df.y1), "x2": whole(df.x2),
        "y2": whole(df.y2), "hidden": [int(bool(h)) for h in df.hidden], "activity": [activities.index(a) for a in activity],
        # Each box's coarse state (working, idle, moving, stopped), where a Classify states node kept one beside its own.
        **({"coarse": [activities.index(c) if c in activities else activities.index("unknown") for c in df["activity"].astype(str)]}
           if "activity" in df else {}),
        "events": [{k: (v.item() if hasattr(v, "item") else v) for k, v in r.items()} for r in ev.to_dict("records")],
        # Where Link tracks joined two tracks into one: the review page shows them, to undo a wrong one.
        "joins": [dict(id=int(r.id), joined=int(r.joined_id), frame=int(r.start_frame), gap_s=float(r.gap_s), jump=float(r.jump))
                  for n in nodes if n["kind"] == "link_tracks" and isinstance(values.get((n["id"], "links")), pd.DataFrame)
                  for r in values[(n["id"], "links")].itertuples() if r.result == "joined"],
    }


def run(pipeline="pipeline.json", video_path=None, out="pipeline-output", device=None, max_s=None, cache=True, cache_dir=None, start=None,
        review=False):
    """Runs every node; returns what each gave, by (node id, output). cache_dir keeps the frame-by-frame results
    somewhere other than the output folder (to share between runs); start is the camera's clock at the video's
    start, for a report not given one; review writes review.json for the labeler's review page."""
    pipeline = Path(pipeline)
    if not pipeline.is_absolute() and not pipeline.exists():
        pipeline = HERE / pipeline
    spec = json.loads(pipeline.read_text())
    nodes = spec["nodes"]  # in the order they run
    name = "".join(c if c.isalnum() or c in "._-" else "_" for c in spec.get("name", "pipeline"))[:40]
    ctx = SimpleNamespace(video=Path(video_path), device=device or pick_device(), max_s=max_s, written=[], start=start or "")
    ctx.out = Path(out) / f"{ctx.video.stem[:40]}__{name}"
    ctx.cache = Path(cache_dir) if cache_dir else ctx.out / "cache"
    ctx.out.mkdir(parents=True, exist_ok=True)
    ctx.cache.mkdir(parents=True, exist_ok=True)
    values = {}

    def keep(n, outputs):
        for port, value in outputs.items():
            values[(n["id"], port)] = value

    def inputs(n):
        return {port: values[tuple(source)] for port, source in n["inputs"].items()}

    for n in nodes:
        if n["kind"] == "video":
            keep(n, video(ctx, n["params"]))
            ctx.frames = values[(n["id"], "frames")]
    frames = ctx.frames

    # The frame-by-frame nodes, all in one pass over the video, less those whose results are cached.
    pending, keys = [], {}
    for n in (n for n in nodes if NODES[n["kind"]].every_frame):
        runner = NODES[n["kind"]].run
        source = n["inputs"].get("detections") if n["kind"] == "python_frame" else None
        keys[n["id"]] = cache_key(n, frames, ctx, keys.get(source[0]) if source else None)
        path = ctx.cache / f"{n['id']}-{keys[n['id']]}"
        meta = path.with_suffix(".json")
        ctx.node = n
        if cache and meta.exists():
            saved = json.loads(meta.read_text())
            keep(n, runner.load(path, saved))
            frames.count = saved["count"]
            print(f"{n['label']}: cached ({path.name})")
        else:
            worker = runner(ctx, n["params"], frames)
            if source:
                worker.boxes = boxes_by_frame(source, values, pending)
            pending.append((n, runner, path, worker))
    if pending:
        print(f"{', '.join(n['label'] for n, *_ in pending)}: {frames.last / frames.vfps:.0f} s of video, 1 frame in {frames.every}", flush=True)
        t0 = time.time()
        frames.count = frame_pass(frames, [w for *_, w in pending])
        print(f"analysed {frames.count} frames in {time.time() - t0:.0f} s")
        for n, runner, path, w in pending:
            outputs = w.result()
            meta = runner.save(outputs, path)
            path.with_suffix(".json").write_text(json.dumps({**meta, "count": frames.count}))
            keep(n, outputs)

    skipped = []
    for n in nodes:
        if n["kind"] == "video" or NODES[n["kind"]].every_frame:
            continue
        given, optional = inputs(n), set(n.get("optional", []))
        # On a Branch's way not taken: skipped, and so is all it feeds. An optional input is given None instead.
        if any(v is SKIPPED for k, v in given.items() if k not in optional):
            keep(n, {port: SKIPPED for port in n.get("outputs", [])})
            skipped.append(f"{n['label']} ({n['id']})")
            continue
        ctx.node = n
        print(f"running {n['label']} ({n['id']})", flush=True)
        try:
            keep(n, NODES[n["kind"]].run(ctx, n["params"], **{k: None if v is SKIPPED else v for k, v in given.items()}))
        except Exception:
            print(f"{n['label']} ({n['id']}) failed:", file=sys.stderr)
            raise

    tracks = [v for (_, port), v in values.items() if port == "tracks" and isinstance(v, Table)]
    views = [v for (_, port), v in values.items() if port == "views" and isinstance(table_of(v), pd.DataFrame) and "paused" in v.df]
    links = [v for (_, port), v in values.items() if port == "links" and isinstance(v, pd.DataFrame) and "result" in v and len(v)]
    if skipped:
        print(f"skipped, on a way not taken: {', '.join(skipped)}")
    said = []
    if tracks:
        said.append(f"{tracks[-1].df.id.nunique()} IDs")
    if views:
        said.append(f"big camera moves {views[-1].df.paused.mean():.0%} of the time")
    given_back, joined = (sum(int((v.result == r).sum()) for v in links) for r in ("same ID", "joined"))
    if views and links:
        said.append(f"{given_back} IDs given back after them")
    if joined:
        said.append(f"{joined} broken tracks joined")
    events = [v for v in values.values() if isinstance(v, Events)]
    if events:
        said.append(f"{int((events[-1].df.kind == 'loading').sum())} loads, {int((events[-1].df.kind == 'queue').sum())} waits")
    print("; ".join(said) + (" -> " if said else "") + f"{ctx.out}: " + ", ".join(p.name for p in ctx.written))
    if review:
        data = review_data(ctx, nodes, values)
        if data is not None:
            (ctx.out / "review.json").write_text(json.dumps(data, separators=(",", ":"), default=str))
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("video")
    parser.add_argument("--pipeline", default=str(HERE / "pipeline.json"))
    parser.add_argument("--out", default="pipeline-output", help="where the outputs go, in a folder per video")
    parser.add_argument("--max-s", type=float, help="seconds of video to analyse (0 = all); overrides the Video node")
    parser.add_argument("--device", help="where the models run: cpu, mps, 0... (default: CUDA, else Apple's GPU, else the CPU)")
    parser.add_argument("--no-cache", action="store_true", help="run the frame-by-frame nodes again instead of reusing their results")
    parser.add_argument("--cache-dir", help="where the frame-by-frame results are kept (default: cache/ in the output folder)")
    parser.add_argument("--start", help="the camera's clock at the video's start, such as 2025-01-15 09:24:59, for a report not given one")
    parser.add_argument("--review", action="store_true", help="also write review.json, every box and what it was doing, for the labeler")
    a = parser.parse_args()
    try:
        run(a.pipeline, a.video, a.out, a.device, a.max_s, not a.no_cache, a.cache_dir, a.start, a.review)
    except Exception:
        # Printed by Python's own traceback module, which shows the lines of a node's code (older Pythons' built-in
        # printer reads only files).
        import traceback

        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
