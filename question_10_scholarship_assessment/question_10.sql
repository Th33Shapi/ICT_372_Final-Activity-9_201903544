-- Question 10: Scholarship Application Assessment

DROP VIEW IF EXISTS v_approved_applicants;
DROP TRIGGER IF EXISTS trg_applications_decision_audit ON applications;
DROP FUNCTION IF EXISTS fn_trg_applications_decision_audit();
DROP PROCEDURE IF EXISTS pr_assess_pending();
DROP PROCEDURE IF EXISTS pr_assess_application(INTEGER);
DROP FUNCTION IF EXISTS fn_scholarship_eligible(INTEGER, NUMERIC, NUMERIC);
DROP TABLE IF EXISTS decision_audit;
DROP TABLE IF EXISTS applications;
DROP TABLE IF EXISTS students;

-- (a) Tables
CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(15) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(15) NOT NULL CHECK (old_status IN ('PENDING', 'APPROVED', 'REJECTED')),
    new_status VARCHAR(15) NOT NULL CHECK (new_status IN ('PENDING', 'APPROVED', 'REJECTED')),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive';
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative';
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100';
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INTEGER;
    v_income NUMERIC(12, 2);
    v_mark NUMERIC(5, 2);
    v_status VARCHAR(15);
    v_next_status VARCHAR(15);
BEGIN
    IF p_application_id IS NULL THEN
        RAISE EXCEPTION 'Application ID cannot be NULL';
    END IF;

    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application ID % does not exist', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application ID % is already %', p_application_id, v_status;
    END IF;

    IF fn_scholarship_eligible(v_age, v_income, v_mark) THEN
        v_next_status := 'APPROVED';
    ELSE
        v_next_status := 'REJECTED';
    END IF;

    UPDATE applications
    SET status = v_next_status
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_applications_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION fn_trg_applications_decision_audit();

-- Seed data (qualifying, non-qualifying, and boundary cases)
INSERT INTO students (student_number, full_name)
VALUES
    ('SCH2026001', 'Chileshe Mwansa'),
    ('SCH2026002', 'Nambela Kaluba'),
    ('SCH2026003', 'David Siame'),
    ('SCH2026004', 'Felistus Banda');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status)
VALUES
    (1, 20, 1800.00, 82.50, CURRENT_DATE - 10, 'PENDING'),
    (2, 18, 3000.00, 70.00, CURRENT_DATE - 8, 'PENDING'),
    (3, 25, 0.00, 100.00, CURRENT_DATE - 6, 'PENDING'),
    (4, 26, 1500.00, 85.00, CURRENT_DATE - 5, 'PENDING'),
    (1, 21, 3000.01, 78.00, CURRENT_DATE - 3, 'PENDING'),
    (2, 22, 2000.00, 69.99, CURRENT_DATE - 1, 'PENDING');

-- (e) View
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED'
ORDER BY a.average_mark DESC, s.student_number;

-- (f) Index
-- Composite index on (status, submitted_on) for filtering by status and submission date range.
CREATE INDEX idx_applications_status_submitted_on
    ON applications (status, submitted_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_app RECORD;
BEGIN
    FOR v_app IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(v_app.application_id);
    END LOOP;
END;
$$;

-- Every Monday at 08:00 (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'assess_pending_scholarships',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);
*/

-- Run assessment and inspect EXPLAIN plan
CALL pr_assess_pending();
CALL pr_assess_pending();

ANALYZE applications;

EXPLAIN (ANALYZE, BUFFERS)
SELECT application_id, student_id, average_mark, submitted_on, status
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;

SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit ORDER BY audit_id;
