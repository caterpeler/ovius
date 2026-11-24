#!/usr/bin/env python3
"""Writes the box-track Parquet fixtures that BoxTrackParquetTests reads, from one real box file.

    python3 scripts/make-parquet-fixtures.py BOXES.parquet Tests/OviusTests/Fixtures

Needs pyarrow (pip install pyarrow). The real file is copied as it is; three variants of it cover what the GPU
worker's writer (pandas → pyarrow) does on bigger or differently configured files, with a value missing at row r of
column c whenever (r + c) % 7 == 0:

  boxes_v2.parquet           data pages v2 (definition levels outside the compressed part)
  boxes_fallback.parquet     a dictionary that overflows into plain pages, many small pages, several row groups
  boxes_plain.parquet        no dictionary and no compression

boxes_expected.json holds the real file's values, which the variants share apart from the missing ones.
"""

import json
import pathlib
import shutil
import sys

import pyarrow as pa
import pyarrow.parquet as pq

NULL_EVERY = 7


def with_nulls(table: pa.Table) -> pa.Table:
    columns = []
    for c, name in enumerate(table.column_names):
        values = table.column(name).to_pylist()
        values = [None if (r + c) % NULL_EVERY == 0 else v for r, v in enumerate(values)]
        columns.append(pa.array(values, type=table.schema.field(name).type))
    return pa.table(columns, names=table.column_names)


def main(source: str, out_dir: str) -> None:
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, out / "boxes_real.parquet")

    table = pq.read_table(source)
    holed = with_nulls(table)
    pq.write_table(holed, out / "boxes_v2.parquet", compression="snappy", data_page_version="2.0")
    pq.write_table(holed, out / "boxes_fallback.parquet", compression="snappy",
                   dictionary_pagesize_limit=256, data_page_size=1024, row_group_size=500)
    pq.write_table(holed, out / "boxes_plain.parquet", compression="none", use_dictionary=False)

    expected = {
        "null_every": NULL_EVERY,
        "columns": table.column_names,
        "values": {name: table.column(name).to_pylist() for name in table.column_names},
    }
    (out / "boxes_expected.json").write_text(json.dumps(expected, separators=(",", ":")))
    for path in sorted(out.iterdir()):
        print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
