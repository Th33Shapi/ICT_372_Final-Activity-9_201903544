-- Question 6: Monthly Payroll Processing

DROP VIEW IF EXISTS v_payroll_report;
DROP TRIGGER IF EXISTS trg_employees_salary_audit ON employees;
DROP FUNCTION IF EXISTS fn_trg_employees_salary_audit();
DROP PROCEDURE IF EXISTS pr_process_payroll(DATE);
DROP FUNCTION IF EXISTS fn_net_pay(INTEGER);
DROP TABLE IF EXISTS salary_audit;
DROP TABLE IF EXISTS payroll;
DROP TABLE IF EXISTS employees;

-- (a) Tables
CREATE TABLE employees (
    employee_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (allowance >= 0),
    deduction NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay NUMERIC(12, 2) NOT NULL CHECK (gross_pay >= 0),
    net_pay NUMERIC(12, 2) NOT NULL CHECK (net_pay >= 0),
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12, 2) NOT NULL CHECK (old_salary >= 0),
    new_salary NUMERIC(12, 2) NOT NULL CHECK (new_salary >= 0),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC(12, 2);
    v_allowance NUMERIC(12, 2);
    v_deduction NUMERIC(12, 2);
    v_net NUMERIC(12, 2);
BEGIN
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'Employee ID cannot be NULL';
    END IF;

    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee ID % does not exist', p_employee_id;
    END IF;

    v_net := ROUND((v_basic + v_allowance) - v_deduction, 2);
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_emp RECORD;
    v_gross NUMERIC(12, 2);
    v_net NUMERIC(12, 2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'pay_month must be the first day of a month';
    END IF;

    FOR v_emp IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        v_gross := ROUND(v_emp.basic_salary + v_emp.allowance, 2);
        v_net := fn_net_pay(v_emp.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (v_emp.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trg_employees_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION fn_trg_employees_salary_audit();

-- Seed data (active and inactive employees across two payroll months)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active)
VALUES
    ('Chisomo Banda', 8500.00, 1500.00, 1200.00, TRUE),
    ('Mubanga Phiri', 10200.00, 2000.00, 1800.00, TRUE),
    ('Taonga Zulu', 6800.00, 900.00, 750.00, TRUE),
    ('Mulenga Kunda', 7400.00, 1100.00, 950.00, TRUE);

CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE);

UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 9000.00 WHERE employee_id = 1;

CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);

-- (e) View
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.employee_id,
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month DESC, e.full_name;

SELECT * FROM v_payroll_report;

-- (f) Index
-- Single-column index on pay_month to avoid duplicating UNIQUE (employee_id, pay_month).
CREATE INDEX idx_payroll_pay_month
    ON payroll (pay_month);

ANALYZE payroll;

EXPLAIN (ANALYZE, BUFFERS)
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
WHERE p.pay_month = (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;

-- (g) Scheduled job
-- Monthly at 02:00 on day 1 for the previous month (requires pg_cron)
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'monthly_payroll_processing',
    '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$$
);

-- Inspect job and run history
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll_processing';

SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll_processing')
ORDER BY start_time DESC;
*/

-- Quick checks
CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);
SELECT * FROM salary_audit ORDER BY audit_id;
SELECT * FROM v_payroll_report;
