# Task: cluster analyses and the team's metrics in Ovius

You are finishing **Ovius**, a native macOS app (SwiftUI) for a mine's supervisors and analysts. It is
separate from the labeler: it imports pipeline bundles made by the labeler, runs them on CCTV footage on the Mac,
keeps every analysis, and compares each new one with the average of earlier ones.

The user is working on a presentation in Keynote while you work. Keep the app's windows off their screen as much as
you can (see Constraints). The user likes short, scannable replies: lead with the answer.

## Where things are

- **App repo:** `/Users/kdwiheldy/Desktop/caterpler/Ovius`. It is a git repo with no commits yet. Read
  `README.md` first: it describes the layout, the library on disk, and how to build, test and run.
  - `Sources/OviusCore`: everything but the windows, and tested. It holds the SQLite database, records, the library on
    disk, bundle import, Python setup, the runner and the comparisons. It also holds `metrics.py`, which turns
    pipeline outputs into `metrics.json`.
  - `Sources/Ovius`: the SwiftUI app. It holds `AppModel` (the database, the run queue, imports, settings) and
    the views: Overview, Analyses, Pipelines, Cameras, Settings, and Import Results.
  - `swift test`: 12 tests pass today.
  - `scripts/build-app.sh` builds `build/Ovius.app`.
  - Setting `OVIUS_LIBRARY=/some/folder` runs the app on a library of its own.
- **The labeler**, at `/Users/kdwiheldy/Desktop/caterpler/labeler`, is a separate repo. **Do not change it.**
  - Its pipeline runner is `server/src/graph/run_pipeline.py`. A bundle's Productivity report node writes, into the
    run's output folder:
    - **`report.csv`**: one row per loading point (an excavator and the trucks it serves), then an `all` row.
    - **`events.csv`**: one row per event. Its columns are `kind` (`loading` or `queue`), `point`, `truck`, `start`,
      `end`, `start_s`, `end_s`, `duration_s`, `spot_s` and `complete`.
      - A `queue` row runs from the truck arriving in the loading area to its load starting, spotting included.
        `spot_s` is the spotting part.
      - `complete` is `False` when the video's start or end cut the event short.
    - **`review.json`**: every box, frame by frame, with each machine's state. `activity` and `coarse` index into
      `activities`.
  - Machine state is a simple motion rule, not a trained model: trucks are `moving` or `stopped`, excavators are
    `working` or `idle`.
- **The spreadsheet** at `/Users/kdwiheldy/Desktop/caterpler/labeler/mining_productivity_dashboard.xlsx` is the team's
  definition of what the dashboard must show. Read it with Python (`openpyxl`).

## What changed, and why this work

1. **Clusters.**
   - A site section, or cluster (for example Section Alpha), has several CCTV cameras. Each camera points at a
     different part of the section, and no two overlap.
   - The user uploads a **batch**: one video per camera of the same cluster, covering the same period. They type each
     video's start time by hand; prefill it from the file name, which the app already does.
   - The app analyses the batch and shows the **cluster's** result for that time: one row per camera, and the
     cluster as a whole.
   - Today the app has Site → Camera, and each video is its own analysis.
2. **Loads are counted by proximity alone.** A truck that comes close to an excavator, stays a while, then leaves
   counts as one load, or cycle. The trained state classification is no longer used.
3. **The dashboard shows the team's metrics** from the spreadsheet (below), not today's figures.
4. **The data stays genuine.** The dashboard shows only what the cameras actually saw: no simulated cycles, and no
   scaling up to a shift. This is the user's decision; see "Genuine data only" below.

## The spreadsheet

Use these sheets:

- **Recording Overview.** This is the main table: one row per recording (a camera's clip), and a
  `TOTAL / SHIFT AGGREGATE` row.
  - Visible columns A–M:
    - Load Cycles.
    - Mean Load Time (s), Load Time Stdev (s).
    - Mean Queue Time (s), Queue Time Stdev (s).
    - Excavator Mean Idle Time (s), Excavator Idle Time Stdev (s).
    - Dump Truck Mean Idle Time (s), Dump Truck Idle Time Stdev (s).
    - Volume Moved (m³).
    - Excavator Utilization %, Dump Truck Utilization %.
  - The total row uses formulas:
    - `SUM` for cycles, volume and duration.
    - `AVERAGEIF(cycles > 0)` for the load time mean and stdev.
    - Plain `AVERAGE` for the others.
  - Columns N–Z are hidden helper columns:
    - The section.
    - Observed complete cycles, and Monte Carlo imputed cycles. Use only the observed ones (see below).
    - The video's duration, PTZ (moving camera) yes or no, the excavator count and the distinct trucks.
    - Min struck and max heaped volume.
    - Fleet match factor. **Match factor is out of scope**: the team decided earlier that it needs the full truck
      haul cycle, which the cameras don't see.
- **Executive Summary.** The KPI cards:
  - Total material moved, with its basis ("56 loads × 51.1 m³").
  - Completed load cycles ("21 observed + 35 MC imputed"). The app shows the observed count only.
  - Mean load duration, with stdev and median.
  - Total queue delay ("55.1 min across 49 queued trucks").
  - Active shovel utilization.
  - Bypass trucks excluded: trucks that only drove past, which are not cycles.
  - Each section's Monte Carlo priors, and the imputation rule. Out of scope (see below).
- **Loading Cycles & Trips.** One row per truck cycle.
  - Times: `t_arrive`, `t_spot`, `t_load_start`, `t_load_end` and `t_depart`.
  - Durations: queue (`t_spot − t_arrive`), spotting, loading and pocket dwell.
  - The cycle's source, observed or MC imputed, and its raw status: `complete`, `in_progress` or `queued_only`.
  - Use this sheet to pin down the definitions, from its **Observed Complete** rows only.
- **Excavator Fleet.**
  - Utilization is effective working (loading plus bench prep or digging) divided by the effective horizon (the
    camera presence window).
  - Excavators are scoped to their clip: E1 in one clip is not E1 in another.
- **Out of scope:**
  - *Scoop Timings & Kinematics*: bucket passes need the dropped state classification.
  - *Pipeline Detection Audit*: this belongs to the labeler.
  - *DynamoDB Single-Table Schema*: the app uses SQLite.

**Genuine data only.** The spreadsheet's numbers are "amplified": trucks cut off by a clip's start or end
(`in_progress`, or `queued_only` at the end) are completed by Monte Carlo, sampling load times from the section's
observed loads. The team did this to estimate a whole afternoon shift. **The app does not do this, and does not scale
anything up to a shift either.** On the dashboard:

- A cycle counts only when the camera saw it **complete**: the truck arrived, was loaded, and left.
- A cycle the video cut short (loading already under way at the start, or not finished at the end) is **not** a
  completed cycle. Show it as a separate count, e.g. "14 completed, plus 2 cut off by the video". Leave it out of
  load-time averages, and never pad it with a simulated time.
- Leave out queue times whose start the camera didn't see.
- Volume moved comes from completed cycles only.
- Keep labeling the figures as estimates, with the hours the cameras saw: they come from what was in view, and the
  volume per load is an assumption.

**The clips are already in the user's library.** The sheet's clips `mock_sample_1` to `mock_sample_11` are the same
videos as analyses 1–11 in the user's real library, `~/Library/Application Support/ovius`. Each one's
pipeline outputs are in `analyses/<id>/out/<folder>/`, with `report.csv`, `events.csv` and `review.json`.

- Sections: **Alpha** is samples 1, 7 and 11; **Beta** is 2, 5, 6, 8 and 10; **Gamma** is 3, 4 and 9.
- Those outputs came from the host's tracks plus the labeler's default Loading events. Their states use no camera
  motion correction, and the team's sheet is partly hand-annotated. **Expect differences.** Compare and report them,
  but don't force-fit the numbers.

## Metric definitions

Pin these down by **reproducing the Recording Overview from the Trips sheet** (and Excavator Fleet for utilization)
in a test. Then implement the same definitions on the pipeline's events. Starting points:

- **Cycle:** a `loading` event with `complete=True`. An incomplete one is counted separately as cut off, never
  completed.
- **Load time:** a loading event's `duration_s`.
- **Queue time (sheet):** the matching queue's `duration_s − spot_s`. Match on the same truck and point, just before
  the load. Spotting is `spot_s`.
- **Excavator idle:** idle spells from the excavator's coarse state in `review.json`. Report the mean and stdev per
  spell, as the sheet does. `metrics.py` already finds spells with `runs()`.
- **Dump truck idle and utilization:** work these out from the Trips sheet. For example, check whether utilization
  is `(dwell − queue) / dwell`, and whether truck idle is the time stopped and not being loaded. Document what you
  settle on.
- **Excavator utilization:** working ÷ time in view. Today's `working_pct` is close; check it against Excavator Fleet.
- **Volume:** cycles × 51.1 m³ (setting `m3PerLoad`). Also show the range from struck to heaped: cycles × 42.1 to
  cycles × 60.1 m³, the per-load values behind the sheet's X and Y columns. Make both new settings.
- **Totals:** match the sheet's formulas, so the user's numbers line up with the team's.

**Cluster totals** need the whole batch. Add a **cluster-level metrics step** to `metrics.py` (stdlib only, Python
3.9 compatible) that runs once every camera in the batch is done, and works out the total row.

Find out from `loading_events` in the labeler's `run_pipeline.py` whether `events.csv` holds trucks that were only
queued when the video ended. It may only record waits that led to a load. If it does hold them, show them in the
"cut off by the video" count. Either way, say what you found in your report. Don't change the labeler.

## What to build

1. **Data model: Site → Cluster → Camera.**
   - Add the migration as a new numbered step in `Database.swift`.
   - Back up `ovius.sqlite` before migrating.
   - Keep every existing analysis working. The user's real library has 30 imported analyses under the site "Labeler
     host runs".
2. **Cluster analyses (batches).**
   - New Analysis: pick a cluster (or make one), then add videos. Each video gets a camera (pick or make one in that
     cluster) and a start time. Then pick a pipeline.
   - Each video runs through the existing queue. When all are done, the cluster metrics step runs.
   - Show the batch's status, including a partial failure (one camera failed).
   - **Import Results** must also take several result folders as one cluster analysis. You need this to load the 11
     samples as three clusters.
3. **The dashboard (batch detail).**
   - Executive Summary cards.
   - The Recording Overview table: one row per camera, then the cluster total; stdevs shown as ±.
   - Each camera's trips: arrive, spot, load start and end, queue and load, with cut-off trips marked as such.
   - "Against the average of earlier analyses of this cluster", reusing the hours-weighted `Comparison`.
4. **Overview page:** group by cluster.
5. **Settings:** volume per load (nominal, struck, heaped). Figure settings already trigger a recalculation of
   everything; keep that.
6. **Tests:**
   - The metric definitions against the spreadsheet's Observed Complete rows.
   - Cut-off cycles: counted separately, and never in averages or volume.
   - The migration on a copy of a library with data.
   - The batch flow end to end, with the fake-bundle pattern already in `Tests/OviusCoreTests`.
7. **README:** update it.

## Constraints

- **Stack:** macOS 14, Swift 5 language mode, no third-party packages, the system SQLite.
- **No downloads:** don't run the Python setup download, and don't `pip install`. `metrics.py` must run on
  `/usr/bin/python3`.
- **Don't touch the user's real library while developing.** Copy analyses 1–11's output folders into a library of
  your own and use `OVIUS_LIBRARY`. The real library changes only through the app's own migration, when the user next
  opens it.
- **Windows:**
  - Check views with `swift build` and screenshots of a `OVIUS_LIBRARY` window only when needed.
  - Close the app right after.
  - Never touch Keynote.
- **Repos:** don't commit, and don't change the labeler repo.
- **UI copy:** plain words, and figures marked as estimates with the hours observed. Nothing simulated or scaled.

## When you finish

Reply in short sections:

1. What you built.
2. What you tested, with the commands and their results.
3. Where the app's numbers differ from the spreadsheet's observed figures for mock_sample_1–11, and why.
4. What's missing or decided differently from this brief.
