-- Aggregated fact tables built from tel_pairs / clean_telemetry / anomalies.

-- grain: vehicle x date
CREATE OR REPLACE TABLE fact_daily_vehicle_summary AS
WITH movement AS (            -- distance and time from consecutive segments
    SELECT
        date_key, vehicle_id,
        SUM(effective_km)                                                   AS total_distance_km,
        SUM(CASE WHEN prev_ign = 'ON'                     THEN dt_sec END) / 3600.0 AS running_hours,
        SUM(CASE WHEN prev_ign = 'ON' AND prev_speed = 0 THEN dt_sec END) / 3600.0 AS idle_hours
    FROM tel_pairs
    GROUP BY date_key, vehicle_id
),
speed AS (                    -- speed and trip counts from the points themselves
    SELECT
        CAST(strftime(event_timestamp, '%Y%m%d') AS INTEGER) AS date_key,
        vehicle_id,
        AVG(CASE WHEN speed_kmph > 0 THEN speed_kmph END)    AS avg_speed,
        MAX(speed_kmph)                                      AS max_speed,
        COUNT(DISTINCT trip_id)                             AS trip_count
    FROM clean_telemetry
    GROUP BY 1, 2
),
anoms AS (
    SELECT date_key, vehicle_id, COUNT(*) AS anomaly_count
    FROM fact_anomaly_events
    GROUP BY 1, 2
)
SELECT
    s.date_key,
    s.vehicle_id,
    ROUND(COALESCE(m.total_distance_km, 0), 2) AS total_distance_km,
    ROUND(COALESCE(m.running_hours, 0), 2)     AS running_hours,
    ROUND(COALESCE(m.idle_hours, 0), 2)        AS idle_hours,
    ROUND(s.avg_speed, 2)                      AS avg_speed,
    s.max_speed                                AS max_speed,
    s.trip_count                               AS trip_count,
    COALESCE(a.anomaly_count, 0)               AS anomaly_count
FROM speed s
LEFT JOIN movement m ON s.date_key = m.date_key AND s.vehicle_id = m.vehicle_id
LEFT JOIN anoms    a ON s.date_key = a.date_key AND s.vehicle_id = a.vehicle_id;

-- grain: trip
CREATE OR REPLACE TABLE fact_trip_summary AS
WITH seg AS (                 -- segment metrics restricted to on-trip points
    SELECT
        trip_id,
        SUM(effective_km)                                                        AS actual_distance_km,
        SUM(CASE WHEN prev_ign = 'ON' AND prev_speed = 0 THEN dt_sec END) / 60.0   AS idle_time_mins,
        SUM(CASE WHEN prev_ign = 'ON'                     THEN dt_sec END) / 3600.0 AS running_hours,
        SUM(CASE WHEN prev_speed > 0 AND speed_kmph = 0 THEN 1 ELSE 0 END)        AS stoppage_count
    FROM tel_pairs
    -- both endpoints need to share the same trip, otherwise the first segment
    -- of each trip pulls in the (up to 300s) gap from the previous off-trip
    -- point and pushes running_hours/idle/distance past the trip's actual span
    WHERE trip_id IS NOT NULL AND prev_trip = trip_id
    GROUP BY trip_id
),
pts AS (                      -- endpoints and speed from the points
    SELECT
        trip_id,
        arg_min(vehicle_id, event_timestamp) AS vehicle_id,
        arg_min(driver_id,  event_timestamp) AS driver_id,
        MIN(event_timestamp)                 AS actual_start,
        MAX(event_timestamp)                 AS actual_end,
        AVG(CASE WHEN speed_kmph > 0 THEN speed_kmph END) AS avg_speed,
        MAX(speed_kmph)                      AS max_speed
    FROM clean_telemetry
    WHERE trip_id IS NOT NULL
    GROUP BY trip_id
),
an AS (
    SELECT trip_id, COUNT(*) AS anomaly_count
    FROM fact_anomaly_events
    WHERE trip_id IS NOT NULL
    GROUP BY trip_id
)
SELECT
    p.trip_id,
    p.vehicle_id,
    p.driver_id,
    tr.origin_city,
    tr.destination_city,
    tr.status,
    tr.planned_start,
    tr.planned_end,
    p.actual_start,
    p.actual_end,
    -- second precision: date_diff('minute') truncates, which made running_hours
    -- look like it exceeded the wall-clock duration by up to a minute
    ROUND(date_diff('second', p.actual_start, p.actual_end) / 60.0, 2) AS actual_duration_mins,
    ROUND(COALESCE(s.actual_distance_km, 0), 2)       AS actual_distance_km,
    ROUND(p.avg_speed, 2)                             AS avg_speed,
    p.max_speed                                       AS max_speed,
    ROUND(COALESCE(s.idle_time_mins, 0), 2)           AS idle_time_mins,
    ROUND(COALESCE(s.running_hours, 0), 2)            AS running_hours,
    COALESCE(s.stoppage_count, 0)                     AS stoppage_count,
    COALESCE(an.anomaly_count, 0)                     AS anomaly_count,
    CAST(strftime(p.actual_start, '%Y%m%d') AS INTEGER) AS date_key,
    (EXTRACT(hour FROM p.actual_start) * 60 + EXTRACT(minute FROM p.actual_start)) AS time_key
FROM pts p
JOIN stg_trips tr ON p.trip_id = tr.trip_id
LEFT JOIN seg s ON p.trip_id = s.trip_id
LEFT JOIN an     ON p.trip_id = an.trip_id;

-- drop the bulky intermediates: the shipped db only needs the model, the dq
-- audit log, and the speed-limit reference. staging/cleaned telemetry (~1.6M
-- rows each) and the anomaly work tables get rebuilt on every run anyway, so
-- dropping them keeps the deliverable db small.
DROP TABLE IF EXISTS telemetry_flagged;
DROP TABLE IF EXISTS tel_ordered;
DROP TABLE IF EXISTS tel_pairs;
DROP TABLE IF EXISTS clean_telemetry;
DROP TABLE IF EXISTS anomaly_overspeed;
DROP TABLE IF EXISTS anomaly_idle;
DROP TABLE IF EXISTS anomaly_gpsjump;
DROP TABLE IF EXISTS stg_telemetry;
DROP TABLE IF EXISTS stg_vehicles;
DROP TABLE IF EXISTS stg_drivers;
DROP TABLE IF EXISTS stg_customers;
DROP TABLE IF EXISTS stg_trips;
