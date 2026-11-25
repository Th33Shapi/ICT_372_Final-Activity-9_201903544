# Question 6: Monthly Payroll Processing

SQL script: [question_06.sql](./question_06.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_payroll_pay_month
    ON payroll (pay_month);
```

The existing `UNIQUE (employee_id, pay_month)` constraint indexes `employee_id` first, which does not serve reports filtered only by `pay_month`. Indexing `(pay_month)` supports month-wide reports without duplicating the unique composite index.

```text
Nested Loop  (cost=0.30..24.20 rows=3 width=272) (actual time=0.080..0.090 rows=3.00 loops=1)
  Buffers: shared hit=7 read=1
  ->  Index Scan using idx_payroll_pay_month on payroll p  (cost=0.14..8.20 rows=3 width=18) (actual time=0.057..0.058 rows=3.00 loops=1)
        Index Cond: (pay_month = ((date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone) - '1 mon'::interval))::date)
        Index Searches: 1
        Buffers: shared hit=1 read=1
  ->  Memoize  (cost=0.15..6.84 rows=1 width=262) (actual time=0.009..0.009 rows=1.00 loops=3)
        ->  Index Scan using employees_pkey on employees e  (cost=0.14..6.83 rows=1 width=262) (actual time=0.004..0.004 rows=1.00 loops=3)
              Index Cond: (employee_id = p.employee_id)
Planning Time: 0.189 ms
Execution Time: 0.121 ms
```

### (g) Job & Run History Inspection

```sql
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll_processing';

SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll_processing')
ORDER BY start_time DESC;
```
