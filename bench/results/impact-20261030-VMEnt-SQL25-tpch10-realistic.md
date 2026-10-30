# Impact benchmark: tpch10-realistic scenario on VMEnt\SQL25

[Issue #2](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/2), part 2, third scenario.
- The [challenge scenario](impact-20261028-VMEnt-SQL25-challenge.md) is built from one hand-made problem per case.
- [sqlstorm-oltp](impact-20261030-VMEnt-SQL25-sqlstorm-oltp.md) is a short-statement OLTP workload.
- This one is a 10 GB TPC-H-derived reporting workload with refresh writes, from the desktop benchmark. It uses the same arms and protocol, plus the `stats-only` control.

The desktop benchmark had left this scenario out, because its writes made indexing look like no net gain. Here the writes got cheaper, for a reason given below.

- **Date:** 2026-10-30
- **Server:** `VMEnt\SQL25`, SQL Server 17.0.1000.7 Enterprise Developer Edition, 4 vCPU, 31 GB, MAXDOP 4. The database's data and log files are on a 64 GB Premium SSD (P30).
- **Database:** `tpch10`, 22.3 GB allocated: TPC-H scale factor 10, with a 60M-row `lineitem`.
  - **Source:** the desktop benchmark's copy in its "realistic" posture. Its existing indexes are left as they are: 8 clustered and 6 nonclustered on the workload tables.
  - **Triggers:** two maintain summary tables. `trg_lineitem_UpdateOrderTotals` keeps `OrderTotals`, and `trg_orders_UpdateCustomerStats` keeps `CustomerOrderStats`.
  - **Copy:** taken from the VM's SQL Server 2022 instance with a copy-only backup and restored on SQL25.
  - **Setup on SQL25:** `sp_AIIndexTuner` installed from the [#27](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/27) build, which adds widenings. The model never recommended one here, so this build behaved like the one used on the other scenarios. The image was taken by `bench prepare` and reverted before every trial.
  - **Image settings:** SIMPLE recovery, and Query Store cleared. See [Limits](#limits).
- **Model:** `gpt-5.6-luna`, reasoning effort `medium`
- **Harness:** the desktop `bench` harness with the proc, naive and stats-only arms from [AI-SQL-Tuner/aisqltuner#247](https://github.com/AI-SQL-Tuner/aisqltuner/pull/247). Scenario `tpch10-realistic` (definition hash `a7e1de8ccd1a79b3`), run with `--server tcp:localhost,51433`
- **Matrices:**

  | Matrix | Arms | Trials | Pinned payload (SHA-256) | System prompt hash |
  |---|---|---|---|---|
  | 20 | noise floor | 5 | none | none |
  | 21 | `proc-create`, `proc-reviewed` | 2 × 5, in randomized order | `be2e8cfb403d2a5d` (the proc's collector) | `D6C7E42CA8C59459`, the #27 build |
  | 22 | `naive-missing-index` | 5 | `69fdebb1d3618d92`: the missing-index DMV's 4 suggestions | none: no model |
  | 23 | `stats-only` | 5 | `b26759586f085151`: the scenario's 8 tables | none: no model |
  | 24 | `desktop` | 5 | `6e3a9ec7c936a7b2` (the desktop app's collector) | `3df11a761fb32f72` |

The arms are the ones described in the [challenge report](impact-20261028-VMEnt-SQL25-challenge.md#arms), plus one control:

| Arm | What was applied |
|---|---|
| `stats-only` | `UPDATE STATISTICS ... WITH FULLSCAN` on each table the scenario lists, and nothing else: no model, no index. It shows how much of a gain fresh statistics alone would give |

## Workload and protocol

The workload has 6 reads and 2 refresh writes, from the scenario definition:
- **Reads:** reports derived from TPC-H queries 3, 5, 7, 10, 17 and 19 (`q03`–`q19`).
- **Writes:**
  - `rf1` inserts 1,500 new orders with 4 line items each;
  - `rf2` deletes the 1,500 oldest orders with their line items.

  The harness rolls both back, so the data volume stays constant, while the index maintenance and trigger work still happen.
- **Weights:** every query weighs 10.
- **Passes per trial:** 1 warm-up pass and 3 measured passes, before and after tuning.
- **Result hashes:** the harness checks all 6 reads.

**Noise floor** (matrix 20): five untuned trials on the image used for every arm.

| Measure | Noise floor |
|---|---:|
| Read logical reads | **0.03%** |
| Read CPU | **4.3%** |
| Read elapsed time | 38.6% |
| Write logical reads | **3.2%** |
| Write CPU | **13.4%** |
| Write elapsed time | 34.2% |
| Total elapsed time | 22.2% |

**Elapsed times are noise on this scenario and support no claim.** Reads and CPU are tight, for both reads and writes. Read CPU is the fairer headline, because one query, `q05`, carries two-thirds of the baseline reads.

## Results

### Per trial

| Arm | Rep | Trial | Read reads | Read CPU | Write CPU | Scripts | Applied | Indexes added | Net index MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| proc-create | 1 | 104 | −85.9% | −23.0% | −80.8% | 18 | 4 / 4 | 4 | 6,507 |
| proc-create | 2 | 107 | −85.9% | −23.4% | −76.7% | 18 | 4 / 4 | 4 | 6,507 |
| proc-create | 3 | 109 | −85.9% | −24.3% | −75.8% | 18 | 4 / 4 | 4 | 6,507 |
| proc-create | 4 | 110 | −85.9% | −23.1% | −77.4% | 18 | 4 / 4 | 4 | 6,507 |
| proc-create | 5 | 112 | −85.9% | −20.8% | −74.3% | 19 | 4 / 4 | 4 | 6,506 |
| proc-reviewed | 1 | 105 | −86.0% | −22.0% | −77.4% | 18 | 18 / 18 | 4 | 6,156 |
| proc-reviewed | 2 | 106 | −84.6% | −20.6% | −78.9% | 19 | 18 / 18 | 4 | 6,159 |
| proc-reviewed | 3 | 108 | −85.8% | −22.8% | −77.9% | 10 | 9 / 9 | 4 | 6,155 |
| proc-reviewed | 4 | 111 | −85.9% | −23.4% | −80.4% | 18 | 18 / 18 | 4 | 6,159 |
| proc-reviewed | 5 | 113 | −88.4% | **+2.9%** | −82.7% | 18 | 18 / 18 | 4, page-compressed | 1,948 |
| desktop | 1 | 124 | −85.9% | −21.9% | −80.9% | 8 | 6 / 7 | 4 | 4,118 |
| desktop | 2 | 125 | −78.7% | **+16.8%** | −77.9% | 5 | 4 / 5 | 3, page-compressed | 1,602 |
| desktop | 3 | 126 | −85.9% | −23.6% | −82.4% | 5 | 4 / 5 | 4 | 4,118 |
| desktop | 4 | 127 | −85.8% | −21.8% | −80.8% | 6 | 5 / 6 | 4 | 6,476 |
| desktop | 5 | 128 | −87.9% | −12.3% | −82.3% | 8 | 6 / 7 | 4, row-compressed | 2,365 |
| naive-missing-index | 1–5 | 114–118 | −86.1% | −22.5% to −22.9% | −72.8% to −79.4% | 4 | 4 / 4 | 4 | 5,895 |
| stats-only | 1–5 | 119–123 | −58.5% | −11.7% to −13.9% | −0.8% to +1.8% | 8 | 8 / 8 | 0 | 0 |

*Applied* is scripts that succeeded / scripts attempted. Two desktop scripts that started with `USE [master]` were blocked by the harness and aren't counted as attempted.

### Per arm (mean of 5)

| Arm | Read reads | Read CPU | Write reads | Write CPU | Net index MB | Read points per GB | Scripts applied |
|---|---:|---:|---:|---:|---:|---:|---:|
| **proc-create** | **−85.9%** | **−22.9%** | −52.4% | **−77.0%** | 6,507 | 13.5 | 20 of 91 |
| **proc-reviewed** | **−86.1%** (−84.6 to −88.4) | **−17.2%** (−23.4 to +2.9) | −52.6% | **−79.5%** | 5,315 | 20.7 | 81 of 81 applicable |
| **desktop** | **−84.8%** (−78.7 to −87.9) | **−12.6%** (−23.6 to +16.8) | −54.8% | **−80.9%** | 3,736 | 28.9 | 25 of 30 attempted |
| **naive-missing-index** | **−86.1%** | **−22.6%** | −51.8% | **−76.1%** | 5,895 | 15.0 | 20 of 20 |
| **stats-only** | **−58.5%** | **−12.9%** | −0.9% | +0.8% | 0 | — | 40 of 40 |

**No result hash changed** in any of the 150 hashed query comparisons (6 queries × 25 trials). **No trial was flagged as suspect.**

### Per query (mean change across 5 trials)

| Query | Baseline reads | Baseline CPU s | proc-create reads / CPU | proc-reviewed | desktop | naive | stats-only | Why |
|---|---:|---:|---|---|---|---|---|---|
| q03 shipping priority | 1.03M | 4.6 | −54.8% / **+42%** | −60.2% / **+55%** | −62.3% / **+59%** | −57.2% / **+42%** | 0% / +1% | Every index arm made it read less and burn more CPU, in every trial. Compressed indexes cost more: +110% and +113% CPU with page compression (trials 113 and 125), +63% with row (trial 128) |
| **q05 local supplier volume** | **10.0M** | 10.5 | −97.4% / −12% | −97.5% / −9% | −97.5% / −8% | −97.4% / −14% | **−84.9% / −35%** | Two-thirds of the baseline reads. A full-scan statistics refresh alone fixes most of it, with the best CPU of any arm. See below |
| q07 volume shipping | 0.91M | 4.0 | −83.0% / −38% | −84.3% / −33% | −85.1% / −32% | −83.3% / −39% | 0% / −4% | The `lineitem (l_suppkey, l_shipdate)` covering index |
| q10 returned items | 1.45M | 6.5 | −93.2% / −77% | −94.0% / −74% | −75.3% / −59% | −93.6% / −77% | 0% / 0% | The `lineitem` return-flag index. Desktop rep 2 left it out, and `q10` didn't move in that trial |
| q17 small-quantity revenue | 0.44M | 0.7 | −8.8% / −54% | −8.8% / −54% | −8.8% / −55% | −8.8% / −55% | 0% / +1% | The `part (p_brand, p_container)` index |
| q19 discounted revenue | 0.67M | 1.5 | 0% / +1% | 0% / +1% | 0% / +2% | 0% / +3% | 0% / 0% | No arm found anything for it |
| **rf1 new orders** | 0.74M | 7.9 | −54.7% / **−78%** | −54.7% / **−80%** | −56.2% / **−82%** | −54.2% / **−80%** | −1.5% / 0% | The `orders` trigger's lookup. See below |
| **rf2 old orders** | 0.47M | 1.5 | −48.8% / **−85%** | −49.1% / **−85%** | −52.5% / **−87%** | −48.1% / −69% | 0% / −5% | The same trigger |

## What this shows

1. **Every arm converged on the same four indexes, and they are the DMV's four suggestions:**
   - `lineitem (l_returnflag) INCLUDE (l_orderkey, l_discount, l_extendedprice)`, or a version filtered on `l_returnflag = 'R'` and keyed on `l_orderkey`;
   - `lineitem (l_suppkey, l_shipdate) INCLUDE (l_orderkey, l_discount, l_extendedprice)`;
   - `orders (o_custkey, o_orderdate) INCLUDE (o_orderkey, o_shippriority)`;
   - `part (p_brand, p_container)`.

   The arms differ only in naming, the filtered variant and compression. Reads fell by about 86% in every arm, within 1.5 points, except for desktop rep 2, which left out the return-flag index. Unlike sqlstorm-oltp, the DMV saw every missing access path here. So the naive arm is as good as any model arm, and this scenario can't separate them on benefit.
2. **CREATE mode was enough.** It built only those four validated indexes, 20 of 91 scripts, and matched the reviewed arm on reads (−85.9% against −86.1%). It was also the steadiest model arm on read CPU: −20.8% to −24.3% in all 5 trials. Applying everything else added nothing measurable:
   - re-trusting the foreign keys;
   - rebuilding the fragmented `OrderTotals` and `CustomerOrderStats` primary keys;
   - the statistics and plan-correction settings.
3. **Index compression traded read CPU for space.** The model sometimes asked for `DATA_COMPRESSION = PAGE` or `ROW`. Those trials added 1.6–2.3 GB instead of 6.0–6.4 GB, but `q03`'s CPU rose by 63% to 113% instead of about 42%.
   - It cancelled the read CPU gain in proc-reviewed rep 5 (+2.9%) and in desktop rep 2 (+16.8%), which also lacked the return-flag index.
   - All five proc-create runs built their indexes uncompressed, which is why that arm was the steadiest.
   - Compression is still a legitimate choice where storage matters. But on this read-heavy reporting workload, it cost more CPU than it saved in reads.
4. **The refresh writes got about 80% cheaper, not more expensive.** `trg_orders_UpdateCustomerStats` recounts each changed customer's orders with `orders ... JOIN ChangedCustomers ON o_custkey`. With no index on `o_custkey`, every insert or delete of orders scans the 15M-row `orders` table. The new `orders (o_custkey, o_orderdate)` index turns that into a seek, so:
   - `rf1` fell 54–56% in reads and 78–82% in CPU;
   - `rf2` fell 48–53% in reads and about 85% in CPU.

   The extra cost of maintaining four more indexes is real, but it's far smaller than the scan it removes. That is why the scenario didn't show the write penalty that made the desktop benchmark leave it out. Without the trigger, the writes would pay for the indexes as on the other scenarios.
5. **Fresh statistics alone get two-thirds of the read reduction.** The image's statistics are the server default sample, as the scenario prescribes for production-like plans. A full-scan refresh of the 8 tables:
   - cut `q05` by 84.9% and the whole read workload by 58.5%;
   - moved no other query, and no write.

   For `q05`, the index arms got −97.4%, so the indexes add 12.5 points over the refresh. But the refresh got more read CPU back on `q05` (−35%, against −8% to −14%). The indexes build full-scan statistics on their own keys, so part of every index arm's `q05` gain may come from those statistics rather than from the access path. This benchmark can't separate the two.

   No model arm recommended a full-scan refresh. Nothing in the payload showed stale statistics, because the refresh writes are rolled back and leave no modification counts. The problem was the sample rate, not staleness.
6. **Scripts:**
   - **proc-reviewed:** all 81 applicable scripts succeeded. The proc's plan-correction script used the valid `ALTER DATABASE ... SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON)`.
   - **desktop:** 5 of 30 attempted scripts failed, one per trial, all for plan correction. Reps 1, 2 and 4 failed on `FORCE_LAST_GOOD_PLAN`, written in reps 1 and 2 as `ALTER DATABASE SCOPED CONFIGURATION SET FORCE_LAST_GOOD_PLAN = ON`. Reps 3 and 5 used a new wording, `ALTER DATABASE SCOPED CONFIGURATION SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON)`. Neither is valid.
   - **Blocked:** reps 1 and 5 each had a statistics-settings script starting with `USE [master]`, which the harness blocked.
   - Both desktop defects are in [AI-SQL-Tuner/aisqltuner#248](https://github.com/AI-SQL-Tuner/aisqltuner/issues/248). Neither failure changed any measurement.

## Limits

- **Converged answers.** All arms found the same indexes, so this scenario tests whether applying them pays off, not which tool finds better ones. The other two scenarios do that.
- **How the image was made:**
  - **Earlier attempts, none of whose trials are used:**
    - The first noise floor (matrix 12) ran on the original 32 GB P4 data disk. It saw I/O stalls of over 15 seconds and failed (read elapsed floor 443%).
    - The disk was raised to P30. Two more floors (matrices 13 and 14) didn't finish, the first because it ran before the new tier applied.
    - Matrix 15's floor passed. But matrix 16's index builds filled the disk with log, because the database was in FULL recovery, and the snapshot went suspect. Trials 74 and 75 finished before that and are discarded. Every later trial in matrices 16–19 failed.
  - **The recovered image:**
    - the disk was grown to 64 GB;
    - the suspect snapshot was dropped;
    - the database was switched to SIMPLE recovery and its Query Store cleared;
    - the image was re-taken.

    Matrix 20's floor was measured on this image, and every arm ran on it.
  - **SIMPLE recovery** changes how much log the index builds write, not what the workload does. The refresh writes are fully logged either way.
- **A different proc build from the other scenarios.** This run used the #27 build (system prompt hash `D6C7E42CA8C59459`). The challenge and first sqlstorm-oltp runs used `A11117F53BDB1EA2`. The only difference is the widening rules and `replaces_index`, which no recommendation here used.
- **Different inputs for proc and desktop**, as on the other scenarios: each answered its own collector's payload.
- **Elapsed time is noise** here (22.2% total-time floor), so no claim rests on it.
- **Run cost:**

  | Arm | Input tokens | Output tokens per run | Tuning time |
  |---|---:|---:|---:|
  | proc-create | 22,035 | 6,700–7,800 | 367–457 s, including building 6.4 GB of indexes |
  | proc-reviewed | 22,035 | 5,900–7,100 | 39–46 s, before the harness applies the scripts |
  | desktop | 21,405 | 9,200–11,100 | 70–81 s, before the harness applies the scripts |

## Reproduce

On VMEnt, with `tpch10` restored on SQL25, the tool installed in it, and its endpoint configured:

```
bench validate    --scenario bench/scenarios/tpch10-realistic.json --server tcp:localhost,51433
bench prepare     --scenario bench/scenarios/tpch10-realistic.json --server tcp:localhost,51433
bench noise-floor --scenario bench/scenarios/tpch10-realistic.json --server tcp:localhost,51433 --trials 5
bench matrix      --scenario bench/scenarios/tpch10-realistic.json --server tcp:localhost,51433 --effort medium --replicates 5 \
                  --models proc-create/gpt-5.6-luna,proc-reviewed/gpt-5.6-luna
bench matrix      ... --models naive-missing-index
bench matrix      ... --models stats-only
bench matrix      ... --models gpt-5.6-luna
```

The data volume needs at least 64 GB for the 22 GB database, its snapshot's sparse files and the index builds.

All of the results are in the harness's `TunerBench` database on SQL25, in matrices 20 to 24.
