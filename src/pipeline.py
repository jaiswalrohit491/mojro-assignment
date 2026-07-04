#!/usr/bin/env python3
"""
ExecuteWyse fleet telemetry ETL pipeline.

Reads raw telemetry + master data, cleans it (with a data-quality audit log),
builds a star-schema dimensional model in DuckDB, detects anomalies, and exports
analytics-ready tables to CSV + Parquet for Power BI.

Usage:
    python src/pipeline.py
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import duckdb

ROOT      = Path(__file__).resolve().parents[1]
RAW_DIR   = ROOT / "data" / "raw"
SQL_DIR   = ROOT / "sql"
OUT_DIR   = ROOT / "output"
EXPORTS   = OUT_DIR / "exports"
DB_PATH   = OUT_DIR / "fleet.duckdb"

SQL_STEPS = [
    "01_staging_dq.sql",
    "02_dimensions.sql",
    "03_anomalies.sql",
    "04_facts.sql",
]

# tables exported for Power BI etc, kept in load order
EXPORT_TABLES = [
    "dim_customer", "dim_vehicle", "dim_driver", "dim_date", "dim_time",
    "fact_daily_vehicle_summary", "fact_trip_summary", "fact_anomaly_events",
    "dq_log",
]


def split_statements(sql: str) -> list[str]:
    """Split a SQL script on ';', ignoring '--' and '/* */' comments and strings."""
    out, buf, in_str, in_line_comment, in_block_comment = [], [], False, False, False
    prev = ""
    for ch in sql:
        if in_line_comment:
            buf.append(ch)
            if ch == "\n":
                in_line_comment = False
            prev = ch
            continue
        if in_block_comment:
            buf.append(ch)
            if ch == "/" and prev == "*":
                in_block_comment = False
                prev = ""  # avoid '*/' + '/' misreads
                continue
            prev = ch
            continue
        if not in_str and ch == "-" and prev == "-":
            in_line_comment = True
            buf.append(ch)
            prev = ch
            continue
        if not in_str and ch == "*" and prev == "/":
            in_block_comment = True
            buf.append(ch)
            prev = ch
            continue
        if ch == "'":
            in_str = not in_str
        if ch == ";" and not in_str:
            stmt = "".join(buf).strip()
            if stmt:
                out.append(stmt)
            buf = []
        else:
            buf.append(ch)
        prev = ch
    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return out


def run_sql_file(con: duckdb.DuckDBPyConnection, path: Path) -> None:
    """Execute every statement in a .sql file after substituting path tokens."""
    sql = path.read_text().replace("@RAW@", RAW_DIR.as_posix())
    for stmt in split_statements(sql):
        con.execute(stmt)


def main() -> int:
    EXPORTS.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()

    # in-memory so the ~1.6M-row staging tables don't bloat the on-disk file;
    # only the final model gets written out below
    con = duckdb.connect()
    t0 = time.time()

    for step in SQL_STEPS:
        st = time.time()
        run_sql_file(con, SQL_DIR / step)
        print(f"  [ok] {step:22s} ({time.time() - st:5.1f}s)")

    for tbl in EXPORT_TABLES:
        con.execute(
            f"COPY (SELECT * FROM {tbl}) TO '{(EXPORTS / (tbl + '.csv')).as_posix()}' "
            f"(HEADER, DELIMITER ',')"
        )
        con.execute(
            f"COPY (SELECT * FROM {tbl}) TO "
            f"'{(EXPORTS / (tbl + '.parquet')).as_posix()}' (FORMAT PARQUET)"
        )
    print(f"  [ok] exported {len(EXPORT_TABLES)} tables -> {EXPORTS.relative_to(ROOT)}")

    # only the model + audit log + speed-limit reference go into the shipped db
    con.execute(f"ATTACH '{DB_PATH.as_posix()}' AS ship")
    for tbl in EXPORT_TABLES + ["ref_speed_limit"]:
        con.execute(f"CREATE TABLE ship.{tbl} AS SELECT * FROM {tbl}")
    con.execute("DETACH ship")
    print(f"  [ok] wrote database -> {DB_PATH.relative_to(ROOT)}")

    print("\n" + "=" * 60 + "\nDATA QUALITY LOG\n" + "=" * 60)
    print(con.sql(
        "SELECT check_name, records_affected, action, detail "
        "FROM dq_log ORDER BY rowid"
    ).df().to_string(index=False))

    print("\n" + "=" * 60 + "\nTABLE ROW COUNTS\n" + "=" * 60)
    for tbl in EXPORT_TABLES:
        n = con.sql(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
        print(f"  {tbl:32s} {n:>12,}")

    print("\n" + "=" * 60 + "\nANOMALY BREAKDOWN\n" + "=" * 60)
    print(con.sql(
        "SELECT anomaly_type, severity, COUNT(*) AS n "
        "FROM fact_anomaly_events GROUP BY 1, 2 ORDER BY 1, 2"
    ).df().to_string(index=False))

    con.close()
    print(f"\nDone in {time.time() - t0:.1f}s. Database: {DB_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
