# Power BI Build Guide — ExecuteWyse Fleet Dashboard

This guide reproduces the 3-page report from the exported tables. Follow it in
Power BI Desktop (Windows, or a Windows VM — Desktop is not available on macOS).
Everything the report needs ships in `output/exports/`.

> **Why CSV import (not a live DuckDB connection)?** The pipeline runs on macOS
> where the DuckDB ODBC driver / Power BI Desktop aren't available. Importing the
> pre-aggregated CSV/Parquet exports is portable, reproducible, and fast (the
> heavy lifting already happened in the pipeline).

---

## 1. Load the data

1. **Home → Get Data → Text/CSV** (or **Parquet**), import all 8 tables from
   `output/exports/`:
   `dim_customer, dim_vehicle, dim_driver, dim_date, dim_time,`
   `fact_daily_vehicle_summary, fact_trip_summary, fact_anomaly_events`.
   (`dq_log` is optional — nice for an appendix visual.)
2. In each query, confirm types: `*_key` = Whole Number, `*_time`/`*_start`/
   `*_end` = Date/Time, lat/long/speed/distance = Decimal.
3. **View → Themes → Browse for themes →** `docs/powerbi_theme.json`.

## 2. Model relationships

Model view → create these (all **single-direction**, dimension → fact,
one-to-many, active):

| From (one) | To (many) | Column |
|------------|-----------|--------|
| dim_vehicle | fact_daily_vehicle_summary | vehicle_id |
| dim_date | fact_daily_vehicle_summary | date_key |
| dim_vehicle | fact_trip_summary | vehicle_id |
| dim_driver | fact_trip_summary | driver_id |
| dim_date | fact_trip_summary | date_key |
| dim_time | fact_trip_summary | time_key |
| dim_vehicle | fact_anomaly_events | vehicle_id |
| dim_driver | fact_anomaly_events | driver_id |
| dim_date | fact_anomaly_events | date_key |
| dim_time | fact_anomaly_events | time_key |
| dim_customer | dim_vehicle | customer_id |

`dim_customer → dim_vehicle → facts` (snowflake) lets a **Customer** slicer
filter every fact. Mark **dim_date** as a date table (Table tools → Mark as date
table → `date`).

> Set `fact_anomaly_events` relationships' cross-filter to **Single**. Keep all
> dims filtering facts one way to avoid ambiguity.

## 3. DAX measures

Create a blank table **`_Measures`** (Home → Enter Data → empty table) and add
these. This report has **10 measures** (spec requires ≥2).

```dax
-- ===== Core rollups =====
Total Vehicles = DISTINCTCOUNT( dim_vehicle[vehicle_id] )

Total Distance (km) = SUM( fact_daily_vehicle_summary[total_distance_km] )

Total Anomalies = COUNTROWS( fact_anomaly_events )

Total Trips = DISTINCTCOUNT( fact_trip_summary[trip_id] )

-- Active vehicles = distinct vehicles reporting in the filter context
Active Vehicles =
CALCULATE(
    DISTINCTCOUNT( fact_daily_vehicle_summary[vehicle_id] ),
    fact_daily_vehicle_summary[total_distance_km] > 0
)

-- KPI card "Active Today": the latest date in the data (2025-01-26; the partial
-- 2025-01-27 spill-over day is dropped in the pipeline so this is a full day)
Active Today =
VAR LastDay = CALCULATE( MAX( dim_date[date_key] ), ALL( dim_date ) )
RETURN
CALCULATE( [Active Vehicles], dim_date[date_key] = LastDay )

-- ===== Requirement measure #1: Running Hours =====
Running Hours = SUM( fact_daily_vehicle_summary[running_hours] )

Idle Hours = SUM( fact_daily_vehicle_summary[idle_hours] )

-- Distance measured from the TRIP fact, which carries driver_id (the daily fact
-- does not). Use this on the Driver page so distance responds to the driver
-- slicer; [Total Distance (km)] (daily fact) is for fleet/vehicle context.
Driver Distance = SUM( fact_trip_summary[actual_distance_km] )

-- ===== Requirement measure #2: Safety Score (0-100) =====
-- Penalizes SERIOUS speeding: 3 points per HIGH-severity overspeed (>20% over
-- limit) per 100 km driven, capped at a 100-point penalty. Higher = safer.
-- Why HIGH only: MEDIUM overspeed (e.g. a 3W at 51 km/h) is near-universal in
-- this fleet, so including it saturates every driver to ~0 and stops the score
-- discriminating. Focusing on HIGH gives a real spread (~34-77 here). GPS jumps
-- are excluded (sensor data-quality, not driving).
-- IMPORTANT: the denominator uses [Driver Distance] (trip fact, driver grain),
-- NOT [Total Distance (km)] (daily fact, which has no driver relationship and
-- would leave the denominator fleet-wide on the Driver page — making every
-- driver score identical and inverting the ranking of the riskiest drivers).
Safety Score =
VAR HighOver =
    CALCULATE( COUNTROWS( fact_anomaly_events ),
        fact_anomaly_events[anomaly_type] = "OVERSPEEDING",
        fact_anomaly_events[severity] = "HIGH" )
VAR Km = [Driver Distance]
VAR Penalty = DIVIDE( HighOver, Km, 0 ) * 100 * 3
RETURN IF( Km = 0, BLANK(), ROUND( 100 - MIN( 100, Penalty ), 0 ) )

-- Helper for the anomaly page (driver-facing count, excludes GPS jumps)
Driver Anomalies =
CALCULATE( COUNTROWS( fact_anomaly_events ),
    fact_anomaly_events[anomaly_type] <> "GPS_JUMP" )
```

This report ships **10 measures** (spec requires ≥2).

---

## Page 1 — Fleet Overview

**Filters (slicers, top of page):** `dim_date[date]` (Between / relative),
`dim_customer[customer_name]`, `dim_vehicle[vehicle_type]`.

**KPI cards (row):**
- Total Vehicles → `[Total Vehicles]`
- Active Today → `[Active Today]`
- Total Distance (7 days) → `[Total Distance (km)]`
- Total Anomalies → `[Total Anomalies]`

**Charts:**
- **Distance by vehicle type** — Clustered bar. Axis `dim_vehicle[vehicle_type]`,
  Value `[Total Distance (km)]`.
- **Daily trend: active vehicles vs anomalies** — Line & clustered column.
  Axis `dim_date[date]`; column `[Active Vehicles]`; line `[Total Anomalies]`.

## Page 2 — Anomaly Analysis

**Visuals:**
- **Anomalies by type** — Donut. Legend `fact_anomaly_events[anomaly_type]`,
  Values `[Total Anomalies]`.
- **Customer × Anomaly Type** — Matrix. Rows `dim_customer[customer_name]`,
  Columns `fact_anomaly_events[anomaly_type]`, Values `[Total Anomalies]`.
  Turn on conditional-formatting background on values.
- **Top 10 vehicles by anomalies** — Bar. Axis `dim_vehicle[vehicle_number]`,
  Value `[Total Anomalies]`; Filter → Top N = 10 by `[Total Anomalies]`.
- **Heatmap: hour × weekday** — Matrix. Rows `dim_time[hour]`,
  Columns `dim_date[day_name]` (Sort-by-column = `dim_date[day_sort]`, Mon→Sun),
  Values `[Total Anomalies]`, background conditional formatting (Minimum=green
  `#12B886`, Maximum=red `#E03131`). A Severity slicer
  (`fact_anomaly_events[severity]`) is a nice add.

> Tip: add an **Anomaly Type** slicer so viewers can isolate overspeeding from
> GPS jumps (which dominate raw counts).

## Page 3 — Driver Scorecard

**Slicer:** `dim_driver[driver_name]` (single-select dropdown).

**KPI cards:**
- Total Trips → `[Total Trips]`
- Total Distance → `[Driver Distance]` (trip fact — carries driver grain)
- Anomaly Count → `[Total Anomalies]`
- Safety Score → `[Safety Score]` (gauge 0–100, or card with conditional color:
  ≥80 green, 60–79 amber, <60 red)

> The daily fact has **no driver relationship**, so on the Driver page use
> `[Driver Distance]` (defined above) for distance and Safety Score — never
> `[Total Distance (km)]`, which would stay fleet-wide under a driver slicer.

**Trend charts:**
- Daily distance — Line/column, Axis `dim_date[date]`, Value `Driver Distance`.
- Daily anomalies — Line, Axis `dim_date[date]`, Value `[Total Anomalies]`.

**Recent anomalies list** — Table filtered to the selected driver:
`fact_anomaly_events` columns start_time, anomaly_type, severity, metric_value,
duration_secs; sort by start_time desc; visual-level Top N = 20.

---

## Formatting & interactivity checklist
- [ ] Theme applied (`powerbi_theme.json`) — consistent blue/green/amber/red.
- [ ] All KPI cards same size/row; titles on every visual.
- [ ] Cross-filtering enabled (default) — clicking a bar filters the page.
- [ ] Severity uses the semantic colors (HIGH=red, MEDIUM=amber, LOW=green).
- [ ] `dim_date` marked as date table; `day_name` sorted by `day_sort` (Mon→Sun).
- [ ] ≥2 DAX measures present (this guide ships 10).

## Exporting the `.pbix`
Once built in Power BI Desktop: **File → Save As** → `ExecuteWyse_Fleet.pbix`.
That binary is the Deliverable #3.
