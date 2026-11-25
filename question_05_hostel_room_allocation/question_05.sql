-- Question 5: Hostel Room Allocation

DROP VIEW IF EXISTS v_room_occupancy;
DROP TRIGGER IF EXISTS trg_allocations_rules ON allocations;
DROP FUNCTION IF EXISTS fn_trg_allocations_rules();
DROP PROCEDURE IF EXISTS pr_refresh_occupancy();
DROP PROCEDURE IF EXISTS pr_allocate_room(INTEGER, INTEGER, DATE);
DROP FUNCTION IF EXISTS fn_free_beds(INTEGER);
DROP TABLE IF EXISTS occupancy_snapshot;
DROP TABLE IF EXISTS allocations;
DROP TABLE IF EXISTS rooms;
DROP TABLE IF EXISTS students;

-- (a) Tables
CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    IF p_room_id IS NULL THEN
        RAISE EXCEPTION 'Room ID cannot be NULL';
    END IF;

    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist', p_room_id;
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_student_id IS NULL OR p_room_id IS NULL OR p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Student ID, Room ID, and allocation date cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
        WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_allocations_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active_in_room INTEGER;
    v_student_active INTEGER;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = NEW.room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist', NEW.room_id;
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_student_active
    FROM allocations
    WHERE student_id = NEW.student_id
      AND status = 'ACTIVE'
      AND (TG_OP = 'INSERT' OR allocation_id <> OLD.allocation_id);

    IF v_student_active > 0 THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_active_in_room
    FROM allocations
    WHERE room_id = NEW.room_id
      AND status = 'ACTIVE'
      AND (TG_OP = 'INSERT' OR allocation_id <> OLD.allocation_id);

    IF v_active_in_room >= v_capacity THEN
        RAISE EXCEPTION 'Room % has no free beds', NEW.room_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_trg_allocations_rules();

-- Seed data (full, partly occupied, and empty rooms)
INSERT INTO students (student_number, full_name)
VALUES
    ('HST2026001', 'Kabwe Mulenga'),
    ('HST2026002', 'Lombe Chanda'),
    ('HST2026003', 'Misozi Phiri'),
    ('HST2026004', 'Daka Banda'),
    ('HST2026005', 'Bupe Mwale');

INSERT INTO rooms (room_number, capacity)
VALUES
    ('A101', 2),
    ('A102', 3),
    ('A103', 2);

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, CURRENT_DATE - 60, CURRENT_DATE - 15, 'ENDED');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 25);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 10);

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id)::INTEGER AS occupied_beds,
    (r.capacity - COUNT(a.allocation_id))::INTEGER AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON a.room_id = r.room_id
   AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_number;

SELECT * FROM v_room_occupancy;

-- (f) Index
-- Partial index on room_id for ACTIVE allocations only.
CREATE INDEX idx_allocations_active_room
    ON allocations (room_id)
    WHERE status = 'ACTIVE';

ANALYZE allocations;

EXPLAIN (ANALYZE, BUFFERS)
SELECT allocation_id, student_id, room_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds = EXCLUDED.free_beds;
END;
$$;

-- Daily at 23:55 (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_occupancy_snapshot',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy();$$
);
*/

-- Quick checks
SELECT room_number, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_number;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
