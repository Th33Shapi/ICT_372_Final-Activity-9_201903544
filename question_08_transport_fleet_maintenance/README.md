# Question 8: Transport Fleet Maintenance

SQL script: [question_08.sql](./question_08.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_trips_vehicle_trip_on
    ON trips (vehicle_id, trip_on);
```

`vehicle_id` leads for the equality filter and `trip_on` follows for the date-range scan within that vehicle's trips.

```text
Index Scan using idx_trips_vehicle_trip_on on trips  (cost=0.14..8.19 rows=2 width=20) (actual time=0.120..0.123 rows=2.00 loops=1)
  Index Cond: ((vehicle_id = 2) AND (trip_on >= (CURRENT_DATE - 7)) AND (trip_on <= CURRENT_DATE))
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.098 ms
Execution Time: 0.140 ms
```
