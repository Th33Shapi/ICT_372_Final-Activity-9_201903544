-- Question 7: Water Meter Readings and Billing

DROP VIEW IF EXISTS v_overdue_bills;
DROP TRIGGER IF EXISTS trg_readings_validate_meter ON readings;
DROP FUNCTION IF EXISTS fn_trg_readings_validate_meter();
DROP PROCEDURE IF EXISTS pr_refresh_receivables();
DROP PROCEDURE IF EXISTS pr_generate_bill(INTEGER, DATE);
DROP FUNCTION IF EXISTS fn_water_charge(NUMERIC);
DROP TABLE IF EXISTS receivable_snapshot;
DROP TABLE IF EXISTS bills;
DROP TABLE IF EXISTS readings;
DROP TABLE IF EXISTS customers;

-- (a) Tables
CREATE TABLE customers (
    customer_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(10, 2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge NUMERIC(12, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(12, 2) NOT NULL CHECK (total_due >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units must be non-negative and not NULL';
    END IF;

    IF p_units = 0 THEN
        RETURN 0.00;
    ELSIF p_units <= 10 THEN
        RETURN ROUND(p_units * 5.00, 2);
    ELSE
        RETURN ROUND((10 * 5.00) + ((p_units - 10) * 8.00), 2);
    END IF;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev NUMERIC(10, 2);
    v_curr NUMERIC(10, 2);
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_reading_id IS NULL OR p_due_on IS NULL THEN
        RAISE EXCEPTION 'Reading ID and due date cannot be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading ID % does not exist', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading ID % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_readings_validate_meter()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.previous_reading IS NULL OR NEW.current_reading IS NULL THEN
        RAISE EXCEPTION 'Meter readings cannot be NULL';
    END IF;

    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be less than previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_validate_meter
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_trg_readings_validate_meter();

-- Seed data (0, 6, 10, 15, and 22 units)
INSERT INTO customers (full_name)
VALUES
    ('Mwila Chileshe'),
    ('Joyce Mwanza'),
    ('Stephen Katongo');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
VALUES
    (1, (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE, 100.00, 100.00),
    (1, (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE, 100.00, 115.00),
    (2, (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE, 250.00, 260.00),
    (2, (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE, 260.00, 282.00),
    (3, (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE, 40.00, 46.00),
    (3, (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE, 46.00, 56.00);

CALL pr_generate_bill(1, CURRENT_DATE - 35);
CALL pr_generate_bill(2, CURRENT_DATE - 5);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE - 10);
CALL pr_generate_bill(5, CURRENT_DATE - 25);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

UPDATE bills SET amount_paid = 50.00 WHERE reading_id = 3;
UPDATE bills SET amount_paid = 46.00 WHERE reading_id = 4;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    ROUND(b.charge - b.amount_paid, 2) AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge
ORDER BY b.due_on, c.full_name;

SELECT * FROM v_overdue_bills;

-- (f) Index
-- Partial index on due_on for unpaid bills only.
CREATE INDEX idx_bills_unpaid_due_on
    ON bills (due_on)
    WHERE amount_paid < charge;

ANALYZE bills;

EXPLAIN (ANALYZE, BUFFERS)
SELECT bill_id, reading_id, charge, amount_paid, due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00) INTO v_total
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;
END;
$$;

-- Daily at 00:30 (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_receivables',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);
*/

-- Quick checks
SELECT fn_water_charge(0) AS zero_u, fn_water_charge(10) AS ten_u, fn_water_charge(15) AS fifteen_u;
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;
