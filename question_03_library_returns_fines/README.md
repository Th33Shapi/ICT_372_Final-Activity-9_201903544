# Question 3: Library Returns and Overdue Fines

SQL script: [question_03.sql](./question_03.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_loans_unreturned_book
    ON loans (book_id)
    WHERE returned_on IS NULL;
```

A partial index on `book_id` with `WHERE returned_on IS NULL` excludes returned loans, keeping the index small and directly matching searches for a book's open loans.

```text
Index Scan using idx_loans_unreturned_book on loans  (cost=0.13..8.15 rows=1 width=29) (actual time=0.068..0.069 rows=2.00 loops=1)
  Index Cond: (book_id = 1)
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.080 ms
Execution Time: 0.084 ms
```
