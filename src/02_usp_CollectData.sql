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

    Not collected yet (the full product's IndexTuning goal has them): Query Store workload, write
    mix and forced plan failures, index page density, index operational hotspots, automatic tuning
    options, CE feedback, OPTIMIZED_SP_EXECUTESQL settings, and the error-log part of
    "Database Usage Statistics Since".
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

    /* Start time and the period the usage DMVs cover. */
    DECLARE @StartTime datetime2(0), @Now datetime2(0) = SYSDATETIME(), @CreateDate datetime2(0),
            @LastRestore datetime2(0), @Since datetime2(0), @SinceSource nvarchar(400);

    BEGIN TRY
        SELECT @StartTime = sqlserver_start_time FROM sys.dm_os_sys_info;
    END TRY
    BEGIN CATCH
        SET @StartTime = NULL;
    END CATCH;

    SELECT @CreateDate = create_date FROM sys.databases WHERE database_id = DB_ID();

    IF @EngineEdition NOT IN (5, 12)   -- Azure SQL Database and Fabric have no msdb restore history
    BEGIN
        BEGIN TRY
            SELECT @LastRestore = MAX(restore_date) FROM msdb.dbo.restorehistory WHERE destination_database_name = DB_NAME();
        END TRY
        BEGIN CATCH
            SET @LastRestore = NULL;
        END CATCH;
    END;

    -- Later candidates win ties, matching the C# collector's order.
    IF @StartTime IS NOT NULL SELECT @Since = @StartTime, @SinceSource = N'the SQL Server start time, the latest reset found';
    IF @CreateDate IS NOT NULL AND (@Since IS NULL OR @CreateDate >= @Since)
        SELECT @Since = @CreateDate, @SinceSource = N'its create date in sys.databases, which an attach or a restore under a new name sets';
    IF @LastRestore IS NOT NULL AND (@Since IS NULL OR @LastRestore >= @Since)
        SELECT @Since = @LastRestore, @SinceSource = N'its latest restore in msdb.dbo.restorehistory';

    DECLARE @UptimeMin int = DATEDIFF(MINUTE, @StartTime, @Now),
            @SinceMin int = DATEDIFF(MINUTE, @Since, @Now);

    SET @Data += CASE WHEN @StartTime IS NOT NULL
        THEN CONCAT(N'SQL Server Start Time: ', CONVERT(varchar(19), @StartTime, 120), N' (server local time); uptime ',
                    @UptimeMin / 1440, N' days ', (@UptimeMin % 1440) / 60, N' hours ', @UptimeMin % 60, N' minutes. ',
                    @RestartCleared, N' cover only this period, because SQL Server clears them when it restarts.', @nl)
        ELSE CONCAT(N'SQL Server Start Time: unknown (reading it needs VIEW SERVER STATE), so how long ', LOWER(@RestartCleared), N' have been accumulating is unknown.', @nl)
    END;

    SET @Data += CASE WHEN @Since IS NOT NULL
        THEN CONCAT(N'Database Usage Statistics Since: ', CONVERT(varchar(19), @Since, 120), N' (server local time), ',
                    @SinceMin / 1440, N' days ', (@SinceMin % 1440) / 60, N' hours ', @SinceMin % 60, N' minutes ago, from ', @SinceSource, N'. ',
                    @RestartCleared, N' for this database cover only this period. ',
                    N'The SQL Server error log was not searched, so a database snapshot revert, an ONLINE after OFFLINE or an AUTO_CLOSE reopen since then would not be seen; the statistics may cover less than this period.', @nl)
        ELSE CONCAT(N'Database Usage Statistics Since: unknown; when this database was last started could not be read.', @nl)
    END;

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
            ELSE N'' END);

    IF @SchemaName IS NOT NULL AND @TableName IS NOT NULL
        SET @Data += CONCAT(N'Object-scoped analysis is limited to table: ', QUOTENAME(@SchemaName), N'.', QUOTENAME(@TableName), N'. Plan cache and database-level sections remain database-scoped.', @nl);
    ELSE IF @SchemaName IS NOT NULL
        SET @Data += CONCAT(N'Object-scoped analysis is limited to schema: ', QUOTENAME(@SchemaName), N'. Plan cache and database-level sections remain database-scoped.', @nl);

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

    /* ===== MISSING INDEX RECOMMENDATIONS ===== */
    BEGIN TRY
        SET @j = (
            SELECT TOP (50)
                s.name + N'.' + o.name AS TableName,
                CASE WHEN LEN(d.equality_columns) > 200 THEN LEFT(d.equality_columns, 200) + N'...' ELSE d.equality_columns END AS EqualityColumns,
                CASE WHEN LEN(d.inequality_columns) > 200 THEN LEFT(d.inequality_columns, 200) + N'...' ELSE d.inequality_columns END AS InequalityColumns,
                CASE WHEN LEN(d.included_columns) > 200 THEN LEFT(d.included_columns, 200) + N'...' ELSE d.included_columns END AS IncludedColumns,
                CAST(st.avg_total_user_cost AS decimal(18, 2)) AS AvgTotalUserCost,
                CAST(st.avg_user_impact AS decimal(5, 2)) AS AvgUserImpactPct,
                st.user_seeks + st.user_scans AS TotalSeeksScans,
                CAST(st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) AS decimal(38, 0)) AS ImpactScore
            FROM sys.dm_db_missing_index_details AS d
            INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
            INNER JOIN sys.dm_db_missing_index_group_stats AS st ON g.index_group_handle = st.group_handle
            INNER JOIN sys.objects AS o ON d.object_id = o.object_id
            INNER JOIN sys.schemas AS s ON o.schema_id = s.schema_id
            WHERE d.database_id = DB_ID()
              AND st.avg_total_user_cost * st.avg_user_impact * (st.user_seeks + st.user_scans) > 100000
              AND s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName)
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
              AND sch.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR sch.name = @SchemaName)
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
              AND s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName)
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
              AND s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName)
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
              AND (st.objectid IS NULL OR OBJECT_SCHEMA_NAME(st.objectid, st.dbid) IS NULL OR OBJECT_SCHEMA_NAME(st.objectid, st.dbid) <> N'AIIndexTuner')
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
        WHERE s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName)
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
              AND SCHEMA_NAME(t.schema_id) <> N'AIIndexTuner' AND (@SchemaName IS NULL OR SCHEMA_NAME(t.schema_id) = @SchemaName)
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
                  AND s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName) AND (@TableName IS NULL OR o.name = @TableName)
                UNION ALL
                SELECT SCHEMA_NAME(o.schema_id) + N'.' + o.name, cc.name, 'CHECK', cc.is_not_trusted, cc.is_disabled
                FROM sys.check_constraints AS cc
                INNER JOIN sys.objects AS o ON o.object_id = cc.parent_object_id
                INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
                WHERE (cc.is_not_trusted = 1 OR cc.is_disabled = 1)
                  AND s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName) AND (@TableName IS NULL OR o.name = @TableName)
            ) AS u
            ORDER BY u.TableName, u.ConstraintName
            FOR JSON PATH);
        SET @Data += CONCAT(@nl, N'=== UNTRUSTED OR DISABLED CONSTRAINTS ===', @nl, ISNULL(@j, N'(none)'), @nl);
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== UNTRUSTED OR DISABLED CONSTRAINTS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;

    /* ===== COLUMN CARDINALITY =====
       Density vectors for the tables behind the top 20 high-impact missing indexes and the 20 largest
       tables over 10,000 rows (plus the scoped table), via DBCC SHOW_STATISTICS ... WITH DENSITY_VECTOR. */
    BEGIN TRY
        CREATE TABLE #RawDensity (AllDensity float, AvgLength float, Columns nvarchar(4000));
        CREATE TABLE #Density (TableName nvarchar(300), AllDensity float, AvgLength float, Columns nvarchar(4000));

        DECLARE @StatsTable nvarchar(300), @StatsName sysname, @sql nvarchar(max), @CardinalityErrors int = 0;

        DECLARE stats_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(s.object_id)), s.name
            FROM sys.stats AS s
            INNER JOIN sys.objects AS o ON s.object_id = o.object_id
            WHERE o.type = 'U'
              AND OBJECT_SCHEMA_NAME(s.object_id) <> N'AIIndexTuner' AND (@SchemaName IS NULL OR OBJECT_SCHEMA_NAME(s.object_id) = @SchemaName)
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
            WHERE s.name <> N'AIIndexTuner' AND (@SchemaName IS NULL OR s.name = @SchemaName) AND (@TableName IS NULL OR t.name = @TableName)
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
    END TRY
    BEGIN CATCH
        SET @Data += CONCAT(@nl, N'=== DATABASE STATISTICS SETTINGS ===', @nl, N'Warning: section skipped: ', ERROR_MESSAGE(), @nl);
    END CATCH;
END;
GO
