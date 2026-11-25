# Question 4: Clinic Appointment Scheduling

SQL script: [question_04.sql](./question_04.sql)

### (f) Index Justification & EXPLAIN

```sql
CREATE INDEX idx_appointments_day_doctor
    ON appointments (appointment_day, doctor_id);
```

The index is non-unique because a doctor has multiple daily slots (and may also have cancelled rows) on the same day. Leading with `appointment_day` supports both `(appointment_day, doctor_id)` lookups and date-only queries.

```text
Index Scan using idx_appointments_day_doctor on appointments  (cost=0.14..8.17 rows=2 width=32) (actual time=0.064..0.065 rows=1.00 loops=1)
  Index Cond: ((appointment_day = CURRENT_DATE) AND (doctor_id = 1))
  Index Searches: 1
  Buffers: shared hit=1 read=1
Planning Time: 0.083 ms
Execution Time: 0.077 ms
```
