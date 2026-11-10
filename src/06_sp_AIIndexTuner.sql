SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    AIIndexTuner.usp_SkipForMaxMinutes: marks a recommendation that was not started because the call's
    @MaxMinutes was reached (issue #49), with how to apply it later. Only one still Recommended is
    marked: an earlier Skipped or Failed result, and its reason, stays as the last attempt left it.
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_SkipForMaxMinutes
    @RecommendationId int,
    @MaxMinutes       int,
    @CallStarted      datetime2(3)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE AIIndexTuner.Recommendation
    SET Status = 'Skipped',
        StatusReason = CONCAT(N'Not started: the limit of ', @MaxMinutes, N' minute(s) for this call (@MaxMinutes) was reached; the call started at ',
                              CONVERT(varchar(19), @CallStarted, 120), N'. Apply it later with sp_AIIndexTuner_Apply @RecommendationId = ', @RecommendationId, N'.')
    WHERE RecommendationId = @RecommendationId AND Status = 'Recommended';
END;
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

    Build limits (issue #49; enforced when applying, the prompt is unchanged):
        @MaxTableRows       skip a new or widened index on a table with more rows than this.
        @MaxIndexSizeMB     skip a new or widened index estimated (an upper bound, from the columns'
                            declared widths) at more MB than this.
        @MaxMinutes         start no change after this many minutes from the start of this call; one
                            already running finishes. The ones not started are marked Skipped with how
                            to apply them later. 0 starts none. Collection and the AI call are not
                            limited by it.
    NULL (the default) is no limit. sp_AIIndexTuner_Apply takes the same three; its size limits replace
    the run's. How builds and drops wait for locks, and their MAXDOP, are set in AIIndexTuner.Config
    (LockTimeoutSec, OnlineWaitMinutes, BuildMaxDop).

    Testing and troubleshooting:
        @CollectOnly = 1    returns the collected data and the system prompt; no AI call, no run row.
        @TestResponse = N'{...}'
                            uses this text as the model's answer instead of calling the endpoint.
        @CollectedData = N'...'
                            uses this text as the collected diagnostics instead of collecting them,
                            for example a run's AIIndexTuner.Run.CollectedData. Benchmarks use it to
                            give every run the same input. Nothing is collected.
        @Logging            1 = write each step (collector section, AI request, AI response, each
                            recommendation applied) to AIIndexTuner.RunLog as it starts and ends;
                            0 = do not; NULL (default) = AIIndexTuner.Config.EnableLogging.

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
    @MinConfidence    varchar(10) = NULL,
    @Logging          bit = NULL,
    @MaxTableRows     bigint = NULL,
    @MaxIndexSizeMB   int = NULL,
    @MaxMinutes       int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @CallStarted datetime2(3) = SYSDATETIME();   -- for @MaxMinutes

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

    DECLARE @IncludeQueryText bit = 1, @KeepDetail bit = 1, @Endpoint nvarchar(400), @Deployment nvarchar(128), @Effort varchar(10),
            @MaxPayloadChars int, @CredentialName sysname, @ConfigLogging bit;
    SELECT @IncludeQueryText = IncludeQueryText, @KeepDetail = KeepRunDetail,
           @Endpoint = Endpoint, @Deployment = Deployment, @Effort = ReasoningEffort, @MaxPayloadChars = MaxPayloadChars,
           @CredentialName = CredentialName, @ConfigLogging = EnableLogging
    FROM AIIndexTuner.Config WHERE ConfigId = 1;
    SET @Logging = COALESCE(@Logging, @ConfigLogging, 1);

    IF @MaxNewIndexes < 0
        THROW 50209, N'@MaxNewIndexes must be 0 or more, or NULL for no limit.', 1;
    IF @MaxTableRows <= 0 OR @MaxIndexSizeMB <= 0 OR @MaxMinutes < 0
        THROW 50215, N'@MaxTableRows and @MaxIndexSizeMB must be more than 0, and @MaxMinutes 0 or more, or NULL for no limit.', 1;
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
                                          @IncludeQueryText = @IncludeQueryText, @Data = @Data OUTPUT, @Logging = @Logging;
        SELECT LEN(@Data) AS CollectedChars, @Data AS CollectedData, @SystemPrompt AS SystemPrompt;
        RETURN;
    END;

    IF @TestResponse IS NULL AND @Endpoint IS NULL
        THROW 50206, N'AIIndexTuner.Config has no row. Run setup/Configure-Endpoint.sql first.', 1;

    /* Before collecting, which can take minutes, stop on a setup error that would fail the AI call
       anyway. With @CollectedData nothing is collected, so the call reports these itself. */
    IF @TestResponse IS NULL AND @CollectedData IS NULL
    BEGIN
        DECLARE @SetupError nvarchar(2000);

        -- Off by default on SQL Server 2025 and Managed Instance (EngineEdition 8); on in Azure SQL Database and Fabric.
        IF CAST(SERVERPROPERTY('EngineEdition') AS int) IN (1, 2, 3, 4, 8)
           AND EXISTS (SELECT 1 FROM sys.configurations WHERE name = N'external rest endpoint enabled' AND value_in_use = 0)
            THROW 50212, N'sp_invoke_external_rest_endpoint is disabled on this instance. Run EXEC sp_configure ''external rest endpoint enabled'', 1; RECONFIGURE WITH OVERRIDE; (step 1 of setup/Configure-Endpoint.sql; needs ALTER SETTINGS).', 1;

        -- The credential name must be the request URL or a more general prefix of it, ending at a path
        -- boundary. Compared case-insensitively, so this fails only on a definite mismatch.
        DECLARE @RequestUrl nvarchar(4000) = CONCAT(
            CASE WHEN RIGHT(@Endpoint, 1) = N'/' THEN LEFT(@Endpoint, LEN(@Endpoint) - 1) ELSE @Endpoint END, N'/openai/v1/responses');
        IF NOT (LOWER(@RequestUrl) = LOWER(@CredentialName)
                OR LOWER(@RequestUrl) LIKE LOWER(AIIndexTuner.fn_EscapeLike(@CredentialName)) + CASE WHEN RIGHT(@CredentialName, 1) = N'/' THEN N'%' ELSE N'/%' END ESCAPE N'\')
        BEGIN
            SET @SetupError = CONCAT(N'AIIndexTuner.Config.CredentialName (', @CredentialName, N') does not match the endpoint: it must be the start of the request URL ',
                                     @RequestUrl, N', normally the endpoint''s root URL with no trailing slash.');
            THROW 50213, @SetupError, 1;
        END;

        -- sys.database_scoped_credentials shows every credential only to a caller with CONTROL on the
        -- database, so the check is made only then.
        IF HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL') = 1
           AND NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = @CredentialName)
        BEGIN
            SET @SetupError = CONCAT(N'The database scoped credential ', @CredentialName, N' (AIIndexTuner.Config.CredentialName) does not exist in this database. ',
                                     N'Credentials here: ', ISNULL((SELECT STRING_AGG(CAST(name AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY name)
                                                                    FROM sys.database_scoped_credentials), N'(none)'),
                                     N'. Create it as in step 3 of setup/Configure-Endpoint.sql.');
            THROW 50214, @SetupError, 1;
        END;
    END;

    DECLARE @RunId int;
    INSERT AIIndexTuner.Run (Mode, SchemaName, TableName, Endpoint, Deployment, ApiShape, ReasoningEffort, SystemPromptHash,
                             AllowColumnstore, AllowDropIndex, MaxNewIndexes, MinPriority, MinConfidence, MaxTableRows, MaxIndexSizeMB)
    VALUES (@Mode, @SchemaName, @TableName,
            CASE WHEN @TestResponse IS NULL THEN @Endpoint END,
            CASE WHEN @TestResponse IS NULL THEN @Deployment END,
            CASE WHEN @TestResponse IS NULL THEN 'OpenAIResponses' ELSE 'Test' END,
            CASE WHEN @TestResponse IS NULL THEN @Effort END,
            CONVERT(char(64), HASHBYTES('SHA2_256', @SystemPrompt), 2),
            @AllowColumnstore, @AllowDropIndex, @MaxNewIndexes, @MinPriority, @MinConfidence, @MaxTableRows, @MaxIndexSizeMB);
    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        DECLARE @Started datetime2(7) = SYSDATETIME();

        IF @CollectedData IS NOT NULL
            SET @Data = @CollectedData;
        ELSE
            EXEC AIIndexTuner.usp_CollectData @SchemaName = @SchemaName, @TableName = @TableName,
                                              @IncludeQueryText = @IncludeQueryText, @Data = @Data OUTPUT,
                                              @RunId = @RunId, @Logging = @Logging;

        UPDATE AIIndexTuner.Run
        SET CollectedChars = LEN(@Data), CollectedData = CASE WHEN @KeepDetail = 1 THEN @Data END,
            PayloadSupplied = CASE WHEN @CollectedData IS NOT NULL THEN 1 ELSE 0 END,
            PayloadHash = CONVERT(char(64), HASHBYTES('SHA2_256', @Data), 2),
            CollectMs = CASE WHEN @CollectedData IS NULL THEN DATEDIFF(MILLISECOND, @Started, SYSDATETIME()) END
        WHERE RunId = @RunId;

        DECLARE @UserPrompt nvarchar(max) = CONCAT(CAST(N'Analyze this SQL Server data:' AS nvarchar(max)), NCHAR(10), NCHAR(10), @Data);
        DECLARE @Text nvarchar(max), @ModelUsed nvarchar(128), @InputTokens int, @OutputTokens int, @Truncated bit, @Raw nvarchar(max),
                @PollCount int, @ModelStarted datetime2(7) = SYSDATETIME();

        -- Checked only when the model is called: a test response sends nothing.
        IF @TestResponse IS NULL AND LEN(@Data) > @MaxPayloadChars
        BEGIN
            DECLARE @SizeError nvarchar(2000) = CONCAT(N'The collected data is ', FORMAT(LEN(@Data), 'N0', 'en-US'), N' characters, over the payload size limit of ',
                FORMAT(@MaxPayloadChars, 'N0', 'en-US'), N' (AIIndexTuner.Config.MaxPayloadChars), so it was not sent. Narrow the scope with @SchemaName and @TableName, ',
                N'or raise MaxPayloadChars if the deployment''s context window and tokens-per-minute quota allow a larger request.');
            THROW 50211, @SizeError, 1;
        END;

        IF @TestResponse IS NOT NULL
            SELECT @Text = @TestResponse, @Truncated = 0;
        ELSE
            EXEC AIIndexTuner.usp_InvokeModel
                @SystemPrompt = @SystemPrompt, @UserPrompt = @UserPrompt,
                @Text = @Text OUTPUT, @ModelUsed = @ModelUsed OUTPUT, @InputTokens = @InputTokens OUTPUT,
                @OutputTokens = @OutputTokens OUTPUT, @Truncated = @Truncated OUTPUT, @RawResponse = @Raw OUTPUT,
                @PollCount = @PollCount OUTPUT, @RunId = @RunId, @Logging = @Logging;

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

        -- A script that targets another table than the recommendation names (issue #41). The apply
        -- step builds its own DDL and never runs Script, but a person may copy it.
        UPDATE AIIndexTuner.Recommendation
        SET ScriptWarning = AIIndexTuner.fn_ScriptTargetWarning(Script, SchemaName, TableName)
        WHERE RunId = @RunId AND NULLIF(LTRIM(Script), N'') IS NOT NULL AND TableName IS NOT NULL;

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
        -- The step that failed is still open; close it with the error.
        UPDATE AIIndexTuner.RunLog
        SET EndTime = SYSDATETIME(), ElapsedMs = DATEDIFF(MILLISECOND, StartTime, SYSDATETIME()), Message = LEFT(CONCAT(N'Failed: ', @Err), 4000)
        WHERE RunId = @RunId AND EndTime IS NULL;
        THROW;
    END CATCH;

    IF @Mode = 'CREATE'
    BEGIN
        DECLARE @RecId int, @ApplyStarted datetime2(7) = SYSDATETIME(), @ApplyStep nvarchar(128), @ApplyLogId int, @ApplyLogChars int, @ApplyLogRow int;
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
            -- @MaxMinutes (issue #49): once it is reached, nothing more starts; what is running has finished.
            IF @MaxMinutes IS NOT NULL AND SYSDATETIME() >= DATEADD(MINUTE, @MaxMinutes, @CallStarted)
            BEGIN
                EXEC AIIndexTuner.usp_SkipForMaxMinutes @RecId, @MaxMinutes, @CallStarted;
                FETCH NEXT FROM apply_cur INTO @RecId;
                CONTINUE;
            END;

            SET @ApplyStep = (SELECT LEFT(CONCAT(N'Apply ', Category, N' ', IndexName, N' (recommendation ', RecommendationId, N')'), 128)
                              FROM AIIndexTuner.Recommendation WHERE RecommendationId = @RecId);
            EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, @ApplyStep, @LogId = @ApplyLogId OUTPUT, @CharsAtStart = @ApplyLogChars OUTPUT;
            SET @ApplyLogRow = @ApplyLogId;
            EXEC AIIndexTuner.usp_ApplyRecommendation @RecommendationId = @RecId;
            EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, NULL, @LogId = @ApplyLogId OUTPUT, @CharsAtStart = @ApplyLogChars OUTPUT;
            IF @Logging = 1
                UPDATE AIIndexTuner.RunLog
                SET Message = (SELECT LEFT(CONCAT(Status, N': ' + StatusReason), 4000) FROM AIIndexTuner.Recommendation WHERE RecommendationId = @RecId)
                WHERE RunLogId = @ApplyLogRow;
            FETCH NEXT FROM apply_cur INTO @RecId;
        END;
        CLOSE apply_cur;
        DEALLOCATE apply_cur;
        UPDATE AIIndexTuner.Run SET ApplyMs = DATEDIFF(MILLISECOND, @ApplyStarted, SYSDATETIME()) WHERE RunId = @RunId;
    END;

    /* Return results, logged around the two result sets (issue #40: on a Managed Instance the client
       reported "A severe error occurred" in place of these results). A closed row means the server
       finished both result sets; Message counts how many it finished. */
    DECLARE @ResultsLogId int, @ResultsLogChars int, @ResultsLogRow int;
    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'Return results', @LogId = @ResultsLogId OUTPUT, @CharsAtStart = @ResultsLogChars OUTPUT;
    SET @ResultsLogRow = @ResultsLogId;

    SELECT r.RunId, r.Status AS RunStatus, r.ModelUsed, r.InputTokens, r.OutputTokens, r.Summary,
           r.CollectedChars, r.StartedAt, r.CompletedAt,
           N'Free and open source from AI SQL Tuner. For query tuning, deadlock analysis, server health checks, code review, HTML reports or SQL Server 2022 and earlier, see AI SQL Tuner Studio: https://aisqltuner.com or https://apps.microsoft.com/detail/9P68072ZM3N5' AS MoreFrom
    FROM AIIndexTuner.Run AS r WHERE r.RunId = @RunId;

    IF @Logging = 1
        UPDATE AIIndexTuner.RunLog SET Message = N'1 of 2 result sets done' WHERE RunLogId = @ResultsLogRow;

    SELECT RecommendationId, Priority, PriorityLevel, Category, Title, SchemaName, TableName, IndexName, IndexType, ReplacesIndex, Confidence, EstimatedSizeMB,
           Status, StatusReason, Rationale, Script, ScriptWarning, AppliedDDL, UndoDDL
    FROM AIIndexTuner.Recommendation
    WHERE RunId = @RunId
    ORDER BY Priority, RecommendationId;

    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, NULL, @LogId = @ResultsLogId OUTPUT, @CharsAtStart = @ResultsLogChars OUTPUT;
    IF @Logging = 1
        UPDATE AIIndexTuner.RunLog SET Message = N'2 of 2 result sets done' WHERE RunLogId = @ResultsLogRow;
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

    @MaxTableRows and @MaxIndexSizeMB replace the run's size limits when given. @MaxMinutes starts no
    change after that many minutes from the start of this call (see sp_AIIndexTuner).
*/
CREATE OR ALTER PROCEDURE dbo.sp_AIIndexTuner_Apply
    @RecommendationId int = NULL,
    @RunId            int = NULL,
    @AllowColumnstore bit = NULL,
    @AllowDropIndex   bit = NULL,
    @MaxNewIndexes    int = NULL,
    @MinPriority      varchar(10) = NULL,
    @MinConfidence    varchar(10) = NULL,
    @MaxTableRows     bigint = NULL,
    @MaxIndexSizeMB   int = NULL,
    @MaxMinutes       int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CallStarted datetime2(3) = SYSDATETIME();   -- for @MaxMinutes

    IF (@RecommendationId IS NULL AND @RunId IS NULL) OR (@RecommendationId IS NOT NULL AND @RunId IS NOT NULL)
        THROW 50301, N'Pass either @RecommendationId or @RunId.', 1;
    IF @MaxNewIndexes < 0
        THROW 50302, N'@MaxNewIndexes must be 0 or more, or NULL for no limit.', 1;
    IF @MaxTableRows <= 0 OR @MaxIndexSizeMB <= 0 OR @MaxMinutes < 0
        THROW 50304, N'@MaxTableRows and @MaxIndexSizeMB must be more than 0, and @MaxMinutes 0 or more, or NULL for the run''s limits / no limit.', 1;
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
        IF @MaxMinutes IS NOT NULL AND SYSDATETIME() >= DATEADD(MINUTE, @MaxMinutes, @CallStarted)
            EXEC AIIndexTuner.usp_SkipForMaxMinutes @Id, @MaxMinutes, @CallStarted;
        ELSE
            EXEC AIIndexTuner.usp_ApplyRecommendation @RecommendationId = @Id, @AllowColumnstore = @AllowColumnstore,
                                                      @AllowDropIndex = @AllowDropIndex, @MaxNewIndexes = @MaxNewIndexes,
                                                      @MinPriority = @MinPriority, @MinConfidence = @MinConfidence,
                                                      @MaxTableRows = @MaxTableRows, @MaxIndexSizeMB = @MaxIndexSizeMB;
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
