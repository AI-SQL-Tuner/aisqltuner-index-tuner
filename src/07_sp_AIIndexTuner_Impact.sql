SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    dbo.sp_AIIndexTuner_Impact (issue #72): what a run's applied recommendations changed in the real
    workload, outside the benchmark. It compares the @Days before the run's first applied change with
    the @Days after its last one (or up to now), on a database whose workload is broadly the same from
    day to day.

    Source of the figures:
    - Query Store (the default when it is on). Its runtime statistics are kept per query and per time
      interval, across plan changes, so the same query can be compared before and after the change.
      The plan cache cannot do that: creating or dropping an index evicts the plans on its table, and
      sys.dm_exec_query_stats loses their counters with them. Intervals that overlap the change are
      left out of both periods. Queries of the tool's own procedures are left out.
    - Workload snapshots (AIIndexTuner.WorkloadSnapshot), when Query Store is off or @Source =
      'Snapshots': database-wide cumulative counters, recorded by each sp_AIIndexTuner run when
      AIIndexTuner.Config.CaptureSnapshots = 1, or by sp_AIIndexTuner_Impact @Snapshot = 1 from a daily
      job. Only the difference between consecutive snapshots with no restart between them is used.

    Parameters:
        @RunId      the run to measure; NULL (default) = the latest run with an Applied recommendation
        @Days       days on each side of the change, 1 to 90 (default 7). Use whole weeks for a
                    workload with a weekly cycle. The after period ends now if @Days have not passed.
        @Top        queries to list as most improved and as most regressed (default 10)
        @RankBy     CPU (default), Reads or Duration: how the queries are ranked, by the change per day
                    (the change per execution times the executions per day after the change)
        @Source     Auto (default: Query Store if it is on, otherwise snapshots), QueryStore or Snapshots
        @ResultSet  NULL (default) returns all four result sets; Summary, Workload, Queries or
                    Recommendations returns only that one, for INSERT ... EXEC
        @Snapshot   1 = only record a workload snapshot now and return it; every other parameter is ignored

    Result sets:
        Summary          the periods compared, the days each covers, Query Store state, and warnings
                         that affect how far the figures can be trusted
        Workload         totals, per day and per execution, before and after, for CPU, duration,
                         reads, writes and log; with Query Store, for all queries and for only the
                         queries that ran in both periods (the like-for-like comparison)
        Queries          the most improved and most regressed queries that ran in both periods
                         (Query Store only), and which of the run's indexes their plans use
        Recommendations  each applied recommendation: whether the index exists, its use and writes
                         since it was created (sys.dm_db_index_usage_stats and
                         sys.dm_db_index_operational_stats, since the instance started), and the
                         queries whose plans use it (Query Store only)

    Per-day figures divide by the days each period covers, so periods of different length compare.
    Per-execution figures are not affected by how much the workload ran. A per-execution drop with a
    per-day rise means the workload grew; look at both.

    Times: AppliedAt is local server time, and Query Store keeps UTC; they are converted with the
    server's offset now, so a change applied before a daylight saving switch is placed an hour off.
    Needs VIEW DATABASE STATE (Query Store) and VIEW SERVER STATE (index usage, snapshots; VIEW
    DATABASE STATE in Azure SQL Database). Reads only; changes nothing, except @Snapshot = 1.
*/
CREATE OR ALTER PROCEDURE dbo.sp_AIIndexTuner_Impact
    @RunId     int = NULL,
    @Days      int = 7,
    @Top       int = 10,
    @RankBy    varchar(10) = 'CPU',
    @Source    varchar(12) = 'Auto',
    @ResultSet varchar(20) = NULL,
    @Snapshot  bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    -- A NULL passed explicitly, as in the script SSMS writes for Execute Procedure, means the default.
    -- Upper-cased under a fixed collation (see AIIndexTuner.fn_LevelRank).
    SELECT @Days = ISNULL(@Days, 7), @Top = ISNULL(@Top, 10), @Snapshot = ISNULL(@Snapshot, 0),
           @RankBy = UPPER(LTRIM(RTRIM(ISNULL(@RankBy, 'CPU'))) COLLATE Latin1_General_100_BIN2),
           @Source = UPPER(LTRIM(RTRIM(ISNULL(@Source, 'Auto'))) COLLATE Latin1_General_100_BIN2),
           @ResultSet = UPPER(LTRIM(RTRIM(@ResultSet)) COLLATE Latin1_General_100_BIN2);

    IF @Snapshot = 1
    BEGIN
        DECLARE @NewSnapshot int;
        EXEC AIIndexTuner.usp_CaptureSnapshot @SnapshotId = @NewSnapshot OUTPUT;
        SELECT * FROM AIIndexTuner.WorkloadSnapshot WHERE SnapshotId = @NewSnapshot;
        RETURN;
    END;

    IF @Days NOT BETWEEN 1 AND 90
        THROW 50501, N'@Days must be from 1 to 90.', 1;
    IF @Top NOT BETWEEN 1 AND 1000
        THROW 50502, N'@Top must be from 1 to 1000.', 1;
    IF @RankBy NOT IN ('CPU', 'READS', 'DURATION')
        THROW 50503, N'@RankBy must be CPU, Reads or Duration.', 1;
    IF @Source NOT IN ('AUTO', 'QUERYSTORE', 'SNAPSHOTS')
        THROW 50504, N'@Source must be Auto, QueryStore or Snapshots.', 1;
    IF @ResultSet NOT IN ('SUMMARY', 'WORKLOAD', 'QUERIES', 'RECOMMENDATIONS')
        THROW 50505, N'@ResultSet must be Summary, Workload, Queries or Recommendations, or NULL for all four.', 1;

    /* ===== The run and its change window ===== */
    DECLARE @Msg nvarchar(2048);
    IF @RunId IS NULL
        SELECT @RunId = MAX(RunId) FROM AIIndexTuner.Recommendation WHERE Status = 'Applied' AND AppliedAt IS NOT NULL;
    IF @RunId IS NULL
        THROW 50506, N'No run has an Applied recommendation. Apply recommendations first (sp_AIIndexTuner @Mode = ''CREATE'' or sp_AIIndexTuner_Apply), or pass @RunId.', 1;

    DECLARE @First datetime2(0), @Last datetime2(0), @AppliedCount int;
    SELECT @First = MIN(AppliedAt), @Last = MAX(AppliedAt), @AppliedCount = COUNT(*)
    FROM AIIndexTuner.Recommendation
    WHERE RunId = @RunId AND Status = 'Applied' AND AppliedAt IS NOT NULL;
    IF @AppliedCount = 0
    BEGIN
        SET @Msg = CONCAT(N'Run ', @RunId, N' has no Applied recommendation, so there is no change to measure.');
        THROW 50507, @Msg, 1;
    END;

    DECLARE @Now datetime2(0) = SYSDATETIME(), @Tz int = DATEPART(TZOFFSET, SYSDATETIMEOFFSET()),
            @Epoch datetime2(0) = '2000-01-01';
    -- Local times; the Query Store branch replaces them with interval boundaries.
    DECLARE @BeforeFrom datetime2(0) = DATEADD(DAY, -@Days, @First), @BeforeTo datetime2(0) = @First,
            @AfterFrom datetime2(0) = @Last, @AfterTo datetime2(0) = DATEADD(DAY, @Days, @Last),
            @BeforeDays float = 0, @AfterDays float = 0;   -- days each period covers
    IF @AfterTo > @Now SET @AfterTo = @Now;

    CREATE TABLE #Warnings (Seq int IDENTITY(1, 1) PRIMARY KEY, Warning nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL);
    IF DATEDIFF(MINUTE, @First, @Last) > 60
        INSERT #Warnings (Warning) VALUES (CONCAT(N'The run''s recommendations were applied over ', CAST(DATEDIFF(MINUTE, @First, @Last) / 60.0 AS decimal(9, 1)),
                                                  N' hours (', CONVERT(varchar(19), @First, 120), N' to ', CONVERT(varchar(19), @Last, 120), N'); that time is in neither period.'));

    /* ===== Query Store state ===== */
    DECLARE @QsState int, @QsStateDesc nvarchar(60), @QsDesiredDesc nvarchar(60), @QsCapture nvarchar(60), @QsStale bigint,
            @QsUsedMB bigint, @QsMaxMB bigint, @QsReadonlyReason int, @QsIntervalMin int, @QsUsable bit = 0;
    BEGIN TRY
        SELECT TOP (1) @QsState = actual_state, @QsStateDesc = actual_state_desc, @QsDesiredDesc = desired_state_desc,
               @QsCapture = query_capture_mode_desc, @QsStale = stale_query_threshold_days, @QsUsedMB = current_storage_size_mb,
               @QsMaxMB = max_storage_size_mb, @QsReadonlyReason = readonly_reason, @QsIntervalMin = interval_length_minutes
        FROM sys.database_query_store_options;
    END TRY
    BEGIN CATCH
        INSERT #Warnings (Warning) VALUES (LEFT(N'Query Store options could not be read: ' + ERROR_MESSAGE(), 1000));
    END CATCH;
    IF @QsState IN (1, 2) SET @QsUsable = 1;   -- READ_ONLY or READ_WRITE

    IF @Source = 'QUERYSTORE' AND @QsUsable = 0
        THROW 50508, N'Query Store is not on in this database (READ_WRITE or READ_ONLY). Use @Source = ''Snapshots'' with workload snapshots, or turn Query Store on and measure the next change.', 1;
    DECLARE @UseQs bit = CASE WHEN @Source = 'SNAPSHOTS' THEN 0 ELSE @QsUsable END,
            @SourceName varchar(20);
    SET @SourceName = CASE WHEN @UseQs = 1 THEN 'Query Store' ELSE 'Snapshots' END;
    IF @Source = 'AUTO' AND @UseQs = 0
        INSERT #Warnings (Warning) VALUES (CONCAT(N'Query Store is ', ISNULL(@QsStateDesc, N'unavailable'), N', so database-wide workload snapshots are compared instead, and no queries are listed.'));

    /* ===== Result tables, the same shape whatever the source ===== */
    CREATE TABLE #mv (Scope nvarchar(40) COLLATE DATABASE_DEFAULT NOT NULL, Seq int NOT NULL, Metric nvarchar(40) COLLATE DATABASE_DEFAULT NOT NULL,
                      Period char(1) NOT NULL, Value float NULL, Execs float NULL, Days float NULL, PerExec bit NOT NULL);
    CREATE TABLE #Queries (Direction varchar(10) NOT NULL, [Rank] int NOT NULL, QueryHash binary(8) NOT NULL, SampleQueryId bigint NULL,
                           ObjectName nvarchar(300) COLLATE DATABASE_DEFAULT NULL, QueryText nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
                           ExecsPerDayBefore decimal(19, 1) NULL, ExecsPerDayAfter decimal(19, 1) NULL,
                           CpuMsPerExecBefore decimal(19, 3) NULL, CpuMsPerExecAfter decimal(19, 3) NULL,
                           DurationMsPerExecBefore decimal(19, 3) NULL, DurationMsPerExecAfter decimal(19, 3) NULL,
                           ReadsPerExecBefore decimal(19, 1) NULL, ReadsPerExecAfter decimal(19, 1) NULL,
                           WritesPerExecBefore decimal(19, 1) NULL, WritesPerExecAfter decimal(19, 1) NULL,
                           CpuMsPerDayChange decimal(19, 1) NULL, DurationMsPerDayChange decimal(19, 1) NULL, ReadsPerDayChange decimal(19, 1) NULL,
                           PlanChanged bit NULL, RunIndexesInPlans nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
    CREATE TABLE #Recs (RecommendationId int NOT NULL PRIMARY KEY, Priority int NULL, Category varchar(30) COLLATE DATABASE_DEFAULT NULL,
                        SchemaName sysname COLLATE DATABASE_DEFAULT NULL, TableName sysname COLLATE DATABASE_DEFAULT NULL, IndexName sysname COLLATE DATABASE_DEFAULT NULL,
                        AppliedAt datetime2(0) NULL, ObjectId int NULL, IndexId int NULL, IndexExists bit NULL,
                        UserSeeks bigint NULL, UserScans bigint NULL, UserLookups bigint NULL, UserUpdates bigint NULL,
                        LeafWrites bigint NULL, LeafPageAllocations bigint NULL, UsageSince datetime2(0) NULL,
                        QueriesUsingBefore int NULL, QueriesUsingAfter int NULL,
                        ExecsPerDayUsingBefore decimal(19, 1) NULL, ExecsPerDayUsingAfter decimal(19, 1) NULL,
                        AffectedQueries int NULL,
                        AffectedCpuMsPerExecBefore decimal(19, 3) NULL, AffectedCpuMsPerExecAfter decimal(19, 3) NULL,
                        AffectedReadsPerExecBefore decimal(19, 1) NULL, AffectedReadsPerExecAfter decimal(19, 1) NULL,
                        Note nvarchar(400) COLLATE DATABASE_DEFAULT NULL);
    -- The run's applied index changes, with the plan XML pattern of each index: an Object element reads
    -- Database="[d]" Schema="[s]" Table="[t]" Index="[i]".
    CREATE TABLE #ri (RecommendationId int NOT NULL PRIMARY KEY, IndexName sysname COLLATE DATABASE_DEFAULT NOT NULL,
                      Pattern nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ri (RecommendationId, IndexName, Pattern)
    SELECT RecommendationId, COALESCE(IndexName, ReplacesIndex),
           N'%Schema="' + AIIndexTuner.fn_EscapeLike(QUOTENAME(SchemaName)) + N'" Table="' + AIIndexTuner.fn_EscapeLike(QUOTENAME(TableName))
           + N'" Index="' + AIIndexTuner.fn_EscapeLike(QUOTENAME(COALESCE(IndexName, ReplacesIndex))) + N'"%'
    FROM AIIndexTuner.Recommendation
    WHERE RunId = @RunId AND Status = 'Applied' AND AppliedAt IS NOT NULL
      AND SchemaName IS NOT NULL AND TableName IS NOT NULL AND COALESCE(IndexName, ReplacesIndex) IS NOT NULL;

    DECLARE @QueriesBoth int, @QueriesBeforeOnly int, @QueriesAfterOnly int, @PairsBefore int, @PairsAfter int;

    IF @UseQs = 1
    BEGIN
        /* ===== Query Store ===== */
        -- Intervals are aligned to their length, which divides a day, so the change window is widened
        -- to whole intervals: the intervals that overlap the change are in neither period. In UTC.
        -- The after period ends at an interval boundary too, except while it is still open (it ends
        -- now): then the current interval is included, since its statistics run only up to now.
        DECLARE @L int = ISNULL(NULLIF(@QsIntervalMin, 0), 60), @QsEarliest datetime2(0), @AfterOpen bit = CASE WHEN @AfterTo >= @Now THEN 1 ELSE 0 END,
                @BeforeFromU datetime2(0), @BeforeToU datetime2(0), @AfterFromU datetime2(0), @AfterToU datetime2(0);
        SELECT @BeforeFromU = DATEADD(MINUTE, ((DATEDIFF(MINUTE, @Epoch, DATEADD(MINUTE, -@Tz, @BeforeFrom)) + @L - 1) / @L) * @L, @Epoch),
               @BeforeToU   = DATEADD(MINUTE, (DATEDIFF(MINUTE, @Epoch, DATEADD(MINUTE, -@Tz, @BeforeTo)) / @L) * @L, @Epoch),
               @AfterFromU  = DATEADD(MINUTE, ((DATEDIFF(MINUTE, @Epoch, DATEADD(MINUTE, -@Tz, @AfterFrom)) + @L - 1) / @L) * @L, @Epoch),
               @AfterToU    = CASE WHEN @AfterOpen = 1 THEN DATEADD(MINUTE, -@Tz, @AfterTo)
                                   ELSE DATEADD(MINUTE, (DATEDIFF(MINUTE, @Epoch, DATEADD(MINUTE, -@Tz, @AfterTo)) / @L) * @L, @Epoch) END;
        SELECT @QsEarliest = MIN(CONVERT(datetime2(0), SWITCHOFFSET(start_time, 0))) FROM sys.query_store_runtime_stats_interval;
        -- Query Store has no data before then.
        IF @QsEarliest > @BeforeFromU SET @BeforeFromU = @QsEarliest;
        IF @QsEarliest > @AfterFromU SET @AfterFromU = @QsEarliest;
        IF @AfterToU < @AfterFromU SET @AfterToU = @AfterFromU;
        SELECT @BeforeDays = CASE WHEN @BeforeToU > @BeforeFromU THEN DATEDIFF(SECOND, @BeforeFromU, @BeforeToU) / 86400.0 ELSE 0 END,
               @AfterDays  = CASE WHEN @AfterToU > @AfterFromU THEN DATEDIFF(SECOND, @AfterFromU, @AfterToU) / 86400.0 ELSE 0 END,
               @BeforeFrom = DATEADD(MINUTE, @Tz, @BeforeFromU), @BeforeTo = DATEADD(MINUTE, @Tz, @BeforeToU),
               @AfterFrom  = DATEADD(MINUTE, @Tz, @AfterFromU), @AfterTo = DATEADD(MINUTE, @Tz, @AfterToU);

        CREATE TABLE #iv (runtime_stats_interval_id bigint NOT NULL PRIMARY KEY, Period char(1) NOT NULL);
        INSERT #iv (runtime_stats_interval_id, Period)
        SELECT i.runtime_stats_interval_id, CASE WHEN u.EndU <= @BeforeToU THEN 'B' ELSE 'A' END
        FROM sys.query_store_runtime_stats_interval AS i
        CROSS APPLY (SELECT CONVERT(datetime2(0), SWITCHOFFSET(i.start_time, 0)) AS StartU, CONVERT(datetime2(0), SWITCHOFFSET(i.end_time, 0)) AS EndU) AS u
        WHERE (u.StartU >= @BeforeFromU AND u.EndU <= @BeforeToU)
           OR (u.StartU >= @AfterFromU AND (u.EndU <= @AfterToU OR (@AfterOpen = 1 AND u.StartU < @AfterToU)));

        -- The tool's own procedures, left out of the workload.
        CREATE TABLE #own (object_id int NOT NULL PRIMARY KEY);
        INSERT #own (object_id)
        SELECT object_id FROM sys.objects
        WHERE type IN ('P', 'FN', 'IF', 'TF')
          AND (schema_id = SCHEMA_ID(N'AIIndexTuner') OR (schema_id = SCHEMA_ID(N'dbo') AND name LIKE N'sp\_AIIndexTuner%' ESCAPE N'\'));

        -- Per plan and period. A plan belongs to one query; totals are the averages times the executions.
        CREATE TABLE #pm (plan_id bigint NOT NULL, Period char(1) NOT NULL, query_hash binary(8) NOT NULL, query_id bigint NOT NULL,
                          Execs float NOT NULL, CpuUs float NULL, DurUs float NULL, Reads float NULL, Writes float NULL, Phys float NULL, LogBytes float NULL,
                          PRIMARY KEY (plan_id, Period));
        INSERT #pm (plan_id, Period, query_hash, query_id, Execs, CpuUs, DurUs, Reads, Writes, Phys, LogBytes)
        SELECT rs.plan_id, iv.Period, q.query_hash, q.query_id,
               SUM(CAST(rs.count_executions AS float)),
               SUM(rs.avg_cpu_time * rs.count_executions), SUM(rs.avg_duration * rs.count_executions),
               SUM(rs.avg_logical_io_reads * rs.count_executions), SUM(rs.avg_logical_io_writes * rs.count_executions),
               SUM(rs.avg_physical_io_reads * rs.count_executions), SUM(ISNULL(rs.avg_log_bytes_used, 0) * rs.count_executions)
        FROM sys.query_store_runtime_stats AS rs
        INNER JOIN #iv AS iv ON iv.runtime_stats_interval_id = rs.runtime_stats_interval_id
        INNER JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
        INNER JOIN sys.query_store_query AS q ON q.query_id = p.query_id
        WHERE NOT EXISTS (SELECT 1 FROM #own AS o WHERE o.object_id = q.object_id)
        GROUP BY rs.plan_id, iv.Period, q.query_hash, q.query_id;

        -- Per query (by query_hash: the same statement can get a new query_id in another compile context).
        CREATE TABLE #qp (query_hash binary(8) NOT NULL, Period char(1) NOT NULL, SampleQueryId bigint NOT NULL, Execs float NOT NULL,
                          CpuUs float NULL, DurUs float NULL, Reads float NULL, Writes float NULL, Phys float NULL, LogBytes float NULL,
                          PRIMARY KEY (query_hash, Period));
        INSERT #qp
        SELECT query_hash, Period, MAX(query_id), SUM(Execs), SUM(CpuUs), SUM(DurUs), SUM(Reads), SUM(Writes), SUM(Phys), SUM(LogBytes)
        FROM #pm GROUP BY query_hash, Period;

        CREATE TABLE #both (query_hash binary(8) NOT NULL PRIMARY KEY);
        INSERT #both SELECT query_hash FROM #qp WHERE Execs > 0 GROUP BY query_hash HAVING COUNT(*) = 2;
        SELECT @QueriesBoth = (SELECT COUNT(*) FROM #both),
               @QueriesBeforeOnly = (SELECT COUNT(DISTINCT query_hash) FROM #qp WHERE Period = 'B' AND query_hash NOT IN (SELECT query_hash FROM #both)),
               @QueriesAfterOnly = (SELECT COUNT(DISTINCT query_hash) FROM #qp WHERE Period = 'A' AND query_hash NOT IN (SELECT query_hash FROM #both));

        -- Workload totals, for all queries and for those in both periods.
        INSERT #mv (Scope, Seq, Metric, Period, Value, Execs, Days, PerExec)
        SELECT t.Scope, m.Seq, m.Metric, t.Period, m.Value, t.Execs, CASE t.Period WHEN 'B' THEN @BeforeDays ELSE @AfterDays END, m.PerExec
        FROM (SELECT N'All queries' AS Scope, Period, SUM(Execs) AS Execs, SUM(CpuUs) AS CpuUs, SUM(DurUs) AS DurUs, SUM(Reads) AS Reads,
                     SUM(Writes) AS Writes, SUM(Phys) AS Phys, SUM(LogBytes) AS LogBytes
              FROM #qp GROUP BY Period
              UNION ALL
              SELECT N'Queries in both periods', qp.Period, SUM(qp.Execs), SUM(qp.CpuUs), SUM(qp.DurUs), SUM(qp.Reads),
                     SUM(qp.Writes), SUM(qp.Phys), SUM(qp.LogBytes)
              FROM #qp AS qp INNER JOIN #both AS b ON b.query_hash = qp.query_hash GROUP BY qp.Period) AS t
        CROSS APPLY (VALUES (1, N'Executions', t.Execs, CAST(0 AS bit)),
                            (2, N'CPU ms', t.CpuUs / 1000.0, CAST(1 AS bit)),
                            (3, N'Duration ms', t.DurUs / 1000.0, CAST(1 AS bit)),
                            (4, N'Logical reads', t.Reads, CAST(1 AS bit)),
                            (5, N'Logical writes', t.Writes, CAST(1 AS bit)),
                            (6, N'Physical reads', t.Phys, CAST(1 AS bit)),
                            (7, N'Log MB', t.LogBytes / 1048576.0, CAST(1 AS bit))) AS m (Seq, Metric, Value, PerExec);

        -- Which plans use an index the run created or dropped.
        CREATE TABLE #planidx (plan_id bigint NOT NULL, RecommendationId int NOT NULL, PRIMARY KEY (plan_id, RecommendationId));
        IF EXISTS (SELECT 1 FROM #ri)
            INSERT #planidx (plan_id, RecommendationId)
            SELECT p.plan_id, ri.RecommendationId
            FROM (SELECT DISTINCT plan_id FROM #pm) AS pm
            INNER JOIN sys.query_store_plan AS p ON p.plan_id = pm.plan_id
            INNER JOIN #ri AS ri ON CAST(p.query_plan AS nvarchar(max)) COLLATE DATABASE_DEFAULT LIKE ri.Pattern ESCAPE N'\';

        -- The queries in both periods, ranked by the change per day of the chosen measure.
        ;WITH c AS (
            SELECT b.query_hash, a.SampleQueryId,
                   b.Execs / NULLIF(@BeforeDays, 0) AS BExecsDay, a.Execs / NULLIF(@AfterDays, 0) AS AExecsDay,
                   b.CpuUs / 1000.0 / b.Execs AS BCpu, a.CpuUs / 1000.0 / a.Execs AS ACpu,
                   b.DurUs / 1000.0 / b.Execs AS BDur, a.DurUs / 1000.0 / a.Execs AS ADur,
                   b.Reads / b.Execs AS BReads, a.Reads / a.Execs AS AReads,
                   b.Writes / b.Execs AS BWrites, a.Writes / a.Execs AS AWrites
            FROM #qp AS b
            INNER JOIN #qp AS a ON a.query_hash = b.query_hash AND a.Period = 'A'
            WHERE b.Period = 'B' AND b.Execs > 0 AND a.Execs > 0),
        d AS (
            SELECT c.*, (c.ACpu - c.BCpu) * c.AExecsDay AS CpuDay, (c.ADur - c.BDur) * c.AExecsDay AS DurDay, (c.AReads - c.BReads) * c.AExecsDay AS ReadsDay
            FROM c),
        r AS (
            SELECT d.*, CASE @RankBy WHEN 'READS' THEN d.ReadsDay WHEN 'DURATION' THEN d.DurDay ELSE d.CpuDay END AS Impact
            FROM d),
        k AS (
            SELECT r.*, CASE WHEN r.Impact < 0 THEN 'Improved' ELSE 'Regressed' END AS Direction,
                   ROW_NUMBER() OVER (PARTITION BY CASE WHEN r.Impact < 0 THEN 0 ELSE 1 END ORDER BY ABS(r.Impact) DESC) AS rk
            FROM r WHERE r.Impact <> 0)
        INSERT #Queries (Direction, [Rank], QueryHash, SampleQueryId, ObjectName, QueryText, ExecsPerDayBefore, ExecsPerDayAfter,
                         CpuMsPerExecBefore, CpuMsPerExecAfter, DurationMsPerExecBefore, DurationMsPerExecAfter,
                         ReadsPerExecBefore, ReadsPerExecAfter, WritesPerExecBefore, WritesPerExecAfter,
                         CpuMsPerDayChange, DurationMsPerDayChange, ReadsPerDayChange, PlanChanged, RunIndexesInPlans)
        SELECT k.Direction, k.rk, k.query_hash, k.SampleQueryId,
               CASE WHEN q.object_id <> 0 THEN QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(q.object_id)) END,
               AIIndexTuner.fn_CleanText(qt.query_sql_text, 300),
               k.BExecsDay, k.AExecsDay, k.BCpu, k.ACpu, k.BDur, k.ADur, k.BReads, k.AReads, k.BWrites, k.AWrites,
               k.CpuDay, k.DurDay, k.ReadsDay,
               CASE WHEN EXISTS (SELECT 1 FROM #pm AS pa WHERE pa.query_hash = k.query_hash AND pa.Period = 'A'
                                 AND NOT EXISTS (SELECT 1 FROM #pm AS pb WHERE pb.query_hash = k.query_hash AND pb.Period = 'B' AND pb.plan_id = pa.plan_id))
                    THEN 1 ELSE 0 END,
               (SELECT STRING_AGG(CONVERT(nvarchar(max), x.IndexName + N' (' + x.Periods + N')'), N', ') WITHIN GROUP (ORDER BY x.IndexName)
                FROM (SELECT ri.IndexName,
                             CASE WHEN MIN(pm.Period) = MAX(pm.Period) THEN CASE MIN(pm.Period) WHEN 'B' THEN N'before' ELSE N'after' END ELSE N'before and after' END AS Periods
                      FROM #pm AS pm
                      INNER JOIN #planidx AS px ON px.plan_id = pm.plan_id
                      INNER JOIN #ri AS ri ON ri.RecommendationId = px.RecommendationId
                      WHERE pm.query_hash = k.query_hash
                      GROUP BY ri.IndexName) AS x)
        FROM k
        LEFT JOIN sys.query_store_query AS q ON q.query_id = k.SampleQueryId
        LEFT JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        WHERE k.rk <= @Top;

        -- Coverage warnings.
        IF @QsState = 1
            INSERT #Warnings (Warning) VALUES (CONCAT(N'Query Store is READ_ONLY (readonly_reason ', @QsReadonlyReason, N'): executions since it switched are not recorded.'));
        IF @QsDesiredDesc <> @QsStateDesc
            INSERT #Warnings (Warning) VALUES (CONCAT(N'Query Store is ', @QsStateDesc, N' but was set to ', @QsDesiredDesc, N'.'));
        IF @QsMaxMB > 0 AND @QsUsedMB >= 0.9 * @QsMaxMB
            INSERT #Warnings (Warning) VALUES (CONCAT(N'Query Store uses ', @QsUsedMB, N' of its ', @QsMaxMB, N' MB: size-based cleanup may have removed queries from the before period.'));
        IF @QsStale IS NOT NULL AND DATEDIFF(DAY, @BeforeFrom, @Now) > @QsStale
            INSERT #Warnings (Warning) VALUES (CONCAT(N'The before period starts ', DATEDIFF(DAY, @BeforeFrom, @Now), N' days ago, past Query Store''s STALE_QUERY_THRESHOLD_DAYS of ', @QsStale, N': some of its queries may have been removed.'));
        IF @QsCapture IS NOT NULL AND @QsCapture <> N'ALL'
            INSERT #Warnings (Warning) VALUES (CONCAT(N'Query Store capture mode is ', @QsCapture, N': infrequent and cheap queries are not captured, so the totals undercount. That holds for both periods if the mode did not change.'));
        IF @QueriesBeforeOnly + @QueriesAfterOnly > 0
            INSERT #Warnings (Warning) VALUES (CONCAT(@QueriesBeforeOnly, N' queries ran only before the change and ', @QueriesAfterOnly,
                                                      N' only after it; the "Queries in both periods" rows of the Workload result set leave them out.'));
    END
    ELSE
    BEGIN
        /* ===== Workload snapshots ===== */
        -- Consecutive snapshots with no restart between them. A pair counts for the I/O counters when
        -- none of them went down, and for the query counters when none of theirs went down (plan cache
        -- eviction lowers them).
        ;WITH s AS (SELECT *, ROW_NUMBER() OVER (ORDER BY CapturedAt, SnapshotId) AS rn FROM AIIndexTuner.WorkloadSnapshot)
        SELECT CASE WHEN p.CapturedAt >= @BeforeFrom AND c.CapturedAt <= @BeforeTo THEN 'B'
                    WHEN p.CapturedAt >= @AfterFrom AND c.CapturedAt <= @AfterTo THEN 'A' END AS Period,
               DATEDIFF(SECOND, p.CapturedAt, c.CapturedAt) / 86400.0 AS Days,
               CASE WHEN (c.ServerStartTime = p.ServerStartTime OR (c.ServerStartTime IS NULL AND p.ServerStartTime IS NULL)) THEN 0 ELSE 1 END AS Restart,
               CASE WHEN c.DataBytesRead >= p.DataBytesRead AND c.DataBytesWritten >= p.DataBytesWritten AND c.IoStallMs >= p.IoStallMs THEN 1 ELSE 0 END AS IoOk,
               CASE WHEN c.Executions >= p.Executions AND c.CpuMs >= p.CpuMs AND c.DurationMs >= p.DurationMs AND c.LogicalReads >= p.LogicalReads
                         AND c.LogicalWrites >= p.LogicalWrites AND c.PhysicalReads >= p.PhysicalReads THEN 1 ELSE 0 END AS QOk,
               CAST(c.Executions - p.Executions AS float) AS dExecs, CAST(c.CpuMs - p.CpuMs AS float) AS dCpu, CAST(c.DurationMs - p.DurationMs AS float) AS dDur,
               CAST(c.LogicalReads - p.LogicalReads AS float) AS dReads, CAST(c.LogicalWrites - p.LogicalWrites AS float) AS dWrites,
               CAST(c.PhysicalReads - p.PhysicalReads AS float) AS dPhys, CAST(c.DataBytesRead - p.DataBytesRead AS float) AS dBytesRead,
               CAST(c.DataBytesWritten - p.DataBytesWritten AS float) AS dBytesWritten, CAST(c.IoStallMs - p.IoStallMs AS float) AS dStall
        INTO #pairs
        FROM s AS c INNER JOIN s AS p ON p.rn = c.rn - 1;
        DELETE #pairs WHERE Period IS NULL;

        SELECT @PairsBefore = COUNT(CASE WHEN Period = 'B' AND Restart = 0 AND (IoOk = 1 OR QOk = 1) THEN 1 END),
               @PairsAfter = COUNT(CASE WHEN Period = 'A' AND Restart = 0 AND (IoOk = 1 OR QOk = 1) THEN 1 END),
               @BeforeDays = ISNULL(SUM(CASE WHEN Period = 'B' AND Restart = 0 AND (IoOk = 1 OR QOk = 1) THEN Days END), 0),
               @AfterDays = ISNULL(SUM(CASE WHEN Period = 'A' AND Restart = 0 AND (IoOk = 1 OR QOk = 1) THEN Days END), 0)
        FROM #pairs;

        INSERT #mv (Scope, Seq, Metric, Period, Value, Execs, Days, PerExec)
        SELECT N'Database', m.Seq, m.Metric, g.Period, m.Value, g.Execs, g.Days, m.PerExec
        FROM (SELECT Period, SUM(Days) AS Days, SUM(dExecs) AS Execs, SUM(dCpu) AS Cpu, SUM(dDur) AS Dur, SUM(dReads) AS Reads,
                     SUM(dWrites) AS Writes, SUM(dPhys) AS Phys
              FROM #pairs WHERE Restart = 0 AND QOk = 1 GROUP BY Period) AS g
        CROSS APPLY (VALUES (1, N'Executions', g.Execs, CAST(0 AS bit)),
                            (2, N'CPU ms', g.Cpu, CAST(1 AS bit)),
                            (3, N'Duration ms', g.Dur, CAST(1 AS bit)),
                            (4, N'Logical reads', g.Reads, CAST(1 AS bit)),
                            (5, N'Logical writes', g.Writes, CAST(1 AS bit)),
                            (6, N'Physical reads', g.Phys, CAST(1 AS bit))) AS m (Seq, Metric, Value, PerExec)
        UNION ALL
        SELECT N'Database', m.Seq, m.Metric, g.Period, m.Value, NULL, g.Days, CAST(0 AS bit)
        FROM (SELECT Period, SUM(Days) AS Days, SUM(dBytesRead) AS BytesRead, SUM(dBytesWritten) AS BytesWritten, SUM(dStall) AS Stall
              FROM #pairs WHERE Restart = 0 AND IoOk = 1 GROUP BY Period) AS g
        CROSS APPLY (VALUES (8, N'Data MB read', g.BytesRead / 1048576.0),
                            (9, N'Data MB written', g.BytesWritten / 1048576.0),
                            (10, N'I/O stall ms', g.Stall)) AS m (Seq, Metric, Value);

        DECLARE @Skipped int = (SELECT COUNT(*) FROM #pairs WHERE Restart = 1 OR (IoOk = 0 AND QOk = 0));
        IF @Skipped > 0
            INSERT #Warnings (Warning) VALUES (CONCAT(@Skipped, N' pairs of consecutive snapshots in the periods were left out: the instance restarted, or the database went offline, between them.'));
        IF EXISTS (SELECT 1 FROM #pairs WHERE Restart = 0 AND IoOk = 1 AND QOk = 0)
            INSERT #Warnings (Warning) VALUES (N'Some snapshot pairs count for the I/O figures only: the plan cache lost plans between them, so their query counters went down.');
        INSERT #Warnings (Warning) VALUES (N'Snapshot query figures sum the plan cache, which loses the counters of evicted plans, and an index change evicts the plans on its table: they undercount. The data file I/O figures do not have that problem.');
    END;

    IF @BeforeDays = 0
        INSERT #Warnings (Warning) VALUES (CASE WHEN @UseQs = 1 THEN N'Query Store has no data before the change.'
                                                ELSE N'No pair of snapshots covers the time before the change. Set AIIndexTuner.Config.CaptureSnapshots = 1, or schedule sp_AIIndexTuner_Impact @Snapshot = 1, before the next change.' END);
    IF @AfterDays = 0
        INSERT #Warnings (Warning) VALUES (CASE WHEN @UseQs = 1 THEN N'No whole Query Store interval has passed since the change.'
                                                ELSE N'No pair of snapshots covers the time since the change: take at least two after it.' END);
    ELSE IF @AfterDays < 1
        INSERT #Warnings (Warning) VALUES (CONCAT(N'Only ', CAST(@AfterDays * 24 AS decimal(9, 1)), N' hours since the change are covered: the figures are preliminary.'));
    IF @BeforeDays > 0 AND @AfterDays > 0 AND ABS(@BeforeDays - @AfterDays) >= 1
        INSERT #Warnings (Warning) VALUES (CONCAT(N'The periods cover ', CAST(@BeforeDays AS decimal(9, 2)), N' and ', CAST(@AfterDays AS decimal(9, 2)), N' days. Per-day figures are scaled to match, but a workload with a weekly cycle compares fairly only over the same whole weeks.'));

    /* ===== Applied recommendations ===== */
    DECLARE @UsageSince datetime2(0);
    BEGIN TRY
        EXEC AIIndexTuner.usp_UsageSince @Since = @UsageSince OUTPUT;
    END TRY
    BEGIN CATCH
        SET @UsageSince = NULL;
    END CATCH;

    INSERT #Recs (RecommendationId, Priority, Category, SchemaName, TableName, IndexName, AppliedAt, ObjectId, IndexId, IndexExists)
    SELECT r.RecommendationId, r.Priority, r.Category, r.SchemaName, r.TableName, COALESCE(r.IndexName, r.ReplacesIndex), r.AppliedAt,
           i.object_id, i.index_id,
           CASE WHEN COALESCE(r.IndexName, r.ReplacesIndex) IS NULL THEN NULL WHEN i.index_id IS NOT NULL THEN 1 ELSE 0 END
    FROM AIIndexTuner.Recommendation AS r
    LEFT JOIN sys.indexes AS i ON i.object_id = OBJECT_ID(QUOTENAME(r.SchemaName) + N'.' + QUOTENAME(r.TableName))
                              AND i.name = COALESCE(r.IndexName, r.ReplacesIndex)
    WHERE r.RunId = @RunId AND r.Status = 'Applied' AND r.AppliedAt IS NOT NULL;

    BEGIN TRY
        UPDATE r
        SET UserSeeks = ISNULL(us.user_seeks, 0), UserScans = ISNULL(us.user_scans, 0), UserLookups = ISNULL(us.user_lookups, 0),
            UserUpdates = ISNULL(us.user_updates, 0),
            UsageSince = CASE WHEN @UsageSince > r.AppliedAt THEN @UsageSince ELSE r.AppliedAt END
        FROM #Recs AS r
        LEFT JOIN sys.dm_db_index_usage_stats AS us ON us.database_id = DB_ID() AND us.object_id = r.ObjectId AND us.index_id = r.IndexId
        WHERE r.IndexId IS NOT NULL;

        UPDATE r
        SET LeafWrites = os.LeafWrites, LeafPageAllocations = os.LeafAllocs
        FROM #Recs AS r
        CROSS APPLY (SELECT SUM(o.leaf_insert_count + o.leaf_update_count + o.leaf_delete_count) AS LeafWrites, SUM(o.leaf_allocation_count) AS LeafAllocs
                     FROM sys.dm_db_index_operational_stats(DB_ID(), r.ObjectId, r.IndexId, NULL) AS o) AS os
        WHERE r.IndexId IS NOT NULL AND r.ObjectId IS NOT NULL;
    END TRY
    BEGIN CATCH
        INSERT #Warnings (Warning) VALUES (LEFT(N'Index usage could not be read: ' + ERROR_MESSAGE(), 1000));
    END CATCH;

    IF @UseQs = 1
        UPDATE r
        SET QueriesUsingBefore = u.QB, QueriesUsingAfter = u.QA,
            ExecsPerDayUsingBefore = u.EB / NULLIF(@BeforeDays, 0), ExecsPerDayUsingAfter = u.EA / NULLIF(@AfterDays, 0),
            AffectedQueries = f.N,
            AffectedCpuMsPerExecBefore = f.BCpu / 1000.0 / NULLIF(f.BExecs, 0), AffectedCpuMsPerExecAfter = f.ACpu / 1000.0 / NULLIF(f.AExecs, 0),
            AffectedReadsPerExecBefore = f.BReads / NULLIF(f.BExecs, 0), AffectedReadsPerExecAfter = f.AReads / NULLIF(f.AExecs, 0)
        FROM #Recs AS r
        INNER JOIN #ri AS ri ON ri.RecommendationId = r.RecommendationId
        CROSS APPLY (SELECT COUNT(DISTINCT CASE WHEN pm.Period = 'B' THEN pm.query_hash END) AS QB,
                            COUNT(DISTINCT CASE WHEN pm.Period = 'A' THEN pm.query_hash END) AS QA,
                            ISNULL(SUM(CASE WHEN pm.Period = 'B' THEN pm.Execs END), 0) AS EB,
                            ISNULL(SUM(CASE WHEN pm.Period = 'A' THEN pm.Execs END), 0) AS EA
                     FROM #pm AS pm INNER JOIN #planidx AS px ON px.plan_id = pm.plan_id
                     WHERE px.RecommendationId = r.RecommendationId) AS u
        -- The queries whose plans used the index in either period and that ran in both: their cost per
        -- execution before and after.
        CROSS APPLY (SELECT COUNT(DISTINCT qp.query_hash) AS N,
                            SUM(CASE WHEN qp.Period = 'B' THEN qp.Execs END) AS BExecs, SUM(CASE WHEN qp.Period = 'A' THEN qp.Execs END) AS AExecs,
                            SUM(CASE WHEN qp.Period = 'B' THEN qp.CpuUs END) AS BCpu, SUM(CASE WHEN qp.Period = 'A' THEN qp.CpuUs END) AS ACpu,
                            SUM(CASE WHEN qp.Period = 'B' THEN qp.Reads END) AS BReads, SUM(CASE WHEN qp.Period = 'A' THEN qp.Reads END) AS AReads
                     FROM #qp AS qp
                     WHERE qp.query_hash IN (SELECT b.query_hash FROM #both AS b)
                       AND qp.query_hash IN (SELECT pm.query_hash FROM #pm AS pm INNER JOIN #planidx AS px ON px.plan_id = pm.plan_id
                                             WHERE px.RecommendationId = r.RecommendationId)) AS f;

    UPDATE #Recs
    SET Note = CASE
        WHEN IndexName IS NULL THEN N'Not an index change: see the Workload result set.'
        WHEN Category = 'DropIndex' AND IndexExists = 1 THEN N'The dropped index exists again.'
        WHEN Category = 'DropIndex' AND AffectedCpuMsPerExecAfter > 1.2 * AffectedCpuMsPerExecBefore
            THEN N'The queries that used it cost more CPU per execution since it was dropped: see the Queries result set.'
        WHEN Category = 'DropIndex' THEN NULL
        WHEN IndexExists = 0 THEN N'The index no longer exists.'
        WHEN UserSeeks + UserScans + UserLookups = 0 AND UserUpdates > 0
            THEN N'Written to but not read since it was created (or the instance started): no query uses it yet.'
        WHEN UserSeeks + UserScans + UserLookups = 0 THEN N'Not used since it was created (or the instance started).'
        WHEN AffectedCpuMsPerExecAfter > 1.2 * AffectedCpuMsPerExecBefore
            THEN N'The queries that use it cost more CPU per execution than before: see the Queries result set.'
        END;

    /* ===== Results ===== */
    IF @ResultSet IS NULL OR @ResultSet = 'SUMMARY'
        SELECT @RunId AS RunId, @SourceName AS Source, @AppliedCount AS AppliedRecommendations,
               @First AS FirstAppliedAt, @Last AS LastAppliedAt,
               @BeforeFrom AS BeforeFrom, @BeforeTo AS BeforeTo, CAST(@BeforeDays AS decimal(10, 4)) AS BeforeDays,
               @AfterFrom AS AfterFrom, @AfterTo AS AfterTo, CAST(@AfterDays AS decimal(10, 4)) AS AfterDays,
               @QueriesBoth AS QueriesInBothPeriods, @QueriesBeforeOnly AS QueriesOnlyBefore, @QueriesAfterOnly AS QueriesOnlyAfter,
               @PairsBefore AS SnapshotPairsBefore, @PairsAfter AS SnapshotPairsAfter,
               @QsStateDesc AS QueryStoreState, @QsCapture AS QueryStoreCaptureMode, @QsIntervalMin AS QueryStoreIntervalMinutes,
               @QsStale AS QueryStoreStaleDays, @QsUsedMB AS QueryStoreUsedMB, @QsMaxMB AS QueryStoreMaxMB,
               (SELECT STRING_AGG(CONVERT(nvarchar(max), Warning), N' | ') WITHIN GROUP (ORDER BY Seq) FROM #Warnings) AS Warnings;

    IF @ResultSet IS NULL OR @ResultSet = 'WORKLOAD'
        SELECT @SourceName AS Source, w.Scope, w.Metric,
               CAST(w.BeforeTotal AS decimal(38, 1)) AS BeforeTotal, CAST(w.AfterTotal AS decimal(38, 1)) AS AfterTotal,
               CAST(w.BeforePerDay AS decimal(38, 1)) AS BeforePerDay, CAST(w.AfterPerDay AS decimal(38, 1)) AS AfterPerDay,
               CAST((w.AfterPerDay - w.BeforePerDay) * 100.0 / NULLIF(w.BeforePerDay, 0) AS decimal(19, 1)) AS PerDayChangePct,
               CAST(w.BeforePerExec AS decimal(38, 3)) AS BeforePerExec, CAST(w.AfterPerExec AS decimal(38, 3)) AS AfterPerExec,
               CAST((w.AfterPerExec - w.BeforePerExec) * 100.0 / NULLIF(w.BeforePerExec, 0) AS decimal(19, 1)) AS PerExecChangePct
        FROM (SELECT Scope, Seq, Metric,
                     SUM(CASE WHEN Period = 'B' THEN Value END) AS BeforeTotal,
                     SUM(CASE WHEN Period = 'A' THEN Value END) AS AfterTotal,
                     SUM(CASE WHEN Period = 'B' THEN Value / NULLIF(Days, 0) END) AS BeforePerDay,
                     SUM(CASE WHEN Period = 'A' THEN Value / NULLIF(Days, 0) END) AS AfterPerDay,
                     SUM(CASE WHEN Period = 'B' AND PerExec = 1 THEN Value / NULLIF(Execs, 0) END) AS BeforePerExec,
                     SUM(CASE WHEN Period = 'A' AND PerExec = 1 THEN Value / NULLIF(Execs, 0) END) AS AfterPerExec
              FROM #mv GROUP BY Scope, Seq, Metric) AS w
        ORDER BY CASE WHEN w.Scope = N'Queries in both periods' THEN 1 ELSE 0 END, w.Seq;

    IF @ResultSet IS NULL OR @ResultSet = 'QUERIES'
        SELECT Direction, [Rank], QueryHash, SampleQueryId, ObjectName, QueryText, ExecsPerDayBefore, ExecsPerDayAfter,
               CpuMsPerExecBefore, CpuMsPerExecAfter, DurationMsPerExecBefore, DurationMsPerExecAfter,
               ReadsPerExecBefore, ReadsPerExecAfter, WritesPerExecBefore, WritesPerExecAfter,
               CpuMsPerDayChange, DurationMsPerDayChange, ReadsPerDayChange, PlanChanged, RunIndexesInPlans
        FROM #Queries
        ORDER BY CASE Direction WHEN 'Improved' THEN 0 ELSE 1 END, [Rank];

    IF @ResultSet IS NULL OR @ResultSet = 'RECOMMENDATIONS'
        SELECT RecommendationId, Priority, Category, SchemaName, TableName, IndexName, AppliedAt, IndexExists,
               UserSeeks, UserScans, UserLookups, UserUpdates, LeafWrites, LeafPageAllocations, UsageSince,
               QueriesUsingBefore, QueriesUsingAfter, ExecsPerDayUsingBefore, ExecsPerDayUsingAfter,
               AffectedQueries, AffectedCpuMsPerExecBefore, AffectedCpuMsPerExecAfter, AffectedReadsPerExecBefore, AffectedReadsPerExecAfter,
               Note
        FROM #Recs
        ORDER BY Priority, RecommendationId;
END;
GO
