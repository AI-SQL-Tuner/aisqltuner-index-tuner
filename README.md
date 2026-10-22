# aisqltuner-index-tuner

AI-assisted index tuning that runs entirely inside SQL Server. One stored procedure collects the
index diagnostics for a database, sends them to **your own Azure OpenAI deployment**, stores the
recommendations in a table, and can create the new indexes it is able to verify.

```sql
EXEC dbo.sp_AIIndexTuner;                                        -- recommend only (the default)
EXEC dbo.sp_AIIndexTuner @SchemaName = N'Sales', @TableName = N'Orders';
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE';                       -- also create verified new indexes
```

Free and open source from [AI SQL Tuner](https://www.aisqltuner.com). The idea comes from Brent
Ozar's post [I'm Probably Not Supposed to Show You Microsoft's Auto-Indexing Tool](https://www.brentozar.com/archive/2026/10/im-probably-not-supposed-to-show-you-microsofts-auto-indexing-tool),
about Microsoft's 2006 `AutoIndex.sql` prototype: a modern version, with AI doing the analysis.

> **Status: prototype.** The collectors, prompt, storage and apply logic are tested against SQL
> Server 2025 with canned model answers (see [Testing](#testing)). The call to a live Azure OpenAI
> endpoint has not been run end to end yet.

## Requirements

- SQL Server 2025, Azure SQL Database, or Azure SQL Managed Instance with the SQL Server 2025 or
  Always-up-to-date update policy. These are the platforms with `sp_invoke_external_rest_endpoint`.
- An Azure OpenAI (or Microsoft Foundry) resource with a deployed OpenAI model, and its API key or
  a managed identity with the *Cognitive Services OpenAI User* role. Only OpenAI models are
  supported for now.
- To collect: `VIEW SERVER STATE` (or `VIEW SERVER PERFORMANCE STATE`), `VIEW DATABASE STATE` and
  `VIEW DEFINITION`. To call the model: `EXECUTE ANY EXTERNAL ENDPOINT`. To create indexes:
  `ALTER` on the tables.

## Install

1. Run [aisqltuner-index-tuner.sql](aisqltuner-index-tuner.sql) in the user database you want to
   tune. It creates the `AIIndexTuner` schema with its tables and procedures, plus
   `dbo.sp_AIIndexTuner` and `dbo.sp_AIIndexTuner_Apply`. Install it in each database you tune,
   because the endpoint credential is a database scoped credential.
2. Fill in and run [setup/Configure-Endpoint.sql](setup/Configure-Endpoint.sql). It enables the
   REST endpoint feature (SQL Server 2025 only), creates the database master key and credential,
   and writes the configuration row.

## What it does

1. **Collects** the Index Tuning diagnostics, ported from AI SQL Tuner's IndexTuning goal:
   - server and edition info, and the period the usage statistics cover (server start, create
     date, restore history and the error log's "Starting up database" message)
   - missing indexes, plus their overlap with existing indexes
   - index usage, duplicate and left-prefix overlapping indexes, operational hotspots and page
     density
   - the top 25 plan cache statements by CPU for this database
   - Query Store: the top 50 queries by total duration over 7 days (with parameter sensitivity),
     the write workload mix, and forced plan failures
   - automatic tuning (`FORCE_LAST_GOOD_PLAN`) and cardinality estimation feedback
   - heaps, constraints, untrusted constraints, column cardinality, large tables, statistics
     settings and `OPTIMIZED_SP_EXECUTESQL`

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
   - table, keys, includes, compression and fill factor
   - estimated size, confidence and rationale
   - the model's script
4. **Applies** (with `@Mode = 'CREATE'`, or later with `sp_AIIndexTuner_Apply`). Only `CreateIndex`
   recommendations are applied; everything else stays for you to review.

### Apply-mode safety

- **The model's script is never executed.** Plan cache text goes into the prompt, so a crafted
  query could try to steer what the model writes. The proc builds the `CREATE INDEX` itself:
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
- **What it adds:** `ONLINE = ON` where the edition supports it (Enterprise, Azure SQL Database,
  Managed Instance).
- **Tagging:** each index it creates gets the extended property `AIIndexTuner`, naming the run and
  the recommendation.

```sql
-- Review, then apply one recommendation or a whole run
SELECT * FROM AIIndexTuner.Recommendation WHERE RunId = 7 ORDER BY Priority;
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
- **No verification or rollback:** the tool does not measure impact after creating an index or
  roll back regressions. [AI SQL Tuner](https://www.aisqltuner.com) also covers deadlocks, code
  review, server health, query tuning, and locking and blocking.

## Testing

```powershell
.\tests\Run-All.ps1            # localhost, Windows authentication
```

The test runner:

1. rebuilds the install script
2. recreates the `AIIndexTunerTest` database, with Query Store capturing every query:
   - 300,000 orders with no supporting index
   - a duplicate index, an untrusted foreign key and a heap
3. installs the tool and runs a workload, including a forced plan whose index is then dropped
   (a `NO_INDEX` forced-plan failure)
4. runs [tests/03_Run-Tests.sql](tests/03_Run-Tests.sql)

The tests use `@TestResponse` canned model answers, so they need no AI endpoint. They cover:

- collection of every section, scoping, and Query Store scope resolution from plan XML
- RECOMMEND storing results without changing the schema
- CREATE applying only the indexes that pass validation, including attempted SQL injection in index
  and table names
- idempotent reruns
- fenced and broken JSON
- parameter validation
- the request body
- reading an answer longer than 4,000 characters

## Repository layout

| Path | |
|---|---|
| `src/` | Source, one object or group per file, in install order |
| `aisqltuner-index-tuner.sql` | Single-file install script, generated by `build.ps1` from `src/` |
| `setup/Configure-Endpoint.sql` | Credential and configuration template |
| `tests/` | Test database, workload, tests and runner |

## License

To be decided before the first public release.
