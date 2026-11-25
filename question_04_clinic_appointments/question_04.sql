-- Question 4: Clinic Appointment Scheduling

DROP VIEW IF EXISTS v_today_appointments;
DROP TRIGGER IF EXISTS trg_appointments_no_clash ON appointments;
DROP FUNCTION IF EXISTS fn_trg_appointments_no_clash();
DROP PROCEDURE IF EXISTS pr_refresh_clinic_summary(DATE);
DROP PROCEDURE IF EXISTS pr_book_appointment(INTEGER, INTEGER, DATE, TIME);
DROP FUNCTION IF EXISTS fn_daily_load(INTEGER, DATE);
DROP TABLE IF EXISTS clinic_summary;
DROP TABLE IF EXISTS appointments;
DROP TABLE IF EXISTS doctors;
DROP TABLE IF EXISTS patients;

-- (a) Tables
CREATE TABLE patients (
    patient_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL CHECK (
        slot_time IN (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00')
    ),
    status VARCHAR(15) NOT NULL DEFAULT 'BOOKED' CHECK (
        status IN ('BOOKED', 'ATTENDED', 'CANCELLED')
    )
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL CHECK (booked_count >= 0),
    attended_count INTEGER NOT NULL CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL CHECK (cancelled_count >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INTEGER,
    p_day DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_load INTEGER;
BEGIN
    IF p_doctor_id IS NULL OR p_day IS NULL THEN
        RAISE EXCEPTION 'Doctor ID and day cannot be NULL';
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor ID % does not exist', p_doctor_id;
    END IF;

    SELECT COUNT(*)::INTEGER INTO v_load
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_load;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id INTEGER,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_patient_id IS NULL OR p_doctor_id IS NULL THEN
        RAISE EXCEPTION 'Patient ID and Doctor ID cannot be NULL';
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date cannot be in the past';
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00') THEN
        RAISE EXCEPTION 'Unsupported slot time: %', p_slot;
    END IF;

    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient ID % does not exist', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor ID % does not exist', p_doctor_id;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

    IF EXISTS (
        SELECT 1
        FROM appointments a
        WHERE a.doctor_id = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time = NEW.slot_time
          AND a.status <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR a.appointment_id <> OLD.appointment_id)
    ) THEN
        RAISE EXCEPTION 'Doctor % already has a booking on % at %',
            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_appointments_no_clash();

-- Seed data
INSERT INTO patients (full_name)
VALUES
    ('Mwape Chilufya'),
    ('Esther Banda'),
    ('Joseph Mbewe');

INSERT INTO doctors (full_name)
VALUES
    ('Dr. Luyando Sakala'),
    ('Dr. Chileshe Mumba'),
    ('Dr. Ruth Kalumba');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
VALUES
    (1, 1, CURRENT_DATE - 1, TIME '09:00:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, TIME '10:00:00', 'CANCELLED'),
    (3, 1, CURRENT_DATE - 1, TIME '10:00:00', 'ATTENDED');

CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '09:00:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE, TIME '11:00:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, TIME '12:00:00');

-- (e) View
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time, d.full_name;

SELECT * FROM v_today_appointments;

-- (f) Index
-- Non-unique composite index because a doctor has multiple slots per day.
CREATE INDEX idx_appointments_day_doctor
    ON appointments (appointment_day, doctor_id);

ANALYZE appointments;

EXPLAIN (ANALYZE, BUFFERS)
SELECT appointment_id, patient_id, doctor_id, appointment_day, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked INTEGER;
    v_attended INTEGER;
    v_cancelled INTEGER;
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Summary date cannot be NULL';
    END IF;

    SELECT COUNT(*) FILTER (WHERE status = 'BOOKED')::INTEGER,
           COUNT(*) FILTER (WHERE status = 'ATTENDED')::INTEGER,
           COUNT(*) FILTER (WHERE status = 'CANCELLED')::INTEGER
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count = EXCLUDED.booked_count,
            attended_count = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Daily at 01:00 for the previous day (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);$$
);
*/

-- Quick checks
SELECT doctor_id, full_name, fn_daily_load(doctor_id, CURRENT_DATE) AS today_load FROM doctors;
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary;
