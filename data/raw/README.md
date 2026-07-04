# ExecuteWyse Sample Telemetry Data

## Data Engineer Take-Home Assignment - Mojro Technologies

This dataset contains 7 days of simulated vehicle telemetry data for the Data Engineer take-home assignment.

---

## Files Included

| File | Records | Description |
|------|---------|-------------|
| `telemetry_events.parquet` | ~1.67M | Raw GPS telemetry events |
| `telemetry_sample.csv` | 1,000 | Sample of telemetry (for quick preview) |
| `vehicles.csv` | 300 | Vehicle master data |
| `drivers.csv` | 350 | Driver master data |
| `customers.csv` | 20 | Customer master data |
| `trips.csv` | ~3,300 | Trip records |

---

## Schema Details

### telemetry_events.parquet

| Column | Type | Description |
|--------|------|-------------|
| event_id | STRING | Unique event identifier |
| vehicle_id | STRING | Vehicle identifier (FK to vehicles.csv) |
| driver_id | STRING | Driver identifier (FK to drivers.csv) |
| trip_id | STRING | Trip identifier (FK to trips.csv) - NULL if not on trip |
| event_timestamp | TIMESTAMP | Event timestamp (UTC) |
| latitude | DOUBLE | GPS latitude |
| longitude | DOUBLE | GPS longitude |
| speed_kmph | DOUBLE | Speed in km/h |
| heading | DOUBLE | Direction in degrees (0-360) |
| gps_accuracy | DOUBLE | GPS accuracy in meters |
| ignition_status | STRING | ON / OFF |
| battery_level | INT | Device battery percentage (0-100) |

### vehicles.csv

| Column | Type | Description |
|--------|------|-------------|
| vehicle_id | STRING | Primary key |
| vehicle_number | STRING | Registration number (e.g., MH12AB1234) |
| vehicle_type | STRING | BIKE / 3W / LCV / HCV |
| customer_id | STRING | FK to customers.csv |
| registration_date | DATE | Vehicle registration date |

### drivers.csv

| Column | Type | Description |
|--------|------|-------------|
| driver_id | STRING | Primary key |
| driver_name | STRING | Full name |
| phone | STRING | Mobile number |
| license_number | STRING | Driving license number |
| vehicle_id | STRING | Currently assigned vehicle |
| joining_date | DATE | Date joined |

### customers.csv

| Column | Type | Description |
|--------|------|-------------|
| customer_id | STRING | Primary key |
| customer_name | STRING | Company name |
| city | STRING | Headquarters city |
| industry | STRING | Industry type |

### trips.csv

| Column | Type | Description |
|--------|------|-------------|
| trip_id | STRING | Primary key |
| vehicle_id | STRING | FK to vehicles.csv |
| driver_id | STRING | FK to drivers.csv |
| planned_start | TIMESTAMP | Planned start time |
| planned_end | TIMESTAMP | Planned end time |
| origin_city | STRING | Trip origin |
| destination_city | STRING | Trip destination |
| status | STRING | COMPLETED / CANCELLED / IN_PROGRESS |

---

## Data Quality Issues (Intentional)

The data contains realistic quality issues that you must handle:

| Issue | Approximate % | How to Identify |
|-------|---------------|-----------------|
| Duplicate event_ids | ~1.5% | Same event_id appears multiple times |
| NULL trip_ids | ~0.7% | trip_id is NULL (vehicle not on active trip) |
| Invalid GPS coordinates | ~0.5% | lat/lon = 0 or outside India bounds (6-36°N, 68-97°E) |
| Negative speeds | ~0.2% | speed_kmph < 0 (sensor errors) |
| Orphan records | ~0.3% | vehicle_id not in vehicles.csv |

---

## Speed Limits by Vehicle Type

Use these thresholds for anomaly detection:

| Vehicle Type | Speed Limit (km/h) |
|--------------|-------------------|
| BIKE | 60 |
| 3W | 50 |
| LCV | 80 |
| HCV | 70 |

---

## Date Range

- Start: 2025-01-20
- End: 2025-01-26
- Total: 7 days

---

## How to Load Data

### Python (Pandas)
```python
import pandas as pd

# Load telemetry
telemetry = pd.read_parquet('telemetry_events.parquet')

# Load master data
vehicles = pd.read_csv('vehicles.csv')
drivers = pd.read_csv('drivers.csv')
customers = pd.read_csv('customers.csv')
trips = pd.read_csv('trips.csv')
```

### Python (PySpark)
```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("TelemetryAnalysis").getOrCreate()

telemetry = spark.read.parquet('telemetry_events.parquet')
vehicles = spark.read.csv('vehicles.csv', header=True, inferSchema=True)
```

### DuckDB
```sql
-- Load directly from Parquet
SELECT * FROM 'telemetry_events.parquet' LIMIT 10;

-- Or create a table
CREATE TABLE telemetry AS SELECT * FROM 'telemetry_events.parquet';
```

---

## Questions?

Email: hiring@mojro.com

Good luck with your assignment!
