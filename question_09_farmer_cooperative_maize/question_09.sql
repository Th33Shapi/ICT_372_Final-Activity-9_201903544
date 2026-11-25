-- Question 9: Farmer Cooperative Maize Deliveries

DROP VIEW IF EXISTS v_farmer_amount_due;
DROP TRIGGER IF EXISTS trg_deliveries_calculate_value ON deliveries;
DROP FUNCTION IF EXISTS fn_trg_deliveries_calculate_value();
DROP PROCEDURE IF EXISTS pr_refresh_purchases(DATE);
DROP PROCEDURE IF EXISTS pr_receive_delivery(INTEGER, CHAR, NUMERIC, DATE);
DROP FUNCTION IF EXISTS fn_maize_rate(CHAR);
DROP TABLE IF EXISTS daily_purchases;
DROP TABLE IF EXISTS deliveries;
DROP TABLE IF EXISTS farmers;

-- (a) Tables
CREATE TABLE farmers (
    farmer_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value NUMERIC(12, 2) NOT NULL CHECK (total_value > 0),
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(12, 2) NOT NULL CHECK (total_weight >= 0),
    total_value NUMERIC(12, 2) NOT NULL CHECK (total_value >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE RAISE EXCEPTION 'Unsupported grade: %', p_grade;
    END CASE;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade CHAR(1),
    p_weight NUMERIC(10, 2),
    p_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_farmer_id IS NULL OR p_date IS NULL THEN
        RAISE EXCEPTION 'Farmer ID and delivery date cannot be NULL';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;

    PERFORM fn_maize_rate(p_grade);

    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Farmer ID % does not exist', p_farmer_id;
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_deliveries_calculate_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;

    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_calculate_value
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_trg_deliveries_calculate_value();

-- Seed data (loaded after installing the trigger)
INSERT INTO farmers (farmer_number, full_name)
VALUES
    ('FRM2026001', 'Benson Phiri'),
    ('FRM2026002', 'Mary Tembo'),
    ('FRM2026003', 'Andrew Lungu');

CALL pr_receive_delivery(1, 'A', 120.00, CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 80.50, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 150.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 50.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 100.00, CURRENT_DATE - 4);

INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
VALUES (3, 'C', 200.00, CURRENT_DATE - 1, TRUE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (4, 5);

-- (e) View
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0.00) AS total_unpaid_value
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

SELECT * FROM v_farmer_amount_due;

-- (f) Index
-- Composite index on (farmer_id, delivered_on) for a farmer's deliveries in a date range.
CREATE INDEX idx_deliveries_farmer_delivered_on
    ON deliveries (farmer_id, delivered_on);

ANALYZE deliveries;

EXPLAIN (ANALYZE, BUFFERS)
SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Purchase date cannot be NULL';
    END IF;

    SELECT COALESCE(SUM(weight_kg), 0.00),
           COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value = EXCLUDED.total_value;
END;
$$;

-- Daily at 01:30 for the previous day (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_purchases',
    '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$
);
*/

-- Quick checks
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);
SELECT * FROM deliveries ORDER BY delivery_id;
SELECT * FROM daily_purchases;
