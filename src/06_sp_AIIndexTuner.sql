SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    dbo.sp_AIIndexTuner: AI-assisted index tuning from inside SQL Server.

        EXEC dbo.sp_AIIndexTuner;                                      -- whole database, recommend only
        EXEC dbo.sp_AIIndexTuner @SchemaName = N'Sales';               -- one schema
        EXEC dbo.sp_AIIndexTuner @SchemaName = N'Sales', @TableName = N'Orders';
        EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE';                     -- also create the new indexes it can verify
        EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @MinPriority = 'Medium', @MinConfidence = 'High';

    RECOMMEND (default) collects the Index Tuning diagnostics, sends them to your Azure OpenAI
    deployment, stores the recommendations in AIIndexTuner.Recommendation and returns them.
    It changes nothing in the schema.

    CREATE does the same, then applies the CreateIndex recommendations, and the ConsolidateIndex
    ones that widen an existing index in place, that pass validation (see
    AIIndexTuner.usp_ApplyRecommendation). Every other recommendation stays for you to review.

    Change controls (each restricts the prompt, and is enforced again when applying):
        @AllowColumnstore   NULL (default) columnstore indexes may be recommended but are not created;
                            1 = they may also be created; 0 = they are not recommended or created.
        @AllowDropIndex     NULL (default) index drops may be recommended but are not run;
                            1 = they may also be run; 0 = they are not recommended or run.
        @MaxNewIndexes      at most this many new or widened indexes are recommended and created
                            (NULL = no limit).

    A recommend-only (NULL) change can be applied after review with sp_AIIndexTuner_Apply and the
    matching setting set to 1. A 0 cannot be overridden later.

    Apply thresholds (enforced when applying; the prompt is unchanged):
        @MinPriority        High, Medium or Low: apply only recommendations whose priority level is
                            at least this (NULL = no minimum).
        @MinConfidence      High, Medium or Low: apply only recommendations whose confidence is at
                            least this (NULL = no minimum).
    The rest are skipped with a reason and stay for review. 'Low', 'Low' applies everything else
    allows, for a dedicated test environment; 'Medium', 'High' is a lower-risk choice for production.
    A recommendation the model gave no level counts as Low. sp_AIIndexTuner_Apply can apply a
    skipped one after review, with a lower minimum.

    Testing and troubleshooting:
        @CollectOnly = 1    returns the collected data and the system prompt; no AI call, no run row.
        @TestResponse = N'{...}'
                            uses this text as the model's answer instead of calling the endpoint.
        @CollectedData = N'...'
                            uses this text as the collected diagnostics instead of collecting them,
                            for example a run's AIIndexTuner.Run.CollectedData. Benchmarks use it to
                            give every run the same input. Nothing is collected.

    Requires SQL Server 2025, Azure SQL Database, Azure SQL Managed Instance or Fabric SQL
    Database (sp_invoke_external_rest_endpoint). Only OpenAI models are supported for now.
*/
CREATE OR ALTER PROCEDURE dbo.sp_AIIndexTuner
    @SchemaName   sysname = NULL,
    @TableName    sysname = NULL,
    @Mode         varchar(10) = 'RECOMMEND',
    @CollectOnly  bit = 0,
    @TestResponse nvarchar(max) = NULL,
    @CollectedData nvarchar(max) = NULL,
    @AllowColumnstore bit = NULL,
    @AllowDropIndex   bit = NULL,
    @MaxNewIndexes    int = NULL,
    @MinPriority      varchar(10) = NULL,
    @MinConfidence    varchar(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    SET @Mode = UPPER(LTRIM(RTRIM(@Mode)));
    SET @SchemaName = NULLIF(LTRIM(RTRIM(@SchemaName)), N'');
    SET @TableName = NULLIF(LTRIM(RTRIM(@TableName)), N'');

    IF @Mode NOT IN ('RECOMMEND', 'CREATE')
        THROW 50201, N'@Mode must be RECOMMEND or CREATE.', 1;
    IF @TableName IS NOT NULL AND @SchemaName IS NULL
        THROW 50202, N'@SchemaName is required when @TableName is specified.', 1;
    IF DB_ID() <= 4
        THROW 50203, N'Run sp_AIIndexTuner in a user database, not a system database.', 1;
    IF @SchemaName IS NOT NULL AND SCHEMA_ID(@SchemaName) IS NULL
        THROW 50204, N'The schema in @SchemaName does not exist in this database.', 1;
    IF @TableName IS NOT NULL AND OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName), N'U') IS NULL
        THROW 50205, N'The table in @SchemaName.@TableName does not exist in this database.', 1;

    DECLARE @IncludeQueryText bit = 1, @KeepDetail bit = 1, @Endpoint nvarchar(400), @Deployment nvarchar(128), @Effort varchar(10);
    SELECT @IncludeQueryText = IncludeQueryText, @KeepDetail = KeepRunDetail,
           @Endpoint = Endpoint, @Deployment = Deployment, @Effort = ReasoningEffort
    FROM AIIndexTuner.Config WHERE ConfigId = 1;

    IF @MaxNewIndexes < 0
        THROW 50209, N'@MaxNewIndexes must be 0 or more, or NULL for no limit.', 1;
    IF (@MinPriority IS NOT NULL AND AIIndexTuner.fn_LevelRank(@MinPriority) IS NULL)
       OR (@MinConfidence IS NOT NULL AND AIIndexTuner.fn_LevelRank(@MinConfidence) IS NULL)
        THROW 50210, N'@MinPriority and @MinConfidence must be High, Medium or Low, or NULL for no minimum.', 1;
    SELECT @MinPriority = CASE AIIndexTuner.fn_LevelRank(@MinPriority) WHEN 3 THEN 'High' WHEN 2 THEN 'Medium' WHEN 1 THEN 'Low' END,
           @MinConfidence = CASE AIIndexTuner.fn_LevelRank(@MinConfidence) WHEN 3 THEN 'High' WHEN 2 THEN 'Medium' WHEN 1 THEN 'Low' END;

    DECLARE @Data nvarchar(max),
            @SystemPrompt nvarchar(max) = AIIndexTuner.fn_SystemPrompt() + AIIndexTuner.fn_ChangeRules(@AllowColumnstore, @AllowDropIndex, @MaxNewIndexes);

    IF @CollectedData IS NOT NULL AND (@CollectOnly = 1 OR LEN(@CollectedData) = 0)
        THROW 50208, N'@CollectedData cannot be empty, and cannot be combined with @CollectOnly = 1.', 1;

    IF @CollectOnly = 1
    BEGIN
        EXEC AIIndexTuner.usp_CollectData @SchemaName = @SchemaName, @TableName = @TableName,
                                          @IncludeQueryText = @IncludeQueryText, @Data = @Data OUTPUT;
        SELECT LEN(@Data) AS CollectedChars, @Data AS CollectedData, @SystemPrompt AS SystemPrompt;
        RETURN;
    END;

    IF @TestResponse IS NULL AND @Endpoint IS NULL
        THROW 50206, N'AIIndexTuner.Config has no row. Run setup/Configure-Endpoint.sql first.', 1;

    DECLARE @RunId int;
    INSERT AIIndexTuner.Run (Mode, SchemaName, TableName, Endpoint, Deployment, ApiShape, ReasoningEffort, SystemPromptHash,
                             AllowColumnstore, AllowDropIndex, MaxNewIndexes, MinPriority, MinConfidence)
    VALUES (@Mode, @SchemaName, @TableName,
            CASE WHEN @TestResponse IS NULL THEN @Endpoint END,
            CASE WHEN @TestResponse IS NULL THEN @Deployment END,
            CASE WHEN @TestResponse IS NULL THEN 'OpenAIResponses' ELSE 'Test' END,
            CASE WHEN @TestResponse IS NULL THEN @Effort END,
            CONVERT(char(64), HASHBYTES('SHA2_256', @SystemPrompt), 2),
            @AllowColumnstore, @AllowDropIndex, @MaxNewIndexes, @MinPriority, @MinConfidence);
    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        DECLARE @Started datetime2(7) = SYSDATETIME();

        IF @CollectedData IS NOT NULL
            SET @Data = @CollectedData;
        ELSE
            EXEC AIIndexTuner.usp_CollectData @SchemaName = @SchemaName, @TableName = @TableName,
                                              @IncludeQueryText = @IncludeQueryText, @Data = @Data OUTPUT;

        UPDATE AIIndexTuner.Run
        SET CollectedChars = LEN(@Data), CollectedData = CASE WHEN @KeepDetail = 1 THEN @Data END,
            PayloadSupplied = CASE WHEN @CollectedData IS NOT NULL THEN 1 ELSE 0 END,
            PayloadHash = CONVERT(char(64), HASHBYTES('SHA2_256', @Data), 2),
            CollectMs = CASE WHEN @CollectedData IS NULL THEN DATEDIFF(MILLISECOND, @Started, SYSDATETIME()) END
        WHERE RunId = @RunId;

        DECLARE @UserPrompt nvarchar(max) = CONCAT(CAST(N'Analyze this SQL Server data:' AS nvarchar(max)), NCHAR(10), NCHAR(10), @Data);
        DECLARE @Text nvarchar(max), @ModelUsed nvarchar(128), @InputTokens int, @OutputTokens int, @Truncated bit, @Raw nvarchar(max),
                @PollCount int, @ModelStarted datetime2(7) = SYSDATETIME();

        IF @TestResponse IS NOT NULL
            SELECT @Text = @TestResponse, @Truncated = 0;
        ELSE
            EXEC AIIndexTuner.usp_InvokeModel
                @SystemPrompt = @SystemPrompt, @UserPrompt = @UserPrompt,
                @Text = @Text OUTPUT, @ModelUsed = @ModelUsed OUTPUT, @InputTokens = @InputTokens OUTPUT,
                @OutputTokens = @OutputTokens OUTPUT, @Truncated = @Truncated OUTPUT, @RawResponse = @Raw OUTPUT,
                @PollCount = @PollCount OUTPUT;

        UPDATE AIIndexTuner.Run
        SET ModelUsed = @ModelUsed, InputTokens = @InputTokens, OutputTokens = @OutputTokens, Truncated = @Truncated,
            RawResponse = CASE WHEN @KeepDetail = 1 THEN ISNULL(@Raw, @Text) END,
            ModelMs = DATEDIFF(MILLISECOND, @ModelStarted, SYSDATETIME()), PollCount = @PollCount
        WHERE RunId = @RunId;

        -- Some models wrap JSON in a Markdown fence even when told not to.
        SET @Text = LTRIM(RTRIM(@Text, NCHAR(10) + NCHAR(13) + N' '), NCHAR(10) + NCHAR(13) + N' ');
        IF LEFT(@Text, 3) = N'```'
        BEGIN
            SET @Text = SUBSTRING(@Text, CHARINDEX(NCHAR(10), @Text + NCHAR(10)) + 1, LEN(@Text));
            IF RIGHT(@Text, 3) = N'```' SET @Text = LEFT(@Text, LEN(@Text) - 3);
        END;

        IF ISJSON(@Text) = 0 OR JSON_QUERY(@Text, '$.recommendations') IS NULL
        BEGIN
            DECLARE @ParseError nvarchar(4000) = CASE WHEN @Truncated = 1
                THEN N'The model ran out of output tokens, so its JSON is incomplete. Raise AIIndexTuner.Config.MaxOutputTokens or narrow the scope.'
                ELSE N'The model did not return the expected JSON object with a recommendations array.' END;
            THROW 50207, @ParseError, 1;
        END;

        INSERT AIIndexTuner.Recommendation
            (RunId, Priority, PriorityLevel, Category, Title, SchemaName, TableName, IndexName, IndexType, KeyColumns, IncludeColumns, FilterPredicate,
             IsUnique, [FillFactor], DataCompression, EstimatedSizeMB, Confidence, Rationale, BenefitingQueries, Script, ReplacesIndex)
        SELECT @RunId, r.priority,
               CASE WHEN r.priority_level IN ('High', 'Medium', 'Low') THEN r.priority_level END,
               CASE WHEN r.category IN ('CreateIndex', 'DropIndex', 'ConsolidateIndex', 'RebuildIndex', 'Constraint', 'Statistics', 'Setting', 'QueryChange') THEN r.category ELSE 'Other' END,
               LEFT(r.title, 400), LEFT(r.schema_name, 128), LEFT(r.table_name, 128), LEFT(r.index_name, 128),
               CASE WHEN r.category = 'CreateIndex' OR (r.category = 'ConsolidateIndex' AND NULLIF(LTRIM(r.replaces_index), N'') IS NOT NULL)
                    THEN CASE WHEN UPPER(r.index_type) IN ('NONCLUSTERED COLUMNSTORE', 'CLUSTERED COLUMNSTORE') THEN UPPER(r.index_type) ELSE 'NONCLUSTERED' END END,
               ISNULL(r.key_columns, N'[]'), ISNULL(r.include_columns, N'[]'), LEFT(r.filter_predicate, 4000),
               r.is_unique,
               CASE WHEN r.fill_factor BETWEEN 1 AND 100 THEN r.fill_factor END,
               CASE WHEN UPPER(r.data_compression) IN ('NONE', 'ROW', 'PAGE') THEN UPPER(r.data_compression) END,
               TRY_CAST(r.estimated_size_mb AS decimal(18, 2)),
               CASE WHEN r.confidence IN ('High', 'Medium', 'Low') THEN r.confidence END,
               r.rationale, r.benefiting_queries, r.script,
               CASE WHEN r.category = 'ConsolidateIndex' THEN LEFT(NULLIF(LTRIM(r.replaces_index), N''), 128) END
        FROM OPENJSON(@Text, '$.recommendations')
             WITH (priority int, priority_level varchar(20), category varchar(30), title nvarchar(4000), schema_name nvarchar(4000), table_name nvarchar(4000),
                   index_name nvarchar(4000), index_type varchar(40), key_columns nvarchar(max) AS JSON, include_columns nvarchar(max) AS JSON,
                   filter_predicate nvarchar(max), is_unique bit, fill_factor int, data_compression varchar(20),
                   estimated_size_mb float, confidence varchar(20), rationale nvarchar(max),
                   benefiting_queries nvarchar(max) AS JSON, script nvarchar(max), replaces_index nvarchar(4000)) AS r;

        UPDATE AIIndexTuner.Run
        SET Summary = JSON_VALUE(@Text, '$.summary'), Status = 'Succeeded', CompletedAt = SYSDATETIME()
        WHERE RunId = @RunId;

        -- JSON_VALUE returns NULL past 4000 characters; keep a long summary whole.
        IF JSON_VALUE(@Text, '$.summary') IS NULL
            UPDATE AIIndexTuner.Run
            SET Summary = (SELECT s FROM OPENJSON(@Text) WITH (s nvarchar(max) '$.summary'))
            WHERE RunId = @RunId;
    END TRY
    BEGIN CATCH
        DECLARE @Err nvarchar(4000) = ERROR_MESSAGE();
        UPDATE AIIndexTuner.Run SET Status = 'Failed', ErrorMessage = @Err, CompletedAt = SYSDATETIME() WHERE RunId = @RunId;
        THROW;
    END CATCH;

    IF @Mode = 'CREATE'
    BEGIN
        DECLARE @RecId int, @ApplyStarted datetime2(7) = SYSDATETIME();
        -- New rowstore indexes and widenings of existing ones, plus the columnstore indexes and drops
        -- this run has a setting for. Recommend-only ones (setting NULL) stay Recommended, for review.
        -- A change the run does not allow (0) is still passed, so that it is marked Skipped if the model
        -- recommended it anyway. Below @MinPriority or @MinConfidence is passed too, and marked Skipped
        -- with how to apply it.
        DECLARE apply_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT RecommendationId FROM AIIndexTuner.Recommendation
            WHERE RunId = @RunId
              AND ((Category = 'CreateIndex' AND (IndexType = 'NONCLUSTERED' OR @AllowColumnstore IS NOT NULL))
                   OR (Category = 'ConsolidateIndex' AND ReplacesIndex IS NOT NULL)
                   OR (Category = 'DropIndex' AND @AllowDropIndex IS NOT NULL))
            ORDER BY Priority, RecommendationId;
        OPEN apply_cur;
        FETCH NEXT FROM apply_cur INTO @RecId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC AIIndexTuner.usp_ApplyRecommendation @RecommendationId = @RecId;
            FETCH NEXT FROM apply_cur INTO @RecId;
        END;
        CLOSE apply_cur;
        DEALLOCATE apply_cur;
        UPDATE AIIndexTuner.Run SET ApplyMs = DATEDIFF(MILLISECOND, @ApplyStarted, SYSDATETIME()) WHERE RunId = @RunId;
    END;

    SELECT r.RunId, r.Status AS RunStatus, r.ModelUsed, r.InputTokens, r.OutputTokens, r.Summary,
           r.CollectedChars, r.StartedAt, r.CompletedAt,
           N'Free and open source from AI SQL Tuner. For query tuning, deadlock analysis, server health checks, code review, HTML reports or SQL Server 2022 and earlier, see AI SQL Tuner Studio: https://aisqltuner.com or https://apps.microsoft.com/detail/9P68072ZM3N5' AS MoreFrom
    FROM AIIndexTuner.Run AS r WHERE r.RunId = @RunId;

    SELECT RecommendationId, Priority, PriorityLevel, Category, Title, SchemaName, TableName, IndexName, IndexType, ReplacesIndex, Confidence, EstimatedSizeMB,
           Status, StatusReason, Rationale, Script, AppliedDDL, UndoDDL
    FROM AIIndexTuner.Recommendation
    WHERE RunId = @RunId
    ORDER BY Priority, RecommendationId;
END;
GO

/*
    dbo.sp_AIIndexTuner_Apply: apply stored recommendations after reviewing them.

        EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = 42;   -- one recommendation
        EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7;               -- the new rowstore indexes and widenings of a run
        EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = 43, @AllowDropIndex = 1;
        EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7, @AllowColumnstore = 1, @AllowDropIndex = 1;
        EXEC dbo.sp_AIIndexTuner_Apply @RunId = 7, @MinPriority = 'Medium', @MinConfidence = 'High';

    @AllowColumnstore and @AllowDropIndex = 1 apply changes that the run left recommend-only (NULL);
    0 blocks them. Neither can override a run that did not allow the change (0). @MaxNewIndexes
    limits the new indexes of a run, together with the run's own limit.

    @MinPriority and @MinConfidence (High, Medium or Low) replace the run's minimums when given, so
    'Low' applies a recommendation the run's minimums held back for review. When NULL, the run's apply.
*/
CREATE OR ALTER PROCEDURE dbo.sp_AIIndexTuner_Apply
    @RecommendationId int = NULL,
    @RunId            int = NULL,
    @AllowColumnstore bit = NULL,
    @AllowDropIndex   bit = NULL,
    @MaxNewIndexes    int = NULL,
    @MinPriority      varchar(10) = NULL,
    @MinConfidence    varchar(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (@RecommendationId IS NULL AND @RunId IS NULL) OR (@RecommendationId IS NOT NULL AND @RunId IS NOT NULL)
        THROW 50301, N'Pass either @RecommendationId or @RunId.', 1;
    IF @MaxNewIndexes < 0
        THROW 50302, N'@MaxNewIndexes must be 0 or more, or NULL for no limit.', 1;
    IF (@MinPriority IS NOT NULL AND AIIndexTuner.fn_LevelRank(@MinPriority) IS NULL)
       OR (@MinConfidence IS NOT NULL AND AIIndexTuner.fn_LevelRank(@MinConfidence) IS NULL)
        THROW 50303, N'@MinPriority and @MinConfidence must be High, Medium or Low, or NULL for the run''s minimums.', 1;
    SELECT @MinPriority = CASE AIIndexTuner.fn_LevelRank(@MinPriority) WHEN 3 THEN 'High' WHEN 2 THEN 'Medium' WHEN 1 THEN 'Low' END,
           @MinConfidence = CASE AIIndexTuner.fn_LevelRank(@MinConfidence) WHEN 3 THEN 'High' WHEN 2 THEN 'Medium' WHEN 1 THEN 'Low' END;

    DECLARE @Ids TABLE (RecommendationId int PRIMARY KEY, Priority int);

    IF @RecommendationId IS NOT NULL
        INSERT @Ids VALUES (@RecommendationId, NULL);
    ELSE
        -- As in sp_AIIndexTuner CREATE mode, with this call's settings added to the run's.
        INSERT @Ids
        SELECT r.RecommendationId, r.Priority
        FROM AIIndexTuner.Recommendation AS r
        INNER JOIN AIIndexTuner.Run AS run ON run.RunId = r.RunId
        WHERE r.RunId = @RunId
          AND ((r.Category = 'CreateIndex' AND (ISNULL(r.IndexType, 'NONCLUSTERED') = 'NONCLUSTERED'
                                                OR run.AllowColumnstore IS NOT NULL OR @AllowColumnstore IS NOT NULL))
               OR (r.Category = 'ConsolidateIndex' AND r.ReplacesIndex IS NOT NULL)
               OR (r.Category = 'DropIndex' AND (run.AllowDropIndex IS NOT NULL OR @AllowDropIndex IS NOT NULL)));

    -- In priority order, so a @MaxNewIndexes limit keeps the most important indexes.
    DECLARE @Id int;
    DECLARE apply_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT RecommendationId FROM @Ids ORDER BY Priority, RecommendationId;
    OPEN apply_cur;
    FETCH NEXT FROM apply_cur INTO @Id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC AIIndexTuner.usp_ApplyRecommendation @RecommendationId = @Id, @AllowColumnstore = @AllowColumnstore,
                                                  @AllowDropIndex = @AllowDropIndex, @MaxNewIndexes = @MaxNewIndexes,
                                                  @MinPriority = @MinPriority, @MinConfidence = @MinConfidence;
        FETCH NEXT FROM apply_cur INTO @Id;
    END;
    CLOSE apply_cur;
    DEALLOCATE apply_cur;

    SELECT r.RecommendationId, r.RunId, r.Priority, r.PriorityLevel, r.Confidence, r.Category, r.Title, r.SchemaName, r.TableName, r.IndexName,
           r.Status, r.StatusReason, r.AppliedDDL, r.AppliedAt, r.UndoDDL
    FROM AIIndexTuner.Recommendation AS r
    INNER JOIN @Ids AS i ON i.RecommendationId = r.RecommendationId
    ORDER BY r.Priority, r.RecommendationId;
END;
GO
