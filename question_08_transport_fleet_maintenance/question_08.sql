-- Question 8: Transport Fleet Maintenance

DROP VIEW IF EXISTS v_service_due;
DROP TRIGGER IF EXISTS trg_trips_update_odometer ON trips;
DROP FUNCTION IF EXISTS fn_trg_trips_update_odometer();
DROP PROCEDURE IF EXISTS pr_refresh_service_alerts();
DROP PROCEDURE IF EXISTS pr_record_trip(INTEGER, DATE, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS fn_service_due(INTEGER);
DROP TABLE IF EXISTS service_alerts;
DROP TABLE IF EXISTS trips;
DROP TABLE IF EXISTS vehicles;

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration VARCHAR(20) NOT NULL UNIQUE,
    current_odometer INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer INTEGER NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL CHECK (km_since_service >= 5000),
    flagged_on DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
    v_last INTEGER;
BEGIN
    IF p_vehicle_id IS NULL THEN
        RAISE EXCEPTION 'Vehicle ID cannot be NULL';
    END IF;

    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on DATE,
    p_start INTEGER,
    p_end INTEGER
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_vehicle_id IS NULL OR p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Vehicle ID and trip date cannot be NULL';
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_start < 0 OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid odometer readings (start: %, end: %)', p_start, p_end;
    END IF;

    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_trips_update_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid trip odometer values';
    END IF;

    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'start_odometer (%) does not match current_odometer (%)',
            NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_update_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_trg_trips_update_odometer();

-- Seed data (trips loaded through procedure after trigger installation)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer)
VALUES
    ('BAA 1024', 10000, 10000),
    ('BAB 2048', 24400, 20000),
    ('BAC 3072', 35200, 30000);

CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10450);
CALL pr_record_trip(1, CURRENT_DATE - 2, 10450, 11100);
CALL pr_record_trip(2, CURRENT_DATE - 5, 24400, 24800);
CALL pr_record_trip(2, CURRENT_DATE - 1, 24800, 25350);
CALL pr_record_trip(3, CURRENT_DATE - 4, 35200, 35600);
CALL pr_record_trip(3, CURRENT_DATE, 35600, 36000);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000
ORDER BY km_since_service DESC, registration;

SELECT * FROM v_service_due;

-- (f) Index
-- Composite index on (vehicle_id, trip_on) for one vehicle's trips over a date range.
CREATE INDEX idx_trips_vehicle_trip_on
    ON trips (vehicle_id, trip_on);

ANALYZE trips;

EXPLAIN (ANALYZE, BUFFERS)
SELECT trip_id, vehicle_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, (current_odometer - last_service_odometer), CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service,
            flagged_on = EXCLUDED.flagged_on;

    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE sa.vehicle_id = v.vehicle_id
      AND (v.current_odometer - v.last_service_odometer) < 5000;
END;
$$;

-- Every Monday at 06:00 (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);
*/

-- Quick checks
SELECT registration, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY vehicle_id;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 3;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;
