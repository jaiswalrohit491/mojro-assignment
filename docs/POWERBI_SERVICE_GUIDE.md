# Power BI **Service** Build Guide (Neon Postgres, macOS-friendly)

Power BI Desktop is Windows-only. This path builds the entire report in the
browser on a Mac: host the star schema in **Neon** (free cloud Postgres), ingest
it with a **Datamart** (native PostgreSQL connector, no gateway), model + build
in the web, then **download the `.pbix`**.

> For the DAX definitions, page layouts, and visual specs, this guide points to
> **[POWERBI_GUIDE.md](POWERBI_GUIDE.md)** — the model relationships, the 10
> measures, and the 3 pages are identical regardless of data source. This file
> only covers the Neon + Service plumbing.

---

## Prerequisites
- A **Neon** account (free): <https://neon.tech>.
- A Power BI workspace on **Fabric capacity, a Fabric trial (free 60 days), or
  Premium-Per-User (PPU)** — a Datamart is what lets you model a *database*
  source entirely in the browser. Plain Pro can ingest via a Dataflow but can't
  model a DB source without Desktop. Start a trial: app.powerbi.com → account
  manager (top-right) → **Start trial**, or Workspace → **Settings → Premium**.

---

## Step 1 — Create the Neon database
1. Neon console → **New Project** (pick a region near you). A database `neondb`
   is created automatically.
2. **Dashboard → Connection string** → copy it. It looks like:
   `postgresql://<user>:<pass>@ep-xxxx-xxxx.<region>.aws.neon.tech/neondb?sslmode=require`
3. Note the parts — you'll need them for Power BI:
   - **Server (host):** `ep-xxxx-xxxx.<region>.aws.neon.tech`
   - **Database:** `neondb`
   - **Username / Password:** from the string.

## Step 2 — Load the star schema into Neon
From the repo root (after `python src/pipeline.py` has built `output/fleet.duckdb`):
```bash
export NEON_DATABASE_URL='postgresql://<user>:<pass>@ep-xxxx.<region>.aws.neon.tech/neondb?sslmode=require'
python src/load_neon.py
```
This bulk-copies all 9 tables (dims, facts, `dq_log`) via DuckDB's Postgres
extension — ~40s. Then, in the **Neon SQL editor**, paste and run
[`sql/neon_constraints.sql`](../sql/neon_constraints.sql) to add PKs/FKs/indexes.

> **Keep the URL as `...?sslmode=require`** — if Neon's default string appends
> `&channel_binding=require`, drop that part for the loader: DuckDB's libpq client
> doesn't support channel binding and will refuse to connect. (Power BI's own
> connector in Step 3 handles channel binding fine, so this only affects the
> loader.)

Verify in the Neon editor: `SELECT count(*) FROM fact_anomaly_events;` → 131109.

## Step 3 — Ingest into Power BI with a Datamart
1. app.powerbi.com → your (Fabric/PPU) **workspace** → **New → Datamart**.
2. **Get data → PostgreSQL database.**
3. Connection settings:
   - **Server:** the Neon host (e.g. `ep-xxxx.<region>.aws.neon.tech`). If it
     fails, try appending `:5432`, or use the non-pooled host (drop `-pooler`).
   - **Database:** `neondb`
   - **Data gateway:** *(none)* — Neon is a public cloud endpoint, so it connects
     cloud-to-cloud without a gateway.
   - **Authentication:** Basic → Neon username + password.
   - ✅ **Use an encrypted connection** (Neon requires SSL).
4. In the Navigator, tick the 8 model tables (`dim_*`, `fact_*`; `dq_log`
   optional) → **Transform data** (or **Load**) → the Datamart ingests them and
   auto-creates a **semantic model**.

## Step 4 — Model in the browser (relationships + measures)
In the Datamart editor:
1. **Model view** → drag the relationships from POWERBI_GUIDE.md §2
   (all single-direction, one-to-many, dim → fact, plus `dim_customer →
   dim_vehicle`). Mark **dim_date** as a date table.
2. **New measure** → add each of the **10 DAX measures** from POWERBI_GUIDE.md §3
   (Total Vehicles, Active Today, Total Distance, Total Anomalies, Total Trips,
   Active Vehicles, Running Hours, Idle Hours, **Driver Distance**, **Safety
   Score**). The DAX is identical — paste as-is.

## Step 5 — Build the report
1. From the datamart/semantic model → **New report**.
2. Build **Page 1 / 2 / 3** exactly per POWERBI_GUIDE.md (KPIs, charts, filters,
   donut, matrix, Top-10, hour×weekday heatmap sorted by `day_sort`, driver
   scorecard).
3. **Theme:** View → Theme. The web editor ships a theme gallery; pick one
   matching the palette, or upload `docs/powerbi_theme.json` if the *Browse for
   themes* option appears in your tenant.
4. **Save** the report to the workspace.

## Step 6 — Produce the `.pbix` deliverable
**File → Download this report (`.pbix`)** — this is deliverable #3, created
entirely on macOS.

> If *Download this report* is greyed out, your tenant admin has disabled it
> (Admin portal → *Users can download .pbix files*). Workarounds: ask the admin
> to enable it, or submit the published report link + page screenshots.

---

## Refresh (optional)
The Datamart can be scheduled to re-pull from Neon (Datamart → Settings →
**Refresh**). Re-run `python src/pipeline.py && python src/load_neon.py` to
update Neon, then refresh the Datamart.

## Troubleshooting
| Symptom | Fix |
|---------|-----|
| "SSL connection required" | Ensure `?sslmode=require` in the URL (loader) and ✅ encrypted connection (Datamart). |
| Loader: "channel binding is required, but client does not support it" | Remove `&channel_binding=require` from `NEON_DATABASE_URL` (DuckDB libpq limitation; affects the loader only). |
| Loader: "cannot execute … in a read-only transaction" | Already handled — the loader opens the DuckDB file read-write; ensure you're on the current `src/load_neon.py`. |
| PostgreSQL connector asks for a gateway | You picked an on-prem style connection — Neon is cloud; leave gateway = none, use the exact Neon host. |
| Can't create a Datamart | Workspace isn't on Fabric/PPU — start the Fabric trial, or use the **Excel-upload** fallback (ask me to generate `ExecuteWyse_Fleet.xlsx`). |
| Load is slow / times out | Use Neon's non-pooled host in the loader URL; the pooled `-pooler` endpoint can throttle bulk loads. |
| `.pbix` download disabled | Tenant setting — see Step 6. |
