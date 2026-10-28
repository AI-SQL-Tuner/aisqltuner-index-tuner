# Impact benchmark: challenge scenario on VMEnt\SQL25

[Issue #2](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/2), part 2, first slice: does applying the recommendations make the workload cheaper, and by how much?

- **Date:** 2026-10-28
- **Server:** `VMEnt\SQL25`, SQL Server 17.0.1000.7 Enterprise Developer Edition, 4 vCPU, 31 GB, MAXDOP 4
- **Database:** `IndexTunerChallenge` (the part 1 challenge database, 1.8 GB), reverted to a snapshot before every trial
- **Model:** `gpt-5.6-luna`, reasoning effort `medium`, background mode
- **Harness:** the desktop `bench` harness (AI-SQL-Tuner/aisqltuner, `bench/`), with the stored-procedure arms added in [AI-SQL-Tuner/aisqltuner#247](https://github.com/AI-SQL-Tuner/aisqltuner/pull/247). Scenario definition hash `b378d063ab5af581`
- **Matrix:** 2 arms × 5 replicates, in randomized order. Every trial answered the same pinned payload (SHA-256 `a97961f2ec009fed`), and every trial had the same system prompt hash (`A11117F53BDB1EA2`)

## Arms

| Arm | What was applied |
|---|---|
| `proc-create` | `sp_AIIndexTuner @Mode = 'CREATE'` with default change controls: only the `CreateIndex` rows that pass validation. Filtered and columnstore indexes, drops, consolidations, heap rebuilds and re-trusts stay recommend-only |
| `proc-reviewed` | `sp_AIIndexTuner @Mode = 'RECOMMEND'`, then every stored script classified and applied by the harness, the way a DBA who follows all the advice would. Scripts with no SQL, or with a Query Store call against IDs from another database, are counted as not applicable |

## Workload and protocol

The workload has 16 queries, one or more per challenge case, and each runs in its own batch so that Extended Events can attribute its cost:
- 13 reads (`r01`–`r13`), covering C1–C4 and C6–C14;
- 3 committed writes (`w01`–`w03`): SkewTickets close and reopen (C2), FactEvents updates and inserts (C4), and AuditQueue enqueue and dequeue (C5).

Each trial follows the same steps:
1. Revert the snapshot.
2. Run 10 history passes, so that Query Store and the DMVs have something to report.
3. Run 2 warm-up passes, then 5 measured baseline passes.
4. Tune and apply.
5. Clear the plan cache.
6. Run 2 warm-up passes, then 5 measured post passes.

Statistics stay as the image had them. The harness checks the result hash of 11 of the read queries before and after.

**The noise floor** (matrix 1) is three trials with no tuning. The change between baseline and post passes was:

| Measure | Noise floor |
|---|---:|
| Read logical reads | **0.002%** |
| Read CPU | 11.6% |
| Read elapsed time | 10.4% |
| Write logical reads | 18.2% |
| Write CPU | 61.9% |

Write CPU is a few milliseconds per pass, so it is almost all noise. **The write CPU column below cannot be used to support a claim.** Write logical reads can.

## Results

### Per trial

| Arm | Rep | Trial | Read reads | Read CPU | Total time | Queries improved / regressed | Scripts | Applied | Net index MB |
|---|---:|---:|---:|---:|---:|---|---:|---:|---:|
| proc-create | 1 | 5 | −86.2% | −66.0% | −64.3% | 5 / 2 | 20 | 9 / 9 | 524 |
| proc-create | 2 | 6 | −85.8% | −66.2% | −64.8% | 2 / 2 | 21 | 7 / 7 | 459 |
| proc-create | 3 | 9 | −52.2% | −59.7% | −58.6% | 4 / 2 | 16 | 6 / 6 | 207 |
| proc-create | 4 | 10 | −85.9% | −67.7% | −64.8% | 5 / 1 | 20 | 8 / 8 | 210 |
| proc-create | 5 | 13 | −85.8% | −69.1% | −67.2% | 7 / 0 | 22 | 11 / 11 | 240 |
| proc-reviewed | 1 | 4 | −91.2% | −80.4% | −77.4% | 7 / 2 | 21 | 17 / 17 | 39 |
| proc-reviewed | 2 | 7 | −91.8% | −78.0% | −69.0% | 6 / 0 | 18 | 14 / 14 | 154 |
| proc-reviewed | 3 | 8 | −93.8% | −81.4% | −79.0% | 9 / 0 | 22 | 18 / 20 | 112 |
| proc-reviewed | 4 | 11 | −94.2% | −82.9% | −79.5% | 11 / 0 | 20 | 18 / 18 | 170 |
| proc-reviewed | 5 | 12 | −91.5% | −80.7% | −77.9% | 7 / 1 | 20 | 16 / 16 | 557 |

The *improved / regressed* column counts queries whose CPU moved by more than the noise floor.

### Per arm (mean of 5)

| Arm | Read reads | Read CPU | Total time | Net index MB | Scripts applied |
|---|---:|---:|---:|---:|---:|
| **proc-create** | **−79.2%** (−52 to −86) | **−65.7%** | −63.9% | 328 | 41 of 99 |
| **proc-reviewed** | **−92.5%** (−91 to −94) | **−80.7%** | −76.6% | 206 | 83 of 85 applicable |

**Both arms improve by far more than the noise floor in every trial.** Even the weakest trial, proc-create rep 3, is more than 4 times the read CPU floor.

**proc-reviewed is better than proc-create on every benefit measure,** and it adds less index space on average.

**proc-reviewed is also more consistent.** Its read reads fall within a 3-point range. proc-create's range is 34 points.

**No result hash changed** in any of the 110 hashed query comparisons (11 queries × 10 trials).

### Per query (mean post vs baseline across 5 trials; improved = trials beyond the noise floor)

| Query | Case | Baseline reads | proc-create reads | improved | proc-reviewed reads | improved | Why |
|---|---|---:|---:|---:|---:|---:|---|
| r01 | C1 low-cardinality | 799,500 | −99.8% | 5/5 | −99.9% | 5/5 | Both arms created the selective covering index |
| r02 | C2 skewed filter | 325,620 | **0%** | 0/5 | −99.7% | 5/5 | The fix is a filtered index, which CREATE mode never applies: *"filtered indexes are recommend-only"* |
| r03 | C3 10M-row analytic | 235,882 | **0%** | 0/5 | −84.5% | 5/5 | The fix is a nonclustered columnstore. Under the default `@AllowColumnstore = NULL`, a columnstore index is recommended but not created |
| r04 | C4 5M-row mixed | 90,446 | −46.8% | 4/5 | −9.2% | 1/5 | proc-create applied the rowstore `EventDate` index more often. The FactEvents write cost is in `w02` |
| r05 | C6 overlapping suggestions | 2,071,690 | −99.8% | 5/5 | −99.9% | 5/5 | |
| r06 | C7 key order | 522,900 | −99.9% | 5/5 | −99.9% | 5/5 | |
| r07 | C8 LOB in INCLUDE | 1,171,800 | −99.9% | 5/5 | −99.9% | 5/5 | |
| r08 | C9 non-SARGable | ~272,000 | −3% | 1/5 | −2% | 1/5 | Expected: the fix is a query rewrite, and the benchmark measures the original text |
| r09 | C10 duplicates | 394,629 | 0% | 0/5 | −35.9% | 3/5 | proc-reviewed improved it by 59.8% in 3 trials and proc-create in none. Not yet traced to one script |
| r10 | C11 already covered | 582 | 0% | 0/5 | 0% | 0/5 | Expected: nothing to do |
| r11 | C12 heap | 3,113,214 | −80.0% | 4/5 | −99.97% | 5/5 | Both arms cover the query with an index on `BatchId`. proc-create rep 3 left it out |
| r12 | C13 untrusted FK | 191,849 | −93.7% | 5/5 | −81.1% | 5/5 | A Payments date index does most of the work. One proc-reviewed trial (rep 2) improved by only 6% |
| r13 | C14 forced plan | 4,666 | −18.0% | 1/5 | −34.5% | 2/5 | Improved only in the runs that recreated the `IX_Readings_Kind` index the forced plan needs (proc-create rep 4, proc-reviewed reps 3 and 5) |
| w01 | C2 writes | 302 | 0% | — | 0% | — | |
| w02 | C4 writes | 2,262 | **+80%** | 4/5 regressed | **+47%** | 2/5 regressed | The cost of the FactEvents index, as C4 predicts |
| w03 | C5 queue | ~107,500 | −38.8% | 2/5 | −92.6% | 5/5 | proc-reviewed applied a pending-queue index in every trial, usually a filtered one, which proc-create can't apply |

## What this shows

1. **On this workload, the free proc's CREATE mode halves the workload's cost or better.** Read CPU fell 60–69% in every proc-create trial. These are validated nonclustered indexes only, applied with no review.
2. **A DBA who reviews and applies every recommendation gets about 15 more points:** −92.5% reads and −80.7% CPU. The extra gain comes from the recommend-only categories:
   - **the C2 filtered index:** −99.7% reads on `r02`;
   - **the C3 columnstore index:** −84.5% reads on `r03`;
   - **the C5 filtered queue index:** −92.6% reads on `w03`;
   - **the C10 drops**, which also save space.

   This is the number the plan said would decide whether validated apply should be extended. The columnstore and filtered-index gaps are the largest. Plain consolidation and drops add little to the benefit, but they offset space.
3. **Writes pay where the cases say they should.** The FactEvents index (C4) made `w02` cost 47–80% more reads. That cost was paid for a read gain on `r04` that is modest and inconsistent. proc-create took this trade-off more often (4 of 5 trials) because it applies the rowstore `EventDate` index without weighing the writes. This supports the C4-P1 finding in [issue #21](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/21).
4. **Index space depends heavily on the run** (39–557 MB). proc-reviewed drops 3–4 indexes per trial and sometimes uses page compression, but one trial (rep 5) still added 557 MB. The mean read reduction per GB added is about 910 points for proc-reviewed and about 280 for proc-create.
5. **Two scripts failed in proc-reviewed rep 3.** Both failures are proc-side:
   - The model recommended `CX_StagingRows_BatchId` twice, once under *Other* and once under *ConsolidateIndex*, so the second `CREATE` failed because the index already existed.
   - A `ConsolidateIndex` script's `sp_rename` failed with *"@objname is ambiguous"*.

   Neither failure changed any results, and the harness rolled both back.

## Limits

- **One scenario and one model.** `tpch10-realistic`, `sqlstorm-oltp` and the `desktop`, `naive-missing-index` and `stats-only` arms are the next slices in the issue #2 plan.
- **Statistics were frozen**, so none of the gain comes from fresh statistics. A `stats-only` arm would confirm that.
- **Each query has equal weight (1).** The read totals are dominated by the large scans (`r05`, `r07`, `r11`), so the CPU column is the fairer headline.
- **Write CPU is below the noise floor** and is not reported as a finding.
- **Run cost:** each tuning call used 31,588 input tokens and about 8,000 output tokens. Tuning wall time was 49–85 s per run.

## Reproduce

Using the desktop harness on the SQL Server host:

```
bench validate    --scenario bench/scenarios/challenge.json --server tcp:localhost,51433
bench prepare     --scenario bench/scenarios/challenge.json --server tcp:localhost,51433
bench noise-floor --scenario bench/scenarios/challenge.json --server tcp:localhost,51433
bench matrix      --scenario bench/scenarios/challenge.json --server tcp:localhost,51433 \
                  --models proc-create/gpt-5.6-luna,proc-reviewed/gpt-5.6-luna --effort medium --replicates 5
```

Prerequisites:
- the challenge database, created by `bench/challenge/00_Create-ChallengeDb.sql` and populated by `bench/challenge/01_Create-ChallengeTables.sql`;
- `sp_AIIndexTuner` installed, with `AIIndexTuner.Config` set to the `gpt-5.6-luna` deployment and `medium` effort;
- the prerequisites in [PREREQUISITES.md](../PREREQUISITES.md).

All of the results are in the harness's `TunerBench` database: matrix 1 is the noise floor and matrix 2 is this run.
