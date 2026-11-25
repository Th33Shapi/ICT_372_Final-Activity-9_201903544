# Question 7: Water Meter Readings and Billing

SQL script: [question_07.sql](./question_07.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_bills_unpaid_due_on
    ON bills (due_on)
    WHERE amount_paid < charge;
```

A partial index on `due_on` for rows where `amount_paid < charge` excludes settled bills and directly supports date-based overdue searches.

```text
Index Scan using idx_bills_unpaid_due_on on bills  (cost=0.13..8.15 rows=1 width=19) (actual time=0.072..0.075 rows=3.00 loops=1)
  Index Cond: (due_on < CURRENT_DATE)
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.098 ms
Execution Time: 0.089 ms
```
