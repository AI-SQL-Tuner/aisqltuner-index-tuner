# aisqltuner-index-tuner

AI-assisted index tuning that runs entirely inside SQL Server. One stored procedure collects the
index diagnostics for a database, sends them to **your own Azure OpenAI deployment**, stores the
recommendations in a table, and can create the new indexes it is able to verify.

```sql
EXEC dbo.sp_AIIndexTuner;                                        -- recommend only (the default)
EXEC dbo.sp_AIIndexTuner @SchemaName = N'Sales', @TableName = N'Orders';
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE';                       -- also create verified new indexes
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @AllowColumnstore = 0, @AllowDropIndex = 1, @MaxNewIndexes = 3;
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @MinPriority = 'Medium', @MinConfidence = 'High';   -- apply only the surest
```

Free and open source from [AI SQL Tuner](https://aisqltuner.com). The idea comes from Brent
Ozar's post [I'm Probably Not Supposed to Show You Microsoft's Auto-Indexing Tool](https://www.brentozar.com/archive/2026/10/im-probably-not-supposed-to-show-you-microsofts-auto-indexing-tool),
about Microsoft's 2006 `AutoIndex.sql` prototype: a modern version, with AI doing the analysis.

> **aisqltuner-index-tuner is the open-source index tuning engine.** Looking for query tuning,
> deadlock analysis, server health checks, code review, a GUI with HTML reports, or support for
> SQL Server 2022 or earlier? See [AI SQL Tuner Studio](https://aisqltuner.com), also available
> from the [Microsoft Store](https://apps.microsoft.com/detail/9P68072ZM3N5).
> [How they compare](#compared-with-ai-sql-tuner-studio).

> **Status: prototype.** The collectors, prompt, storage and apply logic are tested against SQL
> Server 2025 with canned model answers. The live path has also been run end to end against Azure
> OpenAI `gpt-5.6-luna` on SQL Server 2025: collection, the background-mode call, storage, the
> change controls and CREATE mode. See [Testing](#testing) and [Benchmark](#benchmark). Not yet run: the
> rest of the impact benchmark (one scenario of three so far),
> Azure SQL Database, Fabric SQL Database, and `ONLINE = ON` index builds.

## Requirements

- SQL Server 2025, Azure SQL Database, Azure SQL Managed Instance with the SQL Server 2025 or
  Always-up-to-date update policy, or Fabric SQL Database. These are the platforms with
  `sp_invoke_external_rest_endpoint`.
- An Azure OpenAI (or Microsoft Foundry) resource with a deployed OpenAI model, and its API key or
  a managed identity with the *Cognitive Services OpenAI User* role. Only OpenAI models are
  supported for now.
- To collect: `VIEW SERVER STATE` (or `VIEW SERVER PERFORMANCE STATE`), `VIEW DATABASE STATE` and
  `VIEW DEFINITION`. To call the model: `EXECUTE ANY EXTERNAL ENDPOINT`. To create indexes:
  `ALTER` on the tables.

## Compared with AI SQL Tuner Studio

[AI SQL Tuner Studio](https://aisqltuner.com) is AI SQL Tuner's commercial Windows desktop app,
available from the [Microsoft Store](https://apps.microsoft.com/detail/9P68072ZM3N5) or as a direct
download. This project ports Studio's Index Tuning goal to T-SQL, so it runs inside SQL Server and
can apply what it finds.

| | aisqltuner-index-tuner (open source) | AI SQL Tuner Studio |
|---|---|---|
| Index tuning | Yes | Yes |
| Query tuning, deadlock analysis, blocking and locking, server health, code review | No | Yes |
| Interface | T-SQL stored procedures; results in tables | Windows desktop app with HTML reports |
| Runs on | The database server, as stored procedures | Windows 10 or 11 (Microsoft Store or direct download), Windows Server (direct download) |
| SQL Server | SQL Server 2025 only | SQL Server, including 2022 and earlier |
| Azure and Fabric | Azure SQL Database; Azure SQL Managed Instance with the SQL Server 2025 or Always-up-to-date update policy; Fabric SQL Database | Azure SQL Database; Azure SQL Managed Instance with any update policy; Fabric SQL Database |
| AI endpoint | Required: your own Azure OpenAI or Microsoft Foundry deployment | Optional: hosted models are included, and paid editions can bring their own Azure OpenAI endpoint |
| Applies recommendations | Yes: creates verified new indexes and, when allowed, drops indexes, within the [change controls](#change-controls) and [apply thresholds](#apply-thresholds) | No: the report gives ready-to-run scripts for you to review and run |
| Can run on a schedule | Yes: from a SQL Server Agent job or any other scheduler | No |
| Price | Free, [MIT license](LICENSE) | Free Edition and paid editions; see [aisqltuner.com](https://aisqltuner.com) |

## Install

1. Run [aisqltuner-index-tuner.sql](aisqltuner-index-tuner.sql) in the user database you want to
   tune. It creates the `AIIndexTuner` schema with its tables and procedures, plus
   `dbo.sp_AIIndexTuner` and `dbo.sp_AIIndexTuner_Apply`. Install it in each database you tune,
   because the endpoint credential is a database scoped credential.
2. Fill in and run [setup/Configure-Endpoint.sql](setup/Configure-Endpoint.sql). It enables the
   REST endpoint feature (SQL Server 2025 only), creates the database master key and credential,
   and writes the configuration row. To keep a filled-in copy with your key, save it as
   `setup/Configure-Endpoint-DEV.sql`, which `.gitignore` excludes.
3. Smoke test: `EXEC dbo.sp_AIIndexTuner;`, then check that the latest `AIIndexTuner.Run` row has
   `Status = 'Succeeded'`. If it failed, `ErrorMessage` names the part to look at: the HTTP status,
   the credential, or polling.

## What it does

1. **Collects** the Index Tuning diagnostics, ported from AI SQL Tuner's IndexTuning goal:
   - server and edition info, and the period the usage statistics cover (server start, create
     date, restore history and the error log's "Starting up database" message)
   - missing indexes, plus their overlap with existing indexes. Each suggestion's included columns
     are listed with their types, and wide or `(max)` columns with an average width sampled from up
     to 1,000 rows, so a suggestion that would copy a large column into an index can be spotted
   - index usage, duplicate and left-prefix overlapping indexes, operational hotspots and page
     density
   - the top 25 plan cache statements by CPU for this database
   - Query Store: the top 50 queries by total duration over 7 days (with parameter sensitivity),
     the write workload mix, and forced plan failures. Each query variant of an adaptive plan
     (Parameter Sensitive Plan or optional parameter plan optimization) is counted under its parent
     query, with the parent's text
   - automatic tuning (`FORCE_LAST_GOOD_PLAN`), cardinality estimation feedback, degree of
     parallelism (DOP) feedback, and whether optional parameter plan optimization (OPPO) is active
   - heaps, constraints, untrusted constraints, column cardinality, large tables, statistics
     settings and `OPTIMIZED_SP_EXECUTESQL`
   - skewed low-cardinality columns, with each value's share of the rows from the statistics
     histogram (for example `Closed: 99.50%, Open: 0.50%`), so the model can suggest a filtered
     index even when SQL Server suggests none

   The `@SchemaName` and `@TableName` filters apply to every object-level section. For the Query
   Store sections they are resolved once into the set of queries whose plans reference the object,
   confirmed from the plan XML. If that fails, they fall back to a plan-text match, then to module
   dependencies. The section says which one it used.
2. **Asks the model** with AI SQL Tuner's Index Tuning prompt. The prompt asks for a JSON object
   instead of an HTML report, and the response schema enforces that shape.
3. **Stores** a row in `AIIndexTuner.Run` and one row per recommendation in
   `AIIndexTuner.Recommendation`:
   - category (`CreateIndex`, `DropIndex`, `ConsolidateIndex`, `RebuildIndex`, `Constraint`,
     `Statistics`, `Setting`, `QueryChange` or `Other`)
   - for a new index, its type (`NONCLUSTERED`, `NONCLUSTERED COLUMNSTORE` or
     `CLUSTERED COLUMNSTORE`)
   - table, keys, includes, compression and fill factor
   - priority: `Priority` ranks the recommendations (1 is the most important), and
     `PriorityLevel` is `High`, `Medium` or `Low`
   - estimated storage change in MB (negative for storage a drop reclaims), confidence (`High`,
     `Medium` or `Low`) and rationale
   - the model's script
4. **Applies** (with `@Mode = 'CREATE'`, or later with `sp_AIIndexTuner_Apply`):
   - new nonclustered rowstore indexes
   - new columnstore indexes, when `@AllowColumnstore = 1`
   - index drops, when `@AllowDropIndex = 1`

   Everything else stays for you to review. The [apply thresholds](#apply-thresholds) can hold back
   recommendations with a low priority level or confidence too.

### Change controls

These parameters limit what the model may recommend and what the proc may change. Each one adds a
rule to the prompt **and** is enforced again when applying, so a model that ignores the rule still
cannot make the change.

| Parameter | `NULL` (default) | `1` | `0` |
|---|---|---|---|
| `@AllowColumnstore` | Columnstore indexes may be recommended, but are not created | Also created | Not recommended or created |
| `@AllowDropIndex` | Index drops may be recommended, but are not run | Also run | Not recommended or run |

`@MaxNewIndexes` (default `NULL`, no limit) asks for at most that many new indexes, and creates at
most that many, in priority order. `0` asks for none.

A run's settings are stored in `AIIndexTuner.Run`. A recommend-only (`NULL`) change can be applied
after review by passing the setting to `sp_AIIndexTuner_Apply`. A `0` cannot be overridden later:

```sql
EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = 43, @AllowDropIndex = 1;
EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7, @AllowColumnstore = 1, @AllowDropIndex = 1, @MaxNewIndexes = 2;
```

### Apply thresholds

`@MinPriority` and `@MinConfidence` set the lowest priority level and confidence a recommendation
can have and still be applied. Each takes `High`, `Medium` or `Low`; `NULL` (the default) means no
minimum. A recommendation is applied only if both its levels are at the minimum or above, and it
must also pass the change controls and safety checks. The rest are skipped with a reason and
stay for you to review. A recommendation the model gave no level counts as `Low`. Both levels
are the model's own estimates, so a threshold lowers the risk but does not replace review.

The levels vary between runs, as the answers do (see [Known limitations](#known-limitations-prototype)),
so two CREATE runs on the same database can apply different sets. In five live runs of
`gpt-5.6-luna` on the benchmark database, with the same input:
- the model never gave `Low` confidence, so `@MinConfidence = 'Medium'` held nothing back and only
  `'High'` did
- with `Medium` / `High`, new indexes on some tables were applied in every run, others in none, and
  a few in some runs but not others

| Environment | `@MinPriority` | `@MinConfidence` | Applied |
|---|---|---|---|
| Dedicated test environment | `Low` | `Low` | Everything the change controls and safety checks allow |
| Production | `Medium` | `High` | High- and medium-priority changes the model is highly confident in. Review the rest by hand |

```sql
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @MinPriority = 'Low', @MinConfidence = 'Low';      -- test environment
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @MinPriority = 'Medium', @MinConfidence = 'High';  -- production
```

They differ from the change controls in two ways:

- **The prompt does not change.** The model still makes every recommendation, and the thresholds
  only decide which of them are applied.
- **A threshold can be lowered after review.** The run stores its minimums (`MinPriority` and
  `MinConfidence` in `AIIndexTuner.Run`), and `sp_AIIndexTuner_Apply` uses them unless you pass
  your own, which replace them:

```sql
EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7;                                        -- the run's minimums
EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = 44, @MinConfidence = 'Low';    -- one you reviewed
EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7, @MinPriority = 'Low', @MinConfidence = 'Low';
```

### Apply-mode safety

- **The model's script is never executed.** Plan cache text goes into the prompt, so a crafted
  query could try to steer what the model writes. The proc builds the `CREATE INDEX` or
  `DROP INDEX` itself:
  - It uses only the structured fields.
  - It checks every table and column against the catalog.
  - It quotes every name with `QUOTENAME`.
  - It allows only known option values.
- **Recommendations it skips, each with a reason:**
  - an existing index already has the same leading keys and covers the includes, which also makes
    reruns safe
  - an unknown table or column
  - an index name that is already in use
  - a filtered index (the predicate is free text)
  - a change the run's change controls do not allow, or a new index past `@MaxNewIndexes`
  - a priority level or confidence below `@MinPriority` or `@MinConfidence`
  - a second columnstore index on a table, or a clustered columnstore index on a table that has a
    clustered rowstore index (converting it would replace that index and any primary key on it)
- **Drops it refuses, each with a reason:**
  - clustered indexes, and indexes that enforce a primary key or unique constraint
  - indexes a foreign key references
  - indexes named by an index hint in a module, a plan guide or a Query Store hint
  - indexes a forced Query Store plan uses, since the plan would fail with `NO_INDEX`
  - low-use drops before the usage statistics cover 7 days. An index that another index makes
    redundant can be dropped at any time. Redundant here means the other index has the same leading
    keys, covers its includes and filter, and keeps any uniqueness. On SQL Server, a low-use drop
    also needs the error log to confirm the period, which takes securityadmin or sysadmin and doesn't
    work inside `INSERT ... EXEC`. On Azure SQL Database a failover can reset the statistics without
    a trace, so the 7 days are counted from the times it can see.
- **What it adds:** `ONLINE = ON` where the edition supports it (Enterprise, Azure SQL Database,
  Managed Instance).
- **Tagging:** each index it creates gets the extended property `AIIndexTuner`, naming the run and
  the recommendation.
- **Undo:** each applied recommendation stores `UndoDDL`:
  - for a created index, the `DROP INDEX`
  - for a dropped index, the `CREATE INDEX` that restores it from the catalog: keys, includes,
    filter, options, compression and filegroup or partition scheme

```sql
-- Review, then apply one recommendation or a whole run
SELECT * FROM AIIndexTuner.Recommendation WHERE RunId = 7 ORDER BY Priority;
SELECT * FROM AIIndexTuner.Recommendation WHERE RunId = 7 AND StatusReason LIKE N'%below the minimum%';   -- held back by a threshold
EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = 42;
EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7;

-- Indexes this tool created
SELECT OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName, OBJECT_NAME(i.object_id) AS TableName, i.name, ep.value
FROM sys.indexes AS i
JOIN sys.extended_properties AS ep ON ep.class = 7 AND ep.major_id = i.object_id AND ep.minor_id = i.index_id
WHERE ep.name = N'AIIndexTuner';
```

## Configuration

`AIIndexTuner.Config` (one row):

| Column | Default | Meaning |
|---|---|---|
| `Endpoint` | | Root endpoint, e.g. `https://my-resource.openai.azure.com/` |
| `Deployment` | | Azure OpenAI deployment name |
| `CredentialName` | | Database scoped credential; its name must be a prefix of `<endpoint>/openai/v1/responses` |
| `ReasoningEffort` | `medium` | `low`, `medium` or `high` (not sent to GPT-4 / GPT-3.5 deployments) |
| `MaxOutputTokens` | 32000 | |
| `RequestTimeoutSec` | 230 | Per HTTP call; 230 is the `sp_invoke_external_rest_endpoint` maximum |
| `UseBackgroundMode` | 1 | Send the request with `"background": true` and poll it, so a long reasoning run is not cut off at 230 seconds |
| `MaxWaitSec` / `PollIntervalSec` | 900 / 5 | Polling limits in background mode |
| `UseStructuredOutput` | 1 | Schema-constrained JSON; set 0 for a model that rejects it |
| `IncludeQueryText` | 1 | 0 leaves plan cache query text out of the prompt |
| `KeepRunDetail` | 1 | Keep the collected data and raw response on each run |

## Data disclosure

The collected diagnostics go to the Azure OpenAI endpoint you configure, and to nothing else.
They include:

- object, index and column names
- row counts and usage counters
- up to 600 characters of each of the top plan cache statements

Statement text can contain literal values. Set `IncludeQueryText = 0` to leave it out. To see
exactly what would be sent, run `EXEC dbo.sp_AIIndexTuner @CollectOnly = 1;`.

## Known limitations (prototype)

- **Claude:** Claude deployments are not supported yet.
- **No timeouts:** T-SQL has no per-statement timeout, so a collector section cannot be cut off
  the way the desktop app's are. Work is bounded by row caps instead, including the 20,000-plan
  cap on Query Store scope resolution. Each section runs in its own `TRY...CATCH`, so a failed
  section is reported and skipped.
- **Error log:** reading it needs `securityadmin` or `sysadmin`. Without that, the usage window
  says which resets it could not see.
- **`INSERT ... EXEC`:** wrapping `sp_AIIndexTuner` in `INSERT ... EXEC` breaks two parts,
  because SQL Server cannot nest the proc's own `INSERT ... EXEC` calls:
  - the column cardinality section (`DBCC SHOW_STATISTICS`) is skipped
  - the error-log search (`sp_readerrorlog`) fails, so the usage window reports the error log as
    unreadable

  For the same reason, `sp_AIIndexTuner_Apply` inside `INSERT ... EXEC` refuses low-use drops,
  because it cannot confirm the usage period.
- **Model scripts are not checked:** the `Script` column is the model's own T-SQL, kept for review
  and never executed. Live runs show it can be invalid: one suggested
  `ALTER DATABASE SCOPED CONFIGURATION SET AUTOMATIC_TUNING`, which should be
  `ALTER DATABASE ... SET AUTOMATIC_TUNING`. Test a script before running it yourself.
- **Answers vary between runs:** the same input can come back with different categories. For
  example, a deferred drop came back under `Other` in one run and `DropIndex` in another, before the
  prompt reserved `DropIndex` for drops to make now. The change controls and apply-mode checks are
  what make CREATE safe, not the prompt alone.
- **No verification or rollback:** the tool does not measure impact after creating an index or
  roll back regressions. Each applied change does store `UndoDDL` to reverse it by hand.

## Testing

```powershell
.\tests\Run-All.ps1                               # localhost, Windows authentication
.\tests\Run-All.ps1 -Database AIIndexTunerTest2   # another test database
```

The test runner:

1. rebuilds the install script
2. recreates the test database (`AIIndexTunerTest` by default), with Query Store capturing every
   query:
   - 300,000 orders with no supporting index
   - a duplicate index, an untrusted foreign key and a heap

   It stops if that database has a database scoped credential, because recreating it would delete
   your endpoint setup. Use `-Database` for another database, or `-Force`.
3. installs the tool and runs a workload, including a forced plan whose index is then dropped
   (a `NO_INDEX` forced-plan failure)
4. runs [tests/03_Run-Tests.sql](tests/03_Run-Tests.sql)

The tests use `@TestResponse` canned model answers, so they need no AI endpoint. They cover:

- collection of every section, scoping, and Query Store scope resolution from plan XML
- RECOMMEND storing results without changing the schema
- CREATE applying only the indexes that pass validation, including attempted SQL injection in index
  and table names
- change controls: their prompt rules, their enforcement when the model ignores them, columnstore
  creation, the drop safety checks, `UndoDDL` restoring each change, and applying recommend-only
  changes after review
- apply thresholds: `@MinPriority` and `@MinConfidence` holding back lower recommendations, a
  recommendation with no level counting as `Low`, and applying held-back ones after review
- idempotent reruns
- fenced and broken JSON
- parameter validation
- the request body
- reading an answer longer than 4,000 characters
- supplied diagnostics (`@CollectedData`)
- leaving the tool's own statements out of the collected data, including its dynamic SQL and its
  temp-table writes

### Live tests

These need a configured endpoint (see [Install](#install)). Run them in a database that has the
endpoint set up, not in one `Run-All.ps1` recreates:

```sql
EXEC dbo.sp_AIIndexTuner;                                                       -- default run
EXEC dbo.sp_AIIndexTuner @AllowColumnstore = 0, @AllowDropIndex = 0, @MaxNewIndexes = 1;   -- does the model follow the rules?
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @AllowDropIndex = 0, @MaxNewIndexes = 2;      -- end to end, with changes
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @MinPriority = 'Medium', @MinConfidence = 'High';  -- apply thresholds
SELECT TOP (5) RunId, Status, InputTokens, OutputTokens, ModelMs, PollCount, AllowColumnstore, AllowDropIndex, MaxNewIndexes,
       MinPriority, MinConfidence, ErrorMessage
FROM AIIndexTuner.Run ORDER BY RunId DESC;
```

Results on SQL Server 2025 Standard Developer with `gpt-5.6-luna`, medium effort, in
`AIIndexTunerTest` (a 72,000-character payload) and the benchmark database (scoped to one table):

| Check | Result |
|---|---|
| Call and storage | Every run succeeded in background mode: 17–28 s, 2–5 polls, 10,000–27,000 input and 1,300–3,700 output tokens |
| `index_type` | Filled correctly on every new-index recommendation |
| Change controls | With columnstore and drops disallowed and `@MaxNewIndexes = 1`, the model recommended no columnstore index, no drop and one new index |
| CREATE mode | Created the one index that passed validation, with the model's fill factor and compression, and stored its `UndoDDL`. Other categories stayed for review. |
| Usage window | On a few hours of usage data, the model deferred unused indexes rather than dropping them, and filed them under `Other` |

## Benchmark

[bench/](bench/) checks whether the recommendations are right ([issue #2](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/2), part 1) and what applying them gains (part 2). It builds 16 known tuning problems into a `bench` schema, including:
- low-cardinality and skewed filters
- 10M and 5M-row fact tables where columnstore belongs
- a write-heavy queue
- overlapping suggestions, key order and `nvarchar(max)` in INCLUDE
- non-SARGable predicates, duplicate indexes, a heap and an untrusted foreign key
- a forced-plan failure, table scope and a short usage window

It runs `sp_AIIndexTuner` against them and scores every run with 37 rubric checks. Four edited-input variants test:
- a long usage window
- prompt injection in query text
- a Standard-edition server
- a payload of over 550,000 characters

```powershell
.\bench\Run-Rubric.ps1 -Server localhost -Mode Validate -Scale 0.1 -Reps 60   # canned answers, no endpoint
.\bench\Run-Rubric.ps1 -Server VMEnt -Mode Live                                # gpt-5.6-luna, medium, 5 iterations
```

[bench/CASES.md](bench/CASES.md) explains each case and why its expected answer is right. [bench/PREREQUISITES.md](bench/PREREQUISITES.md) lists what a live run needs.

**Impact** (part 2): each trial starts from a reverted snapshot of the challenge database. It runs a 16-query workload, tunes, applies and measures again. On SQL Server 2025, with `gpt-5.6-luna` at `medium` effort and 5 trials per arm:

| Arm | Read logical reads | Read CPU | Net index MB, after drops (mean) |
|---|---:|---:|---:|
| `@Mode = 'CREATE'`: the proc applies its validated indexes on its own | −79% | −66% | 328 |
| Every recommendation reviewed and applied | −93% | −81% | 206 |
| For comparison: the AI SQL Tuner desktop app's IndexTuning goal, every script applied | −83% | −74% | 465 |

No query returned different results. Most of the gap between the two proc rows comes from the filtered and columnstore indexes, which CREATE mode leaves for review. See [the report](bench/results/impact-20261028-VMEnt-SQL25-challenge.md).

`sp_AIIndexTuner @CollectedData = N'…'` runs the model on supplied diagnostics instead of collecting them, for example a run's `AIIndexTuner.Run.CollectedData`. The benchmark uses it so that every iteration answers the same input. `AIIndexTuner.Run` records the payload's SHA-256, collection and model time, apply time, and the number of background polls.

## Release notes

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for what changed in each release and how to upgrade an
existing install.

## Repository layout

| Path | |
|---|---|
| `src/` | Source, one object or group per file, in install order |
| `aisqltuner-index-tuner.sql` | Single-file install script, generated by `build.ps1` from `src/` |
| `setup/Configure-Endpoint.sql` | Credential and configuration template |
| `tests/` | Test database, workload, tests and runner |
| `bench/` | Benchmark: challenge database, workload, rubric, runner, cases, prerequisites and results |
| `RELEASE_NOTES.md` | Changes by release, and how to upgrade |

## License

[MIT](LICENSE). Copyright (c) 2026 AI SQL Tuner LLC.

The software is provided as is, without warranty. It can create and drop indexes, so review
recommendations and test in a non-production database first.
