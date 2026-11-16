# Ovius

A Mac app for a mine's supervisors and analysts. It runs its own pipeline on CCTV footage, here on the Mac, works
out the team's figures (those of `mining_productivity_dashboard.xlsx`) for each section of the mine, and keeps every
run, so each new one is compared with the average of the earlier ones.

The pipeline is built in: the labeler's runner and its "Loading productivity (PTZ)" steps come with the app. What it
takes from the labeler are its models: the detector (a model's or a pipeline's bundle), and optionally a state model
for the excavators' states. It also takes folders of results a pipeline wrote elsewhere.

## Build and run

Needs macOS 14 or newer and Xcode (or its command line tools).

    swift run Ovius          # while working on it
    swift test                     # the core's tests
    scripts/build-app.sh           # build/Ovius.app, to open or copy to /Applications

`OVIUS_LIBRARY=/some/folder swift run Ovius` runs it on a library of its own, leaving the usual one alone.

## Clusters, cameras and runs

A **cluster** is a section of the mine, such as Section Alpha, with several CCTV cameras, each watching a different
part of it, none overlapping. A **run** takes one video from each camera, covering the same period, and gives the
cluster's figures for that time: a row per camera, and the cluster as a whole. Runs are not told apart by where they
were made or by which pipeline: a run made here and one imported from elsewhere are compared alike.

## Using it

1. **Settings → Models** (⌘,): choose the **detector**: a model's or a pipeline's bundle from the labeler (its
   `.tar.gz`, or the folder it unpacks to), which holds the model, its classes and its preprocessing; or a D-FINE
   `.pth` with its `.dfine.json` beside it. It is copied into the library. Optionally, a **state model**
   (`state_model.pth` or `segment_model.pth` from the labeler's state training) for the excavators' states.
2. **New Analysis** (⌘N): pick the cluster (or make one: its name), then the videos, one per camera. Each
   video gets a camera of the cluster (picked, or made: it is named after the file) and its start, the camera's clock
   at the first frame, read from the file name (`20240202160056`, `20240202_160056` or `2024-02-02-16-00-56`); it can
   be typed or left empty. Each video is copied into the library, and the built-in pipeline runs on it.
3. The cameras' videos run one at a time. The first run downloads Python and installs the pipeline's packages
   (PyTorch and the rest, a few GB, once). When every camera is done (or has failed, or was stopped), the cluster's
   figures are worked out. A run with a failed camera shows the others' figures and says which one failed; that camera
   can be run again from the run's page, with the models the library has then.
4. **Import Results** (⇧⌘R) takes what a pipeline wrote elsewhere, a folder per camera (report, events and
   `review.json`), as one run, the same way. From the command line, without a window:

       Ovius --cluster "Section Alpha" \
           --import-results out/north__… [--camera North] [--start "2024-02-02 16:00:56"] [--video north.mp4] \
           --import-results out/south__… …

   The models can be set the same way: `Ovius --detector BUNDLE`, `--state-model FILE`, `--no-state-model`;
   `--print-pipeline` prints the `pipeline.json` a new analysis would run.

### The pipeline

Each camera's video goes through the labeler's "Loading productivity (PTZ)" steps, with the labeler's settings:
detect (the library's detector, its preprocessing included), camera motion, still views, track, re-link after
camera moves, fill gaps, machine state, loading events and the productivity report, writing `review.json` too.

The only optional part is the state model. Without one, an excavator is working or idle by how its box moves, which
is all the figures need. With one, a Classify states step after Machine state gives each excavator the model's states
(a clips model judges a clip every second; a temporal segmentation model labels whole tracks); its idle states
(Settings, `idle` by default) count as idle and the rest as working, and the run's page shows each excavator's time
in each state.

A video runs with the models the library has when it starts; they cannot change while a video is running.

## What it shows

Every figure is an estimate from what the cameras saw, and the app says how many hours of footage that was. Counts
are of the footage: they are not scaled up to a shift. Observed and estimated cycles are always shown apart.

**A run** (the team's sheet, worked out from the pipeline's events):

- **The eight cards**, as on the Dashboard; the averages against the cluster's earlier runs, each weighted by its hours (counts are not compared: they follow the hours). Material moved is cycles ×
  51.1 m³ (Settings, with struck 42.1 m³ and heaped 60.1 m³ in the Recording overview).
- **Recording overview**, laid out as the team's: a numbered row per camera and the cluster's total: load cycles (the
  estimated ones said beside), load, queue and idle time (the excavators'; the dump trucks' under the pointer), each
  as mean and standard deviation, excavator and dump truck utilisation, and volume moved.
  The total follows the sheet's formulas: sums for cycles and volume, the mean load time of the cameras with cycles,
  and plain averages for the rest.
- **Excavator states**, with a state model: each excavator's share of its time in each state.
- **How estimated cycles are completed:** what each camera's estimated load times were drawn from.
- **Trips:** each camera's cycles, truck by truck: arrived, spotting, loading, queue, spot and load times, observed or
  estimated.
- Each camera's status, what went wrong, and what its pipeline printed.

The window has three places: **Dashboard**, **Clusters** and **Simulation** (not built yet). It has no title bar or
toolbar: each page's heading says what it is, with its actions on the right and a back arrow (⌘[) where there is a
way back.

**Dashboard** (the app opens on it): every finished run together, over a day, a week, a month or all of them. Eight cards, two rows of four: load cycles, material moved, excavator and dump truck
utilisation, load cycles and material moved per hour, load time and idle time (the excavators', with the dump trucks'
beside it); the hours covered and of footage are in the heading. Explanations show under the pointer, on the ⓘ beside
a heading or on a card's comparison. A day, week or month is compared with the last one before it that has runs: counts as
they are, the rest averaged over the hours. Below them: one figure run by run (a line per cluster), each cluster side
by side, and the latest runs. A run's day is its cameras' clock, or the day it was added when that is unknown.

**Flags.** A run is flagged, with an orange flag and how many on its row, the cards concerned marked and a list at
the top of its page, for:

- a figure (cycles per hour, load, queue and idle times, excavator and dump truck utilisation) unlike its cluster's
  other runs, or every other run: outside their quartiles widened by 1.5 times the spread between them (the box plot's
  whiskers), and at least 10% (5 points for a share) from their median. It takes 4 other runs to know what is usual;
- a camera that failed or was stopped, saw no excavator, or saw excavators but no load cycles (marked in the
  Recording overview too); more than half the cycles estimated; a camera's footage under half the longest's.

Flags are worked out as the page is shown, so they change as runs are added. The Dashboard's heading says how many
runs are flagged.

**Clusters**, one level after another:

1. every cluster, each with its latest run's figures (load cycles, material moved, excavator use, cycles per hour);
2. a cluster: its runs together in the eight cards; its runs as a month's calendar (each day's runs, green when
   clean, orange when flagged, red with a camera failed, and a dashed "No run" on each day since the first run without
   one) or as a list (each with those figures, against the runs before it); one figure run by run; and its cameras (to
   rename or delete). A run's day is its cameras' clock, or the day it was added when that is unknown;
3. a run: its page, as above.

Settings (⌘,) holds the models (above), the volume of a load (nominal, struck and heaped), how long a loading point must be seen to count
as an excavator, the device (Apple GPU or CPU) and the Python used. When a figure setting changes, the app works out
every run's figures again.

## The figures

As the team's sheet defines them (its Recording Overview reproduces from its own trips and excavators, in
`SheetTests`):

- **Cycle:** a loading event of the pipeline: a truck that stopped beside an excavator, stayed, and left. Seen to start
  and end, it is **observed**; cut short by the video's start or end (or a big camera move), it is **estimated**.
- **Load time:** the loading event's length.
- **Queue time:** the wait before the load (the same truck, at the same point, ending as the load starts), without its
  spotting: from coming into the loading area to starting to move into place. A wait starts no earlier than the same
  truck's last load there ended. Its mean is of the trucks that queued.
- **Dump truck idle:** every cycle's queue time, a truck that did not queue counting as none.
- **Dump truck utilisation:** spotting and loading, over queueing, spotting and loading, every cycle's added up.
- **Excavator idle:** each excavator's time idle in the footage (its motion state, from `review.json`); the mean and
  standard deviation are over the cluster camera's excavators. An excavator is a labeler loading point seen for at
  least 5 minutes (Settings), or one that loaded a truck.
- **Excavator utilisation:** working over time in view, every excavator's added up. An estimated load's unseen part
  counts towards both.
- **Volume:** cycles × the volume of a load.
- Standard deviations are of a sample (0 for one value).

**Estimated cycles.** An estimated cycle's load time is drawn from a normal distribution of the camera's own complete
loads (two or more, not all the same), else the cluster's complete loads (two or more), else every load the cluster's
cameras saw; truncated to ±0.45 σ of the mean, and never under what the camera saw of it (a load seen longer than any
drawn keeps what was seen). Each camera's draws use its analysis's ID as the seed, so the same analysis always gives
the same figures.

Not counted: trucks still waiting when a video ended. The labeler's Loading events only records a wait that led to a
load, so these (the sheet's `queued_only` cycles) are not in `events.csv`. Nor is the fleet match factor (it needs the
trucks' whole haul cycle) or bucket passes (not worked out, even with a state model).

## How it works

    Sources/OviusCore/          everything but the windows (tested)
      BuiltInPipeline.swift  the detector and the state model in the library, and the pipeline.json each run gets
      pipeline/              the built-in pipeline's code: run.sh, the labeler's run_pipeline.py, run_workflow.py,
                             state_models.py, D-FINE's code (dfine/) and requirements.txt
      Database.swift         SQLite (the system's), with numbered migration steps; the library is copied first
      Records.swift          sites, clusters, cameras, pipelines, batches, analyses, settings, and their figures
      Store.swift            the records in the database: clusters, cameras, batches and their analyses
      Library.swift          where things are kept; the camera's clock read from file names
      Tools.swift            short commands; what a folder of results holds
      PythonSetup.swift      downloads a standalone CPython 3.12 (python-build-standalone) and checks its SHA-256
      Runner.swift           runs the pipeline's run.sh, reads its progress, and runs metrics.py for a camera and a cluster
      Comparison.swift       the figures compared, and their hours-weighted averages
      metrics.py             the team's figures from report.csv, events.csv and review.json (stdlib, Python 3.9+)
    Sources/Ovius/     the SwiftUI app: AppModel (the database, the queue) and the views
    Tests/OviusCoreTests/       the core's tests; Fixtures/sheet.json is the team's sheet (scripts/sheet-fixture.py)

Each camera's video is run as follows:

1. The app writes the camera's `pipeline.json` (the steps, the detector's and the state model's paths in the
   library) and runs `bash pipeline/run.sh VIDEO --pipeline pipeline.json --out OUT --review --device mps
   [--start …]`, with `OVIUS_VENV` set to the library's `venv/`, `OVIUS_PYTHON` to the app's Python and
   `OVIUS_REQUIREMENTS` to `models/requirements.txt` (the pipeline's packages, and any its detector's preprocessing
   imports). run.sh installs them the first time, and again when they change.
2. It then runs `python metrics.py OUT settings.json metrics.json`: the camera's cycles and excavators, as seen.

Once every camera of the cluster analysis is over, it runs `python metrics.py --cluster cluster.json metrics.json`:
the cycles cut short completed, and the team's figures for each camera and the cluster.

The library is kept in `~/Library/Application Support/ovius`:

    ovius.sqlite            sites, clusters, cameras, pipelines, batches (cluster analyses), analyses and their figures
    ovius.sqlite.before-step-N   the library as it was before the app last changed its database
    models/              the detector (detector/: detector.json and its model files), the state model (states/),
                         and requirements.txt
    analyses/<id>/       a camera's copied video, out/, settings.json, metrics.json, run.log
    batches/<id>/        a cluster analysis's cluster.json and metrics.json
    python/              the app's Python
    venv/                the pipeline's packages

A library from before clusters is brought forward when the app opens it: it is copied to
`ovius.sqlite.before-step-2`, each camera becomes a cluster of its own (of the same name), each analysis a cluster
analysis of one camera, and every analysis's figures are worked out again with these definitions.

The pipeline's code is the labeler's, copied by `scripts/update-pipeline.sh [LABELER] [DFINE]` (the labeler's
checkout, and a D-FINE checkout or a bundle's `dfine/` folder); it changes nothing in the labeler.

For a presentation, `scripts/demo.sh` makes a demo library beside the usual one (which it does not touch) and opens
the app on it. Its results are made up by `scripts/demo-data.py`, and the app works the figures out from them as from
any run's. Section B has a run a day, 2–10 Nov, each five cameras over a 12 h shift:

- 10 Nov: the team's slide, its Recording Overview row for row (row 2's volume follows its 402 cycles);
- 2 and 3 Nov: ordinary days around it;
- 4 Nov: long queues (flags queue time, idle times and both utilisations);
- 5 Nov: no run, a gap in the calendar;
- 6 Nov: camera 3's view of the trucks blocked (flags a camera with no load cycles);
- 7 Nov: camera 5's video unreadable (a failed camera, and figures off with it gone);
- 8 Nov: camera 2's recorder stopped after 4 h (flags short footage);
- 9 Nov: the cameras kept moving and cut most loads short (flags mostly estimated cycles).

Section A has five ordinary days of another section, so that what is usual across all clusters is not Section B's
alone.

To check a page while working on it without opening a window, `Ovius --snapshot page.png [--clusters |
--cluster ID | --batch ID] [--width 1100] [--dark]` renders the Dashboard, a run or a cluster to a PNG (menus show as
placeholders). `OVIUS_BACKGROUND=1` opens the window without bringing the app to the front.

## Not yet

These are not built yet:

- Simulation;
- the pipeline's settings (they are the labeler's defaults);
- trucks still waiting when a video ended (it needs the labeler to report them);
- moving a camera to another cluster once it has analyses;
- each loading point's day as a timeline;
- a player that jumps to a load or a wait in the video;
- trends over days;
- a PDF report;
- an app icon.
