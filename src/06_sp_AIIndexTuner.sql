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
    AIIndexTuner.usp_MarkAbandonedRuns (issue #50): a run whose session was killed, timed out on the client
    or failed over never reaches the CATCH block that marks it Failed, so it stayed Running and its open
    RunLog step never closed. Each new run first marks such runs Abandoned and closes their open steps.
    A Running run is known to be over when:
    - it was started by this session (@@SPID): this session is running the new call now, so whatever it
      ran before has ended. A client-side query timeout ends the batch but keeps the connection, pooled
      ones included, and a reused session id belongs to a later login.
    - its session (id and login time) no longer runs a request: it is gone, logged in again, or idle.
      Seeing other sessions needs VIEW SERVER STATE (VIEW DATABASE STATE in Azure SQL Database); without
      it only the first rule applies.
    - it is from before the session was recorded and started more than a day ago (same permission).
    Never throws: it is housekeeping, and must not stop the run.
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_MarkAbandonedRuns
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @Now datetime2(3) = SYSDATETIME();
        DECLARE @Abandoned TABLE (RunId int PRIMARY KEY);
        DECLARE @SeeAll bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5
                                   THEN HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DATABASE STATE')
                                   ELSE HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW SERVER STATE') END;

        INSERT @Abandoned (RunId)
        SELECT RunId FROM AIIndexTuner.Run WHERE Status = 'Running' AND SessionId = @@SPID;

        IF @SeeAll = 1
            INSERT @Abandoned (RunId)
            SELECT r.RunId
            FROM AIIndexTuner.Run AS r
            WHERE r.Status = 'Running'
              AND NOT EXISTS (SELECT 1 FROM @Abandoned AS a WHERE a.RunId = r.RunId)
              AND (   (r.SessionId IS NULL AND r.StartedAt < DATEADD(DAY, -1, @Now))
                   OR (r.SessionId IS NOT NULL
                       AND NOT EXISTS (SELECT 1
                                       FROM sys.dm_exec_sessions AS s
                                       INNER JOIN sys.dm_exec_requests AS q ON q.session_id = s.session_id
                                       WHERE s.session_id = r.SessionId AND s.login_time = r.SessionLoginTime)));

        UPDATE r
        SET Status = 'Abandoned', CompletedAt = @Now,
            ErrorMessage = LEFT(CONCAT(
                N'Abandoned: the session that ran it ended or stopped running it before it finished (killed, a client-side query timeout or a failover); found at the start of a later run.',
                CASE WHEN r.StoredResponseId IS NOT NULL AND r.StoredResponseDeleted IS NULL
                     THEN CONCAT(N' Its response ', r.StoredResponseId, N' may still be stored, or running, on the endpoint: cancel and delete it with POST <endpoint>/openai/v1/responses/',
                                 r.StoredResponseId, N'/cancel and DELETE <endpoint>/openai/v1/responses/', r.StoredResponseId, N'.') END), 4000)
        FROM AIIndexTuner.Run AS r
        INNER JOIN @Abandoned AS a ON a.RunId = r.RunId;

        UPDATE l
        SET EndTime = @Now, ElapsedMs = DATEDIFF(MILLISECOND, l.StartTime, @Now),
            Message = LEFT(CONCAT(l.Message + N'; ', N'Abandoned: the run''s session ended or stopped running it.'), 4000)
        FROM AIIndexTuner.RunLog AS l
        INNER JOIN @Abandoned AS a ON a.RunId = l.RunId
        WHERE l.EndTime IS NULL;
    END TRY
    BEGIN CATCH
    END CATCH;
END;
GO

/*
    AIIndexTuner.usp_PurgeRuns (issue #55): removes run history. sp_AIIndexTuner_Purge and, when
    AIIndexTuner.Config sets a retention, each sp_AIIndexTuner run call it.
    - @DeleteBefore: a run completed before it is deleted with its RunLog rows and recommendations.
      Unless @IncludeApplied = 1, a run with Applied recommendations keeps its row and those
      recommendations (the AppliedDDL and UndoDDL that record what changed); its other
      recommendations, its RunLog rows and its detail go. RunLog rows of @CollectOnly calls (no run)
      that started before it go too.
    - @DetailBefore: a run completed before it, and not deleted, loses CollectedData and RawResponse.
    A run still Running has no CompletedAt and is never touched. Each run is changed in its own
    transaction, holding the run's apply lock (AIIndexTuner.Apply.Run.<RunId>, see
    usp_ApplyRecommendation), so a run another session is applying is skipped, not changed under it.
    @WhatIf = 1 changes nothing and reports what would be done. @Results = 1 returns one row per run
    (and one for the RunLog rows without a run); the counts are what was, or would be, removed.
    Must run outside a transaction, except with @WhatIf = 1: each run's changes commit on their own.
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_PurgeRuns
    @DeleteBefore   datetime2(0) = NULL,
    @DetailBefore   datetime2(0) = NULL,
    @IncludeApplied bit = 0,
    @WhatIf         bit = 0,
    @Results        bit = 1,
    @RunsDeleted    int = NULL OUTPUT,   -- runs deleted whole
    @RunsTrimmed    int = NULL OUTPUT,   -- runs kept for their Applied recommendations, the rest removed
    @DetailCleared  int = NULL OUTPUT,   -- runs that lost only CollectedData and RawResponse
    @RunsSkipped    int = NULL OUTPUT    -- runs another session was applying, or whose change failed
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SELECT @RunsDeleted = 0, @RunsTrimmed = 0, @DetailCleared = 0, @RunsSkipped = 0, @IncludeApplied = ISNULL(@IncludeApplied, 0), @WhatIf = ISNULL(@WhatIf, 0);

    IF @@TRANCOUNT > 0 AND @WhatIf = 0
        THROW 50402, N'Run the purge outside a transaction: each run''s changes commit on their own. @WhatIf = 1 may run inside one.', 1;

    DECLARE @Plan TABLE (
        RunId int NULL, StartedAt datetime2(0) NULL, CompletedAt datetime2(0) NULL, RunStatus varchar(20) NULL,
        Action varchar(30) NOT NULL, RunLogRows int NOT NULL, RecommendationRows int NOT NULL, AppliedKept int NOT NULL,
        DetailChars bigint NOT NULL, Outcome nvarchar(2048) NULL);

    -- The runs old enough for either cutoff, then their RunLog and recommendation counts, each
    -- aggregated once over those runs and joined, not looked up per run.
    DECLARE @Candidates TABLE (RunId int PRIMARY KEY);
    INSERT @Candidates (RunId)
    SELECT RunId FROM AIIndexTuner.Run
    WHERE CompletedAt < @DeleteBefore
       OR (CompletedAt < @DetailBefore AND (CollectedData IS NOT NULL OR RawResponse IS NOT NULL));

    -- A run completed before @DeleteBefore is listed unless it was already trimmed to its Applied
    -- recommendations (nothing left to remove); one before @DetailBefore only while it has detail.
    INSERT @Plan (RunId, StartedAt, CompletedAt, RunStatus, Action, RunLogRows, RecommendationRows, AppliedKept, DetailChars)
    SELECT r.RunId, r.StartedAt, r.CompletedAt, r.Status, a.Action,
           CASE WHEN a.Action = 'Clear detail' THEN 0 ELSE ISNULL(l.Logs, 0) END,
           CASE a.Action WHEN 'Delete' THEN ISNULL(c.Recs, 0) WHEN 'Delete except Applied' THEN c.Recs - c.Applied ELSE 0 END,
           CASE WHEN a.Action = 'Delete except Applied' THEN c.Applied ELSE 0 END,
           ISNULL(DATALENGTH(r.CollectedData), 0) / 2 + ISNULL(DATALENGTH(r.RawResponse), 0) / 2
    FROM @Candidates AS cand
    INNER JOIN AIIndexTuner.Run AS r ON r.RunId = cand.RunId
    LEFT JOIN (SELECT rl.RunId, COUNT(*) AS Logs
               FROM AIIndexTuner.RunLog AS rl INNER JOIN @Candidates AS x ON x.RunId = rl.RunId
               GROUP BY rl.RunId) AS l ON l.RunId = r.RunId
    LEFT JOIN (SELECT rec.RunId, COUNT(*) AS Recs, COUNT(CASE WHEN rec.Status = 'Applied' THEN 1 END) AS Applied
               FROM AIIndexTuner.Recommendation AS rec INNER JOIN @Candidates AS x ON x.RunId = rec.RunId
               GROUP BY rec.RunId) AS c ON c.RunId = r.RunId
    CROSS APPLY (SELECT CASE WHEN r.CompletedAt < @DeleteBefore
                             THEN CASE WHEN @IncludeApplied = 0 AND c.Applied > 0 THEN 'Delete except Applied' ELSE 'Delete' END
                             ELSE 'Clear detail' END AS Action) AS a
    WHERE (r.CompletedAt < @DeleteBefore
           AND (a.Action = 'Delete' OR c.Recs > c.Applied OR l.Logs > 0 OR r.CollectedData IS NOT NULL OR r.RawResponse IS NOT NULL))
       OR (r.CompletedAt < @DetailBefore AND (r.CollectedData IS NOT NULL OR r.RawResponse IS NOT NULL));

    DECLARE @RunId int, @Action varchar(30), @Lock nvarchar(255), @Got int, @Logs int, @Recs int, @Outcome nvarchar(2048);
    IF @WhatIf = 1
        UPDATE @Plan SET Outcome = N'WhatIf: not changed';
    ELSE
    BEGIN
        DECLARE purge_cur CURSOR LOCAL FAST_FORWARD FOR SELECT RunId, Action FROM @Plan ORDER BY RunId;
        OPEN purge_cur;
        FETCH NEXT FROM purge_cur INTO @RunId, @Action;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @Logs = 0, @Recs = 0, @Outcome = NULL, @Lock = CONCAT(N'AIIndexTuner.Apply.Run.', @RunId);
            BEGIN TRY
                BEGIN TRANSACTION;
                EXEC @Got = sys.sp_getapplock @Resource = @Lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 0;
                IF @Got < 0
                BEGIN
                    ROLLBACK TRANSACTION;
                    SET @Outcome = N'Skipped: another session is applying this run''s recommendations. The next purge tries again.';
                END
                ELSE
                BEGIN
                    IF @Action IN ('Delete', 'Delete except Applied')
                    BEGIN
                        DELETE AIIndexTuner.RunLog WHERE RunId = @RunId;
                        SET @Logs = @@ROWCOUNT;
                        DELETE AIIndexTuner.Recommendation WHERE RunId = @RunId AND (@IncludeApplied = 1 OR Status <> 'Applied');
                        SET @Recs = @@ROWCOUNT;
                    END;
                    -- Re-checked in the transaction: a recommendation applied since the plan keeps its run.
                    IF @Action = 'Delete' AND NOT EXISTS (SELECT 1 FROM AIIndexTuner.Recommendation WHERE RunId = @RunId)
                        DELETE AIIndexTuner.Run WHERE RunId = @RunId;
                    ELSE
                    BEGIN
                        IF @Action = 'Delete' SET @Action = 'Delete except Applied';
                        UPDATE AIIndexTuner.Run SET CollectedData = NULL, RawResponse = NULL
                        WHERE RunId = @RunId AND (CollectedData IS NOT NULL OR RawResponse IS NOT NULL);
                    END;
                    COMMIT TRANSACTION;
                    SET @Outcome = N'Done';
                END;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
                SELECT @Logs = 0, @Recs = 0, @Outcome = LEFT(CONCAT(N'Skipped: ', ERROR_MESSAGE()), 2048);
            END CATCH;

            UPDATE @Plan
            SET Outcome = @Outcome, Action = @Action, RunLogRows = @Logs, RecommendationRows = @Recs,
                AppliedKept = CASE WHEN @Action = 'Delete except Applied'
                                   THEN (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @RunId) ELSE 0 END,
                DetailChars = CASE WHEN @Outcome = N'Done' THEN DetailChars ELSE 0 END
            WHERE RunId = @RunId;
            FETCH NEXT FROM purge_cur INTO @RunId, @Action;
        END;
        CLOSE purge_cur;
        DEALLOCATE purge_cur;
    END;

    -- RunLog rows of @CollectOnly calls, which create no run.
    IF @DeleteBefore IS NOT NULL
    BEGIN
        IF @WhatIf = 1
            SET @Logs = (SELECT COUNT(*) FROM AIIndexTuner.RunLog WHERE RunId IS NULL AND StartTime < @DeleteBefore);
        ELSE
        BEGIN
            DELETE AIIndexTuner.RunLog WHERE RunId IS NULL AND StartTime < @DeleteBefore;
            SET @Logs = @@ROWCOUNT;
        END;
        IF @Logs > 0
            INSERT @Plan (RunId, Action, RunLogRows, RecommendationRows, AppliedKept, DetailChars, Outcome)
            VALUES (NULL, 'Delete', @Logs, 0, 0, 0, CASE WHEN @WhatIf = 1 THEN N'WhatIf: not changed' ELSE N'Done' END
                    + N' (RunLog rows of @CollectOnly calls, which have no run)');
    END;

    SELECT @RunsDeleted   = COUNT(CASE WHEN RunId IS NOT NULL AND Action = 'Delete' AND Outcome NOT LIKE N'Skipped%' THEN 1 END),
           @RunsTrimmed   = COUNT(CASE WHEN Action = 'Delete except Applied' AND Outcome NOT LIKE N'Skipped%' THEN 1 END),
           @DetailCleared = COUNT(CASE WHEN Action = 'Clear detail' AND Outcome NOT LIKE N'Skipped%' THEN 1 END),
           @RunsSkipped   = COUNT(CASE WHEN Outcome LIKE N'Skipped%' THEN 1 END)
    FROM @Plan;

    IF @Results = 1
        SELECT RunId, StartedAt, CompletedAt, RunStatus, Action, RunLogRows, RecommendationRows, AppliedKept, DetailChars, Outcome
        FROM @Plan
        ORDER BY CASE WHEN RunId IS NULL THEN 1 ELSE 0 END, RunId;
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

    -- A NULL passed explicitly, as in the script SSMS writes for Execute Procedure, means the default.
    SET @Mode = UPPER(LTRIM(RTRIM(ISNULL(@Mode, 'RECOMMEND'))));
    SET @CollectOnly = ISNULL(@CollectOnly, 0);
    SET @SchemaName = NULLIF(LTRIM(RTRIM(@SchemaName)), N'');
    SET @TableName = NULLIF(LTRIM(RTRIM(@TableName)), N'');

    IF @Mode NOT IN ('RECOMMEND', 'CREATE')
        THROW 50201, N'@Mode must be RECOMMEND or CREATE.', 1;
    IF @TableName IS NOT NULL AND @SchemaName IS NULL
        THROW 50202, N'@SchemaName is required when @TableName is specified.', 1;
    -- master, tempdb, model and msdb, and databases that SQL Server features own (issue #52): the
    -- replication distribution database, the SSIS catalog and Reporting Services catalogs.
    IF DB_ID() <= 4
       OR EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_distributor = 1)
       OR DB_NAME() IN (N'distribution', N'SSISDB')
       OR (OBJECT_ID(N'dbo.ExecutionLogStorage', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.Catalog', N'U') IS NOT NULL)   -- a report server catalog, whatever its name
       OR (OBJECT_ID(N'dbo.PersistedStream', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.SessionData', N'U') IS NOT NULL)   -- a report server temp database
        THROW 50203, N'Run sp_AIIndexTuner in a user database, not a system database or one that a SQL Server feature owns (distribution, SSISDB, a report server catalog or report server temp database).', 1;
    IF @SchemaName IS NOT NULL AND SCHEMA_ID(@SchemaName) IS NULL
        THROW 50204, N'The schema in @SchemaName does not exist in this database.', 1;
    IF @TableName IS NOT NULL AND OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName), N'U') IS NULL
        THROW 50205, N'The table in @SchemaName.@TableName does not exist in this database.', 1;

    DECLARE @IncludeQueryText bit = 1, @KeepDetail bit = 1, @Endpoint nvarchar(400), @Deployment nvarchar(128), @Effort varchar(10),
            @MaxPayloadChars int, @CredentialName sysname, @ConfigLogging bit, @RetainRunDays int, @RetainRunDetailDays int;
    SELECT @IncludeQueryText = IncludeQueryText, @KeepDetail = KeepRunDetail,
           @Endpoint = Endpoint, @Deployment = Deployment, @Effort = ReasoningEffort, @MaxPayloadChars = MaxPayloadChars,
           @CredentialName = CredentialName, @ConfigLogging = EnableLogging,
           @RetainRunDays = RetainRunDays, @RetainRunDetailDays = RetainRunDetailDays
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

    -- Runs left Running by a session that is gone or has moved on (issue #50).
    EXEC AIIndexTuner.usp_MarkAbandonedRuns;

    DECLARE @RunId int;
    INSERT AIIndexTuner.Run (SessionId, SessionLoginTime, Mode, SchemaName, TableName, Endpoint, Deployment, ApiShape, ReasoningEffort, SystemPromptHash,
                             AllowColumnstore, AllowDropIndex, MaxNewIndexes, MinPriority, MinConfidence, MaxTableRows, MaxIndexSizeMB, Version)
    VALUES (@@SPID, (SELECT login_time FROM sys.dm_exec_sessions WHERE session_id = @@SPID),
            @Mode, @SchemaName, @TableName,
            CASE WHEN @TestResponse IS NULL THEN @Endpoint END,
            CASE WHEN @TestResponse IS NULL THEN @Deployment END,
            CASE WHEN @TestResponse IS NULL THEN 'OpenAIResponses' ELSE 'Test' END,
            CASE WHEN @TestResponse IS NULL THEN @Effort END,
            CONVERT(char(64), HASHBYTES('SHA2_256', @SystemPrompt), 2),
            @AllowColumnstore, @AllowDropIndex, @MaxNewIndexes, @MinPriority, @MinConfidence, @MaxTableRows, @MaxIndexSizeMB,
            AIIndexTuner.fn_Version());
    SET @RunId = SCOPE_IDENTITY();
    -- With XACT_ABORT OFF a failed INSERT does not stop the procedure; without a run row nothing
    -- after this can be recorded.
    IF @RunId IS NULL
        THROW 50216, N'The run could not be recorded in AIIndexTuner.Run (see the error above), so the run was not started.', 1;

    /* Run history retention (issue #55): with AIIndexTuner.Config.RetainRunDays or RetainRunDetailDays
       set, each run first purges older history, so a scheduled job needs no second step. This run is not
       complete, so it is never purged. It never stops the run: an error is only logged. Inside a caller's
       transaction it is not run, since each purged run commits on its own. */
    IF @RetainRunDays IS NOT NULL OR @RetainRunDetailDays IS NOT NULL
    BEGIN
        DECLARE @PurgeLogId int, @PurgeLogChars int, @PurgeLogRow int, @PurgeMsg nvarchar(4000), @PurgeNow datetime2(0) = SYSDATETIME(),
                @PurgeDeleteBefore datetime2(0), @PurgeDetailBefore datetime2(0),
                @PurgeDeleted int, @PurgeTrimmed int, @PurgeCleared int, @PurgeSkipped int;
        SELECT @PurgeDeleteBefore = DATEADD(DAY, -@RetainRunDays, @PurgeNow), @PurgeDetailBefore = DATEADD(DAY, -@RetainRunDetailDays, @PurgeNow);
        EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'Purge run history', @LogId = @PurgeLogId OUTPUT, @CharsAtStart = @PurgeLogChars OUTPUT;
        SET @PurgeLogRow = @PurgeLogId;
        IF @@TRANCOUNT > 0
            SET @PurgeMsg = N'Not run: sp_AIIndexTuner was called inside a transaction. Run sp_AIIndexTuner_Purge outside one.';
        ELSE
        BEGIN
            BEGIN TRY
                EXEC AIIndexTuner.usp_PurgeRuns @DeleteBefore = @PurgeDeleteBefore, @DetailBefore = @PurgeDetailBefore, @Results = 0,
                                                @RunsDeleted = @PurgeDeleted OUTPUT, @RunsTrimmed = @PurgeTrimmed OUTPUT,
                                                @DetailCleared = @PurgeCleared OUTPUT, @RunsSkipped = @PurgeSkipped OUTPUT;
                SET @PurgeMsg = CONCAT(N'Runs deleted: ', @PurgeDeleted, N'; kept for their Applied recommendations, the rest removed: ', @PurgeTrimmed,
                                       N'; detail cleared: ', @PurgeCleared, N'; skipped: ', @PurgeSkipped,
                                       CASE WHEN @PurgeSkipped > 0 THEN N' (being applied, or failed; see EXEC dbo.sp_AIIndexTuner_Purge @WhatIf = 1)' END);
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                SET @PurgeMsg = LEFT(CONCAT(N'Failed: ', ERROR_MESSAGE()), 4000);
            END CATCH;
        END;
        EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, NULL, @LogId = @PurgeLogId OUTPUT, @CharsAtStart = @PurgeLogChars OUTPUT;
        IF @Logging = 1
            UPDATE AIIndexTuner.RunLog SET Message = @PurgeMsg WHERE RunLogId = @PurgeLogRow;
    END;

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

    SELECT r.RunId, r.Version, r.Status AS RunStatus, r.ModelUsed, r.InputTokens, r.OutputTokens, r.Summary,
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

/*
    dbo.sp_AIIndexTuner_Purge: delete old run history (issue #55).

        EXEC dbo.sp_AIIndexTuner_Purge @WhatIf = 1;                       -- what the configured retention would remove
        EXEC dbo.sp_AIIndexTuner_Purge;                                   -- apply the configured retention
        EXEC dbo.sp_AIIndexTuner_Purge @OlderThanDays = 90;               -- delete runs completed over 90 days ago
        EXEC dbo.sp_AIIndexTuner_Purge @OlderThanDays = 7, @DetailOnly = 1;   -- only clear their CollectedData and RawResponse

    @OlderThanDays NULL (the default) uses AIIndexTuner.Config: RetainRunDays deletes runs, and
    RetainRunDetailDays clears the detail of newer ones; @DetailOnly = 1 uses only RetainRunDetailDays.
    Given, it is the one cutoff: runs completed more than that many days ago are deleted, or with
    @DetailOnly = 1 only lose CollectedData and RawResponse. 0 means every completed run.

    A deleted run takes its AIIndexTuner.RunLog rows and recommendations with it, except that a run
    with Applied recommendations keeps its row and those recommendations, the record of what changed
    and its UndoDDL; @IncludeApplied = 1 deletes them too. Runs still Running are never touched, and
    a run another session is applying is skipped. RunLog rows of @CollectOnly calls older than the
    cutoff are deleted as well.

    Returns one row per run: the action, the rows and characters removed (or that would be, with
    @WhatIf = 1), and the outcome. Run it outside a transaction, except with @WhatIf = 1.
*/
CREATE OR ALTER PROCEDURE dbo.sp_AIIndexTuner_Purge
    @OlderThanDays  int = NULL,
    @DetailOnly     bit = 0,
    @IncludeApplied bit = 0,
    @WhatIf         bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    -- A NULL passed explicitly, as in the script SSMS writes for Execute Procedure, means the default.
    SELECT @DetailOnly = ISNULL(@DetailOnly, 0), @IncludeApplied = ISNULL(@IncludeApplied, 0), @WhatIf = ISNULL(@WhatIf, 0);
    IF @OlderThanDays < 0
        THROW 50401, N'@OlderThanDays must be 0 or more, or NULL for the retention in AIIndexTuner.Config.', 1;

    DECLARE @DeleteDays int, @DetailDays int, @Now datetime2(0) = SYSDATETIME(), @DeleteBefore datetime2(0), @DetailBefore datetime2(0);
    IF @OlderThanDays IS NOT NULL
        SELECT @DeleteDays = CASE WHEN ISNULL(@DetailOnly, 0) = 0 THEN @OlderThanDays END,
               @DetailDays = CASE WHEN @DetailOnly = 1 THEN @OlderThanDays END;
    ELSE
        SELECT @DeleteDays = CASE WHEN ISNULL(@DetailOnly, 0) = 0 THEN RetainRunDays END, @DetailDays = RetainRunDetailDays
        FROM AIIndexTuner.Config WHERE ConfigId = 1;

    IF @DeleteDays IS NULL AND @DetailDays IS NULL
        THROW 50403, N'No retention is set: pass @OlderThanDays, or set RetainRunDays or RetainRunDetailDays in AIIndexTuner.Config (RetainRunDetailDays when @DetailOnly = 1).', 1;

    SELECT @DeleteBefore = DATEADD(DAY, -@DeleteDays, @Now), @DetailBefore = DATEADD(DAY, -@DetailDays, @Now);
    EXEC AIIndexTuner.usp_PurgeRuns @DeleteBefore = @DeleteBefore, @DetailBefore = @DetailBefore,
                                    @IncludeApplied = @IncludeApplied, @WhatIf = @WhatIf, @Results = 1;
END;
GO
