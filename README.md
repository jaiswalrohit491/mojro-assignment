# ExecuteWyse — Fleet Telemetry Data Pipeline & Analytics

Data-engineering take-home for **Mojro Technologies**. Transforms ~1.67M raw
vehicle-telemetry events into an analytics-ready **star schema** in DuckDB,
detects safety/data-quality anomalies, and ships exports + a full Power BI build
guide for three dashboard pages.

---

## What this does

```
data/raw/*.parquet,*.csv
        │
        ▼
 [ 01 ] staging + data-quality cleaning ──► dq_log (audit trail)
        ▼
 [ 02 ] conformed dimensions (vehicle, driver, customer, date, time)
        ▼
 [ 03 ] anomaly detection (overspeeding · idling · GPS jump) ──► fact_anomaly_events
        ▼
 [ 04 ] aggregated facts (daily vehicle summary · trip summary)
        ▼
 output/fleet.duckdb  +  output/exports/*.csv,*.parquet  ──► Power BI
```

## Quick start

```bash
# 1. Install deps (Python 3.9+)
pip install -r requirements.txt

# 2. Run the whole pipeline (rebuilds output/fleet.duckdb from scratch, ~6s)
python src/pipeline.py
```

The run prints the data-quality log, final row counts, and the anomaly
breakdown. Outputs:

| Path | Contents |
|------|----------|
| `output/fleet.duckdb` | Full database: staging, dims, facts, `dq_log` |
| `output/exports/*.csv` | One CSV per dim/fact — **import these into Power BI** |
| `output/exports/*.parquet` | Same tables as Parquet (faster re-load) |

## Repository layout

```
mojro-fleet/
├── README.md
├── requirements.txt
├── data/raw/               # source parquet + CSVs (+ original README)
├── sql/
│   ├── 01_staging_dq.sql   # load + clean + dq_log
│   ├── 02_dimensions.sql   # dim_vehicle/driver/customer/date/time
│   ├── 03_anomalies.sql    # 3 anomaly types → fact_anomaly_events
│   └── 04_facts.sql        # fact_daily_vehicle_summary, fact_trip_summary
├── src/
│   ├── pipeline.py         # orchestrator: runs SQL steps + exports + report
│   └── load_neon.py        # push the star schema to Neon (cloud Postgres)
├── output/                 # generated: fleet.duckdb + exports/
└── docs/
    ├── DATA_MODEL.md            # brief: ER diagram, assumptions, tradeoffs
    ├── POWERBI_GUIDE.md         # model relationships, 10 DAX measures, 3 pages
    ├── POWERBI_SERVICE_GUIDE.md # macOS path: Neon Postgres → Power BI web → .pbix
    └── powerbi_theme.json       # consistent color theme for the report
```

## Building the Power BI report on macOS

**The finished report is `deliverables/ExecuteWyse_Fleet.pbix`** (3 pages: Fleet
Overview, Anomaly Analysis, Driver Scorecard) — authored entirely on macOS in the
Power BI **Service** on a Neon Postgres source, then downloaded as `.pbix`.

Power BI Desktop is Windows-only. Two macOS-friendly paths (both let you
**download the `.pbix`** from the Service):

1. **Neon Postgres + Datamart** (this project's chosen path) —
   `sql/neon_constraints.sql`, `src/load_neon.py`, and
   **[docs/POWERBI_SERVICE_GUIDE.md](docs/POWERBI_SERVICE_GUIDE.md)**. Host the
   model in cloud Postgres, ingest via the native connector (no gateway), model
   + build in the browser.
2. **Excel upload** (simplest fallback) — one workbook of the exported tables to
   *My workspace*; no DB or Pro/Fabric license needed.

The DAX measures, relationships, and page layouts are the same either way and
live in **[docs/POWERBI_GUIDE.md](docs/POWERBI_GUIDE.md)**.

## Tech choices

- **DuckDB** — native Parquet reader, columnar/vectorized aggregation over 1.67M
  rows in seconds, single-file DB. The whole model is set-based SQL.
- **Python** is a thin orchestrator (`src/pipeline.py`): substitutes paths,
  executes the SQL modules in order, exports tables, prints the QA report.
- All transformation logic lives in **`sql/`** so it is readable and portable.

See **[docs/DATA_MODEL.md](docs/DATA_MODEL.md)** for the schema diagram,
assumptions, and tradeoffs, and **[docs/POWERBI_GUIDE.md](docs/POWERBI_GUIDE.md)**
for building the dashboard.

## Headline results (this dataset, 2025-01-20 → 26)

- **1,669,427** raw events → **1,626,599** loaded (**42,828 rejected**, 2.57%).
- Rejections: 2,067 out-of-range date · 24,612 duplicate ids · 8,122 bad GPS ·
  3,036 negative speed · 4,991 orphan-vehicle rows. Repairs: 700 orphan trips →
  NULL, 72,360 battery values clamped to 0–100.
- Anomalies: **109,550 overspeeding** (29,787 HIGH / 79,763 MEDIUM),
  **21,559 GPS jumps** (HIGH, each glitch islanded to one event), and
  **0 excessive-idling** — the simulated fleet never idles >15 min continuously
  (max observed 3.3 min; see DATA_MODEL.md).
