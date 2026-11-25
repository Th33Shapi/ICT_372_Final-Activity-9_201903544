-- Question 2: University Fee Payments

DROP VIEW IF EXISTS v_fee_balances;
DROP TRIGGER IF EXISTS trg_payments_audit ON payments;
DROP FUNCTION IF EXISTS fn_trg_payments_audit();
DROP PROCEDURE IF EXISTS pr_refresh_collections(DATE);
DROP PROCEDURE IF EXISTS pr_receive_payment(INTEGER, NUMERIC, DATE);
DROP FUNCTION IF EXISTS fn_fee_balance(INTEGER);
DROP TABLE IF EXISTS daily_collections;
DROP TABLE IF EXISTS payment_audit;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS students;

-- (a) Tables
CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL,
    fee_due NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    logged_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL CHECK (payment_count >= 0),
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12, 2);
    v_paid NUMERIC(12, 2);
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'Student ID cannot be NULL';
    END IF;

    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_paid, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(12, 2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12, 2);
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'Student ID cannot be NULL';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment (%) exceeds balance (%)', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_payments_audit();

-- Seed data (student 3 initially has no payments)
INSERT INTO students (student_number, full_name, fee_due)
VALUES
    ('STU2026001', 'Mutale Banda', 5000.00),
    ('STU2026002', 'Chanda Mwansa', 6500.00),
    ('STU2026003', 'Thandiwe Phiri', 4200.00);

CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 10);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 7);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    ROUND(s.fee_due - COALESCE(SUM(p.amount), 0.00), 2) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0.00)) > 0
ORDER BY s.student_number;

SELECT * FROM v_fee_balances;

-- (f) Index
-- Composite index on (student_id, paid_on) for filtering by student and payment date range.
CREATE INDEX idx_payments_student_paid_on
    ON payments (student_id, paid_on);

ANALYZE payments;

EXPLAIN (ANALYZE, BUFFERS)
SELECT payment_id, student_id, amount, paid_on
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Collection date cannot be NULL';
    END IF;

    SELECT COUNT(*)::INTEGER, COALESCE(SUM(amount), 0.00)
    INTO v_count, v_total
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_total)
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Daily at 01:00 for the previous day (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$
);
*/

-- Quick checks
SELECT student_id, full_name, fn_fee_balance(student_id) AS balance FROM students ORDER BY student_id;
CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections;
SELECT * FROM payment_audit ORDER BY audit_id;
