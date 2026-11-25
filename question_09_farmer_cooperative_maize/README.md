# Question 9: Farmer Cooperative Maize Deliveries

SQL script: [question_09.sql](./question_09.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_deliveries_farmer_delivered_on
    ON deliveries (farmer_id, delivered_on);
```

`farmer_id` leads for exact farmer equality and `delivered_on` follows to scan the requested date range in a single B-tree lookup.

```text
Index Scan using idx_deliveries_farmer_delivered_on on deliveries  (cost=0.14..8.19 rows=2 width=30) (actual time=0.055..0.056 rows=2.00 loops=1)
  Index Cond: ((farmer_id = 1) AND (delivered_on >= (CURRENT_DATE - 7)) AND (delivered_on <= CURRENT_DATE))
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.085 ms
Execution Time: 0.069 ms
```
