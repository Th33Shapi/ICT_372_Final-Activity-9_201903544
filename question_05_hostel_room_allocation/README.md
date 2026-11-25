# Question 5: Hostel Room Allocation

SQL script: [question_05.sql](./question_05.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_allocations_active_room
    ON allocations (room_id)
    WHERE status = 'ACTIVE';
```

A partial index restricted to `status = 'ACTIVE'` excludes historical `ENDED` allocations, keeping the index small for room occupancy lookups and capacity checks.

```text
Index Scan using idx_allocations_active_room on allocations  (cost=0.13..12.17 rows=2 width=16) (actual time=0.063..0.064 rows=2.00 loops=1)
  Index Cond: (room_id = 1)
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.089 ms
Execution Time: 0.078 ms
```
