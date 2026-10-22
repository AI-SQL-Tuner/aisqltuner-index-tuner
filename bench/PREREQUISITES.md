# Benchmark prerequisites

What has to be in place before a **live** rubric run (`Run-Rubric.ps1 -Mode Live`), on `VMEnt` (SQL Server 2025) and on the Dev EMS database (Azure SQL Database). `Run-Rubric.ps1` checks items 1, 2, 3 and 5 before it starts, and stops on the first one that fails, so a misconfigured server doesn't use up a run.

Validation runs (`-Mode Validate`) use canned answers and need none of this. They run on any SQL Server 2022 or later instance, including a laptop.

## 1. The server

| | `VMEnt` | Dev EMS database |
|---|---|---|
| Platform | SQL Server 2025, Enterprise features (`SERVERPROPERTY('EngineEdition') = 3`) | Azure SQL Database (`EngineEdition = 5`) |
| Before a run | **Start the VM.** It is stopped when not in use | Nothing |

## 2. REST endpoint (SQL Server only)

```sql
EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
```

This needs `ALTER SETTINGS` (sysadmin or serveradmin). It is a server-level change, made by a person, not by the benchmark. Azure SQL Database has it on already.

## 3. Database, install, credential

### `VMEnt`, once

1. Create the challenge database: `sqlcmd -S VMEnt -E -C -f 65001 -i bench\challenge\00_Create-ChallengeDb.sql`. This **drops and recreates** `IndexTunerChallenge`, including its credential and configuration, so run it only for first-time setup.
2. Install the tool in it: `sqlcmd -S VMEnt -E -C -f 65001 -d IndexTunerChallenge -i aisqltuner-index-tuner.sql`.
3. Fill in and run `setup/Configure-Endpoint.sql` in `IndexTunerChallenge`. It creates the database master key, a database scoped credential for the Azure OpenAI endpoint (API key), and the `AIIndexTuner.Config` row.

### Dev EMS database, once

1. Install the tool in it (`aisqltuner-index-tuner.sql`). This adds the `AIIndexTuner` schema and `dbo.sp_AIIndexTuner` / `dbo.sp_AIIndexTuner_Apply` next to the EMS objects.
2. Run `setup/Configure-Endpoint.sql`, using **option B, managed identity**, rather than an API key. Give the server's managed identity the *Cognitive Services OpenAI User* role on the Azure OpenAI resource.
3. The benchmark adds its tables in the `bench` schema and its rubric objects in `AIIndexTunerBench`. To remove both afterwards, run `bench\challenge\09_Drop-ChallengeTables.sql`.

## 4. Permissions

If the benchmark login is not the owner of the database, it needs:

```sql
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [bench_login];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://<resource>.openai.azure.com] TO [bench_login];
GRANT VIEW DATABASE STATE, VIEW DEFINITION TO [bench_login];
-- SQL Server: also VIEW SERVER STATE (or VIEW SERVER PERFORMANCE STATE), and securityadmin to read the error log
```

It also needs rights to create tables and schemas, so the build can run. On `VMEnt` it needs `ALTER DATABASE` too: the build clears Query Store and the plan cache before the workload.

## 5. Configuration

`AIIndexTuner.Config` in the target database:

| Column | Value |
|---|---|
| `Deployment` | `gpt-5.6-luna` |
| `ReasoningEffort` | `medium` |
| `UseBackgroundMode` | `1` |
| `KeepRunDetail` | `1`. The payload variants are built from the first base run's collected data |

`Run-Rubric.ps1` stops if the deployment or effort differs from `-ExpectedDeployment` / `-ExpectedEffort` (defaults `gpt-5.6-luna` / `medium`), so a run is never recorded against the wrong model by accident.

## 6. Smoke test

```sql
EXEC dbo.sp_AIIndexTuner @SchemaName = N'bench', @TableName = N'Products';
SELECT TOP (1) RunId, Status, ModelUsed, InputTokens, OutputTokens, ModelMs, PollCount, ErrorMessage
FROM AIIndexTuner.Run ORDER BY RunId DESC;
```

Expect `Status = Succeeded`, a `ModelUsed`, and token counts. If this fails, the error message says which part (HTTP status, credential, allowlist, polling) to look at.

## Running

```powershell
# Prove the rubric scores right and wrong answers correctly (no endpoint; any SQL Server 2022+):
.\bench\Run-Rubric.ps1 -Server localhost -Mode Validate -Scale 0.1 -Reps 60

# Live, VMEnt, full scale, 5 iterations:
.\bench\Run-Rubric.ps1 -Server VMEnt -Mode Live

# Live, Dev EMS database (base runs scoped to the bench schema). Pick a scale the database can hold:
.\bench\Run-Rubric.ps1 -Server <server>.database.windows.net -Database <dev-ems-db> -Azure -AuthArgs '-G' -Mode Live -Scale 0.25
```

`-Scale 1` builds about 29 million rows; the two fact tables never go below 1.2 million. Workload repetitions scale as 200 / Scale, at most 2,000, which keeps missing-index impact scores above the collector's 100,000 threshold. Reports go to `bench/results/`.
