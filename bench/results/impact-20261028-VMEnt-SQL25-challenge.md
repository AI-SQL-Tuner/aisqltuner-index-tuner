# Impact benchmark: challenge scenario on VMEnt\SQL25

[Issue #2](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/2), part 2: does applying the recommendations make the workload cheaper, and by how much? And how does the free proc compare with the desktop app, and with simply creating every index SQL Server's missing-index DMV suggests?

- **Date:** 2026-10-28
- **Server:** `VMEnt\SQL25`, SQL Server 17.0.1000.7 Enterprise Developer Edition, 4 vCPU, 31 GB, MAXDOP 4
- **Database:** `IndexTunerChallenge` (the part 1 challenge database, 1.8 GB), reverted to a snapshot before every trial
- **Model:** `gpt-5.6-luna`, reasoning effort `medium`
- **Harness:** the desktop `bench` harness (AI-SQL-Tuner/aisqltuner, `bench/`), with the stored-procedure arms added in [AI-SQL-Tuner/aisqltuner#247](https://github.com/AI-SQL-Tuner/aisqltuner/pull/247). Scenario definition hash `b378d063ab5af581`
- **Matrices:**

  | Matrix | Arms | Trials | Pinned payload (SHA-256) | System prompt hash |
  |---|---|---|---|---|
  | 2 | `proc-create`, `proc-reviewed` | 2 × 5, in randomized order | `a97961f2ec009fed` (the proc's collector) | `A11117F53BDB1EA2` |
  | 3 | `desktop` | 5 | `a03bdcce80235226` (the desktop app's collector) | `3df11a761fb32f72` |
  | 4 | `naive-missing-index` | 5 | the missing-index DMV's 21 suggestions | none: no model |

  The harness can't put proc, desktop and naive arms in one matrix, because each answers a different input. The matrices share the snapshot, the workload, the protocol and the noise floor, and every result is a change measured within its own trial. So they compare **the two products as they run**, not two prompts on the same input.

## Arms

| Arm | What was applied |
|---|---|
| `proc-create` | `sp_AIIndexTuner @Mode = 'CREATE'` with default change controls: only the `CreateIndex` rows that pass validation. Filtered and columnstore indexes, drops, consolidations, heap rebuilds and re-trusts stay recommend-only |
| `proc-reviewed` | `sp_AIIndexTuner @Mode = 'RECOMMEND'`, then every stored script classified and applied by the harness, the way a DBA who follows all the advice would. Scripts with no SQL, or with a Query Store call against IDs from another database, are counted as not applicable |
| `desktop` | The desktop app's IndexTuning goal through the dev EMS, then every script in its report classified and applied the same way as `proc-reviewed` |
| `naive-missing-index` | One nonclustered index per `sys.dm_db_missing_index_details` row for the database, keyed and included exactly as suggested: no model, no consolidation, no weighing of writes. Close to what Microsoft's 2006 AutoIndex prototype did. The suggestions are captured after the baseline, like the other arms' input, and pinned, so all 5 trials apply the same 21 indexes |

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
| desktop | 1 | 14 | −81.6% | −76.5% | −73.2% | 7 / 0 | 12 | 11 / 11 | 246 |
| desktop | 2 | 15 | −68.7% | −59.9% | −60.6% | 7 / 0 | 11 | 8 / 10 | 281 |
| desktop | 3 | 16 | −92.0% | −75.9% | −74.1% | 10 / 1 | 16 | 13 / 15 | 483 |
| desktop | 4 | 17 | −82.3% | −77.0% | −74.4% | 7 / 1 | 16 | 14 / 15 | 602 |
| desktop | 5 | 18 | −91.9% | −82.2% | −79.9% | 8 / 0 | 10 | 9 / 10 | 711 |
| naive-missing-index | 1 | 19 | −90.1% | −72.1% | −70.0% | 7 / 0 | 21 | 21 / 21 | 2,075 |
| naive-missing-index | 2 | 20 | −90.1% | −72.6% | −70.7% | 7 / 0 | 21 | 21 / 21 | 2,075 |
| naive-missing-index | 3 | 21 | −90.1% | −73.0% | −71.6% | 8 / 0 | 21 | 21 / 21 | 2,075 |
| naive-missing-index | 4 | 22 | −90.1% | −72.1% | −70.3% | 7 / 0 | 21 | 21 / 21 | 2,075 |
| naive-missing-index | 5 | 23 | −90.1% | −72.9% | −71.1% | 9 / 0 | 21 | 21 / 21 | 2,075 |

The *improved / regressed* column counts queries whose CPU moved by more than the noise floor.

### Per arm (mean of 5)

| Arm | Read reads | Read CPU | Total time | Net index MB | Scripts applied | Tuning time |
|---|---:|---:|---:|---:|---:|---:|
| **proc-create** | **−79.2%** (−52 to −86) | **−65.7%** | −63.9% | 328 | 41 of 99 | 73–85 s |
| **proc-reviewed** | **−92.5%** (−91 to −94) | **−80.7%** | −76.6% | 206 | 83 of 85 applicable | 49–57 s |
| **desktop** | **−83.3%** (−69 to −92) | **−74.3%** | −72.4% | 465 | 55 of 61 applicable | 79–102 s |
| **naive-missing-index** | **−90.1%** | **−72.5%** | −70.7% | **2,075** | 105 of 105 | none |

**Every arm improves by far more than the noise floor in every trial.** Even the weakest trial, proc-create rep 3, is more than 4 times the read CPU floor.

**proc-reviewed is the best arm on every benefit measure.** It also adds the least index space and is the most consistent among the model arms: its read reads fall within a 3-point range, against 23 points for desktop and 34 for proc-create. The naive arm applies the same 21 indexes every time, so its spread is only measurement noise.

**The naive arm is a strong baseline on reads, but it pays for them with ten times the storage.** It comes within 2.4 points of proc-reviewed on reads and beats both proc-create and desktop. On read CPU it trails proc-reviewed by 8 points, and it adds 2,075 MB against 206 MB. Its read reduction per GB added is 44 points, against about 910 for proc-reviewed.

**The desktop arm lands between the two proc arms,** and it adds the most index space. Its best trials match proc-reviewed, but it is less consistent, for the reasons under *What this shows*.

**No result hash changed** in any of the 220 hashed query comparisons (11 queries × 20 trials).

### Per query (mean post vs baseline across 5 trials; improved = trials beyond the noise floor)

| Query | Case | Baseline reads | proc-create | improved | proc-reviewed | improved | desktop | improved | naive | improved | Why |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| r01 | C1 low-cardinality | 799,500 | −99.8% | 5/5 | −99.9% | 5/5 | −99.9% | 5/5 | −99.6% | 5/5 | Every arm created the selective covering index |
| r02 | C2 skewed filter | 325,620 | **0%** | 0/5 | −99.7% | 5/5 | −99.6% | 5/5 | **0%** | 0/5 | The fix is a filtered index. CREATE mode never applies one: *"filtered indexes are recommend-only"*. The DMV never suggests one, and it suggested nothing for this query |
| r03 | C3 10M-row analytic | 235,882 | **0%** | 0/5 | −84.5% | 5/5 | −67.7% | 4/5 | −54.1% | 5/5 | The fix is a nonclustered columnstore. Under the default `@AllowColumnstore = NULL`, the proc recommends one but doesn't create it. Desktop rep 3's columnstore script failed (no key list). The naive arm's three wide rowstore indexes (1,124 MB) got about two-thirds of the columnstore's gain |
| r04 | C4 5M-row mixed | 90,446 | −46.8% | 4/5 | −9.2% | 1/5 | −26.9% | 3/5 | −44.1% | 5/5 | The arms that applied a rowstore FactEvents date index more often gained more here. The write cost of that index is in `w02` |
| r05 | C6 overlapping suggestions | 2,071,690 | −99.8% | 5/5 | −99.9% | 5/5 | −79.9% | 4/5 | −99.7% | 5/5 | Desktop rep 2 recommended no CustomerContacts index. The naive arm created all 4 overlapping suggestions (159 MB) where one index serves |
| r06 | C7 key order | 522,900 | −99.9% | 5/5 | −99.9% | 5/5 | −99.9% | 5/5 | −99.9% | 5/5 | |
| r07 | C8 LOB in INCLUDE | 1,171,800 | −99.9% | 5/5 | −99.9% | 5/5 | −59.9% | 3/5 | −100.0% | 5/5 | Desktop reps 1 and 4 recommended no Documents index. The naive arm copied `Body nvarchar(max)` into INCLUDE (174 MB), as the DMV suggested |
| r08 | C9 non-SARGable | ~272,000 | −3% | 1/5 | −2% | 1/5 | −10.6% | 3/5 | −10.9% | 5/5 | Expected: the fix is a query rewrite, and the benchmark measures the original text |
| r09 | C10 duplicates | 394,629 | 0% | 0/5 | −35.9% | 3/5 | −35.8% | 3/5 | −59.7% | 5/5 | The naive arm's Accounts index gave −59.7% every time. The reviewed arms reached the same figure in 3 trials, not yet traced to one script |
| r10 | C11 already covered | 582 | 0% | 0/5 | 0% | 0/5 | 0% | 0/5 | 0% | 0/5 | Expected: nothing to do |
| r11 | C12 heap | 3,113,214 | −80.0% | 4/5 | −99.97% | 5/5 | −99.9% | 5/5 | −99.9% | 5/5 | Every arm covers the query with an index on `BatchId`. proc-create rep 3 left it out |
| r12 | C13 untrusted FK | 191,849 | −93.7% | 5/5 | −81.1% | 5/5 | −99.8% | 5/5 | −93.6% | 5/5 | A Payments date index does most of the work. One proc-reviewed trial (rep 2) improved by only 6% |
| r13 | C14 forced plan | 4,666 | −18.0% | 1/5 | −34.5% | 2/5 | −34.1% | 2/5 | −85.1% | 5/5 | The model arms improved only in the runs that recreated the `IX_Readings_Kind` index the forced plan needs. The DMV suggested a Readings index every time |
| w01 | C2 writes | 302 | 0% | — | 0% | — | 0% | — | 0% | — | |
| w02 | C4 writes | 2,262 | **+80%** | 4/5 regressed | **+47%** | 2/5 regressed | **+95%** | 3/5 regressed | **+100%** | 5/5 regressed | The cost of the FactEvents indexes, as C4 predicts. Desktop reps 3 and 5 nearly tripled it (+189%) |
| w03 | C5 queue | ~107,500 | −38.8% | 2/5 | −92.6% | 5/5 | −73.8% | 4/5 | −88.9% | 5/5 | The reviewed arms applied a pending-queue index, usually a filtered one, which proc-create can't apply. The naive arm's two queue indexes helped as well |

## What this shows

1. **On this workload, the free proc's CREATE mode halves the workload's cost or better.** Read CPU fell 60–69% in every proc-create trial. These are validated nonclustered indexes only, applied with no review.
2. **A DBA who reviews and applies every recommendation gets about 15 more points:** −92.5% reads and −80.7% CPU. The extra gain comes from the recommend-only categories:
   - **the C2 filtered index:** −99.7% reads on `r02`;
   - **the C3 columnstore index:** −84.5% reads on `r03`;
   - **the C5 filtered queue index:** −92.6% reads on `w03`;
   - **the C10 drops**, which also save space.

   This is the number the plan said would decide whether validated apply should be extended. The columnstore and filtered-index gaps are the largest. Plain consolidation and drops add little to the benefit, but they offset space.
3. **The proc's reviewed advice beat the desktop app's on this scenario:** 9 points of reads and 6 of CPU, with less than half the index space (206 MB against 465 MB). The desktop app found the same kinds of fix, and its best trials (reps 3 and 5) match proc-reviewed. It falls behind for three reasons:
   - **It sometimes leaves a case out.** Desktop reps 1 and 4 recommended no Documents index (C8), and rep 2 none for CustomerContacts (C6). Each omission costs a query worth more than 1M reads. The proc covered both cases in all 10 of its trials.
   - **Some of its scripts don't run.** 6 of its 61 applicable scripts failed, against 2 of 85 for proc-reviewed:
     - 4 of 5 trials wrote last-good-plan correction as `ALTER DATABASE SCOPED CONFIGURATION SET FORCE_LAST_GOOD_PLAN = ON`, or as part of `ALTER DATABASE ... SET`. That isn't valid syntax. The proc writes the correct `SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON)`.
     - Two columnstore scripts failed: one with an unclosed quotation mark, and one with no key list for a nonclustered columnstore index. The second cost rep 3 its C3 gain.
     - One script started with `USE [master]`, so the harness blocked it.
   - **It writes more expensive indexes.** Of the three model arms, it added the most space and taxed the FactEvents writes the most: +95% reads on `w02`, nearly tripled in 2 trials.
4. **Creating every missing-index suggestion is a strong baseline on reads, and that is what the AI arms have to beat.** On this workload it came within 2.4 points of proc-reviewed on reads (−90.1% against −92.5%), and it beat proc-create and desktop. The AI arms' advantage is elsewhere:
   - **Storage:** the naive arm added **2,075 MB**, ten times proc-reviewed's 206 MB. That is 44 read points per GB, against about 910.
   - **What the DMV can't suggest:** it never suggests a filtered or columnstore index. So the naive arm left C2 untouched (0% on `r02`), and on C3 it built three wide rowstore indexes (1,124 MB) that gained −54%, against −85% for one columnstore index.
   - **What the rubric forbids:**
     - it copied `Body nvarchar(max)` into an INCLUDE (C8);
     - it created 4 overlapping CustomerContacts indexes where one serves (C6);
     - it served the FactSales aggregates with long INCLUDE lists instead of columnstore (C3).

     Each pattern wins reads here at a storage cost that the workload barely charges for.
   - **Writes:** the naive arm doubled the FactEvents writes' reads in all 5 trials (+100% on `w02`).

   **Read CPU is where the naive arm falls behind:** −72.5% against −80.7%. Because this workload's writes are light, its storage and write costs barely show in the totals. On a write-heavy table they would weigh more.
5. **Writes pay where the cases say they should.** The FactEvents indexes (C4) made `w02` cost 47–100% more reads, depending on the arm. That cost was paid for a read gain on `r04` that is modest and inconsistent. Among the model arms, proc-create took this trade-off most often (4 of 5 trials), because it applies the rowstore `EventDate` index without weighing the writes. This supports the C4-P1 finding in [issue #21](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/21). The naive arm took it every time.
6. **Index space depends heavily on the arm and the run** (39–711 MB for the model arms, 2,075 MB for naive). proc-reviewed drops 3–4 indexes per trial and sometimes uses page compression, but one trial (rep 5) still added 557 MB. The mean read reduction per GB added is about 910 points for proc-reviewed, 280 for proc-create, 210 for desktop and 44 for naive.
7. **Two scripts failed in proc-reviewed rep 3.** Both failures are proc-side:
   - The model recommended `CX_StagingRows_BatchId` twice, once under *Other* and once under *ConsolidateIndex*, so the second `CREATE` failed because the index already existed.
   - A `ConsolidateIndex` script's `sp_rename` failed with *"@objname is ambiguous"*.

   Neither failure changed any results, and the harness rolled both back.

## Limits

- **One scenario and one model.** `tpch10-realistic`, `sqlstorm-oltp` and the `stats-only` arm are the next slices in the issue #2 plan.
- **Different inputs for proc and desktop.** Each answered its own collector's payload, so the comparison covers the collector, the prompt and the scripts together. It can't say which of those made the difference.
- **A read-heavy workload.** The 3 write queries are light, so storage and index maintenance cost little here. That flatters the naive arm, whose cost shows up mainly in storage and writes.
- **Statistics were frozen**, so none of the gain comes from fresh statistics. A `stats-only` arm would confirm that.
- **Each query has equal weight (1).** The read totals are dominated by the large scans (`r05`, `r07`, `r11`), so the CPU column is the fairer headline.
- **Write CPU is below the noise floor** and is not reported as a finding.
- **Run cost:**

  | Arm | Input tokens | Output tokens per run |
  |---|---:|---:|
  | Proc | 31,588 | about 8,000 |
  | Desktop | 32,557 | about 11,600 |

## Reproduce

Using the desktop harness on the SQL Server host:

```
bench validate    --scenario bench/scenarios/challenge.json --server tcp:localhost,51433
bench prepare     --scenario bench/scenarios/challenge.json --server tcp:localhost,51433
bench noise-floor --scenario bench/scenarios/challenge.json --server tcp:localhost,51433
bench matrix      --scenario bench/scenarios/challenge.json --server tcp:localhost,51433 \
                  --models proc-create/gpt-5.6-luna,proc-reviewed/gpt-5.6-luna --effort medium --replicates 5
bench matrix      --scenario bench/scenarios/challenge.json --server tcp:localhost,51433 \
                  --models gpt-5.6-luna --effort medium --replicates 5
```

The desktop matrix needs an AI SQL Tuner licence key and an EMS URL, in `AISQLTUNER_BENCH_LICENSE_KEY` and `AISQLTUNER_BENCH_EMS_URL`. The naive arm runs with `--models naive-missing-index` and needs neither.

Prerequisites:
- the challenge database, created by `bench/challenge/00_Create-ChallengeDb.sql` and populated by `bench/challenge/01_Create-ChallengeTables.sql`;
- `sp_AIIndexTuner` installed, with `AIIndexTuner.Config` set to the `gpt-5.6-luna` deployment and `medium` effort;
- the prerequisites in [PREREQUISITES.md](../PREREQUISITES.md).

All of the results are in the harness's `TunerBench` database. Matrix 1 is the noise floor, matrix 2 holds the proc arms, matrix 3 the desktop arm, and matrix 4 the naive arm.
