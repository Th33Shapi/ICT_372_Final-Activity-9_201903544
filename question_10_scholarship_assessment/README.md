# Question 10: Scholarship Application Assessment

SQL script: [question_10.sql](./question_10.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_applications_status_submitted_on
    ON applications (status, submitted_on);
```

`status` leads for the equality filter (`status = 'APPROVED'` or `'PENDING'`) and `submitted_on` follows for the date-range filter.

```text
Index Scan using idx_applications_status_submitted_on on applications  (cost=0.14..8.21 rows=3 width=26) (actual time=0.021..0.022 rows=3.00 loops=1)
  Index Cond: (((status)::text = 'APPROVED'::text) AND (submitted_on >= (CURRENT_DATE - 14)) AND (submitted_on <= CURRENT_DATE))
  Index Searches: 1
  Buffers: shared hit=2
Planning Time: 0.126 ms
Execution Time: 0.041 ms
```
