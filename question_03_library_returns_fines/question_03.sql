-- Question 3: Library Returns and Overdue Fines

DROP VIEW IF EXISTS v_overdue_loans;
DROP TRIGGER IF EXISTS trg_loans_returned_audit ON loans;
DROP FUNCTION IF EXISTS fn_trg_loans_returned_audit();
DROP PROCEDURE IF EXISTS pr_refresh_overdue(DATE);
DROP PROCEDURE IF EXISTS pr_return_loan(INTEGER, DATE);
DROP FUNCTION IF EXISTS fn_loan_fine(INTEGER, DATE);
DROP TABLE IF EXISTS overdue_summary;
DROP TABLE IF EXISTS loan_audit;
DROP TABLE IF EXISTS loans;
DROP TABLE IF EXISTS books;

-- (a) Tables
CREATE TABLE books (
    book_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL CHECK (overdue_count >= 0),
    total_fine NUMERIC(12, 2) NOT NULL CHECK (total_fine >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_end_date DATE;
    v_days INTEGER;
BEGIN
    IF p_loan_id IS NULL OR p_as_of IS NULL THEN
        RAISE EXCEPTION 'Loan ID and date cannot be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist', p_loan_id;
    END IF;

    v_end_date := CASE
        WHEN v_returned_on IS NOT NULL THEN LEAST(p_as_of, v_returned_on)
        ELSE p_as_of
    END;

    v_days := GREATEST(0, v_end_date - v_due_on);
    RETURN ROUND(v_days * 2.00, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_fine NUMERIC(10, 2);
BEGIN
    IF p_loan_id IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Loan ID and return date cannot be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan ID % has already been returned', p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrowed_on (%)', p_returned_on, v_borrowed_on;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_loans_returned_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION fn_trg_loans_returned_audit();

-- Seed data
INSERT INTO books (title)
VALUES
    ('Database System Concepts'),
    ('PostgreSQL Up and Running'),
    ('Designing Data-Intensive Applications');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount)
VALUES
    (1, 'Bwalya Tembo', CURRENT_DATE - 20, CURRENT_DATE - 6, NULL, 0.00),
    (2, 'Mulenga Zulu', CURRENT_DATE - 16, CURRENT_DATE - 2, NULL, 0.00),
    (1, 'Natasha Lungu', CURRENT_DATE - 3, CURRENT_DATE + 5, NULL, 0.00),
    (3, 'Kelvin Musonda', CURRENT_DATE - 10, CURRENT_DATE, NULL, 0.00),
    (2, 'Grace Kunda', CURRENT_DATE - 14, CURRENT_DATE - 4, NULL, 0.00),
    (3, 'Patrick Sichone', CURRENT_DATE - 18, CURRENT_DATE - 8, NULL, 0.00);

CALL pr_return_loan(5, CURRENT_DATE - 4);
CALL pr_return_loan(6, CURRENT_DATE - 5);

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE
ORDER BY l.due_on, l.loan_id;

SELECT * FROM v_overdue_loans;

-- (f) Index
-- Partial index on book_id for unreturned loans only.
CREATE INDEX idx_loans_unreturned_book
    ON loans (book_id)
    WHERE returned_on IS NULL;

ANALYZE loans;

EXPLAIN (ANALYZE, BUFFERS)
SELECT loan_id, book_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12, 2);
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Snapshot date cannot be NULL';
    END IF;

    SELECT COUNT(*)::INTEGER,
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_count, v_total
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of);

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine = EXCLUDED.total_fine;
END;
$$;

-- Daily at 00:10 for CURRENT_DATE (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_overdue_summary',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);
*/

-- Quick checks
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;
SELECT * FROM loan_audit ORDER BY audit_id;
