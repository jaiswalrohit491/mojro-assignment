-- Load raw sources, classify data-quality issues, and produce a cleaned
-- telemetry table plus a dq_log audit trail.
-- @RAW@ is the raw data dir, substituted by pipeline.py at runtime.

-- land the raw sources as-is
CREATE OR REPLACE TABLE stg_telemetry AS
    SELECT * FROM read_parquet('@RAW@/telemetry_events.parquet');

CREATE OR REPLACE TABLE stg_vehicles  AS SELECT * FROM read_csv_auto('@RAW@/vehicles.csv');
CREATE OR REPLACE TABLE stg_drivers   AS SELECT * FROM read_csv_auto('@RAW@/drivers.csv');
CREATE OR REPLACE TABLE stg_customers AS SELECT * FROM read_csv_auto('@RAW@/customers.csv');
CREATE OR REPLACE TABLE stg_trips     AS SELECT * FROM read_csv_auto('@RAW@/trips.csv');

-- speed limits by vehicle type
CREATE OR REPLACE TABLE ref_speed_limit(vehicle_type VARCHAR, speed_limit INT);
INSERT INTO ref_speed_limit VALUES ('BIKE', 60), ('3W', 50), ('LCV', 80), ('HCV', 70);

CREATE OR REPLACE TABLE dq_log(
    run_step         VARCHAR,
    table_name       VARCHAR,
    check_name       VARCHAR,
    records_affected BIGINT,
    action           VARCHAR,
    detail           VARCHAR
);

-- Tag every row with each quality issue it has (they can overlap). COALESCE
-- keeps the flags NULL-safe so a null sensor value can't quietly disappear
-- from both the dq_log buckets and clean_telemetry. Duplicates are ranked with
-- earliest kept and event_id as the tie-break.
CREATE OR REPLACE TABLE telemetry_flagged AS
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_timestamp, event_id) AS rn
    FROM stg_telemetry
)
SELECT
    r.* EXCLUDE (rn),
    -- source data is a 7-day window ending 2025-01-26; a handful of rows spill
    -- into a partial 2025-01-27, dropped so per-day metrics aren't skewed by a stub
    COALESCE(r.event_timestamp >= TIMESTAMP '2025-01-27 00:00:00', FALSE) AS is_after_range,
    COALESCE(r.rn > 1, FALSE)                                             AS is_duplicate,
    COALESCE(r.latitude IS NULL OR r.longitude IS NULL
        OR r.latitude = 0 OR r.longitude = 0
        OR r.latitude  < 6  OR r.latitude  > 36
        OR r.longitude < 68 OR r.longitude > 97, TRUE)                   AS is_bad_gps,
    COALESCE(r.speed_kmph < 0, FALSE)                                    AS is_neg_speed,
    (v.vehicle_id IS NULL)                                               AS is_orphan_vehicle,
    (d.driver_id IS NULL)                                               AS is_orphan_driver,
    COALESCE(r.trip_id IS NOT NULL AND t.trip_id IS NULL, FALSE)        AS is_orphan_trip,
    (r.trip_id IS NULL)                                                AS is_null_trip,
    COALESCE(r.battery_level < 0 OR r.battery_level > 100, FALSE)       AS is_bad_battery
FROM ranked r
LEFT JOIN stg_vehicles v ON r.vehicle_id = v.vehicle_id
LEFT JOIN stg_drivers  d ON r.driver_id  = d.driver_id
LEFT JOIN stg_trips    t ON r.trip_id    = t.trip_id;

-- rejection reasons are logged in priority order and are mutually exclusive
-- (each rejected row counts against exactly one reason) so the totals
-- reconcile: total_raw - sum(rejections) = rows_accepted
INSERT INTO dq_log
SELECT 'clean','telemetry','total_raw_rows', COUNT(*), 'read', 'rows read from parquet'
FROM telemetry_flagged;

INSERT INTO dq_log
SELECT 'clean','telemetry','out_of_range_date', COUNT(*), 'rejected',
       'event_timestamp on the partial trailing day 2025-01-27 (outside 7-day window)'
FROM telemetry_flagged WHERE is_after_range;

INSERT INTO dq_log
SELECT 'clean','telemetry','duplicate_event_id', COUNT(*), 'rejected',
       'same event_id seen more than once; earliest kept'
FROM telemetry_flagged WHERE is_duplicate AND NOT is_after_range;

INSERT INTO dq_log
SELECT 'clean','telemetry','invalid_gps', COUNT(*), 'rejected',
       'lat/lon null, zero, or outside India bounds (6-36N, 68-97E)'
FROM telemetry_flagged WHERE is_bad_gps AND NOT is_after_range AND NOT is_duplicate;

INSERT INTO dq_log
SELECT 'clean','telemetry','negative_speed', COUNT(*), 'rejected',
       'speed_kmph < 0 (sensor error)'
FROM telemetry_flagged WHERE is_neg_speed AND NOT is_after_range AND NOT is_duplicate AND NOT is_bad_gps;

INSERT INTO dq_log
SELECT 'clean','telemetry','orphan_vehicle', COUNT(*), 'rejected',
       'vehicle_id not present in vehicles master'
FROM telemetry_flagged WHERE is_orphan_vehicle AND NOT is_after_range AND NOT is_duplicate AND NOT is_bad_gps AND NOT is_neg_speed;

-- repairs / kept, counted only on rows that survive rejection
INSERT INTO dq_log
SELECT 'clean','telemetry','orphan_driver', COUNT(*), 'repaired',
       'driver_id not in drivers master; remapped to UNKNOWN driver'
FROM telemetry_flagged
WHERE is_orphan_driver AND NOT is_after_range AND NOT is_duplicate AND NOT is_bad_gps AND NOT is_neg_speed AND NOT is_orphan_vehicle;

INSERT INTO dq_log
SELECT 'clean','telemetry','orphan_trip', COUNT(*), 'repaired',
       'trip_id not in trips master; set to NULL (treated as off-trip)'
FROM telemetry_flagged
WHERE is_orphan_trip AND NOT is_after_range AND NOT is_duplicate AND NOT is_bad_gps AND NOT is_neg_speed AND NOT is_orphan_vehicle;

INSERT INTO dq_log
SELECT 'clean','telemetry','battery_out_of_range', COUNT(*), 'repaired',
       'battery_level outside 0-100; clamped to nearest bound'
FROM telemetry_flagged
WHERE is_bad_battery AND NOT is_after_range AND NOT is_duplicate AND NOT is_bad_gps AND NOT is_neg_speed AND NOT is_orphan_vehicle;

INSERT INTO dq_log
SELECT 'clean','telemetry','null_trip_id', COUNT(*), 'kept',
       'trip_id NULL = vehicle not on active trip (valid state)'
FROM telemetry_flagged
WHERE is_null_trip AND NOT is_after_range AND NOT is_duplicate AND NOT is_bad_gps AND NOT is_neg_speed AND NOT is_orphan_vehicle;

-- reject: out-of-range date, duplicates, invalid GPS, negative speed, orphan
-- vehicles. repair: orphan driver -> 'UNKNOWN', orphan trip -> NULL,
-- battery_level clamped to [0,100]
CREATE OR REPLACE TABLE clean_telemetry AS
SELECT
    event_id,
    vehicle_id,
    CASE WHEN is_orphan_driver THEN 'UNKNOWN' ELSE driver_id END       AS driver_id,
    CASE WHEN is_orphan_trip   THEN NULL      ELSE trip_id   END       AS trip_id,
    event_timestamp,
    latitude, longitude, speed_kmph, heading, gps_accuracy,
    ignition_status,
    LEAST(GREATEST(battery_level, 0), 100)                             AS battery_level
FROM telemetry_flagged
WHERE NOT is_after_range
  AND NOT is_duplicate
  AND NOT is_bad_gps
  AND NOT is_neg_speed
  AND NOT is_orphan_vehicle;

INSERT INTO dq_log
SELECT 'clean','clean_telemetry','rows_accepted', COUNT(*), 'loaded',
       'rows surviving cleaning and loaded to clean_telemetry'
FROM clean_telemetry;
