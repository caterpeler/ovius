"""The team's spreadsheet as the tests' fixture: its trips and excavators as metrics.py's --rows input, and the
Recording Overview and Executive Summary figures they should give.

    python3 scripts/sheet-fixture.py ../labeler/mining_productivity_dashboard.xlsx Tests/OviusCoreTests/Fixtures/sheet.json

Needs openpyxl (the app itself does not)."""

import json
import re
import sys

import openpyxl


def table(ws, header_row):
    names = [c.value for c in ws[header_row]]
    out = []
    for row in ws.iter_rows(min_row=header_row + 1, values_only=True):
        if row[0] is None:
            continue
        out.append(dict(zip(names, row)))
    return out


def number(text):
    return float(text.replace(",", ""))


def main(xlsx, out):
    wb = openpyxl.load_workbook(xlsx, data_only=True)
    overview = [r for r in table(wb["Recording Overview"], 4) if str(r["Recording (ID)"]).startswith("mock_sample")]
    total = next(r for r in table(wb["Recording Overview"], 4) if r["Recording (ID)"] == "TOTAL / SHIFT AGGREGATE")
    trips = table(wb["Loading Cycles & Trips"], 4)
    fleet = table(wb["Excavator Fleet"], 4)

    cameras = []
    for r in overview:
        clip = r["Recording (ID)"]
        cameras.append({
            "name": clip,
            "section": r["Site Section"],
            "duration_s": r["Video Duration (s)"],
            "cycles": [{"point": t["Loader Machine"], "truck": t["Truck Label"], "arrive_s": t["t_arrive (s)"], "spot_at_s": t["t_spot (s)"],
                        "load_start_s": t["t_load_start (s)"], "load_end_s": t["t_load_end (s)"], "wait_s": t["Queue Delay (s)"] or 0.0,
                        "spot_s": t["Spotting Dur (s)"] or 0.0, "load_s": t["Loading Dur (s)"], "complete": t["Raw Status"] == "complete",
                        "estimated": t["Cycle Source"] != "Observed Complete", "status": t["Raw Status"]}
                       for t in trips if t["Clip ID"] == clip],
            "excavators": [{"point": e["Machine ID"], "working_s": e["Effective Working (s)"], "seen_s": e["Effective Horizon (s)"],
                            "idle_s": e["Idle Dur (s)"]} for e in fleet if e["Clip ID"] == clip],
        })

    columns = {"cycles": "Load Cycles", "load_s_mean": "Mean Load Time (s)", "load_s_stdev": "Load Time Stdev (s)",
               "queue_s_mean": "Mean Queue Time (s)", "queue_s_stdev": "Queue Time Stdev (s)",
               "excavator_idle_s_mean": "Excavator Mean Idle Time (s)", "excavator_idle_s_stdev": "Excavator Idle Time Stdev (s)",
               "truck_idle_s_mean": "Dump Truck Mean Idle Time (s)", "truck_idle_s_stdev": "Dump Truck Idle Time Stdev (s)",
               "volume_m3": "Volume Moved (m³)", "excavator_util": "Excavator Utilization %", "truck_util": "Dump Truck Utilization %",
               "observed": "Observed Complete Cycles", "estimated": "MC Imputed Cycles", "volume_struck_m3": "Min Struck Volume (m³)",
               "volume_heaped_m3": "Max Heaped Volume (m³)", "excavators": "Excavator Count"}
    pick = lambda r: {k: r[v] for k, v in columns.items() if r.get(v) is not None}

    cards = {c.value.split("\n")[0]: c.value.split("\n")[1:] for row in wb["Executive Summary"].iter_rows() for c in row
             if isinstance(c.value, str) and "\n" in c.value}
    load = cards["MEAN LOAD DURATION"]
    queue = cards["TOTAL QUEUE DELAY"]
    summary = {
        "volume_m3": number(re.search(r"([\d,.]+) m³", cards["TOTAL MATERIAL MOVED"][0]).group(1)),
        "volume_observed_m3": number(re.search(r"Raw obs: ([\d,.]+)", cards["TOTAL MATERIAL MOVED"][1]).group(1)),
        "cycles": int(re.match(r"(\d+)", cards["COMPLETED LOAD CYCLES"][0]).group(1)),
        "observed": int(re.match(r"(\d+) observed", cards["COMPLETED LOAD CYCLES"][1]).group(1)),
        "estimated": int(re.search(r"\+ (\d+) MC", cards["COMPLETED LOAD CYCLES"][1]).group(1)),
        "load_s_mean": number(re.match(r"([\d.]+)", load[0]).group(1)),
        "load_s_stdev": number(re.search(r"Stdev: ([\d.]+)", load[1]).group(1)),
        "load_s_median": number(re.search(r"Median: ([\d.]+)", load[1]).group(1)),
        "queue_total_s": number(re.match(r"([\d.]+)", queue[0]).group(1)),
        "queued_trucks": int(re.search(r"across (\d+)", queue[1]).group(1)),
        "excavator_util_pct": number(re.match(r"([\d.]+)%", cards["ACTIVE SHOVEL UTIL."][0]).group(1)),
    }
    fixture = {
        "source": "mining_productivity_dashboard.xlsx (labeler repo): Recording Overview, Loading Cycles & Trips, Excavator Fleet, Executive Summary",
        "settings": {"m3_per_load": 51.1, "m3_struck": 42.1, "m3_heaped": 60.1},
        "cameras": cameras,
        "expected": {"rows": {r["Recording (ID)"]: pick(r) for r in overview}, "total": pick(total), "summary": summary},
    }
    with open(out, "w") as f:
        json.dump(fixture, f, indent=1, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main(*sys.argv[1:3])
