SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    aisqltuner-index-tuner: schema, configuration and result tables.

    Install in the user database you want to tune. The proc calls your AI endpoint through a
    DATABASE SCOPED CREDENTIAL, and credentials are per database, so everything lives here.
*/
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'AIIndexTuner') IS NULL
    EXEC (N'CREATE SCHEMA AIIndexTuner AUTHORIZATION dbo;');
GO

/* One row: which endpoint, deployment and credential to use, and how. */
IF OBJECT_ID(N'AIIndexTuner.Config', N'U') IS NULL
BEGIN
    CREATE TABLE AIIndexTuner.Config
    (
        ConfigId            tinyint         NOT NULL CONSTRAINT PK_AIIndexTuner_Config PRIMARY KEY
                                                     CONSTRAINT CK_AIIndexTuner_Config_Single CHECK (ConfigId = 1),
        -- Root endpoint of your Azure OpenAI / Microsoft Foundry resource, e.g.
        -- https://my-resource.openai.azure.com/ or https://my-resource.cognitiveservices.azure.com/
        -- Do not append /openai, /models or /anthropic/v1/messages; the proc builds the path.
        Endpoint            nvarchar(400)   NOT NULL,
        -- Azure OpenAI deployment name, called through the Responses API. Only OpenAI models are
        -- supported for now.
        Deployment          nvarchar(128)   NOT NULL,
        -- DATABASE SCOPED CREDENTIAL whose name is a prefix of the request URL.
        CredentialName      sysname         NOT NULL,
        ReasoningEffort     varchar(10)     NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Effort DEFAULT ('medium')
                                                     CONSTRAINT CK_AIIndexTuner_Config_Effort CHECK (ReasoningEffort IN ('low', 'medium', 'high')),
        MaxOutputTokens     int             NOT NULL CONSTRAINT DF_AIIndexTuner_Config_MaxTokens DEFAULT (32000),
        -- sp_invoke_external_rest_endpoint caps a single call at 230 seconds.
        RequestTimeoutSec   smallint        NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Timeout DEFAULT (230)
                                                     CONSTRAINT CK_AIIndexTuner_Config_Timeout CHECK (RequestTimeoutSec BETWEEN 1 AND 230),
        -- Run the response in background mode and poll for it, so a long reasoning run is not
        -- cut off by the 230 second limit.
        UseBackgroundMode   bit             NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Background DEFAULT (1),
        MaxWaitSec          int             NOT NULL CONSTRAINT DF_AIIndexTuner_Config_MaxWait DEFAULT (900),
        PollIntervalSec     tinyint         NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Poll DEFAULT (5)
                                                     CONSTRAINT CK_AIIndexTuner_Config_Poll CHECK (PollIntervalSec BETWEEN 1 AND 59),
        -- Ask the model for schema-constrained JSON. Turn off for models that reject it.
        UseStructuredOutput bit             NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Structured DEFAULT (1),
        -- Plan cache query text can contain literals. 0 leaves it out of the prompt.
        IncludeQueryText    bit             NOT NULL CONSTRAINT DF_AIIndexTuner_Config_QueryText DEFAULT (1),
        -- Keep the collected data and the raw model response on each run, for troubleshooting.
        KeepRunDetail       bit             NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Keep DEFAULT (1)
    );
END;
GO

IF OBJECT_ID(N'AIIndexTuner.Run', N'U') IS NULL
BEGIN
    CREATE TABLE AIIndexTuner.Run
    (
        RunId               int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AIIndexTuner_Run PRIMARY KEY,
        StartedAt           datetime2(0)    NOT NULL CONSTRAINT DF_AIIndexTuner_Run_Started DEFAULT (SYSDATETIME()),
        CompletedAt         datetime2(0)    NULL,
        StartedBy           sysname         NOT NULL CONSTRAINT DF_AIIndexTuner_Run_StartedBy DEFAULT (ORIGINAL_LOGIN()),
        Mode                varchar(10)     NOT NULL,
        SchemaName          sysname         NULL,
        TableName           sysname         NULL,
        Endpoint            nvarchar(400)   NULL,
        Deployment          nvarchar(128)   NULL,
        ApiShape            varchar(20)     NULL,   -- OpenAIResponses | Test
        ReasoningEffort     varchar(10)     NULL,
        SystemPromptHash    char(64)        NULL,
        CollectedChars      int             NULL,
        ModelUsed           nvarchar(128)   NULL,
        InputTokens         int             NULL,
        OutputTokens        int             NULL,
        Truncated           bit             NULL,
        Status              varchar(20)     NOT NULL CONSTRAINT DF_AIIndexTuner_Run_Status DEFAULT ('Running'),
        ErrorMessage        nvarchar(4000)  NULL,
        Summary             nvarchar(max)   NULL,
        CollectedData       nvarchar(max)   NULL,
        RawResponse         nvarchar(max)   NULL
    );
END;
GO

/* Columns added after the first release. ALTER, so an existing install keeps its runs. */
IF COL_LENGTH(N'AIIndexTuner.Run', N'PayloadSupplied') IS NULL
    ALTER TABLE AIIndexTuner.Run ADD
        PayloadSupplied bit      NOT NULL CONSTRAINT DF_AIIndexTuner_Run_PayloadSupplied DEFAULT (0),  -- @CollectedData was passed in
        PayloadHash     char(64) NULL,   -- SHA-256 of the collected data, so runs with the same input can be identified
        CollectMs       int      NULL,
        ModelMs         int      NULL,
        ApplyMs         int      NULL,
        PollCount       int      NULL;   -- background-mode polls of the AI response
GO

/* Change controls (sp_AIIndexTuner @AllowColumnstore, @AllowDropIndex, @MaxNewIndexes). For the two
   bits: NULL = may be recommended, never applied unless sp_AIIndexTuner_Apply is told to;
   1 = may be recommended and applied; 0 = not recommended and never applied. */
IF COL_LENGTH(N'AIIndexTuner.Run', N'AllowColumnstore') IS NULL
    ALTER TABLE AIIndexTuner.Run ADD
        AllowColumnstore bit NULL,
        AllowDropIndex   bit NULL,
        MaxNewIndexes    int NULL;   -- at most this many new indexes are recommended and created
GO

/* The largest collected payload sent to the model, in characters; NULL = no limit. A larger one fails
   before the request with an error that names its size, rather than with whatever the deployment
   returns: a context-length error, or a tokens-per-minute rate limit that says nothing about size.
   500,000 characters is roughly 125,000 to 170,000 tokens. WITH VALUES gives existing installs the
   default too. */
IF COL_LENGTH(N'AIIndexTuner.Config', N'MaxPayloadChars') IS NULL
    ALTER TABLE AIIndexTuner.Config ADD
        MaxPayloadChars int NULL CONSTRAINT DF_AIIndexTuner_Config_MaxPayload DEFAULT (500000) WITH VALUES
                                 CONSTRAINT CK_AIIndexTuner_Config_MaxPayload CHECK (MaxPayloadChars > 0);
GO

/* Apply thresholds (sp_AIIndexTuner @MinPriority, @MinConfidence): High, Medium or Low. Only a
   recommendation whose priority level and confidence are at that level or above is applied; the
   rest stay for review. NULL = no minimum. Unlike the change controls, they do not change the prompt. */
IF COL_LENGTH(N'AIIndexTuner.Run', N'MinPriority') IS NULL
    ALTER TABLE AIIndexTuner.Run ADD
        MinPriority   varchar(10) NULL,
        MinConfidence varchar(10) NULL;
GO

/* The response the endpoint stored for the run (issue #48). The Responses API keeps a response for
   30 days by default, prompt and answer included; usp_InvokeModel deletes it once the run is done
   with it. StoredResponseDeleted: 1 = deleted, 0 = the delete failed (AIIndexTuner.RunLog says why;
   delete it yourself with DELETE <endpoint>/openai/v1/responses/<StoredResponseId>), NULL = no
   response was stored (a test response, or the request failed before the endpoint created one). */
IF COL_LENGTH(N'AIIndexTuner.Run', N'StoredResponseId') IS NULL
    ALTER TABLE AIIndexTuner.Run ADD
        StoredResponseId      nvarchar(200) NULL,
        StoredResponseDeleted bit           NULL;
GO

/* Size limits for builds (issue #49): sp_AIIndexTuner @MaxTableRows, @MaxIndexSizeMB. NULL = no limit. */
IF COL_LENGTH(N'AIIndexTuner.Run', N'MaxTableRows') IS NULL
    ALTER TABLE AIIndexTuner.Run ADD
        MaxTableRows   bigint NULL,
        MaxIndexSizeMB int    NULL;
GO

/* How CREATE mode and sp_AIIndexTuner_Apply wait for locks and use CPUs (issue #49). NULL turns each off.
   LockTimeoutSec: the longest a drop, an offline build or a columnstore build waits for its locks before
   it fails (SET LOCK_TIMEOUT). OnlineWaitMinutes: an online rowstore build waits this long at low priority
   for its brief S and Sch-M locks, then gives up (WAIT_AT_LOW_PRIORITY ... ABORT_AFTER_WAIT = SELF).
   BuildMaxDop: MAXDOP for every build; NULL leaves the server's setting. WITH VALUES gives existing installs
   the defaults too. */
IF COL_LENGTH(N'AIIndexTuner.Config', N'LockTimeoutSec') IS NULL
    ALTER TABLE AIIndexTuner.Config ADD
        LockTimeoutSec    int     NULL CONSTRAINT DF_AIIndexTuner_Config_LockTimeout DEFAULT (30) WITH VALUES
                                       CONSTRAINT CK_AIIndexTuner_Config_LockTimeout CHECK (LockTimeoutSec BETWEEN 1 AND 3600),
        OnlineWaitMinutes int     NULL CONSTRAINT DF_AIIndexTuner_Config_OnlineWait DEFAULT (5) WITH VALUES
                                       CONSTRAINT CK_AIIndexTuner_Config_OnlineWait CHECK (OnlineWaitMinutes BETWEEN 1 AND 1440),
        BuildMaxDop       tinyint NULL CONSTRAINT CK_AIIndexTuner_Config_MaxDop CHECK (BuildMaxDop BETWEEN 1 AND 64);
GO

/* Step logging (issue #38): sp_AIIndexTuner @Logging, NULL = this default. On by default, since a
   run writes only about 30 small rows. WITH VALUES gives existing installs the default too. */
IF COL_LENGTH(N'AIIndexTuner.Config', N'EnableLogging') IS NULL
    ALTER TABLE AIIndexTuner.Config ADD
        EnableLogging bit NOT NULL CONSTRAINT DF_AIIndexTuner_Config_Logging DEFAULT (1) WITH VALUES;
GO

/* One row per step of a run: each collector section, the AI request and the wait for its answer,
   and each recommendation applied. A row is written when its step starts and completed when it
   ends, each in its own autocommit statement, so another session can see the step running now:
   the row with EndTime NULL. RunId is NULL for @CollectOnly = 1, which creates no run. */
IF OBJECT_ID(N'AIIndexTuner.RunLog', N'U') IS NULL
BEGIN
    CREATE TABLE AIIndexTuner.RunLog
    (
        RunLogId    int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AIIndexTuner_RunLog PRIMARY KEY,
        RunId       int             NULL CONSTRAINT FK_AIIndexTuner_RunLog_Run REFERENCES AIIndexTuner.Run (RunId),
        Collector   nvarchar(128)   NOT NULL,   -- the section name as in the payload, or AI request, AI response, Apply ...
        StartTime   datetime2(3)    NOT NULL,
        EndTime     datetime2(3)    NULL,       -- NULL while the step runs
        ElapsedMs   int             NULL,
        Chars       int             NULL,       -- characters the section added to the payload; for the AI steps, of the request and of the answer
        Message     nvarchar(4000)  NULL        -- AI response: polls and status so far; a failed step: the error
    );

    CREATE INDEX IX_AIIndexTuner_RunLog_Run ON AIIndexTuner.RunLog (RunId, RunLogId);
END;
GO

IF OBJECT_ID(N'AIIndexTuner.Recommendation', N'U') IS NULL
BEGIN
    CREATE TABLE AIIndexTuner.Recommendation
    (
        RecommendationId    int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AIIndexTuner_Recommendation PRIMARY KEY,
        RunId               int             NOT NULL CONSTRAINT FK_AIIndexTuner_Recommendation_Run
                                                     REFERENCES AIIndexTuner.Run (RunId),
        Priority            int             NULL,
        Category            varchar(30)     NOT NULL,
        Title               nvarchar(400)   NULL,
        SchemaName          sysname         NULL,
        TableName           sysname         NULL,
        IndexName           sysname         NULL,
        KeyColumns          nvarchar(max)   NULL,   -- JSON array of {column, descending}
        IncludeColumns      nvarchar(max)   NULL,   -- JSON array of column names
        FilterPredicate     nvarchar(4000)  NULL,
        IsUnique            bit             NULL,
        [FillFactor]        tinyint         NULL,
        DataCompression     varchar(10)     NULL,
        EstimatedSizeMB     decimal(18, 2)  NULL,
        Confidence          varchar(10)     NULL,
        Rationale           nvarchar(max)   NULL,
        BenefitingQueries   nvarchar(max)   NULL,   -- JSON array
        Script              nvarchar(max)   NULL,   -- the model's script: for review only, never executed
        Status              varchar(20)     NOT NULL CONSTRAINT DF_AIIndexTuner_Recommendation_Status DEFAULT ('Recommended'),
        StatusReason        nvarchar(4000)  NULL,
        AppliedDDL          nvarchar(max)   NULL,   -- the DDL the proc built and ran
        AppliedAt           datetime2(0)    NULL,
        AppliedBy           sysname         NULL
    );

    CREATE INDEX IX_AIIndexTuner_Recommendation_Run ON AIIndexTuner.Recommendation (RunId, Priority);
END;
GO

IF COL_LENGTH(N'AIIndexTuner.Recommendation', N'IndexType') IS NULL
    ALTER TABLE AIIndexTuner.Recommendation ADD
        IndexType varchar(30)   NULL,   -- CreateIndex: NONCLUSTERED, NONCLUSTERED COLUMNSTORE or CLUSTERED COLUMNSTORE
        UndoDDL   nvarchar(max) NULL;   -- reverses AppliedDDL: the DROP for a created index, the CREATE for a dropped one
GO

IF COL_LENGTH(N'AIIndexTuner.Recommendation', N'PriorityLevel') IS NULL
    ALTER TABLE AIIndexTuner.Recommendation ADD
        PriorityLevel varchar(10) NULL;   -- High, Medium or Low; Priority is the rank within the run (1 = most important)
GO

IF COL_LENGTH(N'AIIndexTuner.Recommendation', N'ReplacesIndex') IS NULL
    ALTER TABLE AIIndexTuner.Recommendation ADD
        ReplacesIndex sysname NULL;   -- ConsolidateIndex: the existing nonclustered index a widening rebuilds, under its own name
GO

IF COL_LENGTH(N'AIIndexTuner.Recommendation', N'ScriptWarning') IS NULL
    ALTER TABLE AIIndexTuner.Recommendation ADD
        ScriptWarning nvarchar(4000) NULL;   -- set when Script targets another table than SchemaName.TableName (issue #41)
GO

/* ===== Helpers ===== */

/* Ends the open step, if any, and starts @Step, if given; @Step NULL only ends. Chars is the growth
   of @Data (or @Chars when no @Data) over the step, so contiguous steps add up to the payload length.
   The caller keeps @LogId and @CharsAtStart between calls. Does nothing when @Logging is not 1. */
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_LogStep
    @Logging      bit,
    @RunId        int,
    @Step         nvarchar(128),
    @Data         nvarchar(max) = NULL,
    @Chars        int = NULL,
    @LogId        int = NULL OUTPUT,
    @CharsAtStart int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@Logging, 0) = 0 RETURN;

    DECLARE @Now datetime2(3) = SYSDATETIME(), @Len int = COALESCE(LEN(@Data), @Chars);

    IF @LogId IS NOT NULL
        UPDATE AIIndexTuner.RunLog
        SET EndTime = @Now, ElapsedMs = DATEDIFF(MILLISECOND, StartTime, @Now), Chars = @Len - @CharsAtStart
        WHERE RunLogId = @LogId;
    SET @LogId = NULL;

    IF @Step IS NOT NULL
    BEGIN
        INSERT AIIndexTuner.RunLog (RunId, Collector, StartTime) VALUES (@RunId, @Step, @Now);
        SELECT @LogId = SCOPE_IDENTITY(), @CharsAtStart = @Len;
    END;
END;
GO

/* A High, Medium or Low level as a number to compare: 3, 2 or 1. NULL for anything else.
   Upper-cased under a fixed collation: under a Turkish database collation the capital of i is İ,
   so UPPER('medium') would not be MEDIUM. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_LevelRank(@Level varchar(10))
RETURNS tinyint
AS
BEGIN
    RETURN CASE UPPER(LTRIM(RTRIM(@Level)) COLLATE Latin1_General_100_BIN2) WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 END;
END;
GO

/* Issue #41: a warning when the model's Script targets a different table than the recommendation's
   SchemaName and TableName, NULL otherwise. Script is never run by this tool, but a person may copy
   it, and a script that names another table either fails or changes the wrong table.
   The targets are the objects after ALTER TABLE, UPDATE STATISTICS, and INDEX or STATISTICS
   <name> ON (CREATE / DROP [IF EXISTS] / ALTER INDEX, CREATE STATISTICS), read from a token scan
   that skips comments and string literals. A script with no target (sp_query_store_unforce_plan,
   ALTER DATABASE) or with more than one distinct target table is left unchecked. A one-part name
   is compared by table only. Keywords are upper-cased under a fixed collation (see fn_LevelRank);
   names are compared under the database's collation, as SQL Server resolves them. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_ScriptTargetWarning(@Script nvarchar(max), @SchemaName sysname, @TableName sysname)
RETURNS nvarchar(4000)
AS
BEGIN
    IF @Script IS NULL OR NULLIF(@TableName, N'') IS NULL RETURN NULL;

    DECLARE @Tokens TABLE (Pos int IDENTITY(1, 1) PRIMARY KEY, Raw nvarchar(4000) NOT NULL, Up nvarchar(4000) NOT NULL);
    DECLARE @n bigint = DATALENGTH(@Script) / 2, @i bigint = 1, @j bigint, @c nchar(1), @Close nchar(1),
            @Delims nvarchar(40) = N' .,;()[]"''=+-*/<>!%&|^~' + NCHAR(9) + NCHAR(10) + NCHAR(13);

    -- 1. Tokens: words, delimited identifiers ([x], "x") and single punctuation characters.
    WHILE @i <= @n
    BEGIN
        SET @c = SUBSTRING(@Script, @i, 1);
        IF CHARINDEX(@c COLLATE Latin1_General_100_BIN2, N' ' + NCHAR(9) + NCHAR(10) + NCHAR(13)) > 0
            SET @i += 1;
        ELSE IF @c = N'-' COLLATE Latin1_General_100_BIN2 AND SUBSTRING(@Script, @i + 1, 1) = N'-' COLLATE Latin1_General_100_BIN2
        BEGIN
            SET @j = CHARINDEX(NCHAR(10) COLLATE Latin1_General_100_BIN2, @Script, @i);
            SET @i = CASE WHEN @j = 0 THEN @n + 1 ELSE @j + 1 END;
        END
        ELSE IF @c = N'/' COLLATE Latin1_General_100_BIN2 AND SUBSTRING(@Script, @i + 1, 1) = N'*' COLLATE Latin1_General_100_BIN2
        BEGIN
            SET @j = CHARINDEX(N'*/' COLLATE Latin1_General_100_BIN2, @Script, @i + 2);
            SET @i = CASE WHEN @j = 0 THEN @n + 1 ELSE @j + 2 END;
        END
        ELSE IF CHARINDEX(@c COLLATE Latin1_General_100_BIN2, N'''["') > 0
        BEGIN
            -- A string literal (skipped) or a delimited identifier (kept). A doubled closing character
            -- is part of it. An unterminated one runs to the end of the script.
            SET @Close = CASE WHEN @c = N'[' COLLATE Latin1_General_100_BIN2 THEN N']' ELSE @c END;
            SET @j = @i + 1;
            WHILE 1 = 1
            BEGIN
                SET @j = CHARINDEX(@Close COLLATE Latin1_General_100_BIN2, @Script, @j);
                IF @j = 0 OR SUBSTRING(@Script, @j + 1, 1) <> @Close COLLATE Latin1_General_100_BIN2 BREAK;
                SET @j += 2;
            END;
            IF @j = 0 SET @j = @n;
            IF @c <> N'''' COLLATE Latin1_General_100_BIN2
                INSERT @Tokens (Raw, Up) VALUES (LEFT(SUBSTRING(@Script, @i, @j - @i + 1), 4000), N'');
            SET @i = @j + 1;
        END
        ELSE IF CHARINDEX(@c COLLATE Latin1_General_100_BIN2, @Delims) > 0
        BEGIN
            INSERT @Tokens (Raw, Up) VALUES (@c, @c);
            SET @i += 1;
        END
        ELSE
        BEGIN
            SET @j = @i;
            WHILE @j < @n AND CHARINDEX(SUBSTRING(@Script, @j + 1, 1) COLLATE Latin1_General_100_BIN2, @Delims) = 0
                SET @j += 1;
            INSERT @Tokens (Raw, Up)
            SELECT w, UPPER(w COLLATE Latin1_General_100_BIN2) FROM (SELECT LEFT(SUBSTRING(@Script, @i, @j - @i + 1), 4000) AS w) AS x;
            SET @i = @j + 1;
        END;
    END;

    -- 2. Where each target name starts.
    DECLARE @Starts TABLE (Pos int PRIMARY KEY);
    INSERT @Starts (Pos)
    SELECT b.Pos + 1
    FROM @Tokens AS a INNER JOIN @Tokens AS b ON b.Pos = a.Pos + 1
    WHERE (a.Up = N'ALTER' AND b.Up = N'TABLE') OR (a.Up = N'UPDATE' AND b.Up = N'STATISTICS')
    UNION
    SELECT nm.Pos + 2
    FROM @Tokens AS k
    CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM @Tokens AS f INNER JOIN @Tokens AS e ON e.Pos = f.Pos + 1
                                          WHERE f.Pos = k.Pos + 1 AND f.Up = N'IF' AND e.Up = N'EXISTS')
                             THEN k.Pos + 3 ELSE k.Pos + 1 END AS Pos) AS nm
    INNER JOIN @Tokens AS o ON o.Pos = nm.Pos + 1 AND o.Up = N'ON'
    WHERE k.Up IN (N'INDEX', N'STATISTICS');

    -- 3. The names, joined across '.' and parsed with PARSENAME (up to four parts; "db..t" has no schema).
    DECLARE @Targets TABLE (SchemaName sysname NULL, TableName sysname NOT NULL);
    DECLARE @p int = (SELECT MIN(Pos) FROM @Starts), @q int, @Name nvarchar(4000), @Next nvarchar(4000);
    WHILE @p IS NOT NULL
    BEGIN
        SELECT @Name = Raw, @q = @p FROM @Tokens WHERE Pos = @p;
        IF @@ROWCOUNT = 0 SET @Name = NULL;
        WHILE @Name IS NOT NULL AND EXISTS (SELECT 1 FROM @Tokens WHERE Pos = @q + 1 AND Raw = N'.' COLLATE Latin1_General_100_BIN2)
        BEGIN
            SET @Next = (SELECT Raw FROM @Tokens WHERE Pos = @q + 2);
            IF @Next IS NULL BREAK;
            IF @Next = N'.' COLLATE Latin1_General_100_BIN2
                SELECT @Name += N'.', @q += 1;
            ELSE
                SELECT @Name += N'.' + @Next, @q += 2;
        END;
        -- A name, not punctuation, a temporary table or a table variable; PARSENAME takes at most 128 characters.
        IF @Name IS NOT NULL AND LEN(@Name) <= 128
           AND (CHARINDEX(LEFT(@Name, 1) COLLATE Latin1_General_100_BIN2, N'["') > 0
                OR CHARINDEX(LEFT(@Name, 1) COLLATE Latin1_General_100_BIN2, @Delims + N'#@') = 0)
           AND PARSENAME(@Name, 1) IS NOT NULL
           AND LEFT(PARSENAME(@Name, 1), 1) NOT IN (N'#', N'@')
            INSERT @Targets (SchemaName, TableName) VALUES (PARSENAME(@Name, 2), PARSENAME(@Name, 1));
        SET @p = (SELECT MIN(Pos) FROM @Starts WHERE Pos > @p);
    END;

    -- 4. One target table, compared with the recommendation's.
    IF NOT EXISTS (SELECT 1 FROM @Targets)
       OR (SELECT COUNT(DISTINCT TableName) FROM @Targets) > 1
       OR (SELECT COUNT(DISTINCT SchemaName) FROM @Targets) > 1
        RETURN NULL;
    DECLARE @TargetSchema sysname = (SELECT MAX(SchemaName) FROM @Targets), @TargetTable sysname = (SELECT MAX(TableName) FROM @Targets);
    IF @TargetTable = @TableName AND (@TargetSchema IS NULL OR NULLIF(@SchemaName, N'') IS NULL OR @TargetSchema = @SchemaName)
        RETURN NULL;
    RETURN LEFT(CONCAT(N'The script targets ', QUOTENAME(@TargetSchema) + N'.', QUOTENAME(@TargetTable),
                       N', not ', QUOTENAME(NULLIF(@SchemaName, N'')) + N'.', QUOTENAME(@TableName),
                       N', the table this recommendation names. Correct it before running it by hand. CREATE mode and sp_AIIndexTuner_Apply build their own DDL from the recommendation''s fields and never run the script.'), 4000);
END;
GO

/* Uptime in the largest sensible unit: "3.2 days", "5.5 hours" or "40 minutes" (as FormatUptime in the desktop collector). */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_FormatUptime(@Minutes int)
RETURNS nvarchar(40)
AS
BEGIN
    SET @Minutes = CASE WHEN @Minutes < 0 THEN 0 ELSE @Minutes END;
    RETURN CASE
        WHEN @Minutes >= 2 * 24 * 60 THEN CONCAT(CAST(ROUND(@Minutes / 1440.0, 1) AS decimal(10, 1)), N' days')
        WHEN @Minutes >= 120 THEN CONCAT(CAST(ROUND(@Minutes / 60.0, 1) AS decimal(10, 1)), N' hours')
        WHEN @Minutes = 1 THEN N'1 minute'
        ELSE CONCAT(@Minutes, N' minutes')
    END;
END;
GO

/* Query text on one line: CR/LF to spaces, runs of spaces collapsed, trimmed, cut to @MaxChars (as CleanAndTruncate). */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_CleanText(@Text nvarchar(max), @MaxChars int)
RETURNS nvarchar(max)
AS
BEGIN
    IF @Text IS NULL RETURN NULL;
    SET @Text = REPLACE(REPLACE(REPLACE(@Text, NCHAR(13), N' '), NCHAR(10), N' '), NCHAR(9), N' ');
    WHILE CHARINDEX(N'  ', @Text) > 0
        SET @Text = REPLACE(@Text, N'  ', N' ');
    SET @Text = LTRIM(RTRIM(@Text));
    RETURN CASE WHEN LEN(@Text) > @MaxChars THEN LEFT(@Text, @MaxChars) + N'...' ELSE @Text END;
END;
GO

/* A literal made safe for LIKE ... ESCAPE N'\'. Plan XML object names are bracketed, and an
   unescaped '[' would open a character class. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_EscapeLike(@Value nvarchar(400))
RETURNS nvarchar(800)
AS
BEGIN
    RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@Value, N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\['), N']', N'\]');
END;
GO

/* A column's declared type as it would be written in DDL: nvarchar(max), nvarchar(200),
   decimal(12, 2), datetime2(3), int. Lengths of nchar and nvarchar are in characters. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_ColumnType(@ObjectId int, @ColumnId int)
RETURNS nvarchar(200)
AS
BEGIN
    RETURN (
        SELECT CONCAT(t.name,
            CASE
                WHEN t.name IN (N'varchar', N'char', N'varbinary', N'binary')
                    THEN CONCAT(N'(', CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length AS nvarchar(10)) END, N')')
                WHEN t.name IN (N'nvarchar', N'nchar')
                    THEN CONCAT(N'(', CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length / 2 AS nvarchar(10)) END, N')')
                WHEN t.name IN (N'decimal', N'numeric')
                    THEN CONCAT(N'(', c.precision, N', ', c.scale, N')')
                WHEN t.name IN (N'datetime2', N'time', N'datetimeoffset')
                    THEN CONCAT(N'(', c.scale, N')')
                ELSE N''
            END)
        FROM sys.columns AS c
        INNER JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = @ObjectId AND c.column_id = @ColumnId);
END;
GO
