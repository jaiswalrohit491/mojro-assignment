-- Conformed dimensions for the star schema.

CREATE OR REPLACE TABLE dim_customer AS
SELECT customer_id, customer_name, city, industry
FROM stg_customers;

-- carries its speed limit for convenience
CREATE OR REPLACE TABLE dim_vehicle AS
SELECT
    v.vehicle_id,
    v.vehicle_number,
    v.vehicle_type,
    v.customer_id,
    sl.speed_limit AS speed_limit_kmph,
    v.registration_date
FROM stg_vehicles v
LEFT JOIN ref_speed_limit sl ON v.vehicle_type = sl.vehicle_type;

-- + a synthetic UNKNOWN member for telemetry rows with no matching driver
CREATE OR REPLACE TABLE dim_driver AS
SELECT
    driver_id,
    driver_name,
    phone,
    license_number,
    vehicle_id AS assigned_vehicle_id,
    joining_date
FROM stg_drivers
UNION ALL
SELECT 'UNKNOWN', 'Unknown Driver', NULL, NULL, NULL, NULL;

-- 7-day window, 2025-01-20 .. 2025-01-26. day_sort gives Mon=1..Sun=7 so Power
-- BI can order day_name Mon->Sun (EXTRACT(dow) is 0=Sunday, which would put
-- Sunday first on the heatmap)
CREATE OR REPLACE TABLE dim_date AS
WITH days AS (
    SELECT UNNEST(generate_series(DATE '2025-01-20', DATE '2025-01-26', INTERVAL 1 DAY)) AS ts
)
SELECT
    CAST(strftime(ts, '%Y%m%d') AS INTEGER)                AS date_key,
    CAST(ts AS DATE)                                       AS date,
    EXTRACT(day   FROM ts)                                 AS day,
    EXTRACT(month FROM ts)                                 AS month,
    monthname(ts)                                          AS month_name,
    EXTRACT(year  FROM ts)                                 AS year,
    EXTRACT(dow   FROM ts)                                 AS day_of_week,   -- 0=Sunday
    CASE WHEN EXTRACT(dow FROM ts) = 0 THEN 7
         ELSE EXTRACT(dow FROM ts) END                     AS day_sort,      -- 1=Mon .. 7=Sun
    dayname(ts)                                            AS day_name,
    EXTRACT(week  FROM ts)                                 AS week_of_year,
    (EXTRACT(dow FROM ts) IN (0, 6))                       AS is_weekend
FROM days;

-- minute-of-day grain, 1440 rows
CREATE OR REPLACE TABLE dim_time AS
SELECT
    m                                        AS time_key,      -- minute of day 0..1439
    (m // 60)                                AS hour,
    (m %  60)                                AS minute,
    printf('%02d:%02d', (m // 60), (m % 60)) AS hh_mm,
    CASE
        WHEN m // 60 < 6  THEN 'Night'
        WHEN m // 60 < 12 THEN 'Morning'
        WHEN m // 60 < 17 THEN 'Afternoon'
        WHEN m // 60 < 21 THEN 'Evening'
        ELSE 'Night'
    END                                      AS part_of_day
FROM (SELECT UNNEST(generate_series(0, 1439)) AS m);
