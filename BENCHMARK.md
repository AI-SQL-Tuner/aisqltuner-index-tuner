# Benchmark

This is how `sp_AIIndexTuner` was tested to answer two questions ([issue #2](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/2)):

1. **Are its recommendations right?** A rubric scores each run against 16 known tuning problems.
2. **What does applying them gain?** An impact benchmark measures three workloads before and after tuning, and compares the proc with the desktop app, with SQL Server's missing-index suggestions, and with a statistics refresh.

Every result here is from `gpt-5.6-luna` at `medium` reasoning effort, with 5 runs per test, on SQL Server 2025 Enterprise Developer Edition (`VMEnt\SQL25`: 4 vCPU, 31 GB, MAXDOP 4).

## Part 1: are the recommendations right?

The challenge database ([bench/challenge/](bench/challenge/)) builds 16 known problems into a `bench` schema, one table or set of tables per case:
- low-cardinality and skewed filters;
- 10M and 5M-row fact tables where columnstore belongs;
- a write-heavy queue;
- overlapping suggestions, key order and `nvarchar(max)` in INCLUDE;
- non-SARGable predicates, duplicate indexes, a heap and an untrusted foreign key;
- a forced-plan failure, table scope and a short usage window.

37 rubric checks score each run's recommendations as *required*, *forbidden* or *preferred*. Four edited-input variants test:
- a long usage window;
- prompt injection in query text;
- a Standard-edition server;
- a payload of over 550,000 characters.

[bench/CASES.md](bench/CASES.md) explains each case and why its expected answer is right.

| Batch | Proc build (system prompt hash) | Required + forbidden | Preferred | Report |
|---|---|---:|---:|---|
| 2 | `A11117F5` | **91.3%** | 85.7% | [batch 2](bench/results/rubric-20261028-1401-VMEnt-SQL25-batch2.md) |
| 3 | `D6C7E42C` (widenings, #27) | **95.3%** | 68.6% | [batch 3](bench/results/rubric-20261030-0910-VMEnt-SQL25-batch3.md) |
| 4 | `D6C7E42C` | **94.7%** | 80.0% | [batch 4](bench/results/rubric-20261030-0945-VMEnt-SQL25-batch4.md) |

*Required + forbidden* is the score that matters: what the model must do, and what it must never do. *Preferred* checks are better answers among acceptable ones. With 5 runs per check, one run is 20 points, so batches 3 and 4 differ by run-to-run variance.

## Part 2: what does applying them gain?

### Scenarios

| Scenario | Database | Workload |
|---|---|---|
| **challenge** | `IndexTunerChallenge`, 1.8 GB: the part 1 database | 13 reads and 3 committed writes, one or more per case |
| **sqlstorm-oltp** | `SQLStormOltp`, 1.9 GB: a Stack Overflow sample with a single-column index on every foreign-key column | 4,000 short reads and 480 committed writes per pass |
| **tpch10-realistic** | `tpch10`, 22 GB: TPC-H scale factor 10, with triggers that maintain summary tables | 6 TPC-H-derived reports, plus 2 refresh writes that are rolled back |

### Arms

| Arm | What gets applied |
|---|---|
| `proc-create` | `sp_AIIndexTuner @Mode = 'CREATE'`: only what the proc validates and builds itself |
| `proc-reviewed` | Every script the proc recommends, applied as a DBA who follows all the advice would |
| `desktop` | The [AI SQL Tuner](https://aisqltuner.com) desktop app's IndexTuning goal, every script applied |
| `naive-missing-index` | One index per missing-index DMV suggestion, exactly as suggested: no model |
| `stats-only` | `UPDATE STATISTICS ... WITH FULLSCAN` on the workload's tables, and nothing else: a control for how much of a gain fresh statistics alone give |

### Protocol

The protocol is the desktop `bench` harness's (AI-SQL-Tuner/aisqltuner, [#247](https://github.com/AI-SQL-Tuner/aisqltuner/pull/247)). Each trial:
1. reverts a database snapshot;
2. measures the workload in warm-up and measured baseline passes;
3. tunes and applies;
4. clears the plan cache;
5. measures the same passes again.

Every trial in a matrix answers the same pinned input. The 5 replicates run in randomized order.

Each scenario's **noise floor** comes from untuned trials, measured the same way. **No claim is made for a change smaller than its floor.**

### Metrics

| Family | Metric |
|---|---|
| **Benefit** | **Read logical reads** over the read queries (the headline, because its floor is near 0%) |
| | **Read CPU** |
| | **Total execution time:** the elapsed time of the whole workload, reads and writes together |
| | Queries improved, unchanged or regressed |
| **Cost** | Net index space added, after drops |
| | Write-query cost, kept apart from the benefit |
| **Quality** | Scripts applied, blocked or failed |
| | Result-hash mismatches: a query that returns different rows after tuning |
| **Efficiency** | Read reduction per GB of index added |
| **Run cost** | Tokens and tuning time |

### Results (mean of 5 trials)

**Read logical reads / read CPU / net index space:**

| Arm | challenge | sqlstorm-oltp | tpch10-realistic |
|---|---|---|---|
| `proc-create` | −79% / −66% / 328 MB | −32% / −34% / 26 MB | −86% / −23% / 6.4 GB |
| `proc-create` with widenings (#27) | | −79% / −60% / 42 MB | |
| `proc-reviewed` | −93% / −81% / 206 MB | −79% / −54% / 37 MB | −86% / −17% / 5.2 GB |
| `desktop` | −83% / −74% / 465 MB | −78% / −53% / 34 MB | −85% / −13% / 3.6 GB |
| `naive-missing-index` | −90% / −72% / 2,075 MB | −1% / −19% / 13 MB | −86% / −23% / 5.8 GB |
| `stats-only` | −0.3% / 0% / none | +0.3% / −2% / none | −59% / −13% / none |
| *Noise floor (reads / CPU)* | *0.002% / 11.6%* | *0.04% / 15.8%* | *0.03% / 4.3%* |

**Total execution time:**

| Arm | challenge | sqlstorm-oltp | tpch10-realistic |
|---|---:|---:|---:|
| `proc-create` | **−63.9%** | **−25.1%** | −14.2% |
| `proc-create` with widenings (#27) | | **−43.1%** | |
| `proc-reviewed` | **−76.6%** | **−39.2%** | −14.9% |
| `desktop` | **−72.4%** | **−38.0%** | −21.1% |
| `naive-missing-index` | **−70.7%** | **−13.9%** | −14.1% |
| `stats-only` | 0.0% | −12.9%, or −1.8% without one outlier trial | −16.5% |
| *Noise floor* | *10.6%* | *8.1%* | *22.2%* |

Bold changes are beyond the scenario's noise floor:
- **challenge:** applying the advice cut total execution time by two-thirds to three-quarters.
- **sqlstorm-oltp:** it cut it by about 40%.
- **tpch10-realistic:** every arm's change is inside the 22.2% floor, so this scenario supports no claim about execution time. Its reads and CPU are tight and are the measures to read there.

**No query returned different results** in any of the 75 arm trials, and no trial was flagged as suspect.

### What it shows

1. **The reviewed advice is at or near the best arm in every scenario.** On reads and read CPU it beat the desktop app on challenge, with less than half the index space, and matched it on the other two.
2. **CREATE mode on its own captures most of it.**
   - **challenge:** it trails because filtered and columnstore indexes stay review-only.
   - **sqlstorm-oltp:** it trailed because the model often filed the fix as a widening of an existing index. Since [#26](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/26), CREATE mode widens indexes in place, and it matches the reviewed advice there.
   - **tpch10-realistic:** it ties the other arms.
3. **The missing-index DMV baseline swings from near-best to useless.**
   - **challenge:** it is near-best on reads, at ten times the index space.
   - **sqlstorm-oltp:** it is useless. It never suggested the two ordered covering indexes that matter.
   - **tpch10-realistic:** every arm built its four suggestions.
4. **Writes pay where they should, and can gain.** New indexes made some writes cost more: 47–100% more reads on challenge's FactEvents writes, depending on the arm,, and +13% on sqlstorm-oltp's vote insert. On tpch10-realistic the refresh writes got about 80% cheaper, because a new index serves a trigger's lookup.
5. **A statistics refresh alone gains nothing on two scenarios, and a lot on the third.** On tpch10-realistic it cut reads by 59%. All of that was on one query, whose plan improved once its statistics were built from a full scan instead of the default sample. No model recommended it.

Reports, with per-trial and per-query results:
- [challenge](bench/results/impact-20261028-VMEnt-SQL25-challenge.md)
- [sqlstorm-oltp](bench/results/impact-20261030-VMEnt-SQL25-sqlstorm-oltp.md)
- [tpch10-realistic](bench/results/impact-20261030-VMEnt-SQL25-tpch10-realistic.md)

Every report says how to rerun its matrices.

## Limits

- **One model and one effort level.** Other models and effort levels aren't covered yet.
- **Different inputs for proc and desktop.** Each tool answered its own collector's payload, so the comparison covers the collector, the prompt and the scripts together, as the products run.
- **Three workloads.** They are synthetic or derived, not production traces.

## Not done yet

| Item | Status |
|---|---|
| **Rerun the rubric automatically on prompt and collector changes**, so that a change that drops a case's pass rate is caught before merge | **Deferred.** A meaningful run needs a SQL Server 2025 instance with a live model endpoint and a batch of paid model calls, so it can't run in CI as the repo stands. Until it does, rerun `Run-Rubric.ps1 -Mode Live` by hand after a prompt or collector change, as was done for #27 (batches 3 and 4). `-Mode Validate` with canned answers needs no endpoint, and it checks the rubric itself |
| Part 1 on Azure SQL Database (the Dev EMS database, scoped to the `bench` schema) | Not yet run. `Run-Rubric.ps1 -Azure` supports it ([PREREQUISITES.md](bench/PREREQUISITES.md)) |
| A Database Engine Tuning Advisor (`dta`) arm | Future comparison, out of the initial scope |

## Rerun

**Part 1:** see [bench/PREREQUISITES.md](bench/PREREQUISITES.md).

```powershell
.\bench\Run-Rubric.ps1 -Server localhost -Mode Validate -Scale 0.1 -Reps 60   # canned answers, no endpoint
.\bench\Run-Rubric.ps1 -Server VMEnt -Mode Live                                # gpt-5.6-luna, medium, 5 iterations
```

**Part 2:** the desktop `bench` harness, on the SQL Server host:

```
bench validate | prepare | noise-floor --scenario <scenario>.json --server <server>
bench matrix --scenario <scenario>.json --server <server> --effort medium --replicates 5 --models <arms>
```

Each report lists its exact commands and matrices. All raw results are in the harness's `TunerBench` database.
