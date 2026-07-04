-- Run in the Neon SQL editor (or psql) after `python src/load_neon.py`.
-- Adds primary keys, foreign keys, and indexes to the loaded star schema.
-- Power BI builds its own model relationships, but real db keys/indexes help
-- query folding/performance and document each table's grain.

ALTER TABLE dim_customer            ADD PRIMARY KEY (customer_id);
ALTER TABLE dim_vehicle             ADD PRIMARY KEY (vehicle_id);
ALTER TABLE dim_driver              ADD PRIMARY KEY (driver_id);
ALTER TABLE dim_date                ADD PRIMARY KEY (date_key);
ALTER TABLE dim_time                ADD PRIMARY KEY (time_key);
ALTER TABLE fact_trip_summary       ADD PRIMARY KEY (trip_id);
ALTER TABLE fact_anomaly_events     ADD PRIMARY KEY (anomaly_key);
ALTER TABLE fact_daily_vehicle_summary ADD PRIMARY KEY (date_key, vehicle_id);

ALTER TABLE dim_vehicle
    ADD FOREIGN KEY (customer_id) REFERENCES dim_customer(customer_id);

ALTER TABLE fact_daily_vehicle_summary
    ADD FOREIGN KEY (vehicle_id) REFERENCES dim_vehicle(vehicle_id),
    ADD FOREIGN KEY (date_key)   REFERENCES dim_date(date_key);

ALTER TABLE fact_trip_summary
    ADD FOREIGN KEY (vehicle_id) REFERENCES dim_vehicle(vehicle_id),
    ADD FOREIGN KEY (driver_id)  REFERENCES dim_driver(driver_id),
    ADD FOREIGN KEY (date_key)   REFERENCES dim_date(date_key),
    ADD FOREIGN KEY (time_key)   REFERENCES dim_time(time_key);

ALTER TABLE fact_anomaly_events
    ADD FOREIGN KEY (vehicle_id) REFERENCES dim_vehicle(vehicle_id),
    ADD FOREIGN KEY (driver_id)  REFERENCES dim_driver(driver_id),
    ADD FOREIGN KEY (date_key)   REFERENCES dim_date(date_key),
    ADD FOREIGN KEY (time_key)   REFERENCES dim_time(time_key);

-- indexes on the fact FKs, to speed up slicer/relationship filtering
CREATE INDEX IF NOT EXISTS ix_daily_vehicle   ON fact_daily_vehicle_summary(vehicle_id);
CREATE INDEX IF NOT EXISTS ix_daily_date      ON fact_daily_vehicle_summary(date_key);
CREATE INDEX IF NOT EXISTS ix_trip_vehicle    ON fact_trip_summary(vehicle_id);
CREATE INDEX IF NOT EXISTS ix_trip_driver     ON fact_trip_summary(driver_id);
CREATE INDEX IF NOT EXISTS ix_trip_date       ON fact_trip_summary(date_key);
CREATE INDEX IF NOT EXISTS ix_anom_vehicle    ON fact_anomaly_events(vehicle_id);
CREATE INDEX IF NOT EXISTS ix_anom_driver     ON fact_anomaly_events(driver_id);
CREATE INDEX IF NOT EXISTS ix_anom_date       ON fact_anomaly_events(date_key);
CREATE INDEX IF NOT EXISTS ix_anom_type       ON fact_anomaly_events(anomaly_type);
