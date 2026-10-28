SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    AIIndexTuner.usp_UsageSince

    The period the usage DMVs cover for the current database (GetUsageStatisticsSinceAsync in the
    desktop collector). Usage DMVs and the plan cache start empty when SQL Server starts, and for one
    database when it is restored, attached, reverted from a snapshot, brought ONLINE or reopened
    under AUTO_CLOSE. @Since is the latest of those times that can be read; @SinceSource names it.

    Used by usp_CollectData for the "Database Usage Statistics Since" line, and by
    usp_ApplyRecommendation, which drops an index for low use only after a long enough period.
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_UsageSince
    @Since              datetime2(0)  = NULL OUTPUT,
    @SinceSource        nvarchar(400) = NULL OUTPUT,
    @StartTime          datetime2(0)  = NULL OUTPUT,
    @AutoClose          bit           = NULL OUTPUT,
    @RestoreHistoryRead bit           = NULL OUTPUT,
    @LastStartup        datetime2(0)  = NULL OUTPUT,
    @ErrorLogsSearched  int           = NULL OUTPUT,
    @HasInstanceLogs    bit           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CreateDate datetime2(0), @LastRestore datetime2(0);
    SELECT @Since = NULL, @SinceSource = NULL, @StartTime = NULL, @RestoreHistoryRead = 0, @LastStartup = NULL, @ErrorLogsSearched = 0,
           -- Azure SQL Database, Synapse and Fabric have no msdb restore history or error log to read.
           @HasInstanceLogs = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) IN (5, 6, 11, 12) THEN 0 ELSE 1 END;

    BEGIN TRY
        SELECT @StartTime = sqlserver_start_time FROM sys.dm_os_sys_info;
    END TRY
    BEGIN CATCH
        SET @StartTime = NULL;
    END CATCH;

    SELECT @CreateDate = create_date, @AutoClose = is_auto_close_on FROM sys.databases WHERE database_id = DB_ID();

    IF @HasInstanceLogs = 1
    BEGIN
        BEGIN TRY
            SELECT @LastRestore = MAX(restore_date) FROM msdb.dbo.restorehistory WHERE destination_database_name = DB_NAME();
            SET @RestoreHistoryRead = 1;
        END TRY
        BEGIN CATCH
            SET @LastRestore = NULL;
        END CATCH;

        -- Newest error log first, stopping at the first log with a startup message for this database.
        -- Reading the error log needs securityadmin (or sysadmin). The closing quote in the search keeps
        -- 'Sales' from matching 'Sales2'.
        IF ISNULL(IS_SRVROLEMEMBER(N'securityadmin'), 0) = 1 OR ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) = 1
        BEGIN
            DECLARE @Log int = 0, @Search nvarchar(4000) = CONCAT(N'Starting up database ''', DB_NAME(), N'''.');
            CREATE TABLE #ErrorLog (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));
            WHILE @Log < 7 AND @LastStartup IS NULL
            BEGIN
                BEGIN TRY
                    TRUNCATE TABLE #ErrorLog;
                    INSERT #ErrorLog (LogDate, ProcessInfo, [Text]) EXEC sys.sp_readerrorlog @p1 = @Log, @p2 = 1, @p3 = @Search;
                    SELECT @LastStartup = MAX(LogDate) FROM #ErrorLog;
                    SET @ErrorLogsSearched += 1;
                END TRY
                BEGIN CATCH
                    BREAK;   -- past the oldest archive the log does not exist; any other error also ends the search
                END CATCH;
                SET @Log += 1;
            END;
            DROP TABLE #ErrorLog;
        END;
    END;

    -- Later candidates win ties, so the error log, which names every kind of reset, is preferred.
    IF @StartTime IS NOT NULL SELECT @Since = @StartTime, @SinceSource = N'the SQL Server start time, the latest reset found';
    IF @CreateDate IS NOT NULL AND (@Since IS NULL OR @CreateDate >= @Since)
        SELECT @Since = @CreateDate, @SinceSource = N'its create date in sys.databases, which an attach or a restore under a new name sets';
    IF @LastRestore IS NOT NULL AND (@Since IS NULL OR @LastRestore >= @Since)
        SELECT @Since = @LastRestore, @SinceSource = N'its latest restore in msdb.dbo.restorehistory';
    IF @LastStartup IS NOT NULL AND (@Since IS NULL OR @LastStartup >= @Since)
        SELECT @Since = @LastStartup, @SinceSource = N'its latest "Starting up database" message in the SQL Server error log, which is written whenever it starts: at a server restart, a restore, an attach, a database snapshot revert, an ONLINE after OFFLINE, or an AUTO_CLOSE reopen';
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    AIIndexTuner.usp_CollectData

    Collects the Index Tuning diagnostics for the current database into one text payload for the
    model. Ported from AI SQL Tuner's IndexTuning collectors (SqlCollector.GatherIndexTuningDataAsync).
    Section names match the originals, because the prompt refers to some of them by name.

    Each section runs in its own TRY...CATCH: a section that fails adds a warning line and the run
    goes on, as the C# collector does. Rows are written as JSON arrays.

    Differences from the desktop collector:
      - No per-section command timeouts (T-SQL has none). Work is bounded by row caps instead,
        including the 20,000-plan cap on Query Store scope resolution.
      - Only the SQL Server 2017+ Query Store query (with wait stats), since only SQL Server 2025
        and Azure SQL are supported.
      - The plan cache and the missing-index candidate lists are limited to this database
        (AI-SQL-Tuner/aisqltuner#232).
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_CollectData
    @SchemaName       sysname = NULL,
    @TableName        sysname = NULL,
    @IncludeQueryText bit = 1,
    @Data             nvarchar(max) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @nl nchar(1) = NCHAR(10),
            @j  nvarchar(max),
            @ServerFillFactor int = 100,
            @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int),
            @MajorVersion int,
            @EngineEditionName nvarchar(100),
            @RestartCleared nvarchar(200) = N'Index usage statistics, missing index statistics, index operational statistics and the plan cache';

    SET @Data = N'';

    /* ===== Server information ===== */
    SELECT @MajorVersion = MAX(compatibility_level) / 10 FROM sys.databases;

    SET @EngineEditionName = CASE @EngineEdition
        WHEN 2 THEN N'Standard'
        WHEN 3 THEN N'Enterprise'
        WHEN 4 THEN N'Express'
        WHEN 5 THEN N'Azure SQL Database'
        WHEN 8 THEN N'Azure SQL Managed Instance'
        WHEN 12 THEN N'Microsoft Fabric SQL Database'
        ELSE CONCAT(N'Unknown (', @EngineEdition, N')')
    END;

    SET @Data += CONCAT(
        N'Server Name: ', @@SERVERNAME, @nl,
        N'Database Name: ', DB_NAME(), @nl,
        N'SQL Server Edition: ', CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), @nl,
        N'Engine Edition: ', @EngineEditionName, @nl,
        N'Product Level: ', CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)), @nl,
        N'Major Version: ', CASE WHEN @MajorVersion >= 17 THEN N'SQL Server 2025' WHEN @MajorVersion = 16 THEN N'SQL Server 2022' ELSE CONCAT(N'Version ', @MajorVersion) END, @nl,
        N'Full Version: ', @@VERSION, @nl);

    /* Start time and the period the usage DMVs cover (GetUsageStatisticsSinceAsync); see usp_UsageSince. */
    DECLARE @StartTime datetime2(0), @Now datetime2(0) = SYSDATETIME(), @AutoClose bit, @RestoreHistoryRead bit,
            @LastStartup datetime2(0), @ErrorLogsSearched int, @Since datetime2(0), @SinceSource nvarchar(400), @HasInstanceLogs bit;

    EXEC AIIndexTuner.usp_UsageSince
        @Since = @Since OUTPUT, @SinceSource = @SinceSource OUTPUT, @StartTime = @StartTime OUTPUT, @AutoClose = @AutoClose OUTPUT,
        @RestoreHistoryRead = @RestoreHistoryRead OUTPUT, @LastStartup = @LastStartup OUTPUT,
        @ErrorLogsSearched = @ErrorLogsSearched OUTPUT, @HasInstanceLogs = @HasInstanceLogs OUTPUT;

    SET @Data += CASE WHEN @StartTime IS NOT NULL
        THEN CONCAT(N'SQL Server Start Time: ', CONVERT(varchar(19), @StartTime, 120), N' (server local time); uptime ',
                    AIIndexTuner.fn_FormatUptime(DATEDIFF(MINUTE, @StartTime, @Now)), N'. ',
                    @RestartCleared, N' cover only this period, because SQL Server clears them when it restarts.', @nl)
        ELSE CONCAT(N'SQL Server Start Time: unknown (reading it needs VIEW SERVER STATE), so how long ', LOWER(@RestartCleared), N' have been accumulating is unknown.', @nl)
    END;

    DECLARE @SinceLine nvarchar(max) = N'Database Usage Statistics Since: ' + CASE WHEN @Since IS NOT NULL
        THEN CONCAT(CONVERT(varchar(19), @Since, 120), N' (server local time), ', AIIndexTuner.fn_FormatUptime(DATEDIFF(MINUTE, @Since, @Now)),
                    N' ago, from ', @SinceSource, N'. ', @RestartCleared, N' for this database cover only this period.')
        ELSE N'unknown.' END;

    IF @HasInstanceLogs = 0
        SET @SinceLine += N' The error log and restore history cannot be read on this platform, and a failover or reconfiguration can clear these statistics without changing the times above, so they may cover less than this.';
    ELSE IF @ErrorLogsSearched = 0
    BEGIN
        DECLARE @Missed nvarchar(400) = CONCAT(
            CASE WHEN @StartTime IS NULL THEN N'a server restart, ' ELSE N'' END,
            CASE WHEN @RestoreHistoryRead = 0 THEN N'a restore over the existing database, ' ELSE N'' END,
            N'an ONLINE after OFFLINE, an AUTO_CLOSE reopen or a database snapshot revert');
        SET @SinceLine += CONCAT(N' The error log could not be read (that needs membership in securityadmin or sysadmin), so ', @Missed,
                                 N' since then would not show here, and the statistics may cover less than this.');
    END;
    ELSE IF @LastStartup IS NULL
        SET @SinceLine += CONCAT(N' The ', @ErrorLogsSearched, N' most recent error logs have no "Starting up database" message for it, so it last started before the oldest of them begins, possibly after the time above, and the statistics may cover less than this.');

    IF @AutoClose = 1
        SET @SinceLine += N' AUTO_CLOSE is ON for this database, so these statistics are also cleared whenever its last connection closes.';

    SET @Data += @SinceLine + @nl;

    SET @Data += CONCAT(@nl, N'=== PLATFORM CAPABILITIES ===', @nl,
        CASE @EngineEdition
            WHEN 5 THEN N'- Cloud-based SQL Server (Azure)' + @nl + N'- Automatic tuning and performance insights available' + @nl + N'- Query Store enabled by default' + @nl + N'- Automatic index management available' + @nl
            WHEN 8 THEN N'- Cloud-based SQL Server (Azure)' + @nl + N'- Query Store enabled by default' + @nl
            WHEN 3 THEN N'- Enterprise Edition (full feature set)' + @nl + N'- Columnstore indexes available' + @nl + N'- Online index operations available' + @nl + N'- Advanced compression available' + @nl + N'- Partition switching available' + @nl
            WHEN 2 THEN N'- Standard Edition (mid-tier features)' + @nl + N'- Basic compression available' + @nl + N'- Limited to 128 GB buffer pool memory' + @nl
            WHEN 4 THEN N'- Express Edition limitations: 10 GB maximum database size, 1 socket or 4 cores, 1 GB buffer pool' + @nl
            ELSE N''
        END,
        CASE WHEN @MajorVersion >= 17
            THEN N'- SQL Server 2025+ features available:' + @nl
               + N'  * SQL Server 2025 platform capabilities detected' + @nl
               + N'  * Advanced Intelligent Query Processing enhancements may be available' + @nl
               + N'  * CE feedback (needs compatibility level 160 or higher and Query Store in READ_WRITE) and CE feedback for expressions (CE_FEEDBACK_FOR_EXPRESSIONS)' + @nl
               + N'  * DOP feedback (DOP_FEEDBACK, ON by default; needs compatibility level 160 or higher and Query Store in READ_WRITE)' + @nl
               + N'  * Optional parameter plan optimization (OPTIONAL_PARAMETER_OPTIMIZATION, ON by default; needs compatibility level 170; not on Azure SQL Managed Instance)' + @nl
            ELSE N'' END);

    IF @SchemaName IS NOT NULL AND @TableName IS NOT NULL
        SET @Data += CONCAT(N'Object-scoped analysis is limited to table: ', QUOTENAME(@SchemaName), N'.', QUOTENAME(@TableName), N'. Query Store sections are filtered to queries that reference that table; the Query Store section below states how that scope was resolved. Other database-level sections remain database-scoped.', @nl);
    ELSE IF @SchemaName IS NOT NULL
        SET @Data += CONCAT(N'Object-scoped analysis is limited to schema: ', QUOTENAME(@SchemaName), N'. Query Store sections are filtered to queries that reference that schema; the Query Store section below states how that scope was resolved. Other database-level sections remain database-scoped.', @nl);

    /* sys.indexes.fill_factor is 0 for an index created without FILLFACTOR, meaning the server's
       'fill factor (%)' applies. Printed as 0, models copy it into WITH (FILLFACTOR = 0), which
       SQL Server rejects, so the payload shows the value that actually applies. */
    BEGIN TRY
        SELECT @ServerFillFactor = CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'fill factor (%)';
        IF @ServerFillFactor NOT BETWEEN 1 AND 100 SET @ServerFillFactor = 100;
    END TRY
    BEGIN CATCH
        SET @ServerFillFactor = 100;
    END CATCH;

    /* Included columns of the top 50 missing-index candidates, with their types, for the next two
       sections. A missing-index suggestion names its INCLUDE columns but not their types, so a
       copied suggestion can put an nvarchar(max) column into an index. For (max), xml, text and
       other columns of 256 bytes or more, an average width is also sampled from up to 1,000 rows. */
    CREATE TABLE #IncludeCols (index_handle int, object_id int, column_id int, column_name sysname, type_name nvarchar(200), is_wide bit, avg_bytes bigint NULL);
    CREATE TABLE #IncludeTypes (index_handle int PRIMARY KEY, Types nvarchar(max));
    BEGIN TRY
        INSERT #IncludeCols (index_handle, object_id, column_id, column_name, type_name, is_wide)
        SELECT mi.index_handle, mi.object_id, c.column_id, c.name, AIIndexTuner.fn_ColumnType(c.object_id, c.column_id),
               CASE WHEN c.max_length = -1 OR c.max_length >= 256 OR c.system_type_id IN (34, 35, 99, 241) THEN 1 ELSE 0 END
        FROM (SELECT TOP (50) d.index_handle, d.object_id
              FROM sys.dm_db_missing_index_details AS d
              INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
              INNER JOIN sys.dm_db_missing_index_group_stats AS st ON g.index_group_handle = st.group_handle
              INNER JOIN sys.objects AS o ON d.object_id = o.object_id
              INNER JOIN sys.schemas AS s ON o.schema_id = s.schema_id
              WHERE d.database_id = DB_ID()
                AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
                AND (@TableName IS NULL OR o.name = @TableName)
              ORDER BY st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) DESC) AS mi
        CROSS APPLY sys.dm_db_missing_index_columns(mi.index_handle) AS mc
        INNER JOIN sys.columns AS c ON c.object_id = mi.object_id AND c.column_id = mc.column_id
        WHERE mc.column_usage = 'INCLUDE';

        DECLARE @WideObject int, @WideColumn int, @WideSql nvarchar(max), @WideAvg bigint;
        DECLARE wide_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT object_id, column_id FROM #IncludeCols WHERE is_wide = 1;
        OPEN wide_cur;
        FETCH NEXT FROM wide_cur INTO @WideObject, @WideColumn;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                -- NOLOCK: an estimate, which should not wait on or block the workload.
                -- The marker comment keeps this statement out of the plan cache and Query Store sections:
                -- dynamic SQL has no object_id there, and Query Store drops a comment that comes before
                -- the statement, but keeps one inside it.
                SET @WideSql = N'SELECT /* AIIndexTuner collector */ @Avg = AVG(CAST(DATALENGTH(v) AS bigint)) FROM (SELECT TOP (1000) ' + QUOTENAME(COL_NAME(@WideObject, @WideColumn))
                             + N' AS v FROM ' + QUOTENAME(OBJECT_SCHEMA_NAME(@WideObject)) + N'.' + QUOTENAME(OBJECT_NAME(@WideObject)) + N' WITH (NOLOCK)'
                             + N' WHERE ' + QUOTENAME(COL_NAME(@WideObject, @WideColumn)) + N' IS NOT NULL) AS x;';
                SET @WideAvg = NULL;
                EXEC sys.sp_executesql @WideSql, N'@Avg bigint OUTPUT', @Avg = @WideAvg OUTPUT;
                UPDATE #IncludeCols SET avg_bytes = @WideAvg WHERE object_id = @WideObject AND column_id = @WideColumn;
            END TRY
            BEGIN CATCH
                -- Leave the width unknown; the type is still reported.
            END CATCH;
            FETCH NEXT FROM wide_cur INTO @WideObject, @WideColumn;
        END;
        CLOSE wide_cur;
        DEALLOCATE wide_cur;

        INSERT #IncludeTypes (index_handle, Types)
        SELECT index_handle,
               STRING_AGG(CAST(CONCAT(column_name, N' ', type_name, CASE WHEN avg_bytes IS NOT NULL THEN CONCAT(N' (avg ', avg_bytes, N' bytes)') END) AS nvarchar(max)), N', ')
                   WITHIN GROUP (ORDER BY column_id)
        FROM #IncludeCols
        GROUP BY index_handle;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'wide_cur') >= -1 BEGIN CLOSE wide_cur; DEALLOCATE wide_cur; END;
        -- The two sections below still run, without IncludedColumnTypes.
    END CATCH;

    /* ===== MISSING INDEX RECOMMENDATIONS ===== */
    BEGIN TRY
        SET @j = (
            SELECT TOP (50)
                s.name + N'.' + o.name AS TableName,
                CASE WHEN LEN(d.equality_columns) > 200 THEN LEFT(d.equality_columns, 200) + N'...' ELSE d.equality_columns END AS EqualityColumns,
                CASE WHEN LEN(d.inequality_columns) > 200 THEN LEFT(d.inequality_columns, 200) + N'...' ELSE d.inequality_columns END AS InequalityColumns,
                CASE WHEN LEN(d.included_columns) > 200 THEN LEFT(d.included_columns, 200) + N'...' ELSE d.included_columns END AS IncludedColumns,
                it.Types AS IncludedColumnTypes,
                CAST(st.avg_total_user_cost AS decimal(18, 2)) AS AvgTotalUserCost,
                CAST(st.avg_user_impact AS decimal(5, 2)) AS AvgUserImpactPct,
                st.user_seeks + st.user_scans AS TotalSeeksScans,
                CAST(st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) AS decimal(38, 0)) AS ImpactScore
            FROM sys.dm_db_missing_index_details AS d
            INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
            INNER JOIN sys.dm_db_missing_index_group_stats AS st ON g.index_group_handle = st.group_handle
            INNER JOIN sys.objects AS o ON d.object_id = o.object_id
            INNER JOIN sys.schemas AS s ON o.schema_id = s.schema_id
            LEFT JOIN #IncludeTypes AS it ON it.index_handle = d.index_handle
            WHERE d.database_id = DB_ID()
              AND st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) > 100000
              AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
              AND (@TableName IS NULL OR o.name = @TableName)
            ORDER BY st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== MISSING INDEX RECOMMENDATIONS ===', @nl, ISNULL(@j, N'(none above the impact score threshold of 100,000)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== MISSING INDEX RECOMMENDATIONS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== INDEX USAGE STATISTICS =====
       Half the rows are reserved for drop candidates (unread nonclustered indexes that enforce no
       constraint) and half for indexes that are read; a group with fewer rows leaves its share to
       the other. Within each group: writes per read, then the costliest to maintain. */
    BEGIN TRY
        WITH usage AS (
            SELECT
                sch.name + N'.' + obj.name AS TableName,
                i.name AS IndexName,
                i.type_desc AS IndexType,
                (SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ic2.key_ordinal)
                 FROM sys.index_columns AS ic2
                 INNER JOIN sys.columns AS c ON ic2.object_id = c.object_id AND ic2.column_id = c.column_id
                 WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0) AS KeyColumns,
                (SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ic3.column_id)
                 FROM sys.index_columns AS ic3
                 INNER JOIN sys.columns AS c ON ic3.object_id = c.object_id AND ic3.column_id = c.column_id
                 WHERE ic3.object_id = i.object_id AND ic3.index_id = i.index_id AND ic3.is_included_column = 1) AS IncludedColumns,
                ISNULL(us.user_seeks, 0) AS UserSeeks,
                ISNULL(us.user_scans, 0) AS UserScans,
                ISNULL(us.user_lookups, 0) AS UserLookups,
                ISNULL(us.user_updates, 0) AS UserUpdates,
                ROUND(ISNULL(ps.page_count, 0) * 8 / 1024.0, 1) AS SizeMB,
                p.data_compression_desc AS Compression,
                CASE WHEN i.fill_factor = 0 THEN CONCAT(@ServerFillFactor, ' (default)') ELSE CAST(i.fill_factor AS varchar(3)) END AS [FillFactor],
                i.is_disabled AS IsDisabled,
                i.is_primary_key AS IsPrimaryKey,
                i.is_unique_constraint AS IsUniqueConstraint,
                i.is_unique AS IsUnique,
                ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) AS total_reads,
                ISNULL(ps.page_count, 0) AS page_count,
                CASE WHEN i.type IN (2, 6) AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
                      AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
                     THEN 1 ELSE 0 END AS is_drop_candidate
            FROM sys.indexes AS i
            INNER JOIN sys.objects AS obj ON i.object_id = obj.object_id
            INNER JOIN sys.schemas AS sch ON obj.schema_id = sch.schema_id
            LEFT JOIN sys.dm_db_index_usage_stats AS us ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
            LEFT JOIN (SELECT object_id, index_id, SUM(in_row_data_page_count + lob_used_page_count + row_overflow_used_page_count) AS page_count
                       FROM sys.dm_db_partition_stats GROUP BY object_id, index_id) AS ps
                   ON ps.object_id = i.object_id AND ps.index_id = i.index_id
            LEFT JOIN (SELECT object_id, index_id, MAX(data_compression_desc) AS data_compression_desc
                       FROM sys.partitions GROUP BY object_id, index_id) AS p
                   ON p.object_id = i.object_id AND p.index_id = i.index_id
            WHERE obj.type = 'U'
              AND sch.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR sch.name = @SchemaName)
              AND (@TableName IS NULL OR obj.name = @TableName)
        ),
        ranked AS (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY is_drop_candidate
                                      ORDER BY CAST(UserUpdates AS float) / NULLIF(total_reads, 0) DESC,
                                               UserUpdates DESC, total_reads ASC, page_count DESC) AS group_rank
            FROM usage
        )
        SELECT @j = (
            SELECT TOP (50)
                TableName, IndexName, IndexType, KeyColumns, IncludedColumns,
                UserSeeks, UserScans, UserLookups, UserUpdates, SizeMB, Compression, [FillFactor],
                IsDisabled, IsPrimaryKey, IsUniqueConstraint, IsUnique
            FROM ranked
            ORDER BY CASE WHEN group_rank <= 25 THEN 0 ELSE 1 END, is_drop_candidate DESC, group_rank
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== INDEX USAGE STATISTICS ===', @nl, ISNULL(@j, N'(no indexes)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== INDEX USAGE STATISTICS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== MISSING INDEX OVERLAP SIGNALS =====
       For the top missing-index candidates, the best-matching existing index and a redundancy score,
       with row counts, estimated storage and write penalty. */
    BEGIN TRY
        WITH missing_indexes AS (
            SELECT TOP (15)
                d.object_id,
                d.index_handle,
                s.name + N'.' + o.name AS table_name,
                COALESCE(d.equality_columns, N'') AS equality_columns,
                COALESCE(d.inequality_columns, N'') AS inequality_columns,
                COALESCE(d.included_columns, N'') AS included_columns,
                st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) AS impact_score
            FROM sys.dm_db_missing_index_details AS d
            INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
            INNER JOIN sys.dm_db_missing_index_group_stats AS st ON g.index_group_handle = st.group_handle
            INNER JOIN sys.objects AS o ON d.object_id = o.object_id
            INNER JOIN sys.schemas AS s ON o.schema_id = s.schema_id
            WHERE d.database_id = DB_ID()
              AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
              AND (@TableName IS NULL OR o.name = @TableName)
            ORDER BY impact_score DESC
        ),
        missing_normalized AS (
            SELECT mi.*,
                   REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(CONCAT(
                        mi.equality_columns,
                        CASE WHEN mi.equality_columns <> N'' AND mi.inequality_columns <> N'' THEN N',' ELSE N'' END,
                        mi.inequality_columns))), N'[', N''), N']', N''), N' ', N'') AS requested_key_columns,
                   REPLACE(REPLACE(REPLACE(mi.included_columns, N'[', N''), N']', N''), N' ', N'') AS requested_include_columns
            FROM missing_indexes AS mi
        ),
        table_sizes AS (
            SELECT object_id, SUM(row_count) AS row_count FROM sys.dm_db_partition_stats WHERE index_id IN (0, 1) GROUP BY object_id
        ),
        existing_normalized AS (
            SELECT i.object_id,
                   i.name AS existing_index_name,
                   k.cols AS existing_key_columns,
                   inc.cols AS existing_include_columns,
                   REPLACE(COALESCE(k.cols, N''), N' ', N'') AS existing_key_norm,
                   ISNULL(ius.user_updates, 0) AS user_updates
            FROM sys.indexes AS i
            LEFT JOIN sys.dm_db_index_usage_stats AS ius ON i.object_id = ius.object_id AND i.index_id = ius.index_id AND ius.database_id = DB_ID()
            CROSS APPLY (SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS cols
                         FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                         WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0) AS k
            CROSS APPLY (SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ic.column_id) AS cols
                         FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                         WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1) AS inc
            WHERE i.index_id > 0 AND i.is_hypothetical = 0
        )
        SELECT @j = (
            SELECT
                mn.table_name AS TableName,
                mn.equality_columns AS EqualityColumns,
                mn.inequality_columns AS InequalityColumns,
                mn.included_columns AS IncludedColumns,
                it.Types AS IncludedColumnTypes,
                mn.requested_key_columns AS RequestedKeyColumns,
                best.existing_index_name AS BestMatchingExistingIndex,
                best.existing_key_columns AS ExistingKeyColumns,
                best.existing_include_columns AS ExistingIncludeColumns,
                best.redundancy_score AS RedundancyScore,
                COALESCE(ts.row_count, 0) AS TableRows,
                CAST(COALESCE(ts.row_count, 0) *
                     ((CASE WHEN NULLIF(mn.requested_key_columns, N'') IS NULL THEN 0 ELSE LEN(mn.requested_key_columns) - LEN(REPLACE(mn.requested_key_columns, N',', N'')) + 1 END) * 16
                    + (CASE WHEN NULLIF(mn.requested_include_columns, N'') IS NULL THEN 0 ELSE LEN(mn.requested_include_columns) - LEN(REPLACE(mn.requested_include_columns, N',', N'')) + 1 END) * 8)
                     / 1048576.0 AS decimal(18, 2)) AS EstimatedStorageMB,
                CAST(COALESCE(best.user_updates, 0) *
                     ((CASE WHEN NULLIF(mn.requested_key_columns, N'') IS NULL THEN 0 ELSE LEN(mn.requested_key_columns) - LEN(REPLACE(mn.requested_key_columns, N',', N'')) + 1 END)
                    + (CASE WHEN NULLIF(mn.requested_include_columns, N'') IS NULL THEN 0 ELSE LEN(mn.requested_include_columns) - LEN(REPLACE(mn.requested_include_columns, N',', N'')) + 1 END)) AS bigint) AS EstimatedWritePenalty
            FROM missing_normalized AS mn
            LEFT JOIN table_sizes AS ts ON mn.object_id = ts.object_id
            LEFT JOIN #IncludeTypes AS it ON it.index_handle = mn.index_handle
            OUTER APPLY (
                SELECT TOP (1) en.existing_index_name, en.existing_key_columns, en.existing_include_columns, en.user_updates,
                       CASE
                           WHEN en.existing_key_norm = mn.requested_key_columns THEN 100
                           WHEN LEFT(en.existing_key_norm, LEN(mn.requested_key_columns) + 1) = mn.requested_key_columns + N',' THEN 90
                           WHEN LEFT(mn.requested_key_columns, LEN(en.existing_key_norm) + 1) = en.existing_key_norm + N',' THEN 75
                           WHEN LEFT(en.existing_key_norm, CHARINDEX(N',', en.existing_key_norm + N',') - 1)
                              = LEFT(mn.requested_key_columns, CHARINDEX(N',', mn.requested_key_columns + N',') - 1) THEN 50
                           ELSE 0
                       END AS redundancy_score
                FROM existing_normalized AS en
                WHERE en.object_id = mn.object_id AND mn.requested_key_columns <> N''
                ORDER BY redundancy_score DESC, LEN(en.existing_key_norm) DESC
            ) AS best
            ORDER BY COALESCE(best.redundancy_score, 0) DESC, mn.impact_score DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== MISSING INDEX OVERLAP SIGNALS ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== MISSING INDEX OVERLAP SIGNALS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== DUPLICATE AND OVERLAPPING INDEXES =====
       Exact key duplicates and strict left-prefix overlaps within a table, compared as exact strings. */
    BEGIN TRY
        WITH IndexKeys AS (
            SELECT i.object_id, i.index_id, i.name AS index_name, i.is_unique, i.has_filter,
                   ISNULL(i.filter_definition, N'') AS filter_definition,
                   (SELECT STRING_AGG(CAST(c.name AS nvarchar(max)) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END, N', ') WITHIN GROUP (ORDER BY ic.key_ordinal)
                    FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0) AS key_columns,
                   ISNULL((SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY c.name)
                           FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1), N'') AS included_columns
            FROM sys.indexes AS i
            INNER JOIN sys.objects AS o ON o.object_id = i.object_id
            INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            WHERE o.type = 'U' AND i.index_id > 0 AND i.is_hypothetical = 0 AND i.is_disabled = 0 AND i.type IN (1, 2)
              AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
              AND (@TableName IS NULL OR o.name = @TableName)
        ),
        sizes AS (
            SELECT object_id, index_id, CAST(SUM(used_page_count) * 8.0 / 1024 AS decimal(14, 1)) AS size_mb
            FROM sys.dm_db_partition_stats GROUP BY object_id, index_id
        )
        SELECT @j = (
            SELECT TOP (30)
                SCHEMA_NAME(o.schema_id) + N'.' + o.name AS TableName,
                a.index_name AS WiderIndex, a.key_columns AS WiderKeys, a.included_columns AS WiderIncludes,
                b.index_name AS NarrowerIndex, b.key_columns AS NarrowerKeys, b.included_columns AS NarrowerIncludes,
                CASE WHEN a.key_columns = b.key_columns THEN 'EXACT KEY DUPLICATE' ELSE 'LEFT-PREFIX OVERLAP' END AS OverlapType,
                b.is_unique AS NarrowerIsUnique,
                CASE WHEN a.filter_definition <> b.filter_definition THEN 'DIFFERENT FILTERS' WHEN a.has_filter = 1 THEN 'BOTH FILTERED' ELSE '' END AS FilterNote,
                ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) AS NarrowerReads,
                ISNULL(us.user_updates, 0) AS NarrowerWrites,
                ISNULL(ps.size_mb, 0) AS NarrowerSizeMB,
                ISNULL(psw.size_mb, 0) AS WiderSizeMB
            FROM IndexKeys AS a
            INNER JOIN IndexKeys AS b
                ON a.object_id = b.object_id AND a.index_id <> b.index_id
               AND ((a.key_columns = b.key_columns AND a.index_id < b.index_id)
                    OR LEFT(a.key_columns, LEN(b.key_columns) + 1) = b.key_columns + N',')
            INNER JOIN sys.objects AS o ON o.object_id = a.object_id
            LEFT JOIN sys.dm_db_index_usage_stats AS us ON us.database_id = DB_ID() AND us.object_id = b.object_id AND us.index_id = b.index_id
            LEFT JOIN sizes AS ps ON ps.object_id = b.object_id AND ps.index_id = b.index_id
            LEFT JOIN sizes AS psw ON psw.object_id = a.object_id AND psw.index_id = a.index_id
            ORDER BY NarrowerSizeMB DESC, TableName
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== DUPLICATE AND OVERLAPPING INDEXES ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== DUPLICATE AND OVERLAPPING INDEXES ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== PLAN CACHE QUERY STATISTICS ===== database-wide, top 25 by CPU */
    BEGIN TRY
        SET @j = (
            SELECT TOP (25)
                CONVERT(varchar(18), qs.query_hash, 1) AS QueryHash,
                CONVERT(varchar(18), qs.query_plan_hash, 1) AS QueryPlanHash,
                qs.execution_count AS ExecutionCount,
                qs.total_worker_time / qs.execution_count AS AvgCpuTimeMicroseconds,
                qs.total_logical_reads / qs.execution_count AS AvgLogicalReads,
                qs.max_grant_kb AS MaxGrantKB,
                qs.max_spills AS MaxSpills,
                CASE WHEN @IncludeQueryText = 1 THEN
                    LEFT(SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1), 600)
                ELSE N'(query text omitted by configuration)' END AS QueryText
            FROM sys.dm_exec_query_stats AS qs
            CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
            -- The plan's dbid attribute is the database the statement ran in; sql_text's dbid is NULL
            -- for every ad hoc batch, which would pull in other databases' queries.
            CROSS APPLY (SELECT CAST(pa.value AS int) AS dbid FROM sys.dm_exec_plan_attributes(qs.plan_handle) AS pa WHERE pa.attribute = N'dbid') AS pdb
            WHERE pdb.dbid = DB_ID()
              -- Leave out this tool's own statements: its AIIndexTuner* schemas, the sp_AIIndexTuner* procs in dbo,
              -- ad hoc batches that call or query them, and its dynamic SQL, which carries an AIIndexTuner marker.
              AND (st.objectid IS NULL OR OBJECT_SCHEMA_NAME(st.objectid, st.dbid) IS NULL OR OBJECT_SCHEMA_NAME(st.objectid, st.dbid) NOT LIKE N'AIIndexTuner%')
              AND st.text NOT LIKE N'%AIIndexTuner%'
            ORDER BY qs.total_worker_time DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== PLAN CACHE QUERY STATISTICS ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== PLAN CACHE QUERY STATISTICS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== HEAP TABLE ANALYSIS ===== heaps of 10,000 rows or more, physical stats sampled per heap */
    BEGIN TRY
        DECLARE @Heaps TABLE (object_id int PRIMARY KEY, TableName nvarchar(300), TotalRows bigint, ReservedMB decimal(18, 1));

        INSERT @Heaps (object_id, TableName, TotalRows, ReservedMB)
        SELECT TOP (15) t.object_id, s.name + N'.' + t.name, SUM(ps.row_count), ROUND(SUM(ps.reserved_page_count) * 8.0 / 1024.0, 1)
        FROM sys.tables AS t
        INNER JOIN sys.schemas AS s ON t.schema_id = s.schema_id
        INNER JOIN sys.dm_db_partition_stats AS ps ON t.object_id = ps.object_id AND ps.index_id = 0
        WHERE s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
          AND (@TableName IS NULL OR t.name = @TableName)
        GROUP BY t.object_id, s.name, t.name
        HAVING SUM(ps.row_count) >= 10000
        ORDER BY SUM(ps.row_count) DESC;

        SET @j = (
            SELECT h.TableName, h.TotalRows, h.ReservedMB,
                   CAST(MAX(COALESCE(ips.forwarded_record_count, 0)) AS bigint) AS ForwardedRecordCount,
                   CAST(MAX(COALESCE(ips.avg_fragmentation_in_percent, 0)) AS decimal(10, 2)) AS AvgFragmentationPct
            FROM @Heaps AS h
            OUTER APPLY sys.dm_db_index_physical_stats(DB_ID(), h.object_id, 0, NULL, 'SAMPLED') AS ips
            GROUP BY h.TableName, h.TotalRows, h.ReservedMB
            ORDER BY ForwardedRecordCount DESC, h.TotalRows DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== HEAP TABLE ANALYSIS ===', @nl, ISNULL(@j, N'(no heaps with 10,000 rows or more)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== HEAP TABLE ANALYSIS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== CONSTRAINTS AND RELATIONSHIPS ===== PK, UQ and FK, with the referenced table for FKs */
    BEGIN TRY
        SET @j = (
            SELECT TOP (400)
                SCHEMA_NAME(t.schema_id) + N'.' + t.name AS TableName,
                c.name AS ConstraintName,
                c.type_desc AS ConstraintType,
                col.name AS ColumnName,
                CASE WHEN c.type = 'F' THEN SCHEMA_NAME(rt.schema_id) + N'.' + rt.name END AS ReferencedTable,
                CASE WHEN c.type = 'F' THEN rcol.name END AS ReferencedColumn
            FROM sys.objects AS t
            INNER JOIN sys.objects AS c ON c.parent_object_id = t.object_id
            LEFT JOIN sys.sysconstraints AS sc ON sc.constid = c.object_id
            LEFT JOIN sys.columns AS col ON col.object_id = t.object_id AND col.column_id = sc.colid
            LEFT JOIN sys.foreign_keys AS fk ON c.object_id = fk.object_id
            LEFT JOIN sys.foreign_key_columns AS fkc ON fk.object_id = fkc.constraint_object_id
            LEFT JOIN sys.objects AS rt ON fkc.referenced_object_id = rt.object_id
            LEFT JOIN sys.columns AS rcol ON fkc.referenced_object_id = rcol.object_id AND fkc.referenced_column_id = rcol.column_id
            WHERE c.type IN ('F', 'PK', 'UQ')
              AND SCHEMA_NAME(t.schema_id) NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR SCHEMA_NAME(t.schema_id) = @SchemaName)
              AND (@TableName IS NULL OR t.name = @TableName)
            ORDER BY t.name, c.type_desc, c.name
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== CONSTRAINTS AND RELATIONSHIPS ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== CONSTRAINTS AND RELATIONSHIPS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== UNTRUSTED OR DISABLED CONSTRAINTS ===== */
    BEGIN TRY
        SET @j = (
            SELECT TOP (100) * FROM (
                SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name AS TableName, fk.name AS ConstraintName, 'FOREIGN KEY' AS ConstraintType,
                       fk.is_not_trusted AS IsNotTrusted, fk.is_disabled AS IsDisabled
                FROM sys.foreign_keys AS fk
                INNER JOIN sys.objects AS o ON o.object_id = fk.parent_object_id
                INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
                WHERE (fk.is_not_trusted = 1 OR fk.is_disabled = 1)
                  AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName) AND (@TableName IS NULL OR o.name = @TableName)
                UNION ALL
                SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name, cc.name, 'CHECK', cc.is_not_trusted, cc.is_disabled
                FROM sys.check_constraints AS cc
                INNER JOIN sys.objects AS o ON o.object_id = cc.parent_object_id
                INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
                WHERE (cc.is_not_trusted = 1 OR cc.is_disabled = 1)
                  AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName) AND (@TableName IS NULL OR o.name = @TableName)
            ) AS u
            ORDER BY u.TableName, u.ConstraintName
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== UNTRUSTED OR DISABLED CONSTRAINTS ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== UNTRUSTED OR DISABLED CONSTRAINTS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== INDEX OPERATIONAL HOTSPOTS ===== per-index lock, latch and leaf-operation pressure, top 15 */
    BEGIN TRY
        SET @j = (
            SELECT TOP (15)
                sch.name + N'.' + obj.name AS TableName,
                i.name AS IndexName,
                CASE WHEN i.fill_factor = 0 THEN CONCAT(@ServerFillFactor, ' (default)') ELSE CAST(i.fill_factor AS varchar(3)) END AS [FillFactor],
                ISNULL(ios.leaf_insert_count, 0) AS LeafInserts,
                ISNULL(ios.leaf_update_count, 0) AS LeafUpdates,
                ISNULL(ios.leaf_delete_count, 0) AS LeafDeletes,
                ISNULL(ios.row_lock_wait_count, 0) AS RowLockWaits,
                ISNULL(ios.row_lock_wait_in_ms, 0) AS RowLockWaitMs,
                ISNULL(ios.page_lock_wait_count, 0) AS PageLockWaits,
                ISNULL(ios.page_lock_wait_in_ms, 0) AS PageLockWaitMs,
                ISNULL(ios.page_latch_wait_count, 0) AS PageLatchWaits,
                ISNULL(ios.page_latch_wait_in_ms, 0) AS PageLatchWaitMs
            FROM sys.indexes AS i
            INNER JOIN sys.objects AS obj ON i.object_id = obj.object_id
            INNER JOIN sys.schemas AS sch ON obj.schema_id = sch.schema_id
            OUTER APPLY sys.dm_db_index_operational_stats(DB_ID(), i.object_id, i.index_id, NULL) AS ios
            WHERE obj.type = 'U' AND i.index_id > 0 AND i.is_hypothetical = 0
              AND sch.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR sch.name = @SchemaName)
              AND (@TableName IS NULL OR obj.name = @TableName)
            ORDER BY ISNULL(ios.row_lock_wait_in_ms, 0) + ISNULL(ios.page_lock_wait_in_ms, 0) + ISNULL(ios.page_latch_wait_in_ms, 0) DESC,
                     ISNULL(ios.leaf_update_count, 0) DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== INDEX OPERATIONAL HOTSPOTS ===', @nl, ISNULL(@j, N'No index operational hotspots found.'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== INDEX OPERATIONAL HOTSPOTS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== COLUMN CARDINALITY =====
       Density vectors for the tables behind the top 20 high-impact missing indexes and the 20 largest
       tables over 10,000 rows (plus the scoped table), via DBCC SHOW_STATISTICS ... WITH DENSITY_VECTOR. */
    -- The candidate statistics, kept for SKEWED LOW-CARDINALITY COLUMNS.
    CREATE TABLE #CardStats (object_id int, stats_id int, StatsTable nvarchar(300), StatsName sysname);
    BEGIN TRY
        CREATE TABLE #RawDensity (AllDensity float, AvgLength float, Columns nvarchar(4000));
        CREATE TABLE #Density (TableName nvarchar(300), AllDensity float, AvgLength float, Columns nvarchar(4000));

        DECLARE @StatsTable nvarchar(300), @StatsName sysname, @sql nvarchar(max), @CardinalityErrors int = 0;

        INSERT #CardStats (object_id, stats_id, StatsTable, StatsName)
            SELECT DISTINCT s.object_id, s.stats_id, QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(s.object_id)), s.name
            FROM sys.stats AS s
            INNER JOIN sys.objects AS o ON s.object_id = o.object_id
            WHERE o.type = 'U'
              AND OBJECT_SCHEMA_NAME(s.object_id) NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR OBJECT_SCHEMA_NAME(s.object_id) = @SchemaName)
              AND (@TableName IS NULL OR OBJECT_NAME(s.object_id) = @TableName)
              AND (   s.object_id IN (SELECT TOP (20) d.object_id
                                      FROM sys.dm_db_missing_index_details AS d
                                      INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
                                      INNER JOIN sys.dm_db_missing_index_group_stats AS st ON g.index_group_handle = st.group_handle
                                      WHERE d.database_id = DB_ID()
                                        AND st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) > 100000
                                      ORDER BY st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) DESC)
                   OR s.object_id IN (SELECT TOP (20) ps.object_id
                                      FROM sys.dm_db_partition_stats AS ps
                                      WHERE ps.index_id IN (0, 1)
                                      GROUP BY ps.object_id
                                      HAVING SUM(ps.row_count) > 10000
                                      ORDER BY SUM(ps.row_count) DESC)
                   OR (@SchemaName IS NOT NULL AND @TableName IS NOT NULL));

        DECLARE stats_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT StatsTable, StatsName FROM #CardStats;
        OPEN stats_cur;
        FETCH NEXT FROM stats_cur INTO @StatsTable, @StatsName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                TRUNCATE TABLE #RawDensity;
                SET @sql = N'DBCC SHOW_STATISTICS (N''' + REPLACE(@StatsTable, N'''', N'''''') + N''', ' + QUOTENAME(@StatsName) + N') WITH DENSITY_VECTOR, NO_INFOMSGS;';
                INSERT #RawDensity (AllDensity, AvgLength, Columns) EXEC (@sql);
                INSERT #Density (TableName, AllDensity, AvgLength, Columns)
                SELECT @StatsTable, AllDensity, AvgLength, Columns FROM #RawDensity;
            END TRY
            BEGIN CATCH
                SET @CardinalityErrors += 1;
            END CATCH;
            FETCH NEXT FROM stats_cur INTO @StatsTable, @StatsName;
        END;
        CLOSE stats_cur;
        DEALLOCATE stats_cur;

        SET @j = (
            SELECT DISTINCT TableName, AllDensity,
                   CASE WHEN AllDensity > 0 THEN CAST(1.0 / AllDensity AS bigint) END AS EstimatedDistinctValues,
                   AvgLength, Columns
            FROM #Density
            ORDER BY TableName, Columns
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== COLUMN CARDINALITY ===', @nl, ISNULL(@j, N'(no candidate tables)'), @nl,
                            CASE WHEN @CardinalityErrors > 0 THEN CONCAT(N'Warning: ', @CardinalityErrors, N' statistics objects could not be read.', @nl) ELSE N'' END);

        DROP TABLE #RawDensity;
        DROP TABLE #Density;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'stats_cur') >= -1 BEGIN CLOSE stats_cur; DEALLOCATE stats_cur; END;
        SET @Data += CONCAT(@nl, N'=== COLUMN CARDINALITY ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== SKEWED LOW-CARDINALITY COLUMNS =====
       For the tables in COLUMN CARDINALITY: columns that lead a statistics object whose histogram has
       2 to 10 values, one value per step, where one value holds 80% or more of the rows or one holds
       5% or less. Density alone says State has 2 values; this says Open is 0.5% of the rows. A query
       for a rare value is served by a filtered index, and SQL Server often suggests no missing index
       for it. Shares are from the histogram, so they are as current as StatsUpdated. */
    BEGIN TRY
        WITH lead_stats AS (
            SELECT cs.object_id, cs.StatsTable, sc.column_id, MIN(cs.stats_id) AS stats_id
            FROM #CardStats AS cs
            INNER JOIN sys.stats_columns AS sc ON sc.object_id = cs.object_id AND sc.stats_id = cs.stats_id AND sc.stats_column_id = 1
            GROUP BY cs.object_id, cs.StatsTable, sc.column_id
        ),
        hist AS (
            SELECT ls.object_id, ls.StatsTable, ls.column_id, ls.stats_id, h.range_high_key, h.equal_rows,
                   SUM(h.equal_rows + h.range_rows) OVER (PARTITION BY ls.object_id, ls.column_id) AS total_rows,
                   SUM(h.range_rows) OVER (PARTITION BY ls.object_id, ls.column_id) AS between_rows,
                   COUNT(*) OVER (PARTITION BY ls.object_id, ls.column_id) AS steps
            FROM lead_stats AS ls
            CROSS APPLY sys.dm_db_stats_histogram(ls.object_id, ls.stats_id) AS h
        ),
        skewed AS (
            SELECT object_id, StatsTable, column_id, stats_id, total_rows
            FROM hist
            WHERE steps BETWEEN 2 AND 10 AND between_rows = 0 AND total_rows >= 1000
            GROUP BY object_id, StatsTable, column_id, stats_id, total_rows
            HAVING MAX(equal_rows) >= 0.8 * total_rows OR MIN(equal_rows) <= 0.05 * total_rows
        )
        SELECT @j = (
            SELECT TOP (20)
                sk.StatsTable AS TableName,
                COL_NAME(sk.object_id, sk.column_id) AS ColumnName,
                AIIndexTuner.fn_ColumnType(sk.object_id, sk.column_id) AS ColumnType,
                CAST(sk.total_rows AS bigint) AS HistogramRows,
                CONVERT(varchar(19), STATS_DATE(sk.object_id, sk.stats_id), 120) AS StatsUpdated,
                (SELECT STRING_AGG(CAST(CONCAT(ISNULL(LEFT(CONVERT(nvarchar(4000), h.range_high_key), 60), N'NULL'), N': ',
                                               CAST(100.0 * h.equal_rows / h.total_rows AS decimal(5, 2)), N'%') AS nvarchar(max)), N', ')
                            WITHIN GROUP (ORDER BY h.equal_rows DESC)
                 FROM hist AS h WHERE h.object_id = sk.object_id AND h.column_id = sk.column_id) AS ValueShares
            FROM skewed AS sk
            ORDER BY sk.total_rows DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== SKEWED LOW-CARDINALITY COLUMNS ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== SKEWED LOW-CARDINALITY COLUMNS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== LARGE TABLES ===== over 1,000,000 rows */
    BEGIN TRY
        WITH LargeTables AS (
            SELECT ps.object_id, SUM(ps.row_count) AS TotalRows
            FROM sys.dm_db_partition_stats AS ps
            WHERE ps.index_id IN (0, 1)
            GROUP BY ps.object_id
            HAVING SUM(ps.row_count) > 1000000
        )
        SELECT @j = (
            SELECT TOP (100) s.name AS SchemaName, t.name AS TableName, lt.TotalRows
            FROM LargeTables AS lt
            INNER JOIN sys.tables AS t ON lt.object_id = t.object_id
            INNER JOIN sys.schemas AS s ON t.schema_id = s.schema_id
            WHERE s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName) AND (@TableName IS NULL OR t.name = @TableName)
            ORDER BY lt.TotalRows DESC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== LARGE TABLES ===', @nl, ISNULL(@j, N'(no tables over 1,000,000 rows)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== LARGE TABLES ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== DATABASE STATISTICS SETTINGS ===== */
    BEGIN TRY
        SET @j = (
            SELECT name AS DatabaseName,
                   is_auto_create_stats_on AS AutoCreateStats,
                   is_auto_update_stats_on AS AutoUpdateStats,
                   is_auto_update_stats_async_on AS AutoUpdateStatsAsync
            FROM sys.databases
            WHERE database_id = DB_ID()
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== DATABASE STATISTICS SETTINGS ===', @nl, @j, @nl,
            CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND (is_auto_create_stats_on = 0 OR is_auto_update_stats_on = 0))
                 THEN N'Warning: automatic statistics management is not fully enabled for this database.' + @nl ELSE N'' END);

        -- OPTIMIZED_SP_EXECUTESQL and ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY: a row exists only where the
        -- option does, so a missing row is NOT_AVAILABLE (AppendSpExecuteSqlSettingsAsync).
        DECLARE @OptimizedSpExecuteSql int, @AsyncLowPriority int;
        SELECT @OptimizedSpExecuteSql = MAX(CASE WHEN name = N'OPTIMIZED_SP_EXECUTESQL' THEN CONVERT(int, value) END),
               @AsyncLowPriority = MAX(CASE WHEN name = N'ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY' THEN CONVERT(int, value) END)
        FROM sys.database_scoped_configurations
        WHERE name IN (N'OPTIMIZED_SP_EXECUTESQL', N'ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY');
        SET @Data += CONCAT(
            N'  OPTIMIZED_SP_EXECUTESQL: ', CASE @OptimizedSpExecuteSql WHEN 1 THEN N'ON' WHEN 0 THEN N'OFF' ELSE N'NOT_AVAILABLE' END, @nl,
            N'  ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY: ', CASE @AsyncLowPriority WHEN 1 THEN N'ON' WHEN 0 THEN N'OFF' ELSE N'NOT_AVAILABLE' END, @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== DATABASE STATISTICS SETTINGS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== INDEX PAGE DENSITY =====
       sys.dm_db_index_physical_stats (SAMPLED) once per candidate table, never with a NULL object_id,
       which would scan every object in the database. Candidates: the scoped table; otherwise the top
       20 high-impact missing-index tables plus up to 20 of the largest tables over 10,000 rows, in
       the scoped schema when there is one. */
    BEGIN TRY
        CREATE TABLE #DensityCandidates (object_id int NOT NULL PRIMARY KEY);
        CREATE TABLE #PageDensity (TableName nvarchar(300), IndexName sysname, IndexType nvarchar(60), AvgPageDensityPct float,
                                   AvgFragmentationPct float, PageCount bigint, RecordCount bigint);

        IF @TableName IS NOT NULL
            INSERT #DensityCandidates (object_id) SELECT OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName));
        ELSE
        BEGIN
            INSERT #DensityCandidates (object_id)
            SELECT TOP (20) d.object_id
            FROM sys.dm_db_missing_index_details AS d
            INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
            INNER JOIN sys.dm_db_missing_index_group_stats AS st ON g.index_group_handle = st.group_handle
            INNER JOIN sys.objects AS o ON d.object_id = o.object_id
            INNER JOIN sys.schemas AS s ON o.schema_id = s.schema_id
            WHERE d.database_id = DB_ID()
              AND st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) > 100000
              AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
            GROUP BY d.object_id
            ORDER BY MAX(st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans)) DESC;

            INSERT #DensityCandidates (object_id)
            SELECT TOP (20) ps.object_id
            FROM sys.dm_db_partition_stats AS ps
            INNER JOIN sys.tables AS t ON ps.object_id = t.object_id
            INNER JOIN sys.schemas AS s ON t.schema_id = s.schema_id
            WHERE ps.index_id IN (0, 1)
              AND s.name NOT LIKE N'AIIndexTuner%' AND (@SchemaName IS NULL OR s.name = @SchemaName)
              AND ps.object_id NOT IN (SELECT object_id FROM #DensityCandidates)
            GROUP BY ps.object_id
            HAVING SUM(ps.row_count) > 10000
            ORDER BY SUM(ps.row_count) DESC;
        END;

        DECLARE @DensityObjectId int;
        DECLARE density_cur CURSOR LOCAL FAST_FORWARD FOR SELECT object_id FROM #DensityCandidates;
        OPEN density_cur;
        FETCH NEXT FROM density_cur INTO @DensityObjectId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id = @DensityObjectId)   -- dropped since the list was built
                INSERT #PageDensity
                SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name, i.name, i.type_desc, ips.avg_page_space_used_in_percent,
                       ips.avg_fragmentation_in_percent, ips.page_count, ips.record_count
                FROM sys.dm_db_index_physical_stats(DB_ID(), @DensityObjectId, NULL, NULL, 'SAMPLED') AS ips
                INNER JOIN sys.objects AS o ON ips.object_id = o.object_id
                INNER JOIN sys.indexes AS i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
                WHERE o.type = 'U' AND ips.alloc_unit_type_desc = 'IN_ROW_DATA' AND ips.page_count > 128
                  AND ips.avg_page_space_used_in_percent IS NOT NULL AND i.name IS NOT NULL;
            FETCH NEXT FROM density_cur INTO @DensityObjectId;
        END;
        CLOSE density_cur;
        DEALLOCATE density_cur;

        SET @j = (
            SELECT TOP (50) TableName, IndexName, IndexType,
                   CAST(AvgPageDensityPct AS decimal(5, 2)) AS AvgPageDensityPct,
                   CAST(AvgFragmentationPct AS decimal(5, 2)) AS AvgFragmentationPct,
                   PageCount, CAST(PageCount * 8.0 / 1024 AS decimal(18, 1)) AS SizeMB, RecordCount
            FROM #PageDensity
            ORDER BY AvgPageDensityPct ASC
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== INDEX PAGE DENSITY ===', @nl, ISNULL(@j, N'No index page density rows found.'), @nl);
        DROP TABLE #PageDensity;
        DROP TABLE #DensityCandidates;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'density_cur') >= -1 BEGIN CLOSE density_cur; DEALLOCATE density_cur; END;
        SET @Data += CONCAT(@nl, N'=== INDEX PAGE DENSITY ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== Query Store ===== */
    DECLARE @QsActualState int, @QsDesiredState int, @QsStateDesc nvarchar(60), @QsUsable bit = 0;
    SELECT TOP (1) @QsActualState = actual_state, @QsDesiredState = desired_state, @QsStateDesc = actual_state_desc
    FROM sys.database_query_store_options;
    IF @QsActualState IN (1, 2) SET @QsUsable = 1;   -- READ_ONLY or READ_WRITE

    DECLARE @QsSince datetimeoffset = DATEADD(DAY, -7, SYSUTCDATETIME()),
            @QsMinInterval bigint;
    -- Runtime stats are indexed by interval, so the 7-day window is resolved to an interval id. Match
    -- on end_time so the interval straddling the cutoff is kept.
    IF @QsUsable = 1
        SELECT @QsMinInterval = MIN(runtime_stats_interval_id)
        FROM sys.query_store_runtime_stats_interval
        WHERE end_time >= @QsSince;

    /* Object scope (ResolveQueryStoreScopeAsync): the Query Store query_ids that touch the scoped
       schema or table, resolved once into #qs_scope, which every Query Store section joins.
         1. bound the plan set: plans executed in the window, most recent first, at most 20,000
         2. text prefilter: the plan XML text mentions Schema="[s]" (and Table="[t]")
         3. confirm by shredding the plan XML with exist()
       A step that fails degrades to the coarser scope (text match, then module dependencies), and the
       section says which one it reached. T-SQL has no per-statement timeout, so the plan cap is what
       bounds the work. */
    CREATE TABLE #qs_scope (query_id bigint NOT NULL PRIMARY KEY);
    DECLARE @QsScoped bit = 0, @QsTier varchar(20) = 'Unresolved', @QsScopeCount int = 0, @QsPlansScanned int = 0,
            @QsPlanCap int = 20000, @QsCapped bit = 0, @QsDegradeReason nvarchar(1000), @QsScopeNote nvarchar(max) = N'';

    IF @SchemaName IS NOT NULL AND @QsUsable = 1
    BEGIN
        DECLARE @qs_schema_br nvarchar(260) = QUOTENAME(@SchemaName),
                @qs_table_br nvarchar(260) = QUOTENAME(@TableName),
                @qs_object nvarchar(600) = QUOTENAME(@SchemaName) + ISNULL(N'.' + QUOTENAME(@TableName), N''),
                @qs_schema_like nvarchar(1000), @qs_table_like nvarchar(1000);
        SET @qs_schema_like = N'%Schema="' + AIIndexTuner.fn_EscapeLike(@qs_schema_br) + N'"%';
        SET @qs_table_like = N'%Table="' + AIIndexTuner.fn_EscapeLike(@qs_table_br) + N'"%';   -- NULL without a table

        CREATE TABLE #qs_plan_cand (plan_id bigint NOT NULL PRIMARY KEY, query_id bigint NOT NULL);
        CREATE TABLE #qs_plan_hit (plan_id bigint NOT NULL PRIMARY KEY, query_id bigint NOT NULL);
        DECLARE @QsPrefilterDone bit = 0;

        BEGIN TRY
            -- One past the cap, so "hit the cap" can be told apart from "exactly cap plans".
            INSERT #qs_plan_cand (plan_id, query_id)
            SELECT TOP (@QsPlanCap + 1) p.plan_id, p.query_id
            FROM sys.query_store_plan AS p
            INNER JOIN sys.query_store_query AS q ON q.query_id = p.query_id
            WHERE q.is_internal_query = 0 AND p.last_execution_time >= @QsSince
            ORDER BY p.last_execution_time DESC
            OPTION (RECOMPILE);

            SET @QsPlansScanned = @@ROWCOUNT;
            IF @QsPlansScanned > @QsPlanCap SELECT @QsCapped = 1, @QsPlansScanned = @QsPlanCap;

            INSERT #qs_plan_hit (plan_id, query_id)
            SELECT c.plan_id, c.query_id
            FROM #qs_plan_cand AS c
            INNER JOIN sys.query_store_plan AS p ON p.plan_id = c.plan_id
            WHERE p.query_plan LIKE @qs_schema_like ESCAPE N'\'
              AND (@qs_table_like IS NULL OR p.query_plan LIKE @qs_table_like ESCAPE N'\')
            OPTION (RECOMPILE);
            SET @QsPrefilterDone = 1;
        END TRY
        BEGIN CATCH
            SET @QsDegradeReason = CONCAT(N'the plan-text prefilter failed (', ERROR_MESSAGE(), N')');
        END CATCH;

        IF @QsPrefilterDone = 1
        BEGIN
            BEGIN TRY
                -- exist() stops at the first matching Object node; nodes() would shred every node.
                IF @TableName IS NULL
                    INSERT #qs_scope (query_id)
                    SELECT DISTINCT h.query_id
                    FROM #qs_plan_hit AS h
                    INNER JOIN sys.query_store_plan AS p ON p.plan_id = h.plan_id
                    CROSS APPLY (SELECT TRY_CAST(p.query_plan AS xml) AS plan_xml) AS qp
                    WHERE qp.plan_xml IS NOT NULL
                      AND qp.plan_xml.exist('//*[local-name()="Object"][@Schema=sql:variable("@qs_schema_br")]') = 1
                    OPTION (RECOMPILE);
                ELSE
                    INSERT #qs_scope (query_id)
                    SELECT DISTINCT h.query_id
                    FROM #qs_plan_hit AS h
                    INNER JOIN sys.query_store_plan AS p ON p.plan_id = h.plan_id
                    CROSS APPLY (SELECT TRY_CAST(p.query_plan AS xml) AS plan_xml) AS qp
                    WHERE qp.plan_xml IS NOT NULL
                      AND qp.plan_xml.exist('//*[local-name()="Object"][@Schema=sql:variable("@qs_schema_br")][@Table=sql:variable("@qs_table_br")]') = 1
                    OPTION (RECOMPILE);
                SET @QsTier = 'PlanXmlConfirmed';
            END TRY
            BEGIN CATCH
                -- The prefilter hits are a superset of the confirmed set: still a usable, approximate scope.
                SET @QsDegradeReason = CONCAT(N'the plan-XML confirmation failed (', ERROR_MESSAGE(), N')');
                DELETE #qs_scope;
                INSERT #qs_scope (query_id) SELECT DISTINCT query_id FROM #qs_plan_hit;
                SET @QsTier = 'TextPrefilter';
            END CATCH;
        END;

        -- Last resort: module dependencies. Query Store records the containing module, so this pulls in
        -- every statement of a module that references the object, and no ad hoc statements.
        IF @QsTier = 'Unresolved'
        BEGIN
            BEGIN TRY
                INSERT #qs_scope (query_id)
                SELECT DISTINCT q.query_id
                FROM sys.query_store_query AS q
                WHERE q.is_internal_query = 0 AND q.object_id <> 0
                  AND q.object_id IN (
                        SELECT sed.referencing_id
                        FROM sys.sql_expression_dependencies AS sed
                        INNER JOIN sys.objects AS ro ON ro.object_id = sed.referenced_id
                        INNER JOIN sys.schemas AS rs ON rs.schema_id = ro.schema_id
                        WHERE sed.referenced_class = 1 AND sed.referenced_database_name IS NULL
                          AND rs.name = @SchemaName AND (@TableName IS NULL OR ro.name = @TableName));
                SET @QsTier = 'DependenciesOnly';
            END TRY
            BEGIN CATCH
                SET @QsDegradeReason = CONCAT(ISNULL(@QsDegradeReason + N'; ', N''), N'the dependency fallback failed (', ERROR_MESSAGE(), N')');
            END CATCH;
        END;

        SELECT @QsScopeCount = COUNT(*) FROM #qs_scope;
        SET @QsScoped = CASE WHEN @QsTier = 'Unresolved' THEN 0 ELSE 1 END;
        SET @QsDegradeReason = ISNULL(@QsDegradeReason, N'scope resolution did not complete');

        SET @QsScopeNote = CASE @QsTier
            WHEN 'PlanXmlConfirmed' THEN CONCAT(N'Query Store object scope: ', @QsScopeCount, N' queries reference ', @qs_object,
                                                N' (confirmed from plan XML; ', @QsPlansScanned, N' recent plans scanned).')
            WHEN 'TextPrefilter' THEN CONCAT(N'Warning: Query Store object scope for ', @qs_object, N' is approximate because ', @QsDegradeReason,
                                             N'. Scope fell back to a plan-text match (', @QsScopeCount, N' queries) and may include queries that only mention the object incidentally.')
            WHEN 'DependenciesOnly' THEN CONCAT(N'Warning: Query Store object scope for ', @qs_object, N' is approximate because ', @QsDegradeReason,
                                                N'. Scope fell back to module dependencies (', @QsScopeCount, N' queries): Query Store records the containing module, so this includes statements in those modules that never touch the object, and excludes ad-hoc statements and dynamic SQL.')
            ELSE CONCAT(N'Warning: Query Store object scope for ', @qs_object, N' could not be resolved because ', @QsDegradeReason,
                        N'. Query Store sections below are database-scoped, not limited to that object.')
        END
        + CASE WHEN @QsCapped = 1 THEN CONCAT(N' More than ', @QsPlanCap, N' plans were eligible, so the scan was capped at that many, most recently executed first; less recently executed plans are not represented in this scope.') ELSE N'' END
        + CASE WHEN @QsScoped = 1 AND @QsScopeCount = 0 THEN N' No Query Store queries matched, so the Query Store sections below are empty; that means no captured workload touched the object, not that the sections failed.' ELSE N'' END;

        /* Adaptive plans (Parameter Sensitive Plan, optional parameter plan optimization) store each query
           variant as its own query, with object_id 0, under a parent query that has the module's object_id.
           The plan-XML tiers find the variants, whose plans read the object, and the dependency tier finds
           the parents. Each brings in the other, so a statement is in scope whichever query Query Store
           recorded its work under. */
        IF @QsScoped = 1
        BEGIN
        BEGIN TRY
            INSERT #qs_scope (query_id)
            SELECT x.query_id
            FROM (SELECT qv.query_variant_query_id AS query_id
                  FROM sys.query_store_query_variant AS qv
                  INNER JOIN #qs_scope AS s ON s.query_id = qv.parent_query_id
                  UNION
                  SELECT qv.parent_query_id
                  FROM sys.query_store_query_variant AS qv
                  INNER JOIN #qs_scope AS s ON s.query_id = qv.query_variant_query_id) AS x
            WHERE NOT EXISTS (SELECT 1 FROM #qs_scope AS s2 WHERE s2.query_id = x.query_id);
        END TRY
        BEGIN CATCH
            SET @QsScopeNote += CONCAT(N' Query variants could not be matched to their parent queries (', ERROR_MESSAGE(), N').');
        END CATCH;
        END;

        DROP TABLE #qs_plan_cand;
        DROP TABLE #qs_plan_hit;
    END;

    /* ===== QUERY STORE WORKLOAD INSIGHTS ===== top 50 queries by total duration over the last 7 days */
    SET @Data += CONCAT(@nl, N'=== QUERY STORE WORKLOAD INSIGHTS ===', @nl, CASE WHEN @QsScopeNote <> N'' THEN @QsScopeNote + @nl ELSE N'' END);
    IF @QsActualState IS NULL
        SET @Data += N'Query Store is not supported on this SQL Server version/edition.' + @nl;
    ELSE IF @QsUsable = 0
        SET @Data += CONCAT(N'Query Store is disabled for this database (desired_state=', @QsDesiredState, N', actual_state=', @QsActualState, N').', @nl);
    ELSE BEGIN
    BEGIN TRY
        WITH rs_agg AS (
            SELECT rs.plan_id,
                   SUM(rs.count_executions) AS count_executions,
                   SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_duration,
                   SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_cpu_time,
                   SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,
                   SUM(rs.avg_logical_io_writes * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_writes,
                   SUM(rs.avg_rowcount * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_rowcount,
                   MIN(rs.first_execution_time) AS first_execution_time,
                   MAX(rs.last_execution_time) AS last_execution_time
            FROM sys.query_store_runtime_stats AS rs
            WHERE rs.runtime_stats_interval_id >= @QsMinInterval
              AND (@QsScoped = 0 OR EXISTS (SELECT 1 FROM sys.query_store_plan AS sp INNER JOIN #qs_scope AS sc ON sc.query_id = sp.query_id WHERE sp.plan_id = rs.plan_id))
            GROUP BY rs.plan_id
        ),
        waits AS (
            SELECT ws.plan_id, SUM(ws.total_query_wait_time_ms) AS total_wait_ms
            FROM sys.query_store_wait_stats AS ws
            WHERE ws.runtime_stats_interval_id >= @QsMinInterval
            GROUP BY ws.plan_id
        ),
        -- An adaptive plan query variant (Parameter Sensitive Plan, optional parameter plan optimization)
        -- is counted under its parent query, with the parent's text and module: the parent's dispatcher
        -- plan has no runtime stats, so otherwise one statement's cost is split over its variants.
        qs AS (
            SELECT COALESCE(pq.query_id, q.query_id) AS query_id, COALESCE(pq.query_hash, q.query_hash) AS query_hash,
                   COALESCE(pqt.query_sql_text, qt.query_sql_text) AS query_sql_text,
                   p.plan_id, rs.count_executions, rs.avg_duration, rs.avg_cpu_time,
                   rs.avg_logical_reads, rs.avg_logical_writes, rs.avg_rowcount, rs.first_execution_time, rs.last_execution_time,
                   ISNULL(w.total_wait_ms, 0) AS total_wait_ms
            FROM rs_agg AS rs
            INNER JOIN sys.query_store_plan AS p ON rs.plan_id = p.plan_id
            INNER JOIN sys.query_store_query AS q ON p.query_id = q.query_id
            INNER JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
            LEFT JOIN sys.query_store_query_variant AS qv ON qv.query_variant_query_id = q.query_id
            LEFT JOIN sys.query_store_query AS pq ON pq.query_id = qv.parent_query_id
            LEFT JOIN sys.query_store_query_text AS pqt ON pqt.query_text_id = pq.query_text_id
            LEFT JOIN waits AS w ON rs.plan_id = w.plan_id
            CROSS APPLY (SELECT COALESCE(pq.object_id, q.object_id) AS object_id) AS m
            WHERE q.is_internal_query = 0
              -- Leave out this tool's own statements, as in the plan cache section. A variant has object_id 0,
              -- so its module is its parent's: the collector's own catch-all filters, such as
              -- (@SchemaName IS NULL OR s.name = @SchemaName), get variants at compatibility level 170.
              AND (m.object_id = 0 OR OBJECT_SCHEMA_NAME(m.object_id) IS NULL OR OBJECT_SCHEMA_NAME(m.object_id) NOT LIKE N'AIIndexTuner%')
              AND (m.object_id = 0 OR OBJECT_NAME(m.object_id) IS NULL OR OBJECT_NAME(m.object_id) NOT LIKE N'sp[_]AIIndexTuner%')
              AND qt.query_sql_text NOT LIKE N'%AIIndexTuner%'
        ),
        param_sens AS (
            SELECT query_id, COUNT(*) AS distinct_plan_count,
                   AVG(avg_duration) AS avg_duration_across_plans, STDEV(avg_duration) AS stdev_duration_across_plans,
                   AVG(avg_rowcount) AS avg_rowcount_across_plans, STDEV(avg_rowcount) AS stdev_rowcount_across_plans
            FROM qs GROUP BY query_id
        )
        SELECT @j = (
            SELECT TOP (50)
                q.query_id AS QueryId,
                CONVERT(varchar(18), q.query_hash, 1) AS QueryHash,
                -- avg_duration and avg_cpu_time are microseconds; total_query_wait_time_ms is milliseconds.
                ROUND(SUM(q.avg_duration * q.count_executions) / 1000000.0, 2) AS TotalTimeSecs,
                ROUND(SUM(q.total_wait_ms) / 1000.0, 2) AS TotalWaitSecs,
                SUM(q.count_executions) AS Executions7d,
                ROUND(SUM(q.avg_duration * q.count_executions) / NULLIF(SUM(q.count_executions), 0) / 1000.0, 2) AS AvgDurationMs,
                ROUND(SUM(q.avg_cpu_time * q.count_executions) / NULLIF(SUM(q.count_executions), 0) / 1000.0, 2) AS AvgCpuMs,
                ROUND(SUM(q.avg_logical_reads * q.count_executions) / NULLIF(SUM(q.count_executions), 0), 0) AS AvgLogicalReads,
                ROUND(SUM(q.avg_logical_writes * q.count_executions) / NULLIF(SUM(q.count_executions), 0), 0) AS AvgLogicalWrites,
                ROUND(SUM(q.avg_rowcount * q.count_executions) / NULLIF(SUM(q.count_executions), 0), 0) AS AvgActualRows,
                CONVERT(varchar(16), MIN(q.first_execution_time), 120) AS FirstExecution,
                CONVERT(varchar(16), MAX(q.last_execution_time), 120) AS LastExecution,
                COUNT(DISTINCT q.plan_id) AS DistinctPlans,
                MAX(ps.distinct_plan_count) AS ParamSensitivityPlansSampled,
                ROUND(MAX(ps.avg_duration_across_plans) / 1000.0, 2) AS ParamSensitivityAvgDurationMs,
                ROUND(MAX(ps.stdev_duration_across_plans) / 1000.0, 2) AS ParamSensitivityStdevDurationMs,
                ROUND(MAX(ps.avg_rowcount_across_plans), 0) AS ParamSensitivityAvgRows,
                ROUND(MAX(ps.stdev_rowcount_across_plans), 0) AS ParamSensitivityStdevRows,
                CASE WHEN @IncludeQueryText = 1 THEN AIIndexTuner.fn_CleanText(q.query_sql_text, 600) ELSE N'(query text omitted by configuration)' END AS QueryText
            FROM qs AS q
            LEFT JOIN param_sens AS ps ON q.query_id = ps.query_id
            GROUP BY q.query_id, q.query_hash, q.query_sql_text
            ORDER BY SUM(q.avg_duration * q.count_executions) DESC
            FOR JSON PATH)
        OPTION (RECOMPILE);
        SET @Data += ISNULL(@j, N'No Query Store workload rows available for this database.') + @nl;
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(N'Query Store workload insights unavailable: ', ERROR_MESSAGE(), @nl);
    END CATCH;
    END;

    /* ===== QUERY STORE WRITE WORKLOAD MIX =====
       INSERT/UPDATE/DELETE/MERGE executions by type and UTC hour. The type comes from the leading
       keyword of the statement. Auto-parameterized and sp_executesql statements start with their
       parameter declarations, as in "(@1 tinyint,@2 int)UPDATE [dbo].[Orders] ...", so the
       statement is read from after that prefix and counted under its real type. Statements that
       are not one of the four write types are left out; there is no OTHER bucket. (The desktop
       collector reads only the leading characters, so it leaves parameterized writes out.) */
    SET @Data += CONCAT(@nl, N'=== QUERY STORE WRITE WORKLOAD MIX ===', @nl);
    IF @QsUsable = 0
        SET @Data += N'Query Store write workload mix is not available on this database.' + @nl;
    ELSE BEGIN
    BEGIN TRY
        WITH typed AS (
            SELECT CASE WHEN stmt.s LIKE 'INSERT %' THEN 'INSERT'
                        WHEN stmt.s LIKE 'UPDATE %' THEN 'UPDATE'
                        WHEN stmt.s LIKE 'DELETE %' THEN 'DELETE'
                        WHEN stmt.s LIKE 'MERGE %' THEN 'MERGE'
                   END AS StatementType,
                   DATEPART(HOUR, rsi.start_time) AS HourOfDayUtc,
                   CAST(rs.count_executions AS bigint) AS count_executions
            FROM sys.query_store_query_text AS qt
            INNER JOIN sys.query_store_query AS q ON qt.query_text_id = q.query_text_id
            INNER JOIN sys.query_store_plan AS qp ON q.query_id = qp.query_id
            INNER JOIN sys.query_store_runtime_stats AS rs ON qp.plan_id = rs.plan_id
            INNER JOIN sys.query_store_runtime_stats_interval AS rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
            -- A query variant's module is its parent's (see the workload section).
            LEFT JOIN sys.query_store_query_variant AS qv ON qv.query_variant_query_id = q.query_id
            LEFT JOIN sys.query_store_query AS pq ON pq.query_id = qv.parent_query_id
            CROSS APPLY (SELECT COALESCE(pq.object_id, q.object_id) AS object_id) AS m
            -- Upper-cased head of the text, with line breaks and tabs as spaces.
            CROSS APPLY (SELECT UPPER(LTRIM(REPLACE(REPLACE(REPLACE(LEFT(qt.query_sql_text, 4000), NCHAR(13), N' '), NCHAR(10), N' '), NCHAR(9), N' '))) AS t) AS head
            -- Where the statement starts after a "(@...)" parameter-declaration prefix: the first ')'
            -- followed by a write keyword. Searching for the keyword, not the first ')', copes with
            -- types such as decimal(18,2) inside the declarations.
            CROSS APPLY (SELECT CASE WHEN head.t LIKE N'(@%'
                                     THEN (SELECT MIN(v.pos) FROM (VALUES (CHARINDEX(N')INSERT ', head.t)), (CHARINDEX(N')UPDATE ', head.t)),
                                                                          (CHARINDEX(N')DELETE ', head.t)), (CHARINDEX(N')MERGE ', head.t))) AS v(pos)
                                           WHERE v.pos > 0)
                                END AS p) AS prefix
            CROSS APPLY (SELECT LEFT(CASE WHEN prefix.p IS NOT NULL THEN SUBSTRING(head.t, prefix.p + 1, 4000) ELSE head.t END, 200) AS s) AS stmt
            WHERE rs.runtime_stats_interval_id >= @QsMinInterval
              AND (@QsScoped = 0 OR EXISTS (SELECT 1 FROM #qs_scope AS sc WHERE sc.query_id = q.query_id))
              AND q.is_internal_query = 0
              -- Leave out this tool's own writes, as in the workload section: its temp-table writes in
              -- usp_CollectData and usp_UsageSince, whose text does not name the schema, by module,
              -- and its runs and recommendations by text.
              AND (m.object_id = 0 OR OBJECT_SCHEMA_NAME(m.object_id) IS NULL OR OBJECT_SCHEMA_NAME(m.object_id) NOT LIKE N'AIIndexTuner%')
              AND (m.object_id = 0 OR OBJECT_NAME(m.object_id) IS NULL OR OBJECT_NAME(m.object_id) NOT LIKE N'sp[_]AIIndexTuner%')
              AND qt.query_sql_text NOT LIKE N'%AIIndexTuner%'
        )
        SELECT @j = (
            SELECT TOP (12) StatementType, HourOfDayUtc, SUM(count_executions) AS Executions
            FROM typed
            WHERE StatementType IS NOT NULL
            GROUP BY StatementType, HourOfDayUtc
            ORDER BY SUM(count_executions) DESC, StatementType
            FOR JSON PATH)
        OPTION (RECOMPILE);
        SET @Data += CASE WHEN @j IS NULL THEN N'No recent write workload mix found in Query Store.'
                          ELSE N'Executions over the last 7 days per statement type and UTC hour of day (0-23), the 12 largest buckets; a statement type can appear in several rows.' + @nl + @j
                     END + @nl;
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(N'Query Store write workload mix unavailable: ', ERROR_MESSAGE(), @nl);
    END CATCH;
    END;

    /* ===== QUERY STORE FORCED PLAN FAILURES ===== */
    SET @Data += CONCAT(@nl, N'=== QUERY STORE FORCED PLAN FAILURES ===', @nl);
    IF @QsUsable = 0
        SET @Data += N'Query Store is not available or not enabled; forced plan failure data skipped.' + @nl;
    ELSE BEGIN
    BEGIN TRY
        WITH recent_runtime AS (
            SELECT rs.plan_id,
                   SUM(rs.count_executions) AS executions_last_7d,
                   SUM(CONVERT(bigint, rs.avg_duration) * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_duration_us_last_7d
            FROM sys.query_store_runtime_stats AS rs
            WHERE rs.runtime_stats_interval_id >= @QsMinInterval
            GROUP BY rs.plan_id
        )
        SELECT @j = (
            SELECT TOP (25)
                -- The forced plan's own query, which sp_query_store_unforce_plan takes, and for a query
                -- variant of an adaptive plan the parent query it belongs to.
                qsq.query_id AS QueryId,
                qv.parent_query_id AS ParentQueryId,
                qsp.plan_id AS PlanId,
                qsp.force_failure_count AS ForceFailureCount,
                qsp.last_force_failure_reason_desc AS LastFailureReason,
                ISNULL(rr.executions_last_7d, 0) AS ExecutionsLast7d,
                CAST(ISNULL(rr.avg_duration_us_last_7d, 0) / 1000.0 AS decimal(18, 2)) AS AvgDurationMsLast7d,
                CASE WHEN @IncludeQueryText = 1 THEN AIIndexTuner.fn_CleanText(qt.query_sql_text, 600) ELSE N'(query text omitted by configuration)' END AS QueryText
            FROM sys.query_store_plan AS qsp
            INNER JOIN sys.query_store_query AS qsq ON qsp.query_id = qsq.query_id
            INNER JOIN sys.query_store_query_text AS qt ON qsq.query_text_id = qt.query_text_id
            LEFT JOIN sys.query_store_query_variant AS qv ON qv.query_variant_query_id = qsq.query_id
            LEFT JOIN recent_runtime AS rr ON qsp.plan_id = rr.plan_id
            WHERE qsp.is_forced_plan = 1 AND qsp.force_failure_count >= 1
              AND (@QsScoped = 0 OR EXISTS (SELECT 1 FROM #qs_scope AS sc WHERE sc.query_id = qsq.query_id))
            ORDER BY qsp.force_failure_count DESC, ISNULL(rr.executions_last_7d, 0) DESC, ISNULL(rr.avg_duration_us_last_7d, 0) DESC
            FOR JSON PATH)
        OPTION (RECOMPILE);
        SET @Data += ISNULL(@j, N'No forced plan failures detected.') + @nl;
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(N'Forced plan failure data unavailable: ', ERROR_MESSAGE(), @nl);
    END CATCH;
    END;

    /* ===== AUTOMATIC TUNING OPTIONS ===== FORCE_LAST_GOOD_PLAN */
    BEGIN TRY
        SET @j = (
            SELECT DB_NAME() AS DatabaseName, name AS [Option], desired_state_desc AS DesiredState,
                   actual_state_desc AS ActualState, reason_desc AS Reason
            FROM sys.database_automatic_tuning_options
            WHERE name = N'FORCE_LAST_GOOD_PLAN'
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== AUTOMATIC TUNING OPTIONS ===', @nl, ISNULL(@j, N'FORCE_LAST_GOOD_PLAN option not found.'), @nl);
        -- Standard (including Standard Developer) and Express report the option but cannot turn it on:
        -- ALTER DATABASE ... SET AUTOMATIC_TUNING fails there with error 15707.
        IF @EngineEdition IN (2, 4)
            SET @Data += CONCAT(N'Automatic tuning is available only in the Enterprise and Enterprise Developer editions of SQL Server, so FORCE_LAST_GOOD_PLAN cannot be enabled on this edition (',
                                CONVERT(nvarchar(128), SERVERPROPERTY('Edition')), N'): ALTER DATABASE ... SET AUTOMATIC_TUNING fails here with error 15707.', @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== AUTOMATIC TUNING OPTIONS ===', @nl, N'Automatic tuning options unavailable: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== CARDINALITY ESTIMATION FEEDBACK ===== (AppendCeFeedbackSummaryAsync)
       Next to automatic tuning: a forced plan turns CE feedback off for its query, and automatic plan
       correction can roll CE feedback back (ROLLEDBACK_BY_APRC). */
    SET @Data += CONCAT(@nl, N'=== CARDINALITY ESTIMATION FEEDBACK ===', @nl);
    BEGIN TRY
        DECLARE @Compat int, @CeFeedback int, @CeExpressions int, @Blockers nvarchar(1000) = N'';
        SELECT @Compat = compatibility_level FROM sys.databases WHERE database_id = DB_ID();
        SELECT @CeFeedback = MAX(CASE WHEN name = N'CE_FEEDBACK' THEN CONVERT(int, value) END),
               @CeExpressions = MAX(CASE WHEN name = N'CE_FEEDBACK_FOR_EXPRESSIONS' THEN CONVERT(int, value) END)
        FROM sys.database_scoped_configurations
        WHERE name IN (N'CE_FEEDBACK', N'CE_FEEDBACK_FOR_EXPRESSIONS');

        IF @CeFeedback = 0 SET @Blockers += N'; CE_FEEDBACK is OFF';
        IF @Compat < 160 SET @Blockers += CONCAT(N'; compatibility level is ', @Compat, N' (needs 160 or higher)');
        IF ISNULL(@QsStateDesc, N'') <> N'READ_WRITE'
            SET @Blockers += CASE WHEN @QsStateDesc IS NULL THEN N'; the Query Store state could not be read (needs READ_WRITE)'
                                  ELSE CONCAT(N'; Query Store is ', @QsStateDesc, N' (needs READ_WRITE)') END;

        SET @Data += CASE
            WHEN @CeFeedback IS NULL THEN N'CE feedback: NOT_AVAILABLE (it needs SQL Server 2022 or later, Azure SQL Database or Azure SQL Managed Instance).'
            WHEN @Blockers = N'' THEN CONCAT(N'CE feedback: can run for this database (CE_FEEDBACK ON, compatibility level ', @Compat, N', Query Store READ_WRITE).')
            ELSE CONCAT(N'CE feedback: cannot run for this database: ', STUFF(@Blockers, 1, 2, N''), N'.')
        END + @nl;

        SET @Data += CASE
            WHEN @CeExpressions IS NULL THEN N'CE feedback for expressions: NOT_AVAILABLE (it needs SQL Server 2025, Azure SQL Database, Azure SQL Managed Instance or SQL database in Microsoft Fabric).'
            WHEN @CeExpressions = 0 THEN N'CE feedback for expressions: OFF (CE_FEEDBACK_FOR_EXPRESSIONS).'
            WHEN @Compat < 160 THEN CONCAT(N'CE feedback for expressions: CE_FEEDBACK_FOR_EXPRESSIONS is ON, but compatibility level ', @Compat, N' is below 160, the minimum Microsoft''s feature page gives.')
            WHEN @Compat < 170 THEN CONCAT(N'CE feedback for expressions: ON (CE_FEEDBACK_FOR_EXPRESSIONS), at compatibility level ', @Compat, N'. Microsoft''s feature page gives 160 or later; its intelligent query processing overview lists 170 for Azure SQL Database.')
            ELSE N'CE feedback for expressions: ON (CE_FEEDBACK_FOR_EXPRESSIONS).'
        END + @nl;

        IF @QsUsable = 1
        BEGIN
            SET @Data += N'CE feedback rows by state (sys.query_store_plan_feedback):' + @nl
                + ISNULL((SELECT STRING_AGG(CAST(CONCAT(N'  ', state_desc, N': ', n) AS nvarchar(max)) COLLATE DATABASE_DEFAULT, NCHAR(10)) WITHIN GROUP (ORDER BY n DESC)
                          FROM (SELECT state_desc, COUNT(*) AS n FROM sys.query_store_plan_feedback WHERE feature_id = 1 GROUP BY state_desc) AS x), N'  none') + @nl;

            SET @Data += N'Query Store hints by source (sys.query_store_query_hints; source 0 is set by a user, others are system-generated):' + @nl
                + ISNULL((SELECT STRING_AGG(CAST(CONCAT(N'  ', ISNULL(source_desc, CONCAT(N'source ', source)), N': ', n, CASE WHEN n = 1 THEN N' hint, ' ELSE N' hints, ' END, f, N' failures to apply') AS nvarchar(max)) COLLATE DATABASE_DEFAULT, NCHAR(10)) WITHIN GROUP (ORDER BY source)
                          FROM (SELECT source, source_desc, COUNT(*) AS n, SUM(CAST(query_hint_failure_count AS bigint)) AS f FROM sys.query_store_query_hints GROUP BY source, source_desc) AS x), N'  none') + @nl;

            DECLARE @Recent nvarchar(max) = (
                SELECT STRING_AGG(CAST(CONCAT(N'  query_id ', query_id, N', plan_id ', plan_id, N': ', state_desc, N'; hints: ', hints,
                                         N'; last updated ', CONVERT(varchar(16), last_updated_time AT TIME ZONE 'UTC', 120), N' UTC',
                                         CASE WHEN @IncludeQueryText = 1 THEN N'; query: ' + AIIndexTuner.fn_CleanText(query_sql_text, 200) ELSE N'' END) AS nvarchar(max)) COLLATE DATABASE_DEFAULT, NCHAR(10))
                       WITHIN GROUP (ORDER BY last_updated_time DESC)
                FROM (SELECT TOP (20) p.query_id, pf.plan_id, pf.state_desc, pf.last_updated_time, qt.query_sql_text,
                             -- feedback_data is {"Feedback hints":"..."}; anything else is shown as it is.
                             ISNULL(NULLIF(COALESCE(CASE WHEN ISJSON(pf.feedback_data) = 1 THEN JSON_VALUE(pf.feedback_data, '$."Feedback hints"') END, pf.feedback_data), N''), N'none') AS hints
                      FROM sys.query_store_plan_feedback AS pf
                      INNER JOIN sys.query_store_plan AS p ON p.plan_id = pf.plan_id
                      INNER JOIN sys.query_store_query AS q ON q.query_id = p.query_id
                      INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
                      WHERE pf.feature_id = 1
                      ORDER BY pf.last_updated_time DESC) AS r);
            SET @Data += N'Most recent CE feedback rows (top 20):' + @nl + ISNULL(@Recent, N'  none') + @nl;
            IF @Recent IS NOT NULL
                SET @Data += N'  States: PENDING_VALIDATION and IN_VALIDATION, a different model assumption is waiting to be or being tested; VERIFICATION_PASSED, the tested assumption did better; FEEDBACK_VALID, the assumption is in use as a Query Store hint from CE feedback; VERIFICATION_REGRESSED, it was tried and not kept because the query ran worse; ROLLEDBACK_BY_APRC, automatic plan correction reverted it; NO_RECOMMENDATION, CE feedback found no alternative assumption to try.' + @nl;
        END;
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(N'The CE feedback settings could not be read: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== DEGREE OF PARALLELISM FEEDBACK ===== (AppendDopFeedbackSummaryAsync, issue #17)
       DOP feedback lowers the DOP of repeating parallel queries whose parallelism is inefficient. It is
       ON by default on SQL Server 2025. Unlike CE feedback, a plan forced through Query Store does not
       stop it; a MAXDOP query hint or Query Store hint does. On Managed Instance it needs the SQL Server
       2025 or Always-up-to-date update policy, and ProductUpdateType is 'CU' under both the SQL Server
       2022 policy (no DOP feedback) and the 2025 one, so only 'Continuous' confirms it. */
    SET @Data += CONCAT(@nl, N'=== DEGREE OF PARALLELISM FEEDBACK ===', @nl);
    DECLARE @UpdateType nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateType'));
    BEGIN TRY
        DECLARE @Dop int, @DopDefault int, @DopBlockers nvarchar(1000) = N'';
        SELECT @Compat = compatibility_level FROM sys.databases WHERE database_id = DB_ID();
        SELECT @Dop = MAX(CONVERT(int, value)), @DopDefault = MAX(CONVERT(int, is_value_default))
        FROM sys.database_scoped_configurations
        WHERE name = N'DOP_FEEDBACK';

        IF @Dop = 0
            SET @DopBlockers += CASE @DopDefault
                WHEN 1 THEN N'; DOP_FEEDBACK is OFF, its default on this version'
                WHEN 0 THEN N'; DOP_FEEDBACK was set OFF (not its default here, so it may have been turned off on purpose)'
                ELSE N'; DOP_FEEDBACK is OFF' END;
        IF @Compat < 160 SET @DopBlockers += CONCAT(N'; compatibility level is ', @Compat, N' (needs 160 or higher)');
        IF ISNULL(@QsStateDesc, N'') <> N'READ_WRITE'
            SET @DopBlockers += CASE WHEN @QsStateDesc IS NULL THEN N'; the Query Store state could not be read (needs READ_WRITE)'
                                     ELSE CONCAT(N'; Query Store is ', @QsStateDesc, N' (needs READ_WRITE)') END;

        SET @Data += CASE
            WHEN @Dop IS NULL THEN N'DOP feedback: NOT_AVAILABLE (it needs SQL Server 2022 or later, Azure SQL Database, SQL database in Microsoft Fabric, or Azure SQL Managed Instance with the SQL Server 2025 or Always-up-to-date update policy).'
            WHEN @EngineEdition = 8 AND ISNULL(@UpdateType, N'') <> N'Continuous'
                THEN CONCAT(N'DOP feedback: not confirmed for this database: on Azure SQL Managed Instance it needs the SQL Server 2025 or Always-up-to-date update policy, and this instance reports ProductUpdateType ',
                            ISNULL(@UpdateType, N'NULL'), N', which the SQL Server 2022 policy (no DOP feedback) and the SQL Server 2025 policy share, so check the instance''s update policy',
                            @DopBlockers, N'.')
            WHEN @DopBlockers = N'' THEN CONCAT(N'DOP feedback: ON and can run for this database (DOP_FEEDBACK ON, compatibility level ', @Compat, N', Query Store READ_WRITE).')
            ELSE CONCAT(N'DOP feedback: cannot run for this database: ', STUFF(@DopBlockers, 1, 2, N''), N'.')
        END + @nl;

        IF @Dop IS NOT NULL AND @QsUsable = 1
        BEGIN
            SET @Data += N'DOP feedback rows by state (sys.query_store_plan_feedback, feature_id 3):' + @nl
                + ISNULL((SELECT STRING_AGG(CAST(CONCAT(N'  ', state_desc, N': ', n) AS nvarchar(max)) COLLATE DATABASE_DEFAULT, NCHAR(10)) WITHIN GROUP (ORDER BY n DESC)
                          FROM (SELECT state_desc, COUNT(*) AS n FROM sys.query_store_plan_feedback WHERE feature_id = 3 GROUP BY state_desc) AS x), N'  none') + @nl;

            -- Microsoft documents feedback_data only for CE and memory grant feedback, so the DOP feedback
            -- value is shown as recorded.
            DECLARE @DopRecent nvarchar(max) = (
                SELECT STRING_AGG(CAST(CONCAT(N'  query_id ', query_id, N', plan_id ', plan_id, N': ', state_desc,
                                         N'; feedback_data: ', ISNULL(NULLIF(AIIndexTuner.fn_CleanText(feedback_data, 300), N''), N'none'),
                                         N'; last updated ', CONVERT(varchar(16), last_updated_time AT TIME ZONE 'UTC', 120), N' UTC',
                                         CASE WHEN @IncludeQueryText = 1 THEN N'; query: ' + AIIndexTuner.fn_CleanText(query_sql_text, 200) ELSE N'' END) AS nvarchar(max)) COLLATE DATABASE_DEFAULT, NCHAR(10))
                       WITHIN GROUP (ORDER BY last_updated_time DESC)
                FROM (SELECT TOP (20) p.query_id, pf.plan_id, pf.state_desc, pf.feedback_data, pf.last_updated_time, qt.query_sql_text
                      FROM sys.query_store_plan_feedback AS pf
                      INNER JOIN sys.query_store_plan AS p ON p.plan_id = pf.plan_id
                      INNER JOIN sys.query_store_query AS q ON q.query_id = p.query_id
                      INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
                      WHERE pf.feature_id = 3
                      ORDER BY pf.last_updated_time DESC) AS r);
            SET @Data += N'Most recent DOP feedback rows (top 20):' + @nl + ISNULL(@DopRecent, N'  none') + @nl;
            IF @DopRecent IS NOT NULL
                SET @Data += N'  DOP feedback keeps a row here only once a lower DOP is verified and stable; a regression, including a cancelled query, returns the query to its last known good DOP. The states are those of every feedback feature in sys.query_store_plan_feedback.' + @nl;
        END;
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(N'The DOP feedback settings could not be read: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== OPTIONAL PARAMETER PLAN OPTIMIZATION ===== (DescribeOptionalParameterOptimization, issue #17)
       OPPO gives a catch-all predicate such as (@p IS NULL OR col = @p) a query variant for each NULL state
       of the parameter, so the variant for a non-NULL value can seek an index the single scan plan could
       not use. Microsoft lists it for SQL Server 2025, Azure SQL Database and SQL database in Fabric, not
       for Azure SQL Managed Instance; it needs compatibility level 170 and OPTIONAL_PARAMETER_OPTIMIZATION
       ON, the default. */
    SET @Data += CONCAT(@nl, N'=== OPTIONAL PARAMETER PLAN OPTIMIZATION ===', @nl);
    BEGIN TRY
        DECLARE @Oppo int, @OppoBlockers nvarchar(1000) = N'';
        SELECT @Oppo = MAX(CONVERT(int, value))
        FROM sys.database_scoped_configurations
        WHERE name = N'OPTIONAL_PARAMETER_OPTIMIZATION';

        IF @Oppo = 0 SET @OppoBlockers += N'; OPTIONAL_PARAMETER_OPTIMIZATION is OFF';
        IF @Compat < 170 SET @OppoBlockers += CONCAT(N'; compatibility level is ', @Compat, N' (needs 170)');

        SET @Data += CASE
            WHEN @EngineEdition = 8
                THEN CONCAT(N'Optional parameter plan optimization (OPPO): NOT_AVAILABLE: Microsoft lists it for SQL Server 2025, Azure SQL Database or SQL database in Microsoft Fabric, not for Azure SQL Managed Instance',
                            CASE WHEN @Oppo IS NOT NULL THEN CONCAT(N' (OPTIONAL_PARAMETER_OPTIMIZATION reads ', CASE @Oppo WHEN 1 THEN N'ON' ELSE N'OFF' END, N' here)') ELSE N'' END, N'.')
            WHEN @Oppo IS NULL THEN N'Optional parameter plan optimization (OPPO): NOT_AVAILABLE (it needs SQL Server 2025, Azure SQL Database or SQL database in Microsoft Fabric).'
            WHEN @OppoBlockers = N'' THEN CONCAT(N'Optional parameter plan optimization (OPPO): ACTIVE (OPTIONAL_PARAMETER_OPTIMIZATION ON, compatibility level ', @Compat, N').')
            ELSE CONCAT(N'Optional parameter plan optimization (OPPO): NOT ACTIVE for this database: ', STUFF(@OppoBlockers, 1, 2, N''), N'.')
        END + @nl;

        IF @QsUsable = 1
            SET @Data += CONCAT(N'Query Store holds ', (SELECT COUNT(*) FROM sys.query_store_query_variant),
                                N' adaptive plan query variants (Parameter Sensitive Plan or OPPO). QUERY STORE WORKLOAD INSIGHTS counts each under its parent query, with the parent''s text, and the object scope of a scoped run covers both.', @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(N'The optional parameter plan optimization settings could not be read: ', ERROR_MESSAGE(), @nl);
    END CATCH;
END;
GO
