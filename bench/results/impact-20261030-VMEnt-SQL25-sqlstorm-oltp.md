# Impact benchmark: sqlstorm-oltp scenario on VMEnt\SQL25

[Issue #2](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/2), part 2, second scenario. The [challenge scenario](impact-20261028-VMEnt-SQL25-challenge.md) is built from one hand-made problem per case. This one is an OLTP workload on a real-shaped schema, from the desktop benchmark. It uses the same four arms and the same protocol.

- **Date:** 2026-10-30
- **Server:** `VMEnt\SQL25`, SQL Server 17.0.1000.7 Enterprise Developer Edition, 4 vCPU, 31 GB, MAXDOP 4
- **Database:** `SQLStormOltp`, 1.9 GB.
  - **Source:** the desktop benchmark's copy of the SQLStorm Stack Overflow sample, in its "realistic" posture: every foreign-key column has a single-column index, and every foreign key is untrusted.
  - **Copy:** taken from the VM's SQL Server 2022 instance with a copy-only backup and restored on SQL25. The proc needs SQL Server 2025's `sp_invoke_external_rest_endpoint`.
  - **Setup on SQL25:** `sp_AIIndexTuner` installed from the same build as the challenge database. The image was taken by `bench prepare` and reverted before every trial.
- **Model:** `gpt-5.6-luna`, reasoning effort `medium`
- **Harness:** the desktop `bench` harness with the proc and naive arms from [AI-SQL-Tuner/aisqltuner#247](https://github.com/AI-SQL-Tuner/aisqltuner/pull/247). Scenario `sqlstorm-oltp`, run with `--server tcp:localhost,51433`
- **Matrices:**

  | Matrix | Arms | Trials | Pinned payload (SHA-256) | System prompt hash |
  |---|---|---|---|---|
  | 5 | noise floor | 3 | none | none |
  | 6 | `proc-create`, `proc-reviewed` | 2 × 5, in randomized order | `39e21f1a65a9bbfc` (the proc's collector) | `A11117F53BDB1EA2`, the same as on the challenge scenario |
  | 7 | `desktop` | 5 | `4d92f7ab7f0331ea` (the desktop app's collector) | `3df11a761fb32f72` |
  | 8 | `naive-missing-index` | 5 | the missing-index DMV's 1 suggestion | none: no model |

The arms are the ones described in the [challenge report](impact-20261028-VMEnt-SQL25-challenge.md#arms).

## Workload and protocol

The workload has 8 reads and 3 committed writes, from the scenario definition:
- **Reads:** 4,002 short parameterized statements per pass:
  - `r01` a post by id;
  - `r02` a question's answers;
  - `r03` a post's latest comments;
  - `r04` a user's latest posts;
  - `r05` a post's vote tally;
  - `r06` a user's profile;
  - `r07` a user's badges;
  - `r08` related posts.
- **Writes:** 480 single-row operations per pass, each committed:
  - `w01` a vote insert and score update;
  - `w02` a comment insert;
  - `w03` a view count update.
- **Weights:** reads weigh 1 and writes 2.
- **Passes per trial:** 40 history passes, then 2 warm-up passes and 5 measured passes, before and after tuning.
- **Result hashes:** the harness checks all 8 reads.

**Noise floor** (matrix 5): three untuned trials on SQL25, with the tool installed in the image.

| Measure | Noise floor |
|---|---:|
| Read logical reads | **0.0%** |
| Read CPU | 15.8% |
| Read elapsed time | 4.3% |
| Write logical reads | **0.6%** |
| Write CPU | 127.4% |

Each write statement takes about 16 ms of CPU, so write CPU is noise and is not used for any claim. Write logical reads are tight: at 0.6%, this scenario measures the write cost of an index far better than the challenge scenario does (18.2%).

## Results

### Per trial

| Arm | Rep | Trial | Read reads | Read CPU | Total time | Scripts | Applied | Indexes added / dropped | Net index MB |
|---|---:|---:|---:|---:|---:|---:|---:|---|---:|
| proc-create | 1 | 28 | −1.0% | −22.9% | −14.0% | 5 | 1 / 1 | 1 / 0 | 16 |
| proc-create | 2 | 30 | −79.0% | −53.7% | −40.6% | 8 | 3 / 3 | 3 / 0 | 37 |
| proc-create | 3 | 31 | −1.0% | −18.6% | −15.7% | 11 | 1 / 1 | 1 / 0 | 16 |
| proc-create | 4 | 34 | −79.0% | −53.5% | −38.7% | 5 | 3 / 3 | 3 / 0 | 47 |
| proc-create | 5 | 36 | −1.0% | −22.7% | −16.4% | 5 | 1 / 1 | 1 / 0 | 16 |
| proc-reviewed | 1 | 27 | −78.6% | −54.1% | −39.6% | 8 | 6 / 6 | 1 / 0 | 44 |
| proc-reviewed | 2 | 29 | −78.8% | −53.7% | −36.1% | 6 | 5 / 5 | 3 / 2 | 27 |
| proc-reviewed | 3 | 32 | −78.7% | −54.3% | −42.6% | 6 | 6 / 6 | 4 / 3 | 40 |
| proc-reviewed | 4 | 33 | −79.0% | −56.7% | −38.1% | 5 | 4 / 4 | 3 / 0 | 47 |
| proc-reviewed | 5 | 35 | −78.8% | −51.3% | −39.8% | 5 | 5 / 5 | 1 / 0 | 25 |
| desktop | 1 | 37 | −79.0% | −50.5% | −37.0% | 3 | 3 / 3 | 3 / 0 | 30 |
| desktop | 2 | 38 | −79.0% | −50.6% | −36.2% | 5 | 5 / 5 | 3 / 0 | 30 |
| desktop | 3 | 39 | −72.7% | −49.5% | −35.1% | 5 | 5 / 5 | 3 / 0 | 38 |
| desktop | 4 | 40 | −78.6% | −58.9% | −44.1% | 6 | 5 / 5 | 1 / 0 | 44 |
| desktop | 5 | 41 | −79.0% | −54.0% | −37.5% | 5 | 5 / 5 | 3 / 0 | 30 |
| naive-missing-index | 1–5 | 42–46 | −1.0% | −9.7% to −22.9% | −4.1% to −19.2% | 1 | 1 / 1 | 1 / 0 | 13 |

*Indexes added* counts index objects. A script that rebuilds an index under its own name, with `DROP` and then `CREATE`, adds none, which is why some trials show 1 added for 3 index scripts.

### Per arm (mean of 5)

| Arm | Read reads | Read CPU | Total time | Net index MB | Read points per GB | Scripts applied |
|---|---:|---:|---:|---:|---:|---:|
| **proc-create** | **−32.2%** (−1 or −79) | **−34.3%** | −25.1% | 26 | ~810 | 9 of 34 |
| **proc-reviewed** | **−78.8%** (−78.6 to −79.0) | **−54.0%** | −39.2% | 37 | ~2,320 | 26 of 26 applicable |
| **desktop** | **−77.7%** (−72.7 to −79.0) | **−52.7%** | −38.0% | 34 | ~2,320 | 23 of 23 applicable |
| **naive-missing-index** | **−1.0%** | **−18.6%** | −13.9% | 13 | 77 | 5 of 5 |

**No result hash changed** in any of the 160 hashed query comparisons (8 queries × 20 trials). **No trial was flagged as suspect.**

### Per query (mean reads change across 5 trials; improved = trials beyond the noise floor)

| Query | Baseline reads | proc-create | improved | proc-reviewed | improved | desktop | improved | naive | improved | Why |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| r01 post by id | 10,338 | +3.8% | 0/5 | +3.8% | 0/5 | +3.8% | 0/5 | +3.8% | 0/5 | The same in every arm. It follows the one index every arm created, `Votes (PostId)` |
| r02 answers | 7,240 | 0% | 0/5 | 0% | 0/5 | 0% | 0/5 | 0% | 0/5 | Already served by the foreign-key index |
| r03 latest comments | 13,535 | 0% | 0/5 | 0% | 0/5 | 0% | 0/5 | 0% | 0/5 | An ordered Comments index was applied in 4 trials (proc-reviewed reps 1 and 3, desktop reps 3 and 4) and didn't change its reads |
| **r04 a user's latest posts** | **129,904** | −38.9% | 2/5 | **−97.2%** | 5/5 | **−95.1%** | 5/5 | **0%** | 0/5 | The workload's largest read. The fix is an ordered covering index, `Posts (OwnerUserId, CreationDate DESC, Id DESC) INCLUDE (Title, PostTypeId)`. The DMV never suggested it |
| r05 vote tally | 3,551 | −86.3% | 5/5 | −86.2% | 5/5 | −86.3% | 5/5 | −85.9% | 5/5 | Every arm indexed `Votes.PostId`, the only thing the DMV suggested |
| r06 user profile | 4,900 | +0.1% | 0/5 | +4.7% | 0/5 (reads up in 4) | +1.5% | 0/5 | 0% | 0/5 | A small plan change in some reviewed trials |
| **r07 a user's badges** | **53,241** | −37.9% | 2/5 | **−94.5%** | 5/5 | **−94.6%** | 5/5 | **0%** | 0/5 | The same pattern on Badges: `Badges (UserId, Date DESC, Id DESC) INCLUDE (Name, Class)` |
| r08 related posts | 3,981 | +10.0% | 5/5 regressed | +10.0% | 5/5 regressed | +10.0% | 5/5 regressed | +9.9% | 5/5 regressed | The same in every arm, the naive one included, so it follows `Votes (PostId)` |
| w01 vote insert | 3,730 | **+13.0%** | 5/5 regressed | **+12.9%** | 5/5 regressed | **+12.9%** | 5/5 regressed | **+13.0%** | 5/5 regressed | The write cost of the new `Votes (PostId)` index: each vote insert now maintains it |
| w02 comment insert | 2,925 | 0% | — | 0% | — | 0% | — | 0% | — | |
| w03 view count | 1,874 | 0% | — | 0% | — | 0% | — | 0% | — | |

## What this shows

1. **Applying the reviewed advice cut this OLTP workload's read cost by four-fifths:** −78.8% reads, −54.0% read CPU and −39.2% total time, for 37 MB of index. The desktop app's advice did as well within noise: −77.7%, −52.7% and 34 MB. Both arms found the two ordered covering indexes that carry the gain, on `Posts` for `r04` and on `Badges` for `r07`. Both found them in every trial.
2. **CREATE mode got that gain in only 2 of 5 trials, because of how the model filed the fix.** In those 2 trials, the model filed the two covering indexes under *CreateIndex*, as new indexes beside the single-column foreign-key indexes, and CREATE mode built them. In the other 3, it filed the same two indexes under *ConsolidateIndex*: replace `IX_Posts_OwnerUserId` and `IX_Badges_UserId` with the wider version. CREATE mode never applies consolidation, so only the `Votes` index was built, and reads fell 1%.

   Either filing is a reasonable answer. Replacing the foreign-key index is arguably the better one, because it leaves one index to maintain instead of two. But the CREATE-mode result swings between −1% and −79% on that wording alone. A consolidation that keeps the old index's leading key and only adds key or included columns could be applied as safely as a new index. That is the candidate change this scenario points to.
3. **Creating what the DMV suggests does almost nothing here.** It suggested one index, `Votes (PostId)`. That fixed the vote tally (`r05`, a 3,551-read query), and every other arm made the same fix. The DMV made no suggestion for `r04` or `r07`. Those queries already seek on a foreign-key index, then pay for key lookups and a sort, and the DMV made no suggestion for either of them. The naive arm cut reads by 1.0% and read CPU by 18.6%, barely above the 15.8% floor.

   This is the opposite of the challenge scenario, where the DMV's 21 suggestions got within 2.4 points of the reviewed advice. Across the two scenarios, the DMV baseline swings from strong to useless. The reviewed AI advice stays close to the best result in both.
4. **The write cost is small and the same for every arm.** The one index that every arm created, `Votes (PostId)`, made the vote insert (`w01`) read 13% more, against a 0.6% floor. The covering indexes on `Posts` and `Badges` added no measurable write cost, because no write in this workload touches the columns they cover.
5. **Two side effects are the same in every arm**, the naive one included, so they follow `Votes (PostId)`: `r08` read 10% more, and `r01` 3.8% more.
6. **Scripts ran cleanly:**
   - **The model arms:** every applicable script succeeded, in both proc-reviewed and desktop.
   - **Statistics scripts:** three runs wrote theirs with `USE [master]`, which the harness blocks: proc-create rep 1, proc-reviewed rep 4 and desktop rep 4. For the desktop app this is the defect reported in [AI-SQL-Tuner/aisqltuner#248](https://github.com/AI-SQL-Tuner/aisqltuner/issues/248). It shows up in the proc as well.
   - **Foreign-key re-trust:** every reviewed run re-trusted the foreign keys, without effect on this workload.

## Limits

- **The tool's own foreign key in the image.** The scenario's setup requires every foreign key to be untrusted, so the image's `FK_AIIndexTuner_Recommendation_Run` was disabled and re-enabled to make it untrusted. The proc's collector leaves the `AIIndexTuner` schema out, so the proc arms never saw it. The desktop collector doesn't, and one desktop run (rep 3) re-trusted it alongside the `dbo` foreign keys. That had no effect on the workload.
- **Different inputs for proc and desktop**, as on the challenge scenario: each answered its own collector's payload.
- **A different instance from the desktop benchmark's earlier `sqlstorm-oltp` matrices.** Those ran on SQL Server 2022 without the tool installed, so this run has its own noise floor, and its results are not pooled with theirs.
- **Run cost:**

  | Arm | Input tokens | Output tokens per run | Tuning time |
  |---|---:|---:|---:|
  | Proc | 33,349 | 5,200–6,800 | 32–44 s |
  | Desktop | 31,576 | about 10,000 | 47–70 s |

## Reproduce

On VMEnt, with `SQLStormOltp` restored on SQL25, the tool installed in it, and its endpoint configured:

```
bench validate    --scenario bench/scenarios/sqlstorm-oltp.json --server tcp:localhost,51433
bench prepare     --scenario bench/scenarios/sqlstorm-oltp.json --server tcp:localhost,51433
bench noise-floor --scenario bench/scenarios/sqlstorm-oltp.json --server tcp:localhost,51433 --trials 3
bench matrix      --scenario bench/scenarios/sqlstorm-oltp.json --server tcp:localhost,51433 --effort medium --replicates 5 \
                  --models proc-create/gpt-5.6-luna,proc-reviewed/gpt-5.6-luna
bench matrix      ... --models gpt-5.6-luna
bench matrix      ... --models naive-missing-index
```

All of the results are in the harness's `TunerBench` database on SQL25, in matrices 5 to 8.
