#!/usr/bin/env python3
"""Runs a detection workflow from the labeler, outside it: the same steps,
preprocessing, tiles, rules and merging as on the labeler's Testing page.

    ./run.sh SOURCE                                    # installs requirements.txt the first time, then runs this
    python run_workflow.py SOURCE                      # an image, a folder of images or a video
    python run_workflow.py SOURCE --track bytetrack.yaml --video
    python run_workflow.py SOURCE --track botsort.yaml  # follows a moving camera too

It writes detections.jsonl (a line per frame) to --out, and with --video a copy
of the source with the boxes drawn on. From Python:

    from run_workflow import Workflow
    workflow = Workflow("workflow.json")
    for box in workflow.detect(frame):        # an OpenCV frame, BGR
        print(box.name, box.conf, box.xyxy)
    for index, frame, boxes, tracks in workflow.track(frames):   # (index, frame) pairs
        ...                                   # tracks: [x1, y1, x2, y2, track id, score, class, box index]

Boxes are in the frame's own pixels. Each model runs through Ultralytics'
predict, which prepares pictures within a pixel or two of how the labeler's
tests do, so scores can differ slightly from the Testing page's.
"""

import argparse
import inspect
import json
import math
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
NMS_IOU = 0.7
MAX_DETECTIONS = 300
LOWEST_CONFIDENCE = 0.001


def class_key(name):
    """Class names compared loosely: dump_truck, dumptruck and Dump truck are one class."""
    return "".join(ch for ch in str(name).lower() if not ch.isspace() and ch not in "_-")


def round_half_up(value):
    """Rounding as the labeler does it (halves away from zero), not Python's halves to even."""
    return int(math.floor(value + 0.5))


# ---- preprocessing, as the labeler does it: resize, CLAHE, grayscale, then code blocks ----


def geometry(width, height, resize):
    """Where a frame's pixels land after the labeler's resize: target size, scaled size, scale and offset."""
    if not resize:
        return width, height, width, height, 1.0, 1.0, 0.0, 0.0
    tw, th = int(resize["width"]), int(resize["height"])
    fx, fy = tw / width, th / height
    if resize["mode"] == "stretch":
        nw, nh, dx, dy = tw, th, 0, 0
    elif resize["mode"] == "fit":
        scale = min(fx, fy)
        nw, nh = min(max(round_half_up(width * scale), 1), tw), min(max(round_half_up(height * scale), 1), th)
        dx, dy = (tw - nw) // 2, (th - nh) // 2
    else:  # crop: fill the size, cutting off what overflows
        scale = max(fx, fy)
        nw, nh = max(round_half_up(width * scale), tw), max(round_half_up(height * scale), th)
        dx, dy = -((nw - tw) // 2), -((nh - th) // 2)
    return tw, th, nw, nh, nw / width, nh / height, float(dx), float(dy)


def resized(picture, width, height):
    import cv2

    h, w = picture.shape[:2]
    if (w, h) == (width, height):
        return picture
    shrinking = width < w and height < h
    return cv2.resize(picture, (width, height), interpolation=cv2.INTER_AREA if shrinking else cv2.INTER_LINEAR)


class Refused(Exception):
    """What a code block returned that cannot be a frame."""


def as_frame(out, name):
    """What a code block returned, as height × width × 3 RGB bytes, as the labeler takes it."""
    if out is None:
        raise Refused(f'code block "{name}" returned nothing')
    picture = np.asarray(out)
    if picture.dtype != np.uint8:
        raise Refused(f'code block "{name}" returned {picture.dtype} pixels, not uint8')
    if picture.ndim == 3 and picture.shape[2] == 1:
        picture = picture[:, :, 0]
    if picture.ndim == 2:
        picture = np.repeat(picture[:, :, None], 3, axis=2)
    elif picture.ndim == 3 and picture.shape[2] == 4:
        picture = picture[:, :, :3]
    if picture.ndim != 3 or picture.shape[2] != 3:
        raise Refused(f'code block "{name}" returned an array of shape {picture.shape}')
    return np.ascontiguousarray(picture)


def load_blocks(blocks):
    """Each code block's preprocess function, with its name."""
    loaded = []
    for i, block in enumerate(blocks):
        name = block.get("name") or f"block {i + 1}"
        namespace = {"__name__": f"code_block_{i + 1}", "np": np}
        exec(compile(block["source"], f"<code block {name}>", "exec"), namespace)
        loaded.append((name, namespace["preprocess"]))
    return loaded


def prepare(picture, preprocess, blocks):
    """An RGB picture as a model's preprocessing makes it, and (sx, sy, dx, dy) to map its boxes back."""
    import cv2

    h, w = picture.shape[:2]
    tw, th, nw, nh, sx, sy, dx, dy = geometry(w, h, preprocess.get("resize"))
    resize = preprocess.get("resize")
    if resize:
        scaled = resized(picture, nw, nh)
        if resize["mode"] == "fit":
            picture = np.zeros((th, tw, 3), np.uint8)
            picture[int(dy) : int(dy) + nh, int(dx) : int(dx) + nw] = scaled
        elif resize["mode"] == "crop":
            picture = scaled[int(-dy) : int(-dy) + th, int(-dx) : int(-dx) + tw]
        else:
            picture = scaled
    clahe = preprocess.get("clahe")
    if clahe:
        lab = cv2.cvtColor(np.ascontiguousarray(picture), cv2.COLOR_RGB2LAB)
        tiles = int(clahe["tiles"])
        lab[:, :, 0] = cv2.createCLAHE(clipLimit=float(clahe["clip_limit"]), tileGridSize=(tiles, tiles)).apply(lab[:, :, 0])
        picture = cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)
    if preprocess.get("grayscale"):
        # The labeler's grey: Rec. 709 luma, in whole levels, on three equal channels.
        rgb = picture.astype(np.uint32)
        luma = ((2126 * rgb[:, :, 0] + 7152 * rgb[:, :, 1] + 722 * rgb[:, :, 2]) // 10000).astype(np.uint8)
        picture = np.repeat(luma[:, :, None], 3, axis=2)
    if blocks:
        before = picture.shape[1], picture.shape[0]
        for name, function in blocks:
            picture = as_frame(function(picture), name)
        # A block that changed the size stretched the boxes with it.
        kx, ky = picture.shape[1] / before[0], picture.shape[0] / before[1]
        sx, sy, dx, dy = sx * kx, sy * ky, dx * kx, dy * ky
    return np.ascontiguousarray(picture), (sx, sy, dx, dy)


# ---- tiles, rules and merging, as the labeler does them ----


def tile_areas(width, height, tiles):
    """(x, y, width, height) of overlapping tiles covering a frame, the last ones flush with the far edges."""

    def starts(length):
        size = min(tiles["size"], length)
        if size == length:
            return [0]
        stride = max(round_half_up(size * (1 - tiles["overlap"])), 1)
        count = -(-(length - size) // stride) + 1
        return [min(i * stride, length - size) for i in range(count)]

    tw, th = min(tiles["size"], width), min(tiles["size"], height)
    return [(x, y, tw, th) for y in starts(height) for x in starts(width)]


@dataclass
class Box:
    x1: float
    y1: float
    x2: float
    y2: float
    conf: float
    cls: int
    name: str

    @property
    def xyxy(self):
        return self.x1, self.y1, self.x2, self.y2

    @property
    def area(self):
        return max(self.x2 - self.x1, 0) * max(self.y2 - self.y1, 0)


def floor(rules, name):
    """The confidence a box of class `name` needs: its class's own minimum (names compared loosely), else the rules' one."""
    own = rules.get("class_confidence") or {}
    if name in own:
        return own[name]
    return next((v for c, v in own.items() if class_key(c) == class_key(name)), rules.get("min_confidence", 0))


def keep(rules, box, width, height):
    """Whether a box passes a step's rules or the final ones."""
    if box.conf < floor(rules, box.name):
        return False
    area, frame = box.area, width * height

    def compare(size, at_least):
        if "px" in size:
            limit = size["px"] ** 2
            return area >= limit if at_least else area <= limit
        return area * 100 >= size["pct"] * frame if at_least else area * 100 <= size["pct"] * frame

    if rules.get("min_size") and not compare(rules["min_size"], True):
        return False
    if rules.get("max_size") and not compare(rules["max_size"], False):
        return False
    classes = rules.get("classes") or []
    if classes and not any(class_key(c) == class_key(box.name) for c in classes):
        return False
    cx, cy = (box.x1 + box.x2) / 2 / width, (box.y1 + box.y2) / 2 / height
    return not any(r["x1"] <= cx <= r["x2"] and r["y1"] <= cy <= r["y2"] for r in rules.get("exclude") or [])


def overlap(a, b, measure):
    w = max(min(a.x2, b.x2) - max(a.x1, b.x1), 0)
    h = max(min(a.y2, b.y2) - max(a.y1, b.y1), 0)
    inter = w * h
    base = a.area + b.area - inter if measure == "iou" else min(a.area, b.area)
    return inter / base if base > 0 else 0.0


def merge(found, settings):
    """One box per object, surest first: by IoU the surest of overlapping boxes stays; by IoS
    they are joined into one box covering them all, with the surest's score and class."""
    measure, threshold = settings.get("measure", "ios"), settings.get("threshold", 0.6)
    kept = []
    for box in sorted(found, key=lambda b: -b.conf):
        same = next((k for k in kept if (settings.get("across_classes") or k.cls == box.cls) and overlap(k, box, measure) >= threshold), None)
        if same is None:
            kept.append(box)
        elif measure == "ios":
            same.x1, same.y1, same.x2, same.y2 = min(same.x1, box.x1), min(same.y1, box.y1), max(same.x2, box.x2), max(same.y2, box.y2)
    return kept


class Model:
    """A model file run with Ultralytics."""

    def __init__(self, path, device=None):
        from ultralytics import YOLO

        self.yolo = YOLO(str(path))
        names = self.yolo.names
        self.names = [names[i] for i in range(len(names))]
        size = self.yolo.overrides.get("imgsz")
        # A checkpoint at the size it was trained at; an ONNX file at its own.
        self.imgsz = (max(size) if isinstance(size, (list, tuple)) else size) if str(path).endswith(".pt") and size else None
        self.device = device

    def detect(self, pictures, conf):
        """Boxes on RGB pictures: (xyxy, confidences, classes) for each."""
        options = {"conf": conf, "iou": NMS_IOU, "max_det": MAX_DETECTIONS, "verbose": False}
        if self.imgsz:
            options["imgsz"] = self.imgsz
        if self.device is not None:
            options["device"] = self.device
        answers = []
        for picture in pictures:
            result = self.yolo.predict(np.ascontiguousarray(picture[:, :, ::-1]), **options)[0]
            boxes = result.boxes
            answers.append((boxes.xyxy.cpu().numpy(), boxes.conf.cpu().numpy(), boxes.cls.cpu().numpy().astype(int)))
        return answers


class DFineModel:
    """A D-FINE checkpoint from the labeler (`.pth`, its config and class names beside it in `.dfine.json`), run with
    the D-FINE code that came with the bundle (`dfine/`, or a checkout named by DFINE_DIR) as D-FINE's validation
    runs it: stretched to its input size, 0 to 1, its own postprocessor, no NMS."""

    BATCH = 4

    def __init__(self, path, device=None):
        import tempfile

        import torch
        import yaml

        meta = json.loads(Path(path).with_suffix(".dfine.json").read_text())
        code = HERE / "dfine" if (HERE / "dfine" / "src").is_dir() else Path(os.environ.get("DFINE_DIR", ""))
        if not (code / "src" / "core").is_dir():
            raise SystemExit("a D-FINE model needs the D-FINE code: the bundle's dfine/ folder, or DFINE_DIR set to a checkout")
        sys.path.insert(0, str(code))
        from src.core import YAMLConfig

        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as f:
            yaml.safe_dump(meta["config"], f)
        try:
            cfg = YAMLConfig(f.name)
            model = cfg.model
            try:
                checkpoint = torch.load(str(path), map_location="cpu", weights_only=True)
            except Exception:  # a whole training checkpoint pickles a little more than tensors
                checkpoint = torch.load(str(path), map_location="cpu", weights_only=False)
            # The weights the labeler kept, or a whole training checkpoint: its EMA's, when it kept one.
            ema = checkpoint.get("ema")
            model.load_state_dict(ema["module"] if isinstance(ema, dict) and "module" in ema else checkpoint["model"])
            model, post = model.deploy(), cfg.postprocessor.deploy()
        finally:
            os.unlink(f.name)
        device = device or ("cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu")
        self.device = torch.device(f"cuda:{device}" if str(device).isdigit() else device)
        self.model, self.post = model.to(self.device).eval(), post.to(self.device).eval()
        self.names, self.imgsz, self.torch = list(meta["names"]), int(meta["imgsz"]), torch

    def detect(self, pictures, conf):
        """Boxes on RGB pictures: (xyxy, confidences, classes) for each, best first."""
        from PIL import Image

        torch, size, answers = self.torch, self.imgsz, []
        for start in range(0, len(pictures), self.BATCH):
            group = pictures[start : start + self.BATCH]
            batch = torch.stack(
                [torch.from_numpy(np.array(Image.fromarray(p).resize((size, size), Image.BILINEAR))).permute(2, 0, 1) for p in group]
            )
            sizes = torch.tensor([[p.shape[1], p.shape[0]] for p in group], device=self.device)
            with torch.inference_mode():
                labels, boxes, scores = self.post(self.model(batch.to(self.device).float() / 255), sizes)
            for label, box, score in zip(labels.cpu(), boxes.float().cpu(), scores.float().cpu()):
                keep = (score > conf).nonzero().squeeze(1)
                keep = keep[score[keep].argsort(descending=True, stable=True)][:MAX_DETECTIONS]
                answers.append((box[keep].numpy(), score[keep].numpy(), label[keep].numpy().astype(int)))
        return answers


class Workflow:
    """The workflow in workflow.json, its models beside it."""

    def __init__(self, path=HERE / "workflow.json", device=None):
        path = Path(path)
        self.spec = json.loads(path.read_text())
        self.classes = self.spec["classes"]
        self.steps = []
        models = {}
        for step in self.spec["steps"]:
            file = (path.parent / step["model"]).resolve()
            if file not in models:
                models[file] = DFineModel(file, device) if file.suffix == ".pth" else Model(file, device)
            model = models[file]
            preprocess = step.get("preprocess") or {}
            classes = [next((i for i, c in enumerate(self.classes) if class_key(c) == class_key(n)), None) for n in model.names]
            self.steps.append((step, model, preprocess, load_blocks(preprocess.get("code") or []), classes))

    def detect(self, frame):
        """The workflow's boxes on an OpenCV (BGR) frame, surest first."""
        picture = np.ascontiguousarray(frame[:, :, ::-1])
        height, width = picture.shape[:2]
        found = []
        for step, model, preprocess, blocks, classes in self.steps:
            tiles = step.get("tiles")
            areas = tile_areas(width, height, tiles) if tiles else [(0, 0, width, height)]
            prepared, placed = [], []
            for x, y, tw, th in areas:
                ready, (sx, sy, dx, dy) = prepare(picture[y : y + th, x : x + tw], preprocess, blocks)
                prepared.append(ready)
                placed.append((sx, sy, dx, dy, x, y))
            rules = step.get("rules") or {}
            # The model is asked for boxes down to the weakest any class keeps.
            conf = max(min([rules.get("min_confidence", 0), *(rules.get("class_confidence") or {}).values()]), LOWEST_CONFIDENCE)
            for (xyxy, confs, classes_found), (sx, sy, dx, dy, ox, oy) in zip(model.detect(prepared, conf), placed):
                for (x1, y1, x2, y2), score, k in zip(xyxy, confs, classes_found):
                    c = classes[k] if k < len(classes) else None
                    if c is None:
                        continue
                    box = Box(
                        float(min(max((x1 - dx) / sx + ox, 0), width)),
                        float(min(max((y1 - dy) / sy + oy, 0), height)),
                        float(min(max((x2 - dx) / sx + ox, 0), width)),
                        float(min(max((y2 - dy) / sy + oy, 0), height)),
                        float(score),
                        int(c),
                        self.classes[c],
                    )
                    if box.x2 - box.x1 >= 1 and box.y2 - box.y1 >= 1 and keep(rules, box, width, height):
                        found.append(box)
        kept = [b for b in merge(found, self.spec.get("merge") or {}) if keep(self.spec.get("rules") or {}, b, width, height)]
        return kept[:MAX_DETECTIONS]

    def track(self, frames, tracker="bytetrack.yaml", fps=30):
        """Follows the workflow's boxes from frame to frame with an Ultralytics tracker, as
        `model.track` does for one model. Yields (index, frame, boxes, tracks) for each
        (index, frame) given; a track row is [x1, y1, x2, y2, track id, score, class, box index]."""
        from ultralytics.engine.results import Boxes
        from ultralytics.trackers.track import TRACKER_MAP
        from ultralytics.utils import IterableSimpleNamespace
        from ultralytics.utils.checks import check_yaml

        try:
            from ultralytics.utils import YAML

            settings = YAML.load(check_yaml(tracker))
        except ImportError:  # older Ultralytics
            from ultralytics.utils import yaml_load

            settings = yaml_load(check_yaml(tracker))
        cfg = IterableSimpleNamespace(**settings)
        if getattr(cfg, "with_reid", False) and getattr(cfg, "model", "auto") == "auto":
            print("ReID is off: it reads a single model's features, and a workflow has several.", file=sys.stderr)
            cfg.with_reid = False
        kind = TRACKER_MAP[cfg.tracker_type]
        # Older Ultralytics scales track_buffer by the frame rate; newer counts it in frames.
        takes_rate = "frame_rate" in inspect.signature(kind.__init__).parameters
        follower = kind(args=cfg, frame_rate=int(round(fps))) if takes_rate else kind(args=cfg)
        for index, frame in frames:
            boxes = self.detect(frame)
            data = np.array([[b.x1, b.y1, b.x2, b.y2, b.conf, b.cls] for b in boxes], np.float32).reshape(-1, 6)
            tracks = follower.update(Boxes(data, frame.shape[:2]), frame) if len(data) else np.zeros((0, 8))
            yield index, frame, boxes, tracks


# ---- the command line ----


def frames_of(source):
    """(index, name, frame) for an image, a folder of images or a video, and its frame rate."""
    import cv2

    source = Path(source)
    pictures = (".jpg", ".jpeg", ".png", ".bmp", ".webp")
    if source.is_dir() or source.suffix.lower() in pictures:
        files = sorted(p for p in source.iterdir() if p.suffix.lower() in pictures) if source.is_dir() else [source]

        def read():
            for i, f in enumerate(files):
                frame = cv2.imread(str(f))
                if frame is not None:
                    yield i, f.name, frame

        return read(), 30.0
    capture = cv2.VideoCapture(str(source))
    if not capture.isOpened():
        raise SystemExit(f"{source} is not an image, a folder of images or a video OpenCV can read")
    fps = capture.get(cv2.CAP_PROP_FPS) or 30.0

    def read():
        i = 0
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            yield i, f"frame {i}", frame
            i += 1
        capture.release()

    return read(), fps


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("source", help="an image, a folder of images or a video")
    parser.add_argument("--workflow", default=str(HERE / "workflow.json"))
    parser.add_argument("--out", default="workflow-output", help="where detections.jsonl (and the video) go")
    parser.add_argument("--track", metavar="TRACKER", help="an Ultralytics tracker: bytetrack.yaml, botsort.yaml, or a file of your own")
    parser.add_argument("--video", action="store_true", help="also write the frames with their boxes drawn on, as a video")
    parser.add_argument("--device", help="where the models run: cpu, mps, 0...")
    args = parser.parse_args()

    import cv2

    workflow = Workflow(args.workflow, device=args.device)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    frames, fps = frames_of(args.source)
    names = {}

    def pairs():
        for index, name, frame in frames:
            names[index] = name
            yield index, frame

    results = (
        workflow.track(pairs(), args.track, fps)
        if args.track
        else ((i, f, workflow.detect(f), None) for i, f in pairs())
    )
    writer = None
    with open(out / "detections.jsonl", "w") as lines:
        for count, (index, frame, boxes, tracks) in enumerate(results, 1):
            ids = {}
            if tracks is not None:
                for row in tracks:
                    ids[int(row[7])] = int(row[4])
            rows = [
                {"box": [round(b.x1, 1), round(b.y1, 1), round(b.x2, 1), round(b.y2, 1)], "conf": round(b.conf, 4), "class": b.name, **({"track": ids[i]} if i in ids else {})}
                for i, b in enumerate(boxes)
            ]
            lines.write(json.dumps({"frame": index, "source": names.pop(index, ""), "boxes": rows}) + "\n")
            if args.video:
                if writer is None:
                    h, w = frame.shape[:2]
                    writer = cv2.VideoWriter(str(out / "boxes.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
                for i, b in enumerate(boxes):
                    colour = (60, 180, 75) if i in ids else (0, 200, 255)
                    cv2.rectangle(frame, (int(b.x1), int(b.y1)), (int(b.x2), int(b.y2)), colour, 2)
                    label = f"{b.name} {b.conf:.2f}" + (f" #{ids[i]}" if i in ids else "")
                    cv2.putText(frame, label, (int(b.x1), max(12, int(b.y1) - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, colour, 1)
                writer.write(frame)
            if count % 50 == 0:
                print(f"{count} frames", file=sys.stderr)
    if writer is not None:
        writer.release()
    print(f"Wrote {out / 'detections.jsonl'}" + (f" and {out / 'boxes.mp4'}" if writer else ""))


if __name__ == "__main__":
    main()
