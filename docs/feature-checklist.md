# Ovius feature checklist

Tick what should be in the app. Write anything different on the `Note:` line under an item.

The tag after each item says where it stands now:

- **Kept**: your team's feature, still in the app as it was.
- **New**: from the prototype, and in the app now.
- **Swapped out**: your team's old version, which the **New** item next to it replaced. Ticking it brings the old one back. Say in the note whether it should sit alongside the new one or replace it.
- **Not built**: from the prototype or proposed, and not in the app.
- **Mine**: something I added that neither of you asked for.

---

## 1. App layout

- [ ] **Icon rail on the far left: Dashboard, Clusters & Sections, and Settings at the foot.** *New: the first version's rail, now with your team's pages.*
  - Note:
- [ ] **Three columns: rail, list column, main area.** *Kept as a layout. The rail replaces the old text sidebar.*
  - Note:
- [ ] **Help › Component Gallery: every design component on one page.** *Mine, a design review tool.*
  - Note:
- [ ] **`--fleet` launch flag: only the charts, on sample data, offline. It has no rail.** *Mine, a review tool.*
  - Note:
- [ ] **`--shell-preview` launch flag: the whole window on generated data, without touching your library, cache or the cloud.** *Mine, a review tool.*
  - Note:

## 2. Recordings column (Dashboard tab)

- [ ] **Cluster picker.** *Kept, restyled as a pill.*
  - Note:
- [ ] **Section and camera filters.** *Kept.*
  - Note:
- [ ] **Search clips, cameras, locations.** *Kept.*
  - Note:
- [ ] **Date range: presets, plus custom From/To in UTC. Defaults to last month.** *Kept.*
  - Note:
- [ ] **List of 25 at a time with "Load more", Select all, and a selected count.** *Kept.*
  - Note:
- [ ] **A changed selection waits for a Refresh bar before loading.** *Kept.*
  - Note:
- [ ] **Recording cards as in the prototype: status tag (Unusual / Below target / Balanced), cycles, rate, and EEU bars.** *New. Figures appear once a recording's telemetry has been loaded.*
  - Note:
- [ ] **A click shows that recording straight away. ⌘-click or the box adds it to a selection, which the Refresh bar then shows.** *New.*
  - Note:
- [ ] **This column in the new look.** *New.*
  - Note:

## 3. Dashboard: status messages

- [ ] **Sync error banner, too-much-data warning, and loading progress.** *Kept.*
  - Note:
- [ ] **"No recording selected" message.** *Kept.*
  - Note:

## 4. Dashboard: figures

- [ ] **Summary banner: the one finding that matters most.** Examples: trucks arrive in waves, one camera queues far more, below target, on target. *New.*
  - Note:
- [ ] **Throughput card.** Shows cycles, cycles per hour, cycles per clip and passes per cycle. Also the mean cycle time ± σ, and how a cycle splits into queue, load, spot and depart. *New.*
  - Note:
- [ ] **Idle and bunching card.** Excavator idle and truck idle, each as mean and σ, and whether trucks bunch up. *New.*
  - Note:
- [ ] **Utilisation (EEU) card.** Excavator and truck EEU, and the gap between them. *New.*
  - Note:
- [ ] **Shift timeline.** Bars show cycles per hour and dots show mean queue, in 15, 30 or 60-minute bins. Clicking a bin filters the cycles below. A strip shows how many clips cover each bin when clip lengths differ. *New.*
  - Note:
- [ ] **Each machine.** A tile per excavator and per truck with its EEU, cycles, and load or queue time. Clicking a tile filters the cycles. *New.*
  - Note:
- [ ] **Your team's three metric cards.** These are cycles & passes, idle time, and EEU in the old style. *Swapped out: the cards above replace them.*
  - Note:

## 5. Data Explorer

- [ ] **Breadcrumb: All recordings › one recording.** *New.*
  - Note:
- [ ] **With several recordings picked, a side-by-side table.** Each row has its length, cycles, rate, EEU bars, passes, queue and load, and opens that recording's cycles. *New.*
  - Note:
- [ ] **Cycle list, one row per cycle.** Each row has the time in the video, truck → excavator, a flag, and a bar split into the cycle's phases. It also has queue, load, passes, total and confidence. *New.*
  - Note:
- [ ] **Quick filters: All, Outliers (or Over target), Long queue, Unsure (< 0.70).** Each shows its count. *New.*
  - Note:
- [ ] **Excavator and truck filters, search, and sorting by time, total, queue or passes.** The list shows 50 more at a time. *New.*
  - Note:
- [ ] **Incomplete cycles are listed but never flagged.** *Mine.*
  - Note:
- [ ] **Narrow windows hide the Load and Confidence columns.** *Mine.*
  - Note:
- [ ] **"Open Timings": every machine state in a cycle.** Each state has its machine, start, end, duration and confidence, with low-confidence states marked. *Swapped out.*
  - Note:
- [ ] **Scoop pass table with the gap between scoops.** *Swapped out. The cycle panel shows passes, but without the gaps.*
  - Note:
- [ ] **Raw times per cycle: arrive, spot, load start, load end, depart.** *Swapped out.*
  - Note:
- [ ] **The old explorer's toolbar.** It sorts by date, cycles, passes, queue, load or camera. It filters by complete or incomplete status, by excavator or truck, and by section, and searches by ID. *Swapped out. Only the new filters above are there.*
  - Note:
- [ ] **Count of unsure states per cycle.** *Swapped out. The new list shows the lowest confidence instead.*
  - Note:

## 6. Cycle detail panel (opens at the side)

- [ ] **Header: camera, cycle number, time in the video, section, location.** *New.*
  - Note:
- [ ] **Phase cards: queue, load, spot, depart, total.** *New.*
  - Note:
- [ ] **Pass by pass: duration, time so far, passes done, confidence.** *New.*
  - Note:
- [ ] **A one-line assessment of why the cycle is (or isn't) flagged.** *New.*
  - Note:
- [ ] **Video frame of the moment.** *Not built. The video and box endpoints aren't live yet, so a placeholder note shows instead.*
  - Note:
- [ ] **This cycle's machine states as a small timeline, to bring "Open Timings" back here.** *Not built.*
  - Note:

## 7. Targets (SLA)

- [ ] **Each cluster has four optional targets.** They are least excavator EEU, least truck EEU, longest queue and longest cycle, set in the cluster editor. *New.*
  - Note:
- [ ] **A cluster with no targets is judged by its own spread.** Something is flagged when it is far above its usual level (mean + 1.5σ). *New.*
  - Note:
- [ ] **Each target that is set shows how the selection compares.** Header chips, ticks on bars, a line on the timeline, and red where it is missed. *New.*
  - Note:
- [ ] **The prototype's Statistical / Targets switch on the dashboard.** *Not built: the cluster's targets decide.*
  - Note:
- [ ] **A Targets button on the dashboard that edits the current cluster's targets.** *New.*
  - Note:
- [ ] **A targets panel with "Edit Targets" on the Clusters & Sections page.** *New.*
  - Note:
- [ ] **The prototype's target steppers on the dashboard.** *Not built.*
  - Note:
- [ ] **Targets per section, not only per cluster.** *Not built.*
  - Note:

## 8. Clusters & Sections tab

- [ ] **Add, edit and delete clusters.** *Kept. The editor now also has Targets.*
  - Note:
- [ ] **Add, edit and delete sections with their recording selectors.** Selectors are camera IDs, locations, tags, filenames and assigned trucks. *Kept.*
  - Note:
- [ ] **Test a section's selectors against AWS.** *Kept.*
  - Note:
- [ ] **The prototype's section cards.** Each section shows cycles, rate, both EEUs, each camera with a status, and an "Open this section's clips" button. *Not built.*
  - Note:
- [ ] **Restyle this tab in the new look.** *Not built.*
  - Note:

## 9. Settings tab

- [ ] **AWS endpoint.** Main and fallback URLs, timeout, Test connection, Reset, Save. *Kept.*
  - Note:
- [ ] **Offline cache: size, refresh, clear.** *Kept.*
  - Note:
- [ ] **Restyle this tab in the new look.** *Not built.*
  - Note:

## 10. Look and feel

- [ ] **New design system: warm grey, white cards, sage accent, pill controls.** *New on the dashboard only.*
  - Note:
- [ ] **Dark mode.** *New on the dashboard only.*
  - Note:

## Anything missing?

Add what isn't listed here:

-
