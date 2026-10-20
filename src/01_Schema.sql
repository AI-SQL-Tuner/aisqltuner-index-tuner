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
