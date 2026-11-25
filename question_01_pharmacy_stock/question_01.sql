-- Question 1: Pharmacy Stock and Daily Sales

DROP VIEW IF EXISTS v_low_stock;
DROP TRIGGER IF EXISTS trg_medicines_stock_audit ON medicines;
DROP FUNCTION IF EXISTS fn_trg_medicines_stock_audit();
DROP PROCEDURE IF EXISTS pr_refresh_sales(DATE);
DROP PROCEDURE IF EXISTS pr_record_sale(INTEGER, INTEGER, DATE);
DROP FUNCTION IF EXISTS fn_sale_value(INTEGER, INTEGER);
DROP TABLE IF EXISTS daily_sales;
DROP TABLE IF EXISTS stock_audit;
DROP TABLE IF EXISTS sales;
DROP TABLE IF EXISTS medicines;

-- (a) Tables
CREATE TABLE medicines (
    medicine_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_medicine_id IS NULL THEN
        RAISE EXCEPTION 'Medicine ID cannot be NULL';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be greater than zero';
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INTEGER;
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    PERFORM fn_sale_value(p_medicine_id, p_quantity);

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine % (available: %, requested: %)',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_trg_medicines_stock_audit();

-- Seed data
INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES
    ('Paracetamol 500mg', 12.50, 25),
    ('Amoxicillin 250mg', 35.00, 15),
    ('Ibuprofen 400mg', 18.00, 40),
    ('Oral Rehydration Salts', 8.50, 12);

CALL pr_record_sale(1, 5, CURRENT_DATE - 3);
CALL pr_record_sale(1, 12, CURRENT_DATE - 1);
CALL pr_record_sale(2, 6, CURRENT_DATE - 2);
CALL pr_record_sale(2, 3, CURRENT_DATE - 1);
CALL pr_record_sale(3, 10, CURRENT_DATE - 1);
CALL pr_record_sale(4, 5, CURRENT_DATE);

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10
ORDER BY stock_qty, medicine_name;

SELECT * FROM v_low_stock;

-- (f) Index
-- Composite index on (medicine_id, sold_on) for equality lookup on medicine_id and range scan on sold_on.
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

ANALYZE sales;

EXPLAIN (ANALYZE, BUFFERS)
SELECT sale_id, medicine_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 5 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qty INTEGER;
    v_amount NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Date cannot be NULL';
    END IF;

    SELECT COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_qty, v_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_qty, v_amount)
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Daily at 00:15 for the previous day (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1);$$
);
*/

-- Quick checks
SELECT fn_sale_value(1, 4) AS sale_val;
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;
SELECT * FROM stock_audit ORDER BY audit_id;
