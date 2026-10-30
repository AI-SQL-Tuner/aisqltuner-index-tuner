# Release notes

Changes to the stored procedure version of aisqltuner-index-tuner, newest first. Each entry names
the pull request that made it.

To upgrade, run the new [aisqltuner-index-tuner.sql](aisqltuner-index-tuner.sql) in each database
where the tool is installed. It adds new columns with `ALTER TABLE`, so earlier runs and
recommendations are kept, and it replaces the procedures and functions.

## Unreleased

### Added

- **CREATE mode widens indexes in place** (issue #26). Before, a `ConsolidateIndex`
  recommendation was always left for review, so the same covering index was built or not depending
  on which category the model chose. In the sqlstorm-oltp benchmark that decided between −79% and
  −1% read reads.
  - **New field:** `replaces_index` in the response schema, stored as
    `AIIndexTuner.Recommendation.ReplacesIndex`. The prompt asks the model to fill it for a
    widening: a `ConsolidateIndex` that keeps an existing nonclustered index's keys as its leading
    keys, keeps its included columns, and adds key or included columns.
  - **What is applied:** CREATE mode and `sp_AIIndexTuner_Apply @RunId` now apply widenings, by
    default. The index is rebuilt in place under its own name from the validated fields, with
    `CREATE INDEX ... WITH (DROP_EXISTING = ON)`, on its own filegroup, and online where the edition
    allows it. The model's script is still never run.
  - **What stays for review, with a reason:**
    - a consolidation with no `replaces_index`;
    - a replaced index that is clustered, unique or constraint-backed, filtered, partitioned or
      disabled;
    - new keys that don't start with the old ones in the same order and direction;
    - a new index that loses an included column;
    - a unique, filtered or columnstore new index;
    - a script that builds a clustered index.
  - **Change controls:** a widening counts towards `@MaxNewIndexes`, and the prompt rule for it now
    says so. It obeys `@MinPriority` and `@MinConfidence`, and needs no `@AllowDropIndex`.
  - **Undo and tag:** `UndoDDL` rebuilds the old definition in place, options included. The
    `AIIndexTuner` extended property says *Widened by*, not *Created by*, so the index is rolled
    back with its `UndoDDL`, not dropped.
  - **New function:** `AIIndexTuner.fn_IndexDefinition` scripts an index from the catalog. It is
    shared by the drop and widening undo scripts.
  - **Test:** T25.

- **DOP feedback and optional parameter plan optimization** (issue #17), ported from AI SQL Tuner
  Studio:
  - New section DEGREE OF PARALLELISM FEEDBACK: whether DOP feedback can run for the database and
    every reason it cannot (`DOP_FEEDBACK` off, and whether that is its default; compatibility level
    below 160; Query Store not `READ_WRITE`), "not confirmed" on a Managed Instance whose update
    policy cannot be told apart, its feedback rows by state and the 20 most recent.
  - New section OPTIONAL PARAMETER PLAN OPTIMIZATION: `ACTIVE`, `NOT ACTIVE` with its blockers
    (`OPTIONAL_PARAMETER_OPTIMIZATION` off, compatibility level below 170), or `NOT_AVAILABLE`
    (Azure SQL Managed Instance), and how many query variants Query Store holds.
  - Prompt rules for both: a `MAXDOP` hint makes a query ineligible for DOP feedback, while a forced
    plan does not stop it; where OPPO is active, no drop of an index that only lacked seeks before
    OPPO, and no `RECOMPILE` or rewrite for a catch-all predicate OPPO already handles.
  - The prompt's input sentence names every section of the collected input by its header.
  - Tests T20 to T23.

- **Apply thresholds** ([#14](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/14)):
  `@MinPriority` and `@MinConfidence` on `sp_AIIndexTuner` and `sp_AIIndexTuner_Apply`. Each takes
  `High`, `Medium` or `Low`, or `NULL` (the default) for no minimum. Only recommendations whose
  priority level and confidence are at the minimum or above are applied. The rest are skipped with
  a reason and stay for review.
  - `'Low', 'Low'` applies everything the change controls and safety checks allow, for a dedicated
    test environment. `'Medium', 'High'` is a lower-risk choice for production.
  - The run stores its minimums. `sp_AIIndexTuner_Apply` uses them unless it is given its own,
    which replace them, so a held-back recommendation can be applied after review.
  - A recommendation with no level, for example one from an earlier run, counts as `Low`.
  - Unlike the change controls, the thresholds add no rule to the prompt.
  - Invalid values raise error 50210 (`sp_AIIndexTuner`) or 50303 (`sp_AIIndexTuner_Apply`).
- **Priority level** (#14): the model now returns `priority_level` (`High`, `Medium` or `Low`)
  next to the `priority` rank. It is stored in the new column `AIIndexTuner.Recommendation.PriorityLevel`.
  The prompt also says what `confidence` means: how sure the model is, from the evidence, that the
  change is correct.
- New columns `AIIndexTuner.Run.MinPriority` and `MinConfidence` (#14).
- Test T19 (#14).

### Changed

- **Result sets** (#14): `sp_AIIndexTuner` returns `PriorityLevel` after `Priority`.
  `sp_AIIndexTuner_Apply` returns `PriorityLevel` and `Confidence` after `Priority`. A script that
  captures these result sets with `INSERT ... EXEC` needs the new columns.
- The system prompt and response schema changed (#14), so `AIIndexTuner.Run.SystemPromptHash`
  differs from earlier runs.
- **AI SQL Tuner Studio links** ([#16](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/16)):
  the README compares this project with [AI SQL Tuner Studio](https://aisqltuner.com), the
  commercial desktop app. The `MoreFrom` column of `sp_AIIndexTuner`'s run result, and the install
  script's header, link to Studio's website and its
  [Microsoft Store](https://apps.microsoft.com/detail/9P68072ZM3N5) listing.

### Fixed

- **Query Store query variants** (issue #17): an adaptive plan (Parameter Sensitive Plan, optional
  parameter plan optimization) stores each query variant as its own query, with `object_id` 0, and
  records no runtime stats for the parent's dispatcher plan. So:
  - QUERY STORE WORKLOAD INSIGHTS split one statement's cost over its variants, ranked it too low,
    and lost its module. It now counts each variant under its parent query, with the parent's text.
  - A run scoped by module dependencies missed the variants, and one scoped by plan XML missed the
    parents. Each now brings in the other.
  - The self-exclusion by module missed variants of the tool's own statements, whose catch-all
    filters such as `(@SchemaName IS NULL OR s.name = @SchemaName)` get variants at compatibility
    level 170. It now uses the parent's module, in the workload and the write mix.
  - QUERY STORE FORCED PLAN FAILURES adds `ParentQueryId` for a forced plan of a variant.
- **`FORCE_LAST_GOOD_PLAN` scripts** (found in a live run for issue #17):
  - The model scripted the option as `ALTER DATABASE SCOPED CONFIGURATION SET FORCE_LAST_GOOD_PLAN = ON`, which
    SQL Server rejects, in four of five live runs. The prompt now gives the statement:
    `ALTER DATABASE [db] SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON)`.
  - It also recommended the option on Standard Developer edition, which has no automatic tuning (error 15707).
    On Standard and Express, AUTOMATIC TUNING OPTIONS now says the edition cannot enable it, and the prompt
    says not to recommend it there.
  - Test T24 runs the prompt's statement: it must turn the option on where automatic tuning exists, and fail
    only with the edition error on Standard and Express.

- **The collector's own statements in the payload**
  ([issue #18](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/issues/18)): two kinds got
  through the filters and were shown to the model as workload.
  - The width sampling of wide `INCLUDE` columns, added in #13, is dynamic SQL, which has no
    `object_id` in the plan cache or Query Store. It appeared in PLAN CACHE QUERY STATISTICS and
    QUERY STORE WORKLOAD INSIGHTS as a query that reads the wide column. It now carries an
    `/* AIIndexTuner collector */` marker inside the statement, where Query Store keeps it.
  - QUERY STORE WRITE WORKLOAD MIX counted the collector's own temp-table writes, such as one
    `INSERT #RawDensity` per statistic read. It now leaves out statements of the tool's modules
    and internal queries, as the workload section does.
  - Payloads collected before this fix, including pinned benchmark payloads, may include these
    statements.
  - T13 now checks for the sampling statement itself, and that two more collector runs leave the
    write mix unchanged. The test workload has a query that returns `dbo.Orders.Notes`, so the
    sampling runs.

## 2026-10-24

- **Benchmark gaps closed** ([#13](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/13), issue #12):
  - Missing-index suggestions list each included column with its type, plus an average width for
    wide and `(max)` columns. New helper: `AIIndexTuner.fn_ColumnType`.
  - New collector section, SKEWED LOW-CARDINALITY COLUMNS, with each value's share of the rows.
  - Prompt rules for forwarded records in heaps, wide columns in `INCLUDE`, filtered indexes on
    skewed columns, columnstore on tables with writes, and `schema_name`.
  - In a live A/B run on the challenge database, the required and forbidden rubric pass rate rose
    from 80.0% to 91.2%.
  - New test T18.
- **Prompt mapped onto the JSON contract** ([#11](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/11)):
  - Each rule that asked for report sections or findings now names the category or field it goes
    in.
  - `estimated_size_mb` is a signed net change.
  - Drops of redundant indexes are recommended as `DropIndex`, whatever the usage window.
- Added [SECURITY.md](SECURITY.md) ([#10](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/10)).

## 2026-10-23

- MIT license, and links use https://aisqltuner.com
  ([#9](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/9)).

## 2026-10-22

- **README** ([#8](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/8)):
  - records live endpoint testing on SQL Server 2025 with `gpt-5.6-luna`
  - adds a smoke-test install step
  - lists known limitations
- **Change controls** ([#5](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/5), issue #4):
  `@AllowColumnstore`, `@AllowDropIndex` and `@MaxNewIndexes`.
  - Each control adds a rule to the prompt and is enforced again when applying.
  - Columnstore indexes are `CreateIndex` with an `index_type`.
  - Drops are limited to nonclustered indexes that nothing depends on, and low-use drops need 7 days
    of usage statistics.
  - Every applied change stores `UndoDDL`.
  - New tests T14 to T17.
- **Benchmark, part 1** ([#3](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/3), issue #2):
  - a challenge database with 16 tuning problems, 37 rubric checks and 4 payload variants
  - `sp_AIIndexTuner @CollectedData` to pin the input
  - payload hash and timings on `AIIndexTuner.Run`
  - the collector leaves out the tool's own statements
- **Remaining Index Tuning collectors** ([#1](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/pull/1)):
  - index hotspots and page density
  - Query Store workload, write mix and forced-plan failures, scoped from plan XML
  - automatic tuning, CE feedback, `OPTIMIZED_SP_EXECUTESQL`, and the error-log usage window

## 2026-10-20

- **First prototype**:
  - `dbo.sp_AIIndexTuner` with `@SchemaName`, `@TableName` and `@Mode = RECOMMEND | CREATE`
  - Index Tuning collectors, and a prompt with a JSON contract and a strict response schema
  - calls to Azure OpenAI through `sp_invoke_external_rest_endpoint`, in background mode
  - results in `AIIndexTuner.Run` and `AIIndexTuner.Recommendation`
  - CREATE builds the DDL of new indexes from validated fields and never runs the model's script
