#!/usr/bin/env python3
"""
Load the star schema from output/fleet.duckdb into a Neon (Postgres) database
so Power BI Service can consume it via the native PostgreSQL connector.

Uses DuckDB's `postgres` extension to bulk-copy each table over the wire — no
psycopg2 / local Postgres client needed.

Setup:
    1. Create a free project at https://neon.tech and copy its connection string.
    2. Export it (keep the ?sslmode=require — Neon requires TLS):
         export NEON_DATABASE_URL='postgresql://user:pass@ep-xxx.aws.neon.tech/neondb?sslmode=require'
    3. python src/pipeline.py      # build output/fleet.duckdb first (if not already)
       python src/load_neon.py     # push tables to Neon
    4. Run sql/neon_constraints.sql in the Neon SQL editor to add keys/indexes.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import duckdb

ROOT    = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "output" / "fleet.duckdb"

# dims before facts so tables exist in FK order; constraints get added
# afterwards by sql/neon_constraints.sql
TABLES = [
    "dim_customer", "dim_vehicle", "dim_driver", "dim_date", "dim_time",
    "fact_daily_vehicle_summary", "fact_trip_summary", "fact_anomaly_events",
    "dq_log",
]


def _mask(url: str) -> str:
    """Hide the password when echoing the target."""
    if "@" in url and "//" in url:
        head, tail = url.split("@", 1)
        scheme, creds = head.split("//", 1)
        user = creds.split(":", 1)[0]
        return f"{scheme}//{user}:****@{tail}"
    return "****"


def main() -> int:
    url = os.environ.get("NEON_DATABASE_URL")
    if not url:
        print("ERROR: NEON_DATABASE_URL is not set. See the header of this file.",
              file=sys.stderr)
        return 1
    if not DB_PATH.exists():
        print("ERROR: output/fleet.duckdb not found — run `python src/pipeline.py` first.",
              file=sys.stderr)
        return 1

    print(f"Target: {_mask(url)}")
    # opening read-write on purpose: a read-only DuckDB connection puts the
    # attached Postgres in READ ONLY transactions too, which blocks CREATE/DROP
    # on Neon. we only ever SELECT from the local tables so the .duckdb file
    # itself doesn't change.
    con = duckdb.connect(DB_PATH.as_posix())
    con.execute("INSTALL postgres; LOAD postgres;")
    con.execute(f"ATTACH '{url}' AS pg (TYPE postgres)")

    t0 = time.time()
    for tbl in TABLES:
        st = time.time()
        # raw DROP ... CASCADE so re-runs still work once FKs are in place
        con.execute(f"CALL postgres_execute('pg', 'DROP TABLE IF EXISTS {tbl} CASCADE')")
        con.execute(f"CREATE TABLE pg.{tbl} AS SELECT * FROM {tbl}")
        n = con.sql(f"SELECT COUNT(*) FROM pg.{tbl}").fetchone()[0]
        print(f"  loaded {tbl:32s} {n:>10,} rows ({time.time() - st:4.1f}s)")

    con.close()
    print(f"\nDone in {time.time() - t0:.1f}s.")
    print("Next: run sql/neon_constraints.sql in the Neon SQL editor to add keys/indexes,")
    print("then follow docs/POWERBI_SERVICE_GUIDE.md to build the report.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
