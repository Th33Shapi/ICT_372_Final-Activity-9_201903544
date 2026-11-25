# Question 2: University Fee Payments

SQL script: [question_02.sql](./question_02.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_payments_student_paid_on
    ON payments (student_id, paid_on);
```

`student_id` leads for the equality condition and `paid_on` follows for the date range filter in one B-tree scan.

```text
Index Scan using idx_payments_student_paid_on on payments  (cost=0.14..8.21 rows=3 width=17) (actual time=0.110..0.112 rows=3.00 loops=1)
  Index Cond: ((student_id = 2) AND (paid_on >= (CURRENT_DATE - 10)) AND (paid_on <= CURRENT_DATE))
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.096 ms
Execution Time: 0.138 ms
```
