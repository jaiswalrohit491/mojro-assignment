-- Build ordered/paired telemetry (reused by the fact builds) and detect the
-- three anomaly types, then union them into fact_anomaly_events.
--
-- All three anomalies use the same time-aware islanding: contiguous flagged
-- points collapse into one event, and a run breaks when either an unflagged
-- point intervenes (seq gap) or the real-time gap between flagged points
-- exceeds 120s. Without the time-gap break, a vehicle that's flagged, drops
-- offline for hours, then comes back still flagged would read as one event
-- spanning the whole gap. 120s vs the ~10s median sampling rate.

-- per-vehicle sequence + lagged values
CREATE OR REPLACE TABLE tel_ordered AS
SELECT
    *,
    ROW_NUMBER()          OVER w AS seq,
    LAG(latitude)         OVER w AS prev_lat,
    LAG(longitude)        OVER w AS prev_lon,
    LAG(event_timestamp)  OVER w AS prev_ts,
    LAG(ignition_status)  OVER w AS prev_ign,
    LAG(speed_kmph)       OVER w AS prev_speed,
    LAG(trip_id)          OVER w AS prev_trip
FROM clean_telemetry
WINDOW w AS (PARTITION BY vehicle_id ORDER BY event_timestamp, event_id);

-- consecutive-point pairs (segments) for distance/time metrics. dt_sec is
-- capped at 300s so long offline gaps don't inflate running/idle time or the
-- odometer. distance is integrated from the speed sensor (trapezoidal: avg of
-- the two endpoint speeds x elapsed time) instead of GPS haversine, since GPS
-- scatter alone racks up tens of phantom km/day per vehicle while stationary.
-- gated on prev_ign = 'ON' so distance stays consistent with running_hours
-- (both count engine-on movement only) — GPS_JUMP below still uses haversine,
-- since the jump itself is the point there.
CREATE OR REPLACE TABLE tel_pairs AS
WITH raw AS (
    SELECT
        vehicle_id, driver_id, trip_id, prev_trip, event_timestamp, prev_ts,
        speed_kmph, prev_speed, ignition_status, prev_ign,
        CAST(strftime(prev_ts, '%Y%m%d') AS INTEGER)  AS date_key,
        date_diff('second', prev_ts, event_timestamp) AS raw_dt_sec
    FROM tel_ordered
    WHERE prev_ts IS NOT NULL
)
SELECT
    *,
    LEAST(raw_dt_sec, 300) AS dt_sec,
    CASE WHEN prev_ign = 'ON'
         THEN (speed_kmph + prev_speed) / 2.0 * (LEAST(raw_dt_sec, 300) / 3600.0)
         ELSE 0 END AS effective_km
FROM raw;

-- Anomaly 1: overspeeding. Contiguous runs above the vehicle-type speed limit
-- collapse into a single event. HIGH if peak is >20% over limit, else MEDIUM.
CREATE OR REPLACE TABLE anomaly_overspeed AS
WITH flagged AS (
    SELECT t.*, v.speed_limit_kmph
    FROM tel_ordered t
    JOIN dim_vehicle v ON t.vehicle_id = v.vehicle_id
    WHERE t.speed_kmph > v.speed_limit_kmph
),
brks AS (
    SELECT *,
        CASE WHEN LAG(seq) OVER w IS NULL
               OR seq - LAG(seq) OVER w > 1
               OR date_diff('second', LAG(event_timestamp) OVER w, event_timestamp) > 120
             THEN 1 ELSE 0 END AS brk
    FROM flagged
    WINDOW w AS (PARTITION BY vehicle_id ORDER BY seq)
),
islanded AS (
    SELECT *, SUM(brk) OVER (PARTITION BY vehicle_id ORDER BY seq) AS island
    FROM brks
)
SELECT
    vehicle_id,
    arg_min(driver_id, event_timestamp) AS driver_id,
    arg_min(trip_id,   event_timestamp) AS trip_id,
    MIN(event_timestamp)                AS start_time,
    MAX(event_timestamp)                AS end_time,
    MAX(speed_kmph)                     AS max_speed,
    ANY_VALUE(speed_limit_kmph)         AS speed_limit,
    arg_max(latitude,  speed_kmph)      AS latitude,
    arg_max(longitude, speed_kmph)      AS longitude,
    COUNT(*)                            AS point_count
FROM islanded
GROUP BY vehicle_id, island;

-- Anomaly 2: excessive idling. Contiguous runs of ignition ON + speed 0 lasting
-- over 15 min. LOW under 30 min, MEDIUM under 1hr, else HIGH.
CREATE OR REPLACE TABLE anomaly_idle AS
WITH flagged AS (
    SELECT * FROM tel_ordered WHERE ignition_status = 'ON' AND speed_kmph = 0
),
brks AS (
    SELECT *,
        CASE WHEN LAG(seq) OVER w IS NULL
               OR seq - LAG(seq) OVER w > 1
               OR date_diff('second', LAG(event_timestamp) OVER w, event_timestamp) > 120
             THEN 1 ELSE 0 END AS brk
    FROM flagged
    WINDOW w AS (PARTITION BY vehicle_id ORDER BY seq)
),
islanded AS (
    SELECT *, SUM(brk) OVER (PARTITION BY vehicle_id ORDER BY seq) AS island
    FROM brks
),
agg AS (
    SELECT
        vehicle_id,
        arg_min(driver_id, event_timestamp) AS driver_id,
        arg_min(trip_id,   event_timestamp) AS trip_id,
        MIN(event_timestamp)                AS start_time,
        MAX(event_timestamp)                AS end_time,
        arg_min(latitude,  event_timestamp) AS latitude,
        arg_min(longitude, event_timestamp) AS longitude,
        COUNT(*)                            AS point_count
    FROM islanded
    GROUP BY vehicle_id, island
)
SELECT *, date_diff('second', start_time, end_time) AS duration_secs
FROM agg
WHERE date_diff('second', start_time, end_time) > 900;

-- Anomaly 3: GPS jump. Implied point-to-point speed over 200 km/h, which isn't
-- physically possible. A single bad coordinate produces two such transitions
-- (into it and out of it); islanding folds that burst into one event so a lone
-- glitch isn't double-counted. Always HIGH.
CREATE OR REPLACE TABLE anomaly_gpsjump AS
WITH computed AS (
    SELECT
        vehicle_id, driver_id, trip_id, seq, event_timestamp, prev_ts,
        latitude, longitude,
        2 * 6371 * asin(sqrt(
            pow(sin(radians(latitude - prev_lat) / 2), 2) +
            cos(radians(prev_lat)) * cos(radians(latitude)) *
            pow(sin(radians(longitude - prev_lon) / 2), 2)
        ))                                            AS dist_km,
        date_diff('second', prev_ts, event_timestamp) AS dt_sec
    FROM tel_ordered
    WHERE prev_ts IS NOT NULL
),
flagged AS (
    SELECT *, dist_km / (dt_sec / 3600.0) AS implied_speed_kmph
    FROM computed
    WHERE dt_sec > 0 AND dist_km / (dt_sec / 3600.0) > 200
),
brks AS (
    SELECT *,
        CASE WHEN LAG(seq) OVER w IS NULL
               OR seq - LAG(seq) OVER w > 1
               OR date_diff('second', LAG(event_timestamp) OVER w, event_timestamp) > 120
             THEN 1 ELSE 0 END AS brk
    FROM flagged
    WINDOW w AS (PARTITION BY vehicle_id ORDER BY seq)
),
islanded AS (
    SELECT *, SUM(brk) OVER (PARTITION BY vehicle_id ORDER BY seq) AS island
    FROM brks
)
SELECT
    vehicle_id,
    arg_min(driver_id, event_timestamp)     AS driver_id,
    arg_min(trip_id,   event_timestamp)     AS trip_id,
    MIN(prev_ts)                            AS start_time,
    MAX(event_timestamp)                    AS end_time,
    MAX(implied_speed_kmph)                 AS implied_speed_kmph,
    arg_max(latitude,  implied_speed_kmph)  AS latitude,
    arg_max(longitude, implied_speed_kmph)  AS longitude,
    COUNT(*)                                AS point_count
FROM islanded
GROUP BY vehicle_id, island;

-- unify all three into one fact table
CREATE OR REPLACE TABLE fact_anomaly_events AS
WITH u AS (
    SELECT
        'OVERSPEEDING' AS anomaly_type, vehicle_id, driver_id, trip_id,
        start_time, end_time,
        date_diff('second', start_time, end_time) AS duration_secs,
        latitude, longitude,
        CASE WHEN max_speed > speed_limit * 1.2 THEN 'HIGH' ELSE 'MEDIUM' END AS severity,
        max_speed AS metric_value, CAST(speed_limit AS DOUBLE) AS threshold_value
    FROM anomaly_overspeed
    UNION ALL
    SELECT
        'EXCESSIVE_IDLING', vehicle_id, driver_id, trip_id,
        start_time, end_time, duration_secs, latitude, longitude,
        CASE WHEN duration_secs < 1800 THEN 'LOW'
             WHEN duration_secs < 3600 THEN 'MEDIUM'
             ELSE 'HIGH' END,
        CAST(duration_secs AS DOUBLE), 900.0
    FROM anomaly_idle
    UNION ALL
    SELECT
        'GPS_JUMP', vehicle_id, driver_id, trip_id,
        start_time, end_time,
        date_diff('second', start_time, end_time), latitude, longitude,
        'HIGH', implied_speed_kmph, 200.0
    FROM anomaly_gpsjump
)
SELECT
    ROW_NUMBER() OVER (ORDER BY start_time, vehicle_id, anomaly_type) AS anomaly_key,
    anomaly_type, vehicle_id, driver_id, trip_id,
    start_time, end_time, duration_secs,
    ROUND(latitude, 6)  AS latitude,
    ROUND(longitude, 6) AS longitude,
    severity,
    ROUND(metric_value, 2) AS metric_value,
    threshold_value,
    CAST(strftime(start_time, '%Y%m%d') AS INTEGER) AS date_key,
    (EXTRACT(hour FROM start_time) * 60 + EXTRACT(minute FROM start_time)) AS time_key
FROM u;
