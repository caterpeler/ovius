# The labeler's state models: the trainers' code, and what runs a model on a pipeline's tracks.
import sys, time, socket, platform, json
from pathlib import Path
from types import SimpleNamespace


# Labeler · the state trainer: a state version's clips, the model and its training. Nothing here needs changing.
import json
import random
from types import SimpleNamespace

import numpy as np
import torch
import torchvision
from PIL import Image
from torch import nn
from torch.utils.data import DataLoader, Dataset

MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
# What TRAIN_ARGS can set, and what each is until it does.
STATE_DEFAULTS = dict(
    epochs=40,  # passes over the training clips
    batch=32,
    lr=1e-3,
    weight_decay=1e-4,
    freeze=True,  # the image model stays as it was trained (fast: each clip is read once); False trains it too
    temporal="gru",  # how the frames' features are put together: "gru" (in order) or "pool" (averages and changes)
    hidden=256,
    dropout=0.3,
    patience=10,  # stops after this many epochs without a better validation F1
    balance=True,  # weighs each state by how rare it is, so a rare one (loading) counts as much as a common one
    device=None,  # "cuda", "mps" or "cpu"; None: the best there is
    seed=0,
)


def state_dataset(labeler, version_id, folder):
    """Downloads and unpacks the state version, unless that was done before: a folder of clips per state, per split."""
    folder = Path(folder)
    if (folder / "train").is_dir():
        return folder
    with labeler.request("GET", f"{labeler.url}/api/v1/versions/{version_id}/export", params={"archive": "tar"}, stream=True) as response:
        response.raw.decode_content = True
        unpack(response.raw, folder)
    return folder


def folder_of(state):
    """A state's folder in the version's download, as the labeler names it."""
    return state.replace("/", "_").replace("\\", "_")


def read_clip(path):
    """A clip's JPEG, its frames side by side, as frames × 3 × size × size, from 0 to 1."""
    strip = torch.from_numpy(np.asarray(Image.open(path).convert("RGB"))).permute(2, 0, 1).float() / 255
    size = strip.shape[1]
    frames = strip.shape[2] // size
    return strip[:, :, : frames * size].reshape(3, size, frames, size).permute(2, 0, 1, 3)


class Clips(Dataset):
    """A split's clips: every JPEG in <split>/<state>/, its frames side by side, as frames × 3 × size × size."""

    def __init__(self, folder, states, augment=False):
        self.items = [(p, i) for i, s in enumerate(states) for p in sorted((Path(folder) / folder_of(s)).glob("*.jpg"))]
        self.augment = augment

    def __len__(self):
        return len(self.items)

    def __getitem__(self, k):
        path, label = self.items[k]
        x = read_clip(path)
        if self.augment:
            # The same for every frame of a clip: a machine does not flip or brighten halfway through.
            if random.random() < 0.5:
                x = x.flip(-1)
            x = (x * random.uniform(0.8, 1.2) + random.uniform(-0.08, 0.08)).clamp(0, 1)
        return (x - MEAN) / STD, label


def image_model(name, pretrained=True):
    """A torchvision model pretrained on ImageNet, without its last layer: it gives each picture a feature vector.
    Not `pretrained`, it is built empty, for weights of its own (a saved state model's)."""
    m = torchvision.models.get_model(name, weights="DEFAULT" if pretrained else None)
    for attr in ("fc", "classifier", "heads", "head"):
        layer = getattr(m, attr, None)
        if isinstance(layer, nn.Linear):
            setattr(m, attr, nn.Identity())
            return m, layer.in_features
        if isinstance(layer, nn.Sequential):
            last = max((i for i, l in enumerate(layer) if isinstance(l, nn.Linear)), default=None)
            if last is not None:
                dim = layer[last].in_features
                layer[last] = nn.Identity()
                return m, dim
    raise ValueError(f"{name}: its last layer was not found; try resnet18, resnet50, efficientnet_b0 or convnext_tiny")


class Temporal(nn.Module):
    """From a clip's frames' features (batch × frames × dim) to its state's scores."""

    def __init__(self, dim, states, kind="gru", hidden=256, dropout=0.3):
        super().__init__()
        self.kind = kind
        if kind == "gru":
            self.gru = nn.GRU(dim, hidden, batch_first=True, bidirectional=True)
            out = 2 * hidden
        else:
            out = 3 * dim  # the average, the most, and how much it changes from frame to frame
        self.head = nn.Sequential(nn.Dropout(dropout), nn.Linear(out, states))

    def forward(self, f):
        if self.kind == "gru":
            y, _ = self.gru(f)
            z = y.mean(1)
        else:
            z = torch.cat([f.mean(1), f.amax(1), (f[:, 1:] - f[:, :-1]).abs().mean(1)], 1)
        return self.head(z)


def pick_device(wanted=None):
    if wanted:
        return torch.device(wanted)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


@torch.no_grad()
def features(backbone, clips, device, batch, flipped=False):
    """Every clip's frames' features, once: the image model is not trained, so they do not change."""
    out, labels = [], []
    for x, y in DataLoader(clips, batch_size=max(1, batch // 2)):
        if flipped:
            x = x.flip(-1)
        b, t = x.shape[:2]
        out.append(backbone(x.flatten(0, 1).to(device)).float().view(b, t, -1).cpu())
        labels.append(y)
    return (torch.cat(out), torch.cat(labels)) if out else (torch.zeros(0), torch.zeros(0, dtype=torch.long))


def scores(true, pred, n):
    """Accuracy, macro F1, and each state's precision, recall, F1 and clips; and the confusion (true × predicted)."""
    confusion = np.zeros((n, n), dtype=int)
    for t, p in zip(true, pred):
        confusion[t, p] += 1
    per = []
    for i in range(n):
        tp = confusion[i, i]
        precision = tp / confusion[:, i].sum() if confusion[:, i].sum() else 0.0
        recall = tp / confusion[i].sum() if confusion[i].sum() else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        per.append(dict(precision=float(precision), recall=float(recall), f1=float(f1), clips=int(confusion[i].sum())))
    present = [p["f1"] for p in per if p["clips"]]
    accuracy = float(np.trace(confusion) / confusion.sum()) if confusion.sum() else 0.0
    return dict(accuracy=accuracy, macro_f1=float(np.mean(present)) if present else 0.0, per_state=per, confusion=confusion.tolist())


def train_states(labeler, data_dir, save_dir, states, backbone_name, train_args):
    """Trains a state model on the version's train clips, picks the epoch best on its validation clips, scores that
    on the test clips, and saves it (state_model.pth, and what it is in state_model.json). Every epoch goes to the labeler."""
    args = {**STATE_DEFAULTS, **train_args}
    unknown = set(train_args) - set(STATE_DEFAULTS)
    if unknown:
        raise ValueError(f"TRAIN_ARGS has {', '.join(sorted(unknown))}; a state run takes {', '.join(STATE_DEFAULTS)}")
    random.seed(args["seed"])
    torch.manual_seed(args["seed"])
    save_dir = Path(save_dir)
    save_dir.mkdir(parents=True, exist_ok=True)
    data_dir = Path(data_dir)
    device = pick_device(args["device"])
    splits = {s: Clips(data_dir / s, states, augment=(s == "train" and not args["freeze"])) for s in ("train", "val", "test")}
    if not len(splits["train"]) or not len(splits["val"]):
        raise ValueError("the version needs train and validation clips")
    frames, _, size, _ = splits["train"][0][0].shape
    backbone, dim = image_model(backbone_name)
    backbone = backbone.to(device).eval()
    head = Temporal(dim, len(states), args["temporal"], args["hidden"], args["dropout"])
    counts = np.bincount([label for _, label in splits["train"].items], minlength=len(states))
    weight = torch.tensor(counts.sum() / (len(states) * np.maximum(counts, 1)), dtype=torch.float) if args["balance"] else None
    print(f"{len(splits['train'])} train, {len(splits['val'])} validation and {len(splits['test'])} test clips of {frames} frames, "
          f"{size} px; {backbone_name} on {device}, {'frozen' if args['freeze'] else 'trained too'}")
    environment = {"host": socket.gethostname(), "python": platform.python_version(), "torch": torch.__version__,
                   "torchvision": torchvision.__version__, "device": str(device)}
    if torch.cuda.is_available():
        environment["gpu"] = torch.cuda.get_device_name(0)
    labeler.started = time.time()
    labeler.send("start", {"args": {**args, "backbone": backbone_name, "frames": frames, "size": size, "states": states},
                           "environment": environment, "epochs": args["epochs"]})

    if args["freeze"]:
        # Each clip read once (and the train clips once more, mirrored); then only the small model on top learns.
        print("Reading every clip with the image model…")
        train_x, train_y = features(backbone, splits["train"], device, args["batch"])
        flip_x, _ = features(backbone, splits["train"], device, args["batch"], flipped=True)
        held = {s: features(backbone, splits[s], device, args["batch"]) for s in ("val", "test")}
        model, run_on = head, torch.device("cpu")
        params = head.parameters()
    else:
        model, run_on = nn.ModuleDict({"backbone": backbone, "head": head}).to(device), device
        params = model.parameters()

    def predict(x):
        if args["freeze"]:
            return model(x)
        b, t = x.shape[:2]
        return model["head"](model["backbone"](x.flatten(0, 1)).view(b, t, -1))

    def batches(split):
        """A split's clips in batches: features (frozen) or pictures."""
        if args["freeze"]:
            x, y = (train_x, train_y) if split == "train" else held[split]
            if split == "train":
                x = torch.where(torch.rand(len(x), 1, 1) < 0.5, x, flip_x)
                order = torch.randperm(len(x))
                x, y = x[order], y[order]
            for i in range(0, len(x), args["batch"]):
                yield x[i:i + args["batch"]], y[i:i + args["batch"]]
        else:
            yield from DataLoader(splits[split], batch_size=args["batch"], shuffle=(split == "train"))

    loss_of = nn.CrossEntropyLoss(weight=weight.to(run_on) if weight is not None else None)
    optimiser = torch.optim.AdamW(params, lr=args["lr"], weight_decay=args["weight_decay"])
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=max(1, args["epochs"]))

    def evaluate(split):
        model.eval()
        losses, true, pred = [], [], []
        with torch.no_grad():
            for x, y in batches(split):
                x, y = x.to(run_on), y.to(run_on)
                out = predict(x)
                losses.append(loss_of(out, y).item() * len(y))
                true += y.tolist()
                pred += out.argmax(1).tolist()
        found = scores(true, pred, len(states))
        found["loss"] = sum(losses) / max(1, len(true))
        return found

    epochs, best, best_f1, waited = [], None, -1.0, 0
    for epoch in range(1, args["epochs"] + 1):
        model.train()
        if args["freeze"]:
            backbone.eval()
        total, seen = 0.0, 0
        for x, y in batches("train"):
            x, y = x.to(run_on), y.to(run_on)
            optimiser.zero_grad()
            loss = loss_of(predict(x), y)
            loss.backward()
            optimiser.step()
            total += loss.item() * len(y)
            seen += len(y)
        schedule.step()
        val = evaluate("val")
        figures = {"train/loss": round(total / max(1, seen), 6), "val/loss": round(val["loss"], 6),
                   "val/accuracy": round(val["accuracy"], 6), "val/macro_f1": round(val["macro_f1"], 6),
                   "lr": round(optimiser.param_groups[0]["lr"], 8), "seconds": round(time.time() - labeler.started, 1)}
        for name, per in zip(states, val["per_state"]):
            if per["clips"]:
                figures[f"val/f1/{name}"] = round(per["f1"], 6)
        epochs.append({"epoch": epoch, "metrics": figures})
        labeler.send("epochs", {"epoch": epoch, "metrics": figures})
        print(f"epoch {epoch}: train loss {figures['train/loss']:.4f}, val loss {figures['val/loss']:.4f}, "
              f"accuracy {val['accuracy']:.3f}, macro F1 {val['macro_f1']:.3f}")
        if val["macro_f1"] > best_f1:
            best_f1, waited = val["macro_f1"], 0
            now = model.state_dict()
            kept = type(now)((k, v.detach().cpu().clone()) for k, v in now.items())
            kept._metadata = getattr(now, "_metadata", None)  # some models (MNASNet) need it to load again
            best = {"epoch": epoch, "state": kept}
        else:
            waited += 1
            if waited >= args["patience"]:
                print(f"No better validation F1 for {waited} epochs: stopping.")
                break

    model.load_state_dict(best["state"])
    test = evaluate("test") if len(splits["test"]) else None
    head_state = head.state_dict()
    torch.save({"format": "labeler-state-model", "backbone": backbone_name, "backbone_state": backbone.state_dict(),
                "temporal": args["temporal"], "hidden": args["hidden"], "dropout": args["dropout"], "dim": dim,
                "head_state": head_state, "states": states, "frames": frames, "size": size,
                "mean": MEAN.flatten().tolist(), "std": STD.flatten().tolist()}, save_dir / "state_model.pth")
    about = {"states": states, "backbone": backbone_name, "frames": frames, "size": size, "temporal": args["temporal"],
             "best_epoch": best["epoch"], "validation": epochs[best["epoch"] - 1]["metrics"], "test": test}
    (save_dir / "state_model.json").write_text(json.dumps(about, indent=2))
    with open(save_dir / "results.csv", "w") as f:
        keys = sorted({k for e in epochs for k in e["metrics"]})
        f.write(",".join(["epoch", *keys]) + "\n")
        for e in epochs:
            f.write(",".join([str(e["epoch"]), *(str(e["metrics"].get(k, "")) for k in keys)]) + "\n")
    if test:
        print(f"Test clips: accuracy {test['accuracy']:.3f}, macro F1 {test['macro_f1']:.3f}")
        for name, per in zip(states, test["per_state"]):
            print(f"  {name:20} F1 {per['f1']:.3f}  precision {per['precision']:.3f}  recall {per['recall']:.3f}  ({per['clips']} clips)")
    return SimpleNamespace(save_dir=save_dir, epochs=epochs, best_epoch=best["epoch"], test=test, states=states)


def finish_states(labeler, trained, notebook=None, script=False):
    """Sends the summary (the test clips' scores in it), every epoch again, the results and this notebook (or, for a
    script, the script and what it printed)."""
    best = trained.epochs[trained.best_epoch - 1]["metrics"]
    final = {}
    if trained.test:
        final = {"test/accuracy": trained.test["accuracy"], "test/macro_f1": trained.test["macro_f1"]}
        if "edit" in trained.test:  # a segmentation run's: how its segments come out
            final.update({"test/edit": trained.test["edit"], "test/f1@50": trained.test["f1_50"]})
    weights = next((trained.save_dir / n for n in ("state_model.pth", "segment_model.pth") if (trained.save_dir / n).exists()), trained.save_dir / "state_model.pth")
    summary = {"task": "states", "epochs": len(trained.epochs), "best_epoch": trained.best_epoch, "best": best,
               "last": trained.epochs[-1]["metrics"], "final": final, "test": trained.test, "states": trained.states,
               "minutes": round((time.time() - labeler.started) / 60, 1),
               "weights_mb": round(weights.stat().st_size / 1e6, 1) if weights.exists() else None,
               "save_dir": str(trained.save_dir), "extra": labeler.extra}
    for name in ("results.csv",):
        try:
            labeler.upload(trained.save_dir / name)
        except RuntimeError as error:
            print(f"labeler: {name} not sent ({error})", file=sys.stderr)
    if not labeler.send("finish", {"status": "finished", "summary": summary, "epochs": trained.epochs}):
        print("The summary could not be sent: run this cell again once the labeler can be reached.")
        return
    print(f"Best epoch {trained.best_epoch} of {len(trained.epochs)}: validation macro F1 {best['val/macro_f1']:.3f}")
    if script:
        labeler.upload_script()
    else:
        labeler.upload_notebook(notebook)


# Labeler · the segmentation trainer: every checked machine's whole track, a state for every frame of it. Nothing
# here needs changing. It reads the state version's reviews and videos (its "annotations + videos" download).
import csv
from collections import defaultdict

import cv2

# What TRAIN_ARGS can set for a segmentation run, and what each is until it does.
SEGMENT_DEFAULTS = dict(
    epochs=60,
    lr=5e-4,
    weight_decay=1e-4,
    stages=3,  # rounds: each one reads the one before and tidies it
    layers=10,  # per round; it sees 2^layers frames around each one
    channels=64,
    dropout=0.5,
    window=256,  # frames of a track trained on at once
    windows=400,  # stretches of tracks per epoch
    batch=8,
    smooth=0.15,  # how much flickering from frame to frame costs
    motion=True,  # adds how the machine's box moves and changes size to what the image model sees
    size=224,  # the square cut around the machine, in pixels
    padding=0.15,  # room around the machine
    patience=15,
    balance=True,
    device=None,
    seed=0,
)


def segment_dataset(labeler, version_id, folder):
    """Downloads and unpacks the state version's reviews with their videos, unless that was done before."""
    folder = Path(folder)
    if (folder / "boxes.csv").exists():
        return folder
    url = f"{labeler.url}/api/v1/versions/{version_id}/export"
    with labeler.request("GET", url, params={"format": "annotations", "archive": "tar"}, stream=True) as response:
        response.raw.decode_content = True
        unpack(response.raw, folder)
    return folder


def read_tracks(data_dir, states):
    """Every checked machine's track: its video and split, its frames, boxes, and the state of each (-1 where it is
    none of `states`: can't tell, not a machine, or a state left out)."""
    data_dir = Path(data_dir)
    rows = lambda name: list(csv.DictReader(open(data_dir / name, newline="")))
    videos = {v["video"]: v for v in rows("videos.csv")}
    known = {name: i for i, name in enumerate(states)}
    segments = defaultdict(list)
    for s in rows("states.csv"):
        segments[(s["video"], s["machine"])].append((int(s["start_frame"]), int(s["end_frame"]), known.get(s["state"], -1)))
    boxes = defaultdict(list)
    for b in rows("boxes.csv"):
        boxes[(b["video"], b["machine"])].append((int(b["frame"]), float(b["x1"]), float(b["y1"]), float(b["x2"]), float(b["y2"])))
    tracks = []
    for key, found in boxes.items():
        found.sort()
        video, machine = key
        labels = []
        for f, *_ in found:
            label = next((l for a, b, l in segments.get(key, []) if a <= f <= b), -1)
            labels.append(label)
        v = videos.get(video, {})
        tracks.append(SimpleNamespace(video=video, machine=machine, split=v.get("split", "train"), fps=float(v.get("fps") or 25),
                                      frames=np.array([b[0] for b in found]), boxes=np.array([b[1:] for b in found]),
                                      labels=np.array(labels)))
    return tracks


def cut_square(img, box, pad, size):
    """The square around a box, `pad` of its side larger each way, at size × size; outside the picture is black."""
    h, w = img.shape[:2]
    x1, y1, x2, y2 = box
    side = max(x2 - x1, y2 - y1, 8.0) * (1 + 2 * pad)
    x0, y0, side = int(round((x1 + x2 - side) / 2)), int(round((y1 + y2 - side) / 2)), int(round(side))
    out = np.zeros((side, side, 3), dtype=np.uint8)
    a, b, c, d = max(0, x0), max(0, y0), min(w, x0 + side), min(h, y0 + side)
    if c > a and d > b:
        out[b - y0:d - y0, a - x0:c - x0] = img[b:d, a:c]
    return cv2.resize(out, (size, size), interpolation=cv2.INTER_AREA)


@torch.no_grad()
def track_features(tracks, data_dir, cache, backbone, device, size, pad, batch=32, video_path=None):
    """Every track's frames read by the image model, once: each video is read front to back (no seeking, which some
    OpenCV builds fail at), each machine cut out of each frame it is in. Kept in `cache` (unless it is None), so
    another run with the same image model, size and room reads them back. The videos are in data_dir/videos, or, for
    tracks of one video, at `video_path`."""
    cache = Path(cache) if cache else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)
    file_of = lambda t: cache / f"{Path(t.video).stem}__m{t.machine}.npy"
    by_video = defaultdict(list)
    for t in tracks:
        if cache and file_of(t).exists():
            t.features = np.load(file_of(t))
        else:
            by_video[t.video].append(t)
    for video, todo in by_video.items():
        print(f"Reading {video} for {len(todo)} machine(s)…", flush=True)
        need = defaultdict(list)
        for t in todo:
            t.features = None
            t.parts = [None] * len(t.frames)
            for i, f in enumerate(t.frames):
                need[int(f)].append((t, i))
        pending = []

        def run(pending):
            x = torch.stack([torch.from_numpy(c[:, :, ::-1].copy()).permute(2, 0, 1).float() / 255 for c, _, _ in pending])
            out = backbone(((x - MEAN) / STD).to(device)).float().cpu().numpy().astype(np.float16)
            for (_, t, i), row in zip(pending, out):
                t.parts[i] = row

        cap = cv2.VideoCapture(str(video_path or Path(data_dir) / "videos" / video))
        last = max(need) if need else -1
        for f in range(last + 1):
            if not cap.grab():
                break
            if f not in need:
                continue
            try:
                ok, img = cap.retrieve()
            except cv2.error:
                ok = False
            if not ok:
                continue
            for t, i in need[f]:
                pending.append((cut_square(img, t.boxes[i], pad, size), t, i))
            if len(pending) >= batch:
                run(pending)
                pending = []
        if pending:
            run(pending)
        cap.release()
        for t in todo:
            dim = next((p.shape[0] for p in t.parts if p is not None), None)
            if dim is None:
                raise RuntimeError(f"{video}: none of machine {t.machine}'s frames could be read")
            # A frame that could not be read takes the one before it (or after it).
            filled, prev = [], None
            for p in t.parts:
                prev = p if p is not None else prev
                filled.append(prev)
            first = next(p for p in filled if p is not None)
            t.features = np.stack([p if p is not None else first for p in filled])
            del t.parts
            if cache:
                np.save(file_of(t), t.features)
    return tracks


def motion_of(t):
    """How the box moves and changes size between frames: across and down (in its own widths per second), and its
    width and height (log, per second). A zoom does not change them."""
    b = t.boxes
    cx, cy = (b[:, 0] + b[:, 2]) / 2, (b[:, 1] + b[:, 3]) / 2
    w, h = np.maximum(b[:, 2] - b[:, 0], 1), np.maximum(b[:, 3] - b[:, 1], 1)
    dt = np.maximum(np.diff(t.frames, prepend=t.frames[0] - 1) / t.fps, 1e-3)
    m = np.stack([np.diff(cx, prepend=cx[0]) / w / dt, np.diff(cy, prepend=cy[0]) / w / dt,
                  np.diff(np.log(w), prepend=np.log(w[0])) / dt, np.diff(np.log(h), prepend=np.log(h[0])) / dt], 1)
    return np.clip(m, -5, 5).astype(np.float32)


class DilatedResidual(nn.Module):
    def __init__(self, dilation, channels, dropout):
        super().__init__()
        self.conv = nn.Conv1d(channels, channels, 3, padding=dilation, dilation=dilation)
        self.out = nn.Conv1d(channels, channels, 1)
        self.drop = nn.Dropout(dropout)

    def forward(self, x, mask):
        return (x + self.drop(self.out(torch.relu(self.conv(x))))) * mask


class Stage(nn.Module):
    def __init__(self, layers, channels, dim, states, dropout):
        super().__init__()
        self.inp = nn.Conv1d(dim, channels, 1)
        self.layers = nn.ModuleList(DilatedResidual(2**i, channels, dropout) for i in range(layers))
        self.out = nn.Conv1d(channels, states, 1)

    def forward(self, x, mask):
        x = self.inp(x)
        for layer in self.layers:
            x = layer(x, mask)
        return self.out(x) * mask


class Segmenter(nn.Module):
    """A multi-stage temporal convolutional network (MS-TCN): from every frame's features (batch × dim × frames) to
    every frame's state scores, once per stage; the last stage's are the answer."""

    def __init__(self, dim, states, stages=3, layers=10, channels=64, dropout=0.5):
        super().__init__()
        self.stages = nn.ModuleList([Stage(layers, channels, dim, states, dropout)]
                                    + [Stage(layers, channels, states, states, dropout) for _ in range(stages - 1)])

    def forward(self, x, mask):
        outs = []
        for stage in self.stages:
            x = stage(x if not outs else torch.softmax(x, 1) * mask, mask)
            outs.append(x)
        return outs


def segments_of(labels):
    """A frame-by-frame labelling as segments: (label, start, end), end not included; frames of -1 dropped."""
    labels = [l for l in labels if l >= 0]
    out = []
    for i, l in enumerate(labels):
        if not out or out[-1][0] != l:
            out.append([l, i, i + 1])
        else:
            out[-1][2] = i + 1
    return out


def edit_score(pred, true):
    """How alike the order of states is (100: the same order), from the edit distance between them."""
    p, t = [s[0] for s in segments_of(pred)], [s[0] for s in segments_of(true)]
    if not p and not t:
        return 100.0
    d = np.zeros((len(p) + 1, len(t) + 1))
    d[:, 0], d[0, :] = np.arange(len(p) + 1), np.arange(len(t) + 1)
    for i in range(1, len(p) + 1):
        for j in range(1, len(t) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + (p[i - 1] != t[j - 1]))
    return float((1 - d[-1, -1] / max(len(p), len(t))) * 100)


def segment_f1(pred, true, overlap=0.5):
    """Of the segments found and the true ones, the F1 of those that match: same state, at least `overlap` of them shared."""
    p, t = segments_of(pred), segments_of(true)
    used = [False] * len(t)
    tp = 0
    for l, a, b in p:
        best, k = 0.0, -1
        for j, (m, c, d) in enumerate(t):
            if m == l and not used[j]:
                inter, union = max(0, min(b, d) - max(a, c)), max(b, d) - min(a, c)
                if union and inter / union > best:
                    best, k = inter / union, j
        if k >= 0 and best >= overlap:
            tp += 1
            used[k] = True
    precision = tp / len(p) if p else 0.0
    recall = tp / len(t) if t else 0.0
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def train_segments(labeler, data_dir, save_dir, states, backbone_name, train_args):
    """Trains a segmentation model on the version's train videos' tracks, picks the epoch best on its validation
    videos (frame macro F1), scores that on its test videos, and saves it (segment_model.pth, and what it is in
    segment_model.json). Every epoch goes to the labeler."""
    args = {**SEGMENT_DEFAULTS, **train_args}
    unknown = set(train_args) - set(SEGMENT_DEFAULTS)
    if unknown:
        raise ValueError(f"TRAIN_ARGS has {', '.join(sorted(unknown))}; a segmentation run takes {', '.join(SEGMENT_DEFAULTS)}")
    random.seed(args["seed"])
    np.random.seed(args["seed"])
    torch.manual_seed(args["seed"])
    save_dir, data_dir = Path(save_dir), Path(data_dir)
    save_dir.mkdir(parents=True, exist_ok=True)
    device = pick_device(args["device"])
    tracks = [t for t in read_tracks(data_dir, states) if (t.labels >= 0).any()]
    split = {s: [t for t in tracks if t.split == s] for s in ("train", "val", "test")}
    if not split["train"] or not split["val"]:
        raise ValueError("the version needs checked machines in train and validation videos")
    backbone, dim = image_model(backbone_name)
    backbone = backbone.to(device).eval()
    cache = Path(save_dir).parent / "features" / f"{backbone_name}_{args['size']}_{args['padding']}"
    track_features(tracks, data_dir, cache, backbone, device, args["size"], args["padding"])
    for t in tracks:
        x = t.features.astype(np.float32)
        t.x = np.concatenate([x, motion_of(t)], 1) if args["motion"] else x
    # Every feature as the train frames have it: centred, and of about the same spread.
    stacked = np.concatenate([t.x for t in split["train"]])
    mean, std = stacked.mean(0), stacked.std(0) + 1e-6
    for t in tracks:
        t.x = (t.x - mean) / std
    width = tracks[0].x.shape[1]
    frames_of = {s: int(sum(len(t.frames) for t in split[s])) for s in split}
    print(f"{len(split['train'])} train, {len(split['val'])} validation and {len(split['test'])} test tracks "
          f"({frames_of['train']}, {frames_of['val']} and {frames_of['test']} frames); {backbone_name} on {device}")
    environment = {"host": socket.gethostname(), "python": platform.python_version(), "torch": torch.__version__,
                   "torchvision": torchvision.__version__, "opencv": cv2.__version__, "device": str(device)}
    labeler.started = time.time()
    labeler.send("start", {"args": {**args, "backbone": backbone_name, "states": states, "kind": "segmentation"},
                           "environment": environment, "epochs": args["epochs"]})

    model = Segmenter(width, len(states), args["stages"], args["layers"], args["channels"], args["dropout"])
    counts = np.bincount(np.concatenate([t.labels[t.labels >= 0] for t in split["train"]]), minlength=len(states))
    weight = torch.tensor(counts.sum() / (len(states) * np.maximum(counts, 1)), dtype=torch.float) if args["balance"] else None
    ce = nn.CrossEntropyLoss(weight=weight, ignore_index=-1)
    optimiser = torch.optim.AdamW(model.parameters(), lr=args["lr"], weight_decay=args["weight_decay"])

    def loss_of(outs, y, mask):
        total = 0.0
        for out in outs:
            total = total + ce(out.transpose(1, 2).reshape(-1, len(states)), y.reshape(-1))
            logp = torch.log_softmax(out, 1)
            jump = (logp[:, :, 1:] - logp.detach()[:, :, :-1]) ** 2
            total = total + args["smooth"] * (jump.clamp(0, 16) * mask[:, :, 1:]).mean()
        return total

    def windows():
        """Stretches of the train tracks, longer tracks more often; a short track whole, padded."""
        lengths = np.array([len(t.frames) for t in split["train"]], dtype=float)
        picks = np.random.choice(len(lengths), size=args["windows"], p=lengths / lengths.sum())
        n = args["window"]
        for i in range(0, len(picks), args["batch"]):
            xs, ys, ms = [], [], []
            for k in picks[i:i + args["batch"]]:
                t = split["train"][k]
                a = np.random.randint(0, max(1, len(t.frames) - n + 1))
                x, y = t.x[a:a + n], t.labels[a:a + n]
                pad = n - len(y)
                xs.append(np.pad(x, ((0, pad), (0, 0))))
                ys.append(np.pad(y, (0, pad), constant_values=-1))
                ms.append(np.pad(np.ones(len(y)), (0, pad)))
            yield (torch.tensor(np.stack(xs), dtype=torch.float).transpose(1, 2), torch.tensor(np.stack(ys), dtype=torch.long),
                   torch.tensor(np.stack(ms), dtype=torch.float).unsqueeze(1))

    @torch.no_grad()
    def evaluate(tracks_of):
        model.eval()
        losses, true, pred, edits, f1s = [], [], [], [], []
        for t in tracks_of:
            x = torch.tensor(t.x, dtype=torch.float).T.unsqueeze(0)
            y = torch.tensor(t.labels, dtype=torch.long).unsqueeze(0)
            mask = torch.ones(1, 1, x.shape[2])
            outs = model(x, mask)
            losses.append(float(loss_of(outs, y, mask)))
            p = outs[-1].argmax(1)[0].numpy()
            keep = t.labels >= 0
            true += t.labels[keep].tolist()
            pred += p[keep].tolist()
            edits.append(edit_score(p[keep], t.labels[keep]))
            f1s.append(segment_f1(p[keep], t.labels[keep]))
        found = scores(true, pred, len(states))
        found.update(loss=float(np.mean(losses)) if losses else 0.0, edit=float(np.mean(edits)) if edits else 0.0,
                     f1_50=float(np.mean(f1s)) if f1s else 0.0, frames=len(true), tracks=len(tracks_of))
        return found

    epochs, best, best_f1, waited = [], None, -1.0, 0
    for epoch in range(1, args["epochs"] + 1):
        model.train()
        total, seen = 0.0, 0
        for x, y, mask in windows():
            optimiser.zero_grad()
            loss = loss_of(model(x, mask), y, mask)
            loss.backward()
            optimiser.step()
            total += float(loss) * len(y)
            seen += len(y)
        val = evaluate(split["val"])
        figures = {"train/loss": round(total / max(1, seen), 6), "val/loss": round(val["loss"], 6),
                   "val/accuracy": round(val["accuracy"], 6), "val/macro_f1": round(val["macro_f1"], 6),
                   "val/edit": round(val["edit"], 4), "val/f1@50": round(val["f1_50"], 6),
                   "seconds": round(time.time() - labeler.started, 1)}
        for name, per in zip(states, val["per_state"]):
            if per["clips"]:
                figures[f"val/f1/{name}"] = round(per["f1"], 6)
        epochs.append({"epoch": epoch, "metrics": figures})
        labeler.send("epochs", {"epoch": epoch, "metrics": figures})
        print(f"epoch {epoch}: train loss {figures['train/loss']:.4f}, val frames: accuracy {val['accuracy']:.3f}, "
              f"macro F1 {val['macro_f1']:.3f}; segments: edit {val['edit']:.1f}, F1@50 {val['f1_50']:.3f}")
        if val["macro_f1"] > best_f1:
            best_f1, waited = val["macro_f1"], 0
            best = {"epoch": epoch, "state": {k: v.detach().clone() for k, v in model.state_dict().items()}}
        else:
            waited += 1
            if waited >= args["patience"]:
                print(f"No better validation F1 for {waited} epochs: stopping.")
                break

    model.load_state_dict(best["state"])
    test = evaluate(split["test"]) if split["test"] else None
    torch.save({"format": "labeler-segment-model", "backbone": backbone_name, "backbone_state": backbone.state_dict(),
                "size": args["size"], "padding": args["padding"], "motion": args["motion"], "width": width,
                "segmenter": {k: args[k] for k in ("stages", "layers", "channels", "dropout")},
                "segmenter_state": model.state_dict(), "mean": mean.tolist(), "std": std.tolist(), "states": states},
               save_dir / "segment_model.pth")
    about = {"kind": "segmentation", "states": states, "backbone": backbone_name, "size": args["size"],
             "padding": args["padding"], "motion": args["motion"], "best_epoch": best["epoch"],
             "validation": epochs[best["epoch"] - 1]["metrics"], "test": test}
    (save_dir / "segment_model.json").write_text(json.dumps(about, indent=2))
    with open(save_dir / "results.csv", "w") as f:
        keys = sorted({k for e in epochs for k in e["metrics"]})
        f.write(",".join(["epoch", *keys]) + "\n")
        for e in epochs:
            f.write(",".join([str(e["epoch"]), *(str(e["metrics"].get(k, "")) for k in keys)]) + "\n")
    if test:
        print(f"Test videos ({test['tracks']} tracks, {test['frames']} frames): accuracy {test['accuracy']:.3f}, macro F1 "
              f"{test['macro_f1']:.3f}, edit {test['edit']:.1f}, F1@50 {test['f1_50']:.3f}")
        for name, per in zip(states, test["per_state"]):
            print(f"  {name:20} F1 {per['f1']:.3f}  precision {per['precision']:.3f}  recall {per['recall']:.3f}  ({per['clips']} frames)")
    return SimpleNamespace(save_dir=save_dir, epochs=epochs, best_epoch=best["epoch"], test=test, states=states)


# ---- scoring a saved state model on a state version's clips: the trainer's own code reads them ----


def load_state_model(path, device):
    """A saved state model (state_model.pth): its image model and the small model on top, ready to read clips."""
    saved = torch.load(path, map_location="cpu", weights_only=False)
    if saved.get("format") != "labeler-state-model":
        raise ValueError(f"{path} is not a state model made by a state training run")
    backbone, _ = image_model(saved["backbone"], pretrained=False)
    backbone.load_state_dict(saved["backbone_state"])
    head = Temporal(saved["dim"], len(saved["states"]), saved["temporal"], saved["hidden"], saved["dropout"])
    head.load_state_dict(saved["head_state"])
    return saved, backbone.to(device).eval(), head.eval()


@torch.no_grad()
def score_clips(model_path, manifest_path, out_path, device=None):
    """Scores a state model on clips: the manifest lists each clip's file, split and true state (by name). Clips of a
    state the model does not know are counted apart. Prints `scored <n>` as it goes; writes the scores as JSON, with the
    clips it got wrong."""
    device = pick_device(device)
    saved, backbone, head = load_state_model(model_path, device)
    states = saved["states"]
    known = {name: i for i, name in enumerate(states)}
    clips = json.loads(Path(manifest_path).read_text())["clips"]
    true, pred, wrong, unknown = [], [], [], 0
    batch = 16
    for start in range(0, len(clips), batch):
        part = clips[start:start + batch]
        x = torch.stack([(read_clip(c["path"]) - MEAN) / STD for c in part])
        b, t = x.shape[:2]
        f = backbone(x.flatten(0, 1).to(device)).float().view(b, t, -1).cpu()
        p = head(f).softmax(1)
        for c, row in zip(part, p):
            guess = int(row.argmax())
            if c["truth"] not in known:
                unknown += 1
                continue
            true.append(known[c["truth"]])
            pred.append(guess)
            if guess != known[c["truth"]]:
                wrong.append({"filename": c["filename"], "split": c["split"], "truth": c["truth"], "predicted": states[guess],
                              "confidence": round(float(row[guess]), 4)})
        print(f"scored {min(start + batch, len(clips))}", flush=True)
    found = scores(true, pred, len(states))
    found.update(states=states, clips=len(true), unknown=unknown, device=str(device),
                 mistakes=sorted(wrong, key=lambda w: -w["confidence"])[:400])
    Path(out_path).write_text(json.dumps(found))


if __name__ == "__main__":
    score_clips(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)


# ---- a saved state model run on a pipeline's tracks (its Classify states node) ----


def union_box(boxes):
    """The box around every box of a clip, as the state version cut its clips around them."""
    b = np.asarray(boxes, dtype=float)
    return b[:, 0].min(), b[:, 1].min(), b[:, 2].max(), b[:, 3].max()


@torch.no_grad()
def classify_tracks(model_path, video, tracks, fps, every_s=1.0, clip_s=3.0, padding=0.15, device=None, batch=8):
    """Gives every frame of each track a state with a saved state model. `tracks`: {id: (frames, boxes)} of one
    video, frames in order (the video's own numbers), boxes as x1 y1 x2 y2. Returns {id: (state names, confidence)},
    one of each per frame.

    A segmentation model reads each whole track at once. A clips model judges a clip around a moment every `every_s`,
    each `clip_s` long and cut as the state version cut its clips (the same square around every box of the clip,
    `padding` of room); each frame takes the state of the clip nearest it."""
    device = pick_device(device)
    saved = torch.load(model_path, map_location="cpu", weights_only=False)
    states = saved["states"]
    backbone, _ = image_model(saved["backbone"], pretrained=False)
    backbone.load_state_dict(saved["backbone_state"])
    backbone = backbone.to(device).eval()
    if not tracks:
        return {}

    if saved.get("format") == "labeler-segment-model":
        model = Segmenter(saved["width"], len(states), **saved["segmenter"])
        model.load_state_dict(saved["segmenter_state"])
        model.eval()
        objs = [SimpleNamespace(video=Path(video).name, machine=str(i), split="", fps=fps, frames=np.asarray(f), boxes=np.asarray(b, dtype=float),
                                labels=np.full(len(f), -1)) for i, (f, b) in tracks.items()]
        track_features(objs, "", None, backbone, device, saved["size"], saved["padding"], video_path=video)
        mean, std = np.asarray(saved["mean"]), np.asarray(saved["std"])
        out = {}
        for t in objs:
            x = t.features.astype(np.float32)
            if saved["motion"]:
                x = np.concatenate([x, motion_of(t)], 1)
            x = torch.tensor((x - mean) / std, dtype=torch.float).T.unsqueeze(0)
            p = torch.softmax(model(x, torch.ones(1, 1, x.shape[2]))[-1], 1)[0]
            conf, idx = p.max(0)
            out[int(t.machine)] = ([states[i] for i in idx.tolist()], conf.numpy())
        return out

    if saved.get("format") != "labeler-state-model":
        raise ValueError(f"{model_path} is not a state model made by a state training run")
    head = Temporal(saved["dim"], len(states), saved["temporal"], saved["hidden"], saved["dropout"])
    head.load_state_dict(saved["head_state"])
    head.eval()
    frames_n, size = saved["frames"], saved["size"]
    half, slot = clip_s * fps / 2, clip_s * fps / frames_n
    # The clips of every track: a centre every so often, its frames the track's nearest to each slot of it.
    clips = []  # (track, centre, [frame], window)
    for i, (frames, boxes) in tracks.items():
        frames, boxes = np.asarray(frames), np.asarray(boxes, dtype=float)
        if len(frames) < frames_n:
            continue
        span = frames[-1] - frames[0]
        centres = np.arange(frames[0] + half, frames[-1] - half + 1, max(1.0, every_s * fps)) if span >= 2 * half else [frames[0] + span / 2]
        for c in centres:
            picked = []
            for k in range(frames_n):
                t = c - half + (k + 0.5) * slot
                j = int(np.abs(frames - t).argmin())
                if j in picked or abs(frames[j] - t) > max(slot, 1.0):
                    break
                picked.append(j)
            if len(picked) == frames_n:
                clips.append((i, float(c), [int(frames[j]) for j in picked], union_box(boxes[picked])))
    need = defaultdict(list)
    for n, (_, _, fs, _) in enumerate(clips):
        for k, f in enumerate(fs):
            need[f].append((n, k))
    found = {}  # clip -> (state, confidence)
    crops, filled, ready = {}, defaultdict(int), []

    def judge(ready):
        x = torch.stack([(torch.stack(crops.pop(n)) - MEAN) / STD for n in ready])
        b, t = x.shape[:2]
        f = backbone(x.flatten(0, 1).to(device)).float().view(b, t, -1).cpu()
        p = torch.softmax(head(f), 1)
        for n, row in zip(ready, p):
            found[n] = (int(row.argmax()), float(row.max()))

    cap = cv2.VideoCapture(str(video))
    last = max(need) if need else -1
    for f in range(last + 1):
        if not cap.grab():
            break
        if f not in need:
            continue
        try:
            ok, img = cap.retrieve()
        except cv2.error:
            ok = False
        if not ok:
            continue
        for n, k in need[f]:
            crop = cut_square(img, clips[n][3], padding, size)
            crops.setdefault(n, [None] * frames_n)[k] = torch.from_numpy(crop[:, :, ::-1].copy()).permute(2, 0, 1).float() / 255
            filled[n] += 1
            if filled[n] == frames_n:
                ready.append(n)
        if len(ready) >= batch:
            judge(ready)
            ready = []
    if ready:
        judge(ready)
    cap.release()

    out = {}
    for i, (frames, _) in tracks.items():
        mine = sorted((c, found[n]) for n, (t, c, _, _) in enumerate(clips) if t == i and n in found)
        if not mine:
            out[i] = (["unknown"] * len(frames), np.zeros(len(frames)))
            continue
        centres = np.array([c for c, _ in mine])
        nearest = np.abs(np.asarray(frames)[:, None] - centres[None, :]).argmin(1)
        out[i] = ([states[mine[j][1][0]] for j in nearest], np.array([mine[j][1][1] for j in nearest]))
    return out
