# Contributing to aisqltuner-index-tuner

Thanks for helping improve aisqltuner-index-tuner, the open-source T-SQL index tuning engine from [AI SQL Tuner](https://aisqltuner.com). Bug reports, fixes, tests, benchmark cases and documentation improvements are all welcome.

This project is released under the [MIT license](LICENSE). By contributing, you agree that your contribution is licensed under it.

## Before you start

- **Bugs and ideas:** open a [GitHub issue](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues). For a bug, include the platform and version (SQL Server 2025, Azure SQL Database, Managed Instance or Fabric SQL Database), the procedure and parameters you ran, and the `ErrorMessage` or the relevant `AIIndexTuner.RunLog` rows.
- **Bad index recommendations** are ordinary issues, not security reports. The model's answers vary between runs. Include the run's `CollectedData` if you can share it (see *Data disclosure* in the [README](README.md) first).
- **Larger changes:** open an issue before you start, so we can agree on the approach.
- **Security vulnerabilities:** do not open a public issue. Follow [SECURITY.md](SECURITY.md).
- **Looking for query tuning, deadlock analysis, server health checks or code review?** Those are in [AI SQL Tuner Studio](https://aisqltuner.com), not this repository.

## Repository layout

| Path | What it holds |
|---|---|
| `src/` | The source: one object or group per file, numbered in install order |
| `aisqltuner-index-tuner.sql` | The single-file install script. **Generated** by `build.ps1` from `src/` |
| `build.ps1` | Concatenates `src/*.sql` into the install script |
| `setup/Configure-Endpoint.sql` | Credential and configuration template |
| `tests/` | Test database, workload, tests and the `Run-All.ps1` runner |
| `bench/` | Benchmark: challenge database, workload, rubric, cases and results |
| `diagrams/` | Architecture, data flow, data model and recommendation type diagrams |
| `RELEASE_NOTES.md` | Changes by release, and how to upgrade |

## Development setup

You need:

- A SQL Server 2025 instance you can create and drop databases on. The test runner uses `localhost` with Windows authentication by default.
- `sqlcmd` on your path, and PowerShell, to run the scripts.

The tests use canned model answers (`@TestResponse`), so you don't need an Azure OpenAI endpoint for them. You only need one for the live tests and the live benchmark.

## Making a change

1. Fork the repository, or create a branch if you have write access. Use a short descriptive name, for example `fix/collation-conflict` or `docs/benchmark-notes`.
2. **Edit the files in `src/`, never `aisqltuner-index-tuner.sql`.** Then regenerate the install script and commit it together with your change:

   ```powershell
   .\build.ps1
   ```

3. Run the tests (below).
4. Update the documentation and `RELEASE_NOTES.md` (below).
5. Open a pull request against `main` that says what changed and why, and links the issue it closes.

Keep a pull request to one change. Unrelated cleanups belong in their own.

### Commit messages

Write a short imperative summary of what the change does, and name the issue or pull request number, as the existing history does:

```
Build limits, lock handling and @MaxMinutes for CREATE mode and sp_AIIndexTuner_Apply (#49) (#56)
```

## Running the tests

```powershell
.\tests\Run-All.ps1                               # localhost, Windows authentication
.\tests\Run-All.ps1 -Server sql01                 # another server
.\tests\Run-All.ps1 -Database AIIndexTunerTest2   # another test database
.\tests\Run-All.ps1 -Collation Turkish_100_CI_AS  # a test database in that collation
```

The runner rebuilds the install script, **drops and recreates the test database** (`AIIndexTunerTest` by default), installs the tool, runs a workload, and then runs [tests/03_Run-Tests.sql](tests/03_Run-Tests.sql). It stops if the test database has a database scoped credential, because recreating it would delete your endpoint setup. Use `-Database` to point it at another database, and pass `-Force` only when you mean it.

Test guidelines:

- Add a test to `tests/03_Run-Tests.sql` for every behavior change and bug fix. Use `@TestResponse` canned answers so the test is repeatable and needs no endpoint.
- A test should fail before your fix and pass after it.
- Anything that touches names or collations should run on a database whose collation differs from the instance's. That is the runner's default.
- A change to the collectors, the prompt or the response schema should also be run live at least once against a real endpoint, and the result noted in the pull request. See *Live tests* in the [README](README.md#live-tests).

If your change could affect the quality of the recommendations or what applying them gains, say so in the pull request. The maintainers can run the [benchmark](BENCHMARK.md) (`bench/Run-Rubric.ps1`); see [bench/PREREQUISITES.md](bench/PREREQUISITES.md) for what a live run needs. New benchmark cases are welcome: add the case with an explanation of why its expected answer is right to [bench/CASES.md](bench/CASES.md).

## T-SQL guidelines

- **Match the surrounding code.** Follow its naming, formatting and structure before introducing new patterns.
- **Target SQL Server 2025 and the Azure platforms listed in the README's *Requirements*.** Don't add a dependency on a feature those platforms lack.
- **Quote every name** that comes from the catalog or the model with `QUOTENAME`, and check it against the catalog before it goes into dynamic SQL. Treat plan cache and Query Store text as untrusted input.
- **Keep collection sections independent.** Each collector section runs in its own `TRY...CATCH`, so a failed section is reported and skipped rather than failing the run. Cap the rows a new section reads, because T-SQL has no per-statement timeout.
- **Write for every collation, not just your own.** Compare catalog and DMV text with an explicit `COLLATE` where the two can differ (see issue #42). Under a Turkish collation `UPPER('index')` gives `İNDEX`, so change the case of keywords under `Latin1_General_100_BIN2` (see pull request #44), and test on a non-default collation such as Turkish.
- **Make setup and re-installs safe to repeat.** The install script is re-run to upgrade an existing install: add new columns with `ALTER TABLE ... ADD` guarded by an existence check, so earlier runs and recommendations are kept.
- Comment non-obvious logic. Keep comments short and explain intent, not what the code already says.

### Safety rules for Apply mode

These protect people's databases, so changes here get the closest review:

- **The model's script is never executed.** The procedures build `CREATE INDEX`, `DROP INDEX` and `CREATE INDEX ... WITH (DROP_EXISTING = ON)` themselves, from the structured recommendation fields only.
- Every new change type or option needs a rule in the prompt **and** the same rule enforced again when applying, so a model that ignores the prompt still cannot make the change.
- Every change that can lose something (drops, widenings) needs a refusal rule for each case it cannot do safely, a reason in `StatusReason`, and a stored `UndoDDL`.
- Add tests for each refusal case, including attempted SQL injection in object names, index names and query text.

## Documentation

Code and documentation change in the same pull request.

- **Update the [README](README.md)** wherever it describes behavior you changed: parameters, configuration columns, collected sections, change controls, apply thresholds, safety checks, data disclosure and known limitations. Keep the examples runnable.
- **Update the *Data disclosure* section** if your change sends anything new to the endpoint or keeps anything new in the database.
- **Add an entry under *Unreleased* in [RELEASE_NOTES.md](RELEASE_NOTES.md)** for every user-visible change. Name the issue or pull request, say what changed and why, and note anything an upgrader must do.
- **Update [SECURITY.md](SECURITY.md)** if a change affects what is in or out of scope.
- If you change the schema, the procedures or the recommendation types, update the matching diagrams in `diagrams/` (SVG and PNG).
- Don't rewrite unrelated documentation.

## Sensitive data

- **Never commit** API keys, endpoint credentials, master key passwords or a filled-in `setup/Configure-Endpoint.sql`. Keep your local copy as `setup/Configure-Endpoint-DEV.sql`, which `.gitignore` excludes.
- Don't put real server, database, table or column names, query text or customer data in tests, benchmark cases, issues or pull requests. Use the test and benchmark databases' synthetic data.
- Check a `CollectedData` payload for anything sensitive before you attach it anywhere.

## Pull request checklist

- [ ] The change is made in `src/`, and `aisqltuner-index-tuner.sql` is regenerated with `.\build.ps1`
- [ ] `.\tests\Run-All.ps1` passes
- [ ] New or changed behavior has a test
- [ ] README and `RELEASE_NOTES.md` are updated
- [ ] No secrets, real names or customer data are included
- [ ] The pull request links its issue
