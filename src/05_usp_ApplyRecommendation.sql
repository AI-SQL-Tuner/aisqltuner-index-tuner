SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    AIIndexTuner.fn_IndexDefinition: the CREATE INDEX that puts an existing nonclustered index back as
    the catalog has it: keys, includes, filter, options, compression and filegroup or partition
    scheme. With @DropExisting = 1 it rebuilds an index of the same name in place
    (WITH DROP_EXISTING = ON). The UndoDDL of a drop and of a widening.
*/
CREATE OR ALTER FUNCTION AIIndexTuner.fn_IndexDefinition(@ObjectId int, @IndexId int, @DropExisting bit)
RETURNS nvarchar(max)
AS
BEGIN
    -- A variable, so the name takes the database collation and does not conflict with the catalog's.
    DECLARE @Target nvarchar(300) = QUOTENAME(OBJECT_SCHEMA_NAME(@ObjectId)) + N'.' + QUOTENAME(OBJECT_NAME(@ObjectId));
    RETURN (
        SELECT CONCAT(
            N'CREATE ', CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' END, N'NONCLUSTERED ', CASE WHEN i.type = 6 THEN N'COLUMNSTORE ' END,
            N'INDEX ', QUOTENAME(i.name COLLATE DATABASE_DEFAULT), N' ON ', @Target, N' (',
            CASE WHEN i.type = 6
                 THEN (SELECT STRING_AGG(CAST(QUOTENAME(c.name COLLATE DATABASE_DEFAULT) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ic.index_column_id)
                       FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                       WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id)
                 ELSE (SELECT STRING_AGG(CAST(QUOTENAME(c.name COLLATE DATABASE_DEFAULT) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END AS nvarchar(max)), N', ')
                              WITHIN GROUP (ORDER BY ic.key_ordinal)
                       FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                       WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0) END,
            N')',
            CASE WHEN i.type = 2 THEN
                (SELECT N' INCLUDE (' + STRING_AGG(CAST(QUOTENAME(c.name COLLATE DATABASE_DEFAULT) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ic.index_column_id) + N')'
                 FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1) END,
            CASE WHEN i.has_filter = 1 THEN N' WHERE ' + i.filter_definition COLLATE DATABASE_DEFAULT END,
            N' WITH (' + NULLIF(STUFF(CONCAT(
                CASE WHEN i.fill_factor > 0 THEN CONCAT(N', FILLFACTOR = ', i.fill_factor) END,
                CASE WHEN i.is_padded = 1 THEN N', PAD_INDEX = ON' END,
                CASE WHEN i.ignore_dup_key = 1 THEN N', IGNORE_DUP_KEY = ON' END,
                CASE WHEN i.type = 2 AND i.allow_row_locks = 0 THEN N', ALLOW_ROW_LOCKS = OFF' END,
                CASE WHEN i.type = 2 AND i.allow_page_locks = 0 THEN N', ALLOW_PAGE_LOCKS = OFF' END,
                CASE WHEN i.optimize_for_sequential_key = 1 THEN N', OPTIMIZE_FOR_SEQUENTIAL_KEY = ON' END,
                CASE WHEN p.data_compression_desc IN (N'ROW', N'PAGE', N'COLUMNSTORE_ARCHIVE') THEN N', DATA_COMPRESSION = ' + p.data_compression_desc COLLATE DATABASE_DEFAULT END,
                CASE WHEN @DropExisting = 1 THEN N', DROP_EXISTING = ON' END),
                1, 2, N''), N'') + N')',
            N' ON ', QUOTENAME(ds.name COLLATE DATABASE_DEFAULT),
            CASE WHEN ds.type = 'PS' THEN
                (SELECT N'(' + QUOTENAME(c.name COLLATE DATABASE_DEFAULT) + N')'
                 FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.partition_ordinal = 1) END,
            N';')
        FROM sys.indexes AS i
        INNER JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        OUTER APPLY (SELECT TOP (1) data_compression_desc FROM sys.partitions
                     WHERE object_id = i.object_id AND index_id = i.index_id ORDER BY partition_number) AS p
        WHERE i.object_id = @ObjectId AND i.index_id = @IndexId);
END;
GO

/*
    AIIndexTuner.usp_ApplyRecommendation

    Applies one stored CreateIndex or DropIndex recommendation, or a ConsolidateIndex one that
    widens an existing index. The model's own script is never
    executed: plan cache text goes into the prompt, so a crafted query could steer what the model
    writes. The DDL is built here from the structured fields, after every name is checked against
    the catalog, with QUOTENAME and an allow-list for each option.

    Change controls: the run's settings (sp_AIIndexTuner @AllowColumnstore, @AllowDropIndex,
    @MaxNewIndexes) are enforced here as well as in the prompt, in case the model ignores them. The
    caller can pass the same settings: 0 from either side blocks a change, and 1 from either side
    allows one that the other left NULL (recommend-only). @MaxNewIndexes uses the lower limit.

    Apply thresholds: @MinPriority and @MinConfidence (High, Medium or Low) skip a recommendation
    whose priority level or confidence is below them; one the model gave no level counts as Low.
    The caller's value replaces the run's (sp_AIIndexTuner @MinPriority, @MinConfidence), so a
    recommendation held back for review can be applied after it, with a lower minimum.

    Applied: new rowstore indexes; new columnstore indexes when allowed; drops of nonclustered
    indexes when allowed, nothing depends on them, and either another index makes them redundant
    or the usage statistics cover at least 7 days; and widenings. A widening is a ConsolidateIndex
    that names the index it replaces (ReplacesIndex): a nonclustered rowstore index that is not
    unique, not filtered, not partitioned and not disabled. The new index must keep its keys as
    its leading keys, in the same order and direction, and keep every column it includes. It is
    rebuilt in place under its own name (CREATE INDEX ... WITH (DROP_EXISTING = ON)), so nothing
    that names it breaks, and it counts as a new index for @MaxNewIndexes. Every other category,
    and any filtered index, is left for review. The outcome is written to the recommendation row: Applied (with the DDL and
    the DDL that reverses it), Skipped (with the reason) or Failed (with the error). Skipped and
    Failed recommendations can be applied again, for example with a setting that allows them.
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_ApplyRecommendation
    @RecommendationId int,
    @AllowColumnstore bit = NULL,
    @AllowDropIndex   bit = NULL,
    @MaxNewIndexes    int = NULL,
    @MinPriority      varchar(10) = NULL,
    @MinConfidence    varchar(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Category varchar(30), @Status varchar(20), @SchemaName sysname, @TableName sysname, @IndexName sysname,
            @IndexType varchar(30), @KeyColumns nvarchar(max), @IncludeColumns nvarchar(max), @Filter nvarchar(4000), @IsUnique bit,
            @FillFactor tinyint, @Compression varchar(10), @RunId int, @PriorityLevel varchar(10), @Confidence varchar(10),
            @ReplacesIndex sysname, @Script nvarchar(max),
            @RunColumnstore bit, @RunDropIndex bit, @RunMaxNew int, @RunMinPriority varchar(10), @RunMinConfidence varchar(10);

    SELECT @Category = r.Category, @Status = r.Status, @SchemaName = r.SchemaName, @TableName = r.TableName, @IndexName = r.IndexName,
           @IndexType = r.IndexType, @KeyColumns = r.KeyColumns, @IncludeColumns = r.IncludeColumns, @Filter = r.FilterPredicate,
           @IsUnique = r.IsUnique, @FillFactor = r.[FillFactor], @Compression = r.DataCompression, @RunId = r.RunId,
           @PriorityLevel = r.PriorityLevel, @Confidence = r.Confidence, @ReplacesIndex = NULLIF(LTRIM(r.ReplacesIndex), N''), @Script = r.Script,
           @RunColumnstore = run.AllowColumnstore, @RunDropIndex = run.AllowDropIndex, @RunMaxNew = run.MaxNewIndexes,
           @RunMinPriority = run.MinPriority, @RunMinConfidence = run.MinConfidence
    FROM AIIndexTuner.Recommendation AS r
    INNER JOIN AIIndexTuner.Run AS run ON run.RunId = r.RunId
    WHERE r.RecommendationId = @RecommendationId;

    IF @Category IS NULL
        THROW 50101, N'No recommendation with that RecommendationId.', 1;

    IF @Status = 'Applied'
        RETURN;

    -- The effective settings: 0 from either side wins, then 1 from either side; NULL is recommend-only.
    SELECT @AllowColumnstore = CASE WHEN @RunColumnstore = 0 OR @AllowColumnstore = 0 THEN 0
                                    WHEN @RunColumnstore = 1 OR @AllowColumnstore = 1 THEN 1 END,
           @AllowDropIndex = CASE WHEN @RunDropIndex = 0 OR @AllowDropIndex = 0 THEN 0
                                  WHEN @RunDropIndex = 1 OR @AllowDropIndex = 1 THEN 1 END,
           @MaxNewIndexes = CASE WHEN @RunMaxNew IS NULL THEN @MaxNewIndexes
                                 WHEN @MaxNewIndexes IS NULL OR @RunMaxNew < @MaxNewIndexes THEN @RunMaxNew
                                 ELSE @MaxNewIndexes END,
           @MinPriority = ISNULL(@MinPriority, @RunMinPriority),
           @MinConfidence = ISNULL(@MinConfidence, @RunMinConfidence);

    -- A widening builds a new index from the same fields as CreateIndex, under the replaced index's name.
    DECLARE @IsWidening bit = CASE WHEN @Category = 'ConsolidateIndex' AND @ReplacesIndex IS NOT NULL THEN 1 ELSE 0 END;
    SET @IndexType = CASE WHEN @Category = 'CreateIndex' OR @IsWidening = 1 THEN ISNULL(@IndexType, 'NONCLUSTERED') END;

    DECLARE @Reason nvarchar(4000) = NULL, @ObjectId int, @Ddl nvarchar(max), @Undo nvarchar(max),
            @IsColumnstore bit = CASE WHEN @IndexType LIKE '%COLUMNSTORE' THEN 1 ELSE 0 END,
            @Target nvarchar(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);

    /* ----- Validation: each failed check skips the recommendation with a reason ----- */
    IF @Category = 'ConsolidateIndex' AND @IsWidening = 0
        SET @Reason = N'ConsolidateIndex is applied only when it widens one existing index, and this one does not name the index it replaces (replaces_index). Review the script and apply it yourself.';
    ELSE IF @Category NOT IN ('CreateIndex', 'DropIndex', 'ConsolidateIndex')
        SET @Reason = CONCAT(N'Category ', @Category, N' is recommend-only; review the script and apply it yourself.');
    ELSE IF @IsWidening = 1 AND @IndexType <> 'NONCLUSTERED'
        SET @Reason = N'Only a nonclustered rowstore index is widened here; a columnstore index is recommended under CreateIndex.';
    -- The model's script is never run, but one that builds a clustered index means the fields describe something else.
    ELSE IF @IsWidening = 1 AND @Script LIKE N'%CREATE%[^N]CLUSTERED%INDEX%'
        SET @Reason = N'The script creates a clustered index, which is not a widening of a nonclustered one. Review it and apply it yourself.';
    ELSE IF @IsWidening = 1 AND @IsUnique = 1
        SET @Reason = N'A widening keeps the index non-unique; a unique index changes which rows the table accepts. Review it and apply it yourself.';
    ELSE IF @Category = 'DropIndex' AND @AllowDropIndex = 0
        SET @Reason = N'Index drops are not allowed (@AllowDropIndex = 0).';
    ELSE IF @Category = 'DropIndex' AND @AllowDropIndex IS NULL
        SET @Reason = CONCAT(N'Index drops are recommend-only for this run. Review it, then apply it with sp_AIIndexTuner_Apply @RecommendationId = ',
                             @RecommendationId, N', @AllowDropIndex = 1.');
    ELSE IF @IsColumnstore = 1 AND @AllowColumnstore = 0
        SET @Reason = N'Columnstore indexes are not allowed (@AllowColumnstore = 0).';
    ELSE IF @IsColumnstore = 1 AND @AllowColumnstore IS NULL
        SET @Reason = CONCAT(N'Columnstore indexes are recommend-only for this run. Review it, then apply it with sp_AIIndexTuner_Apply @RecommendationId = ',
                             @RecommendationId, N', @AllowColumnstore = 1.');
    ELSE IF ISNULL(AIIndexTuner.fn_LevelRank(@PriorityLevel), 1) < AIIndexTuner.fn_LevelRank(@MinPriority)
        SET @Reason = CONCAT(N'Priority level ', ISNULL(@PriorityLevel, N'(none)'), N' is below the minimum of ', @MinPriority,
                             N' (@MinPriority). Review it, then apply it with sp_AIIndexTuner_Apply @RecommendationId = ', @RecommendationId, N', @MinPriority = ''Low''.');
    ELSE IF ISNULL(AIIndexTuner.fn_LevelRank(@Confidence), 1) < AIIndexTuner.fn_LevelRank(@MinConfidence)
        SET @Reason = CONCAT(N'Confidence ', ISNULL(@Confidence, N'(none)'), N' is below the minimum of ', @MinConfidence,
                             N' (@MinConfidence). Review it, then apply it with sp_AIIndexTuner_Apply @RecommendationId = ', @RecommendationId, N', @MinConfidence = ''Low''.');
    ELSE IF @Category IN ('CreateIndex', 'ConsolidateIndex') AND @MaxNewIndexes IS NOT NULL
         AND (SELECT COUNT(*) FROM AIIndexTuner.Recommendation
              WHERE RunId = @RunId AND Category IN ('CreateIndex', 'ConsolidateIndex') AND Status = 'Applied') >= @MaxNewIndexes
        SET @Reason = CONCAT(N'The limit of ', @MaxNewIndexes, N' new index(es) for this run (@MaxNewIndexes) has been reached.');
    ELSE IF @Category IN ('CreateIndex', 'ConsolidateIndex') AND NULLIF(LTRIM(@Filter), N'') IS NOT NULL
        SET @Reason = N'Filtered indexes are recommend-only: the filter predicate is free text from the model. Review the script and apply it yourself.';
    ELSE IF @SchemaName IS NULL OR @TableName IS NULL
        SET @Reason = N'The recommendation does not name a schema and table.';
    ELSE
    BEGIN
        SET @ObjectId = OBJECT_ID(@Target, N'U');
        IF @ObjectId IS NULL
            SET @Reason = CONCAT(N'Table ', @Target, N' does not exist in this database.');
    END;

    /* ===== DropIndex ===== */
    IF @Category = 'DropIndex'
    BEGIN
        DECLARE @IndexId int, @Type tinyint, @TypeDesc nvarchar(60), @IsPk bit, @IsUq bit;

        IF @Reason IS NULL
        BEGIN
            SELECT @IndexId = index_id, @Type = type, @TypeDesc = type_desc, @IsPk = is_primary_key, @IsUq = is_unique_constraint
            FROM sys.indexes
            WHERE object_id = @ObjectId AND name = @IndexName;

            IF @IndexId IS NULL
                SET @Reason = CONCAT(N'Index ', QUOTENAME(@IndexName), N' does not exist on ', @Target, N'.');
            ELSE IF @Type NOT IN (2, 6)
                SET @Reason = CONCAT(N'Only nonclustered indexes are dropped here; ', QUOTENAME(@IndexName), N' is ', @TypeDesc, N'.');
            ELSE IF @IsPk = 1 OR @IsUq = 1
                SET @Reason = CONCAT(QUOTENAME(@IndexName), N' enforces a primary key or unique constraint.');
            ELSE IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE referenced_object_id = @ObjectId AND key_index_id = @IndexId)
                SET @Reason = CONCAT(N'A foreign key references ', QUOTENAME(@IndexName), N'.');
        END;

        -- Anything that names the index would break when it is gone: index hints in modules, plan
        -- guides and Query Store hints, and Query Store plans forced with it (a NO_INDEX failure).
        IF @Reason IS NULL
        BEGIN
            DECLARE @Like nvarchar(1000) = N'%' + AIIndexTuner.fn_EscapeLike(@IndexName) + N'%',
                    @PlanLike nvarchar(1000) = N'%Index="' + AIIndexTuner.fn_EscapeLike(QUOTENAME(@IndexName)) + N'"%',
                    @Ref nvarchar(400);
            BEGIN TRY
                SELECT TOP (1) @Ref = N'module ' + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(OBJECT_NAME(object_id))
                FROM sys.sql_modules WHERE definition LIKE @Like ESCAPE N'\';
                IF @Ref IS NULL
                    SELECT TOP (1) @Ref = N'plan guide ' + QUOTENAME(name)
                    FROM sys.plan_guides WHERE is_disabled = 0 AND hints LIKE @Like ESCAPE N'\';
                IF @Ref IS NULL
                    SELECT TOP (1) @Ref = CONCAT(N'the Query Store hint on query_id ', query_id)
                    FROM sys.query_store_query_hints WHERE query_hint_text LIKE @Like ESCAPE N'\';
                IF @Ref IS NULL
                    SELECT TOP (1) @Ref = CONCAT(N'the forced Query Store plan_id ', plan_id, N' (query_id ', query_id, N')')
                    FROM sys.query_store_plan WHERE is_forced_plan = 1 AND query_plan LIKE @PlanLike ESCAPE N'\';
                IF @Ref IS NOT NULL
                    SET @Reason = CONCAT(QUOTENAME(@IndexName), N' is named by ', @Ref, N', which would fail without it.');
            END TRY
            BEGIN CATCH
                SET @Reason = CONCAT(N'Could not check what references ', QUOTENAME(@IndexName), N': ', ERROR_MESSAGE());
            END CATCH;
        END;

        -- Why it can go. Either another index makes it redundant: it has the same leading keys,
        -- covers the includes and filter, and keeps any uniqueness, so nothing is lost however short
        -- the usage history. Or it is little used, which the usage DMVs show only over enough time,
        -- so a low-use drop needs at least @MinUsageDays of usage statistics.
        DECLARE @Basis nvarchar(4000), @MinUsageDays int = 7;
        IF @Reason IS NULL
        BEGIN
            DECLARE @Redundant sysname, @Sig nvarchar(max), @DropUnique bit, @DropFilter nvarchar(max);
            SELECT @DropUnique = is_unique, @DropFilter = filter_definition FROM sys.indexes WHERE object_id = @ObjectId AND index_id = @IndexId;
            SET @Sig = (SELECT STRING_AGG(CONCAT(column_id, CASE WHEN is_descending_key = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY key_ordinal)
                        FROM sys.index_columns WHERE object_id = @ObjectId AND index_id = @IndexId AND key_ordinal > 0);

            IF @Type = 2
                SELECT TOP (1) @Redundant = i.name
                FROM sys.indexes AS i
                CROSS APPLY (SELECT STRING_AGG(CONCAT(ic.column_id, CASE WHEN ic.is_descending_key = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS sig
                             FROM sys.index_columns AS ic
                             WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0) AS k
                WHERE i.object_id = @ObjectId AND i.index_id <> @IndexId AND i.type IN (1, 2) AND i.is_disabled = 0 AND i.is_hypothetical = 0
                  AND (i.has_filter = 0 OR i.filter_definition = @DropFilter)
                  AND (k.sig = @Sig OR LEFT(k.sig, LEN(@Sig) + 1) = @Sig + ',')
                  AND (@DropUnique = 0 OR (i.is_unique = 1 AND k.sig = @Sig))
                  AND (i.type = 1   -- the clustered index covers every column
                       OR NOT EXISTS (SELECT 1 FROM sys.index_columns AS inc
                                      WHERE inc.object_id = @ObjectId AND inc.index_id = @IndexId AND inc.is_included_column = 1
                                        AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic
                                                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.column_id = inc.column_id)))
                ORDER BY i.index_id;

            IF @Redundant IS NOT NULL
                SET @Basis = CONCAT(N'Redundant: ', QUOTENAME(@Redundant), N' has the same leading keys and covers it.');
            ELSE
            BEGIN
                DECLARE @Since datetime2(0), @SinceSource nvarchar(400), @ErrorLogsSearched int, @HasInstanceLogs bit;
                BEGIN TRY
                    EXEC AIIndexTuner.usp_UsageSince @Since = @Since OUTPUT, @SinceSource = @SinceSource OUTPUT,
                                                     @ErrorLogsSearched = @ErrorLogsSearched OUTPUT, @HasInstanceLogs = @HasInstanceLogs OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @Since = NULL;
                END CATCH;

                IF @Since IS NULL
                    SET @Reason = CONCAT(N'No other index covers ', QUOTENAME(@IndexName), N', and the period the usage statistics cover is unknown, so it is not dropped for low use.');
                -- Without the error log, a reset after the times above (an ONLINE after OFFLINE, a
                -- snapshot revert, an AUTO_CLOSE reopen) would not show, so the period may be shorter.
                ELSE IF @HasInstanceLogs = 1 AND @ErrorLogsSearched = 0
                    SET @Reason = CONCAT(N'No other index covers ', QUOTENAME(@IndexName), N', and the error log could not be read (that needs securityadmin or sysadmin, ',
                                         N'and does not work inside INSERT ... EXEC), so the period the usage statistics cover cannot be confirmed for a low-use drop.');
                ELSE IF @Since > DATEADD(DAY, -@MinUsageDays, SYSDATETIME())
                    SET @Reason = CONCAT(N'No other index covers ', QUOTENAME(@IndexName), N', and the usage statistics cover only ',
                                         AIIndexTuner.fn_FormatUptime(DATEDIFF(MINUTE, @Since, SYSDATETIME())), N' (since ', CONVERT(varchar(19), @Since, 120),
                                         N', from ', @SinceSource, N'). An index is dropped for low use only after at least ', @MinUsageDays, N' days of them.');
                ELSE
                    SET @Basis = CONCAT(N'Low use over ', AIIndexTuner.fn_FormatUptime(DATEDIFF(MINUTE, @Since, SYSDATETIME())), N' of usage statistics (since ',
                                        CONVERT(varchar(19), @Since, 120), N').');
            END;
        END;

        IF @Reason IS NOT NULL
        BEGIN
            UPDATE AIIndexTuner.Recommendation SET Status = 'Skipped', StatusReason = @Reason WHERE RecommendationId = @RecommendationId;
            RETURN;
        END;

        -- The CREATE that puts the index back, from the catalog.
        SET @Undo = AIIndexTuner.fn_IndexDefinition(@ObjectId, @IndexId, 0);

        SET @Ddl = CONCAT(N'DROP INDEX ', QUOTENAME(@IndexName), N' ON ', @Target, N';');

        BEGIN TRY
            EXEC sys.sp_executesql @Ddl;
        END TRY
        BEGIN CATCH
            UPDATE AIIndexTuner.Recommendation
            SET Status = 'Failed', StatusReason = ERROR_MESSAGE(), AppliedDDL = @Ddl
            WHERE RecommendationId = @RecommendationId;
            RETURN;
        END CATCH;

        UPDATE AIIndexTuner.Recommendation
        SET Status = 'Applied', StatusReason = @Basis, AppliedDDL = @Ddl, UndoDDL = @Undo,
            AppliedAt = SYSDATETIME(), AppliedBy = ORIGINAL_LOGIN()
        WHERE RecommendationId = @RecommendationId;
        RETURN;
    END;

    /* ===== CreateIndex ===== */
    DECLARE @Keys TABLE (ordinal int PRIMARY KEY, column_name nvarchar(4000), is_descending bit, column_id int);
    DECLARE @Includes TABLE (ordinal int PRIMARY KEY, column_name nvarchar(4000), column_id int);

    -- A clustered columnstore index takes every column, so its column lists are not used.
    IF @Reason IS NULL AND @IndexType <> 'CLUSTERED COLUMNSTORE'
    BEGIN
        IF ISJSON(@KeyColumns) = 0 OR ISJSON(ISNULL(@IncludeColumns, N'[]')) = 0
            SET @Reason = N'The key or include column list is not valid JSON.';
        ELSE
        BEGIN
            INSERT @Keys (ordinal, column_name, is_descending)
            SELECT CAST(k.[key] AS int), JSON_VALUE(k.value, '$.column'), ISNULL(CAST(JSON_VALUE(k.value, '$.descending') AS bit), 0)
            FROM OPENJSON(@KeyColumns) AS k;

            INSERT @Includes (ordinal, column_name)
            SELECT CAST(i.[key] AS int), i.value
            FROM OPENJSON(ISNULL(@IncludeColumns, N'[]')) AS i;

            -- A nonclustered columnstore index has one column list: keys, then any includes.
            IF @IsColumnstore = 1
            BEGIN
                INSERT @Keys (ordinal, column_name, is_descending)
                SELECT 10000 + ordinal, column_name, 0 FROM @Includes;
                DELETE @Includes;
            END;

            -- Exact catalog names only: no brackets, no expressions.
            UPDATE k SET column_id = c.column_id
            FROM @Keys AS k INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.name = k.column_name;
            UPDATE i SET column_id = c.column_id
            FROM @Includes AS i INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.name = i.column_name;

            IF NOT EXISTS (SELECT 1 FROM @Keys)
                SET @Reason = N'The recommendation has no key columns.';
            ELSE IF @IsColumnstore = 0 AND (SELECT COUNT(*) FROM @Keys) > 32
                SET @Reason = N'More than 32 key columns.';
            ELSE IF (SELECT COUNT(*) FROM @Keys) > 1024
                SET @Reason = N'More than 1024 columns.';
            ELSE IF EXISTS (SELECT 1 FROM @Keys WHERE column_id IS NULL) OR EXISTS (SELECT 1 FROM @Includes WHERE column_id IS NULL)
                SET @Reason = CONCAT(N'Unknown column(s) on ', @Target, N': ',
                    (SELECT STRING_AGG(column_name, N', ') FROM (SELECT column_name FROM @Keys WHERE column_id IS NULL
                                                                 UNION ALL SELECT column_name FROM @Includes WHERE column_id IS NULL) AS u), N'.');
            ELSE IF EXISTS (SELECT column_id FROM @Keys GROUP BY column_id HAVING COUNT(*) > 1)
                 OR EXISTS (SELECT column_id FROM @Includes GROUP BY column_id HAVING COUNT(*) > 1)
                 OR EXISTS (SELECT 1 FROM @Keys AS k INNER JOIN @Includes AS i ON i.column_id = k.column_id)
                SET @Reason = N'A column appears more than once in the key and include lists.';
        END;
    END;

    IF @Reason IS NULL AND @IsColumnstore = 1
    BEGIN
        DECLARE @Columnstore sysname = (SELECT TOP (1) name FROM sys.indexes WHERE object_id = @ObjectId AND type IN (5, 6));
        IF @Columnstore IS NOT NULL
            SET @Reason = CONCAT(N'The table already has columnstore index ', QUOTENAME(@Columnstore), N', and a table can have only one.');
        ELSE IF @IndexType = 'CLUSTERED COLUMNSTORE' AND EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = @ObjectId AND type = 1)
            SET @Reason = N'The table has a clustered rowstore index. Converting it to clustered columnstore replaces that index and any primary key on it, so it is recommend-only.';
    END;

    -- A widening: the replaced index must be a plain nonclustered rowstore index, and the new one must keep
    -- its keys as its leading keys and every column it includes, so no query it served loses anything.
    DECLARE @OldId int, @OldFilegroup sysname;
    IF @Reason IS NULL AND @IsWidening = 1
    BEGIN
        DECLARE @OldType tinyint, @OldTypeDesc nvarchar(60), @OldUnique bit, @OldFilter bit, @OldDisabled bit, @OldSpaceType char(2),
                @OldSig nvarchar(max), @NewSig nvarchar(max), @Lost nvarchar(max);

        SELECT @OldId = i.index_id, @OldType = i.type, @OldTypeDesc = i.type_desc, @OldUnique = i.is_unique, @OldFilter = i.has_filter,
               @OldDisabled = i.is_disabled, @OldSpaceType = ds.type, @OldFilegroup = ds.name
        FROM sys.indexes AS i
        INNER JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        WHERE i.object_id = @ObjectId AND i.name = @ReplacesIndex;

        SET @OldSig = (SELECT STRING_AGG(CONCAT(column_id, CASE WHEN is_descending_key = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY key_ordinal)
                       FROM sys.index_columns WHERE object_id = @ObjectId AND index_id = @OldId AND key_ordinal > 0);
        SET @NewSig = (SELECT STRING_AGG(CONCAT(column_id, CASE WHEN is_descending = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY ordinal) FROM @Keys);
        SET @Lost = (SELECT STRING_AGG(c.name, N', ') WITHIN GROUP (ORDER BY ic.index_column_id)
                     FROM sys.index_columns AS ic INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                     WHERE ic.object_id = @ObjectId AND ic.index_id = @OldId AND ic.is_included_column = 1
                       AND NOT EXISTS (SELECT 1 FROM @Keys AS k WHERE k.column_id = ic.column_id)
                       AND NOT EXISTS (SELECT 1 FROM @Includes AS inc WHERE inc.column_id = ic.column_id));

        IF @OldId IS NULL
            SET @Reason = CONCAT(N'Index ', QUOTENAME(@ReplacesIndex), N', which the recommendation widens, does not exist on ', @Target, N'.');
        ELSE IF @OldType <> 2
            SET @Reason = CONCAT(N'Only a nonclustered rowstore index is widened here; ', QUOTENAME(@ReplacesIndex), N' is ', @OldTypeDesc, N'.');
        ELSE IF @OldUnique = 1
            SET @Reason = CONCAT(QUOTENAME(@ReplacesIndex), N' is unique or enforces a constraint, so widening it is left for review.');
        ELSE IF @OldFilter = 1
            SET @Reason = CONCAT(QUOTENAME(@ReplacesIndex), N' is filtered, so widening it is left for review.');
        ELSE IF @OldDisabled = 1
            SET @Reason = CONCAT(QUOTENAME(@ReplacesIndex), N' is disabled, so widening it is left for review.');
        ELSE IF @OldSpaceType <> 'FG'
            SET @Reason = CONCAT(QUOTENAME(@ReplacesIndex), N' is partitioned, so widening it is left for review.');
        ELSE IF NOT (@NewSig = @OldSig OR LEFT(@NewSig, LEN(@OldSig) + 1) = @OldSig + ',')
            SET @Reason = CONCAT(N'The new keys do not start with the keys of ', QUOTENAME(@ReplacesIndex),
                                 N' in the same order and direction, so this is not a widening. Review the script and apply it yourself.');
        ELSE IF @Lost IS NOT NULL
            SET @Reason = CONCAT(N'The new index leaves out column(s) that ', QUOTENAME(@ReplacesIndex), N' includes: ', @Lost,
                                 N'. Review the script and apply it yourself.');
    END;

    -- An existing index with the same leading keys that already covers the includes makes this one redundant.
    -- For a widening that adds nothing, that index is the one it would replace.
    IF @Reason IS NULL AND @IsColumnstore = 0
    BEGIN
        DECLARE @KeySig nvarchar(max) = (SELECT STRING_AGG(CONCAT(column_id, CASE WHEN is_descending = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY ordinal) FROM @Keys);
        DECLARE @Covering sysname;

        SELECT TOP (1) @Covering = i.name
        FROM sys.indexes AS i
        CROSS APPLY (SELECT STRING_AGG(CONCAT(ic.column_id, CASE WHEN ic.is_descending_key = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS sig
                     FROM sys.index_columns AS ic
                     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0 AND ic.key_ordinal > 0) AS k
        WHERE i.object_id = @ObjectId AND i.type IN (1, 2) AND i.is_disabled = 0 AND i.is_hypothetical = 0 AND i.has_filter = 0
          AND (k.sig = @KeySig OR LEFT(k.sig, LEN(@KeySig) + 1) = @KeySig + ',')
          AND (i.type = 1   -- the clustered index covers every column
               OR NOT EXISTS (SELECT 1 FROM @Includes AS inc
                              WHERE NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic
                                                WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.column_id = inc.column_id)));

        IF @Covering IS NOT NULL
            SET @Reason = CONCAT(N'Existing index ', QUOTENAME(@Covering), N' already has these leading keys and covers the included columns.');
    END;

    -- Name: a widening keeps the replaced index's, so hints and plans that name it still work.
    DECLARE @Note nvarchar(4000) = NULL;
    IF @Reason IS NULL AND @IsWidening = 1
    BEGIN
        SET @Note = CONCAT(N'Widened ', QUOTENAME(@ReplacesIndex), N' in place, keeping its keys and included columns.',
                           CASE WHEN NULLIF(LTRIM(@IndexName), N'') IS NOT NULL AND @IndexName <> @ReplacesIndex
                                THEN CONCAT(N' The recommendation named the new index ', QUOTENAME(@IndexName), N'; it keeps the name of the index it replaces.') END);
        SET @IndexName = @ReplacesIndex;
    END;

    -- Otherwise the model's name when it is free, or a generated one.
    IF @Reason IS NULL AND @IsWidening = 0
    BEGIN
        IF NULLIF(LTRIM(@IndexName), N'') IS NULL OR LEN(@IndexName) > 128
            SET @IndexName = LEFT(CONCAT(CASE @IndexType WHEN 'NONCLUSTERED COLUMNSTORE' THEN N'NCCI' WHEN 'CLUSTERED COLUMNSTORE' THEN N'CCI' ELSE N'IX' END,
                                         N'_AIT_', @TableName, N'_', @RecommendationId), 128);

        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = @ObjectId AND name = @IndexName)
            SET @Reason = CONCAT(N'An index named ', QUOTENAME(@IndexName), N' already exists on the table.');
    END;

    IF @Reason IS NOT NULL
    BEGIN
        UPDATE AIIndexTuner.Recommendation SET Status = 'Skipped', StatusReason = @Reason WHERE RecommendationId = @RecommendationId;
        RETURN;
    END;

    /* ----- Build the DDL from validated parts ----- */
    DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int),
            @Options nvarchar(400) = CASE WHEN @IsWidening = 1 THEN N', DROP_EXISTING = ON' ELSE N'' END;

    -- Online index operations: Enterprise (and Developer), Azure SQL Database and Managed Instance.
    -- With DROP_EXISTING, the old index keeps serving queries until the new one is built.
    IF @EngineEdition IN (3, 5, 8)
        SET @Options += N', ONLINE = ON';
    IF @IsColumnstore = 0 AND @FillFactor BETWEEN 1 AND 100
        SET @Options += CONCAT(N', FILLFACTOR = ', @FillFactor);
    IF @IsColumnstore = 0 AND @Compression IN ('NONE', 'ROW', 'PAGE')
        SET @Options += CONCAT(N', DATA_COMPRESSION = ', @Compression);

    SET @Ddl = CONCAT(
        N'CREATE ',
        CASE @IndexType WHEN 'CLUSTERED COLUMNSTORE' THEN N'CLUSTERED COLUMNSTORE'
                        WHEN 'NONCLUSTERED COLUMNSTORE' THEN N'NONCLUSTERED COLUMNSTORE'
                        ELSE CASE WHEN @IsUnique = 1 THEN N'UNIQUE ' ELSE N'' END + N'NONCLUSTERED' END,
        N' INDEX ', QUOTENAME(@IndexName), N' ON ', @Target,
        CASE WHEN @IndexType <> 'CLUSTERED COLUMNSTORE' THEN
            N' (' + (SELECT STRING_AGG(QUOTENAME(c.name) + CASE WHEN @IsColumnstore = 1 THEN N'' WHEN k.is_descending = 1 THEN N' DESC' ELSE N' ASC' END, N', ')
                            WITHIN GROUP (ORDER BY k.ordinal)
                     FROM @Keys AS k INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.column_id = k.column_id) + N')' END,
        CASE WHEN EXISTS (SELECT 1 FROM @Includes)
             THEN N' INCLUDE (' + (SELECT STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY i.ordinal)
                                   FROM @Includes AS i INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.column_id = i.column_id) + N')'
             ELSE N'' END,
        CASE WHEN @Options <> N'' THEN N' WITH (' + STUFF(@Options, 1, 2, N'') + N')' ELSE N'' END,
        CASE WHEN @IsWidening = 1 THEN N' ON ' + QUOTENAME(@OldFilegroup) ELSE N'' END,
        N';');
    -- A new index is undone by dropping it; a widening by rebuilding the old definition in place.
    SET @Undo = CASE WHEN @IsWidening = 1 THEN AIIndexTuner.fn_IndexDefinition(@ObjectId, @OldId, 1)
                     ELSE CONCAT(N'DROP INDEX ', QUOTENAME(@IndexName), N' ON ', @Target, N';') END;

    BEGIN TRY
        EXEC sys.sp_executesql @Ddl;
    END TRY
    BEGIN CATCH
        UPDATE AIIndexTuner.Recommendation
        SET Status = 'Failed', StatusReason = ERROR_MESSAGE(), AppliedDDL = @Ddl
        WHERE RecommendationId = @RecommendationId;
        RETURN;
    END CATCH;

    -- Tag the index so it can be found and rolled back later. A widened index existed before, so its tag
    -- says so: it is rolled back with its UndoDDL, not dropped. The index exists either way, so a tagging
    -- failure is noted but does not mark the recommendation Failed.
    BEGIN TRY
        DECLARE @Tag sql_variant = CONCAT(CASE WHEN @IsWidening = 1 THEN N'Widened' ELSE N'Created' END, N' by aisqltuner-index-tuner, run ', @RunId,
                                          N', recommendation ', @RecommendationId, N', ', CONVERT(varchar(19), SYSDATETIME(), 120));
        IF EXISTS (SELECT 1 FROM sys.extended_properties AS ep INNER JOIN sys.indexes AS i ON i.object_id = ep.major_id AND i.index_id = ep.minor_id
                   WHERE ep.class = 7 AND ep.name = N'AIIndexTuner' AND i.object_id = @ObjectId AND i.name = @IndexName)
            EXEC sys.sp_updateextendedproperty
                @name = N'AIIndexTuner', @value = @Tag,
                @level0type = N'SCHEMA', @level0name = @SchemaName,
                @level1type = N'TABLE', @level1name = @TableName,
                @level2type = N'INDEX', @level2name = @IndexName;
        ELSE
            EXEC sys.sp_addextendedproperty
                @name = N'AIIndexTuner', @value = @Tag,
                @level0type = N'SCHEMA', @level0name = @SchemaName,
                @level1type = N'TABLE', @level1name = @TableName,
                @level2type = N'INDEX', @level2name = @IndexName;
    END TRY
    BEGIN CATCH
        SET @Note = CONCAT(@Note + N' ', N'Index ', CASE WHEN @IsWidening = 1 THEN N'widened' ELSE N'created' END, N', but tagging it failed: ', ERROR_MESSAGE());
    END CATCH;

    UPDATE AIIndexTuner.Recommendation
    SET Status = 'Applied', StatusReason = @Note, IndexName = @IndexName, IndexType = @IndexType, AppliedDDL = @Ddl, UndoDDL = @Undo,
        AppliedAt = SYSDATETIME(), AppliedBy = ORIGINAL_LOGIN()
    WHERE RecommendationId = @RecommendationId;
END;
GO
