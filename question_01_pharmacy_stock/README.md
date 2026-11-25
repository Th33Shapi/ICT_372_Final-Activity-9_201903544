# Question 1: Pharmacy Stock and Daily Sales

SQL script: [question_01.sql](./question_01.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);
```

`medicine_id` is placed first for the equality filter (`medicine_id = 1`) and `sold_on` second for the date range (`BETWEEN`), allowing a single B-tree index range scan.

```text
Index Scan using idx_sales_medicine_sold_on on sales  (cost=0.14..8.19 rows=2 width=22) (actual time=0.132..0.133 rows=2.00 loops=1)
  Index Cond: ((medicine_id = 1) AND (sold_on >= (CURRENT_DATE - 5)) AND (sold_on <= CURRENT_DATE))
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.208 ms
Execution Time: 0.160 ms
```
