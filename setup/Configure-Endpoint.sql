/*
    Point aisqltuner-index-tuner at your Azure OpenAI deployment.

    Run in the database where you installed aisqltuner-index-tuner.sql. Fill in step 0 only, then
    run the whole script in one session: every later step reads the values from step 0, so the
    endpoint is typed once and the credential name always matches it. If a <placeholder> is left,
    the script stops before changing anything.
*/

/* 0. Your values. */
DROP TABLE IF EXISTS #Setup;
SELECT
    -- Root endpoint of your Azure OpenAI / Microsoft Foundry resource. No /openai or other path.
    CAST(N'https://<your-resource>.openai.azure.com/' AS nvarchar(400)) AS Endpoint,
    CAST(N'<your deployment name>' AS nvarchar(128))                   AS Deployment,
    -- 0 = API key (ApiKey below); 1 = the instance's managed identity, which needs the
    -- "Cognitive Services OpenAI User" role on the Azure OpenAI resource (ApiKey is then ignored).
    CAST(0 AS bit)                                                     AS UseManagedIdentity,
    CAST(N'<your Azure OpenAI key>' AS nvarchar(400))                  AS ApiKey,
    -- Used only if the database has no master key yet.
    CAST(N'<a strong password>' AS nvarchar(128))                      AS MasterKeyPassword
INTO #Setup;

DECLARE @Problems nvarchar(2000) = (
    SELECT STRING_AGG(p, N'; ')
    FROM #Setup AS s
    CROSS APPLY (VALUES
        (CASE WHEN s.Endpoint LIKE N'%<%>%' THEN N'Endpoint' END),
        (CASE WHEN s.Endpoint NOT LIKE N'https://%' THEN N'Endpoint must start with https://' END),
        (CASE WHEN s.Endpoint LIKE N'https://%/%_%' THEN N'Endpoint must be the root URL, with no path' END),
        (CASE WHEN s.Deployment LIKE N'%<%>%' THEN N'Deployment' END),
        (CASE WHEN s.UseManagedIdentity = 0 AND (s.ApiKey IS NULL OR s.ApiKey LIKE N'%<%>%') THEN N'ApiKey' END),
        (CASE WHEN NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
                   AND (s.MasterKeyPassword IS NULL OR s.MasterKeyPassword LIKE N'%<%>%') THEN N'MasterKeyPassword (this database has no master key yet)' END)
    ) AS v(p)
    WHERE p IS NOT NULL);
IF @Problems IS NOT NULL
BEGIN
    DECLARE @Msg nvarchar(2048) = CONCAT(N'Fill in step 0 first: ', @Problems, N'. Nothing was changed; the rest of the script is skipped.');
    RAISERROR (@Msg, 16, 1);
    SET NOEXEC ON;   -- compile but do not run the remaining batches; the last batch turns it off
END;
GO

/* 1. SQL Server 2025 and Azure SQL Managed Instance: allow sp_invoke_external_rest_endpoint (off
      by default on both). A Managed Instance needs the SQL Server 2025 or Always-up-to-date update
      policy. Azure SQL Database and Fabric SQL Database have it on already. Needs ALTER SETTINGS
      (sysadmin or serveradmin), so it is left for you to run:

EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;

      Managed identity on SQL Server 2025 (enabled by Azure Arc) also needs:

EXEC sp_configure 'allow server scoped db credentials', 1;
RECONFIGURE WITH OVERRIDE;
*/

/* 2. A database master key protects the credential's secret. Skipped if the database has one. */
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
BEGIN
    DECLARE @Sql nvarchar(max) = CONCAT(N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''',
                                        REPLACE((SELECT MasterKeyPassword FROM #Setup), N'''', N''''''), N''';');
    EXEC (@Sql);
END;
GO

/* 3. The credential. Its name is the endpoint's root URL with no trailing slash: the proc calls
      <endpoint>/openai/v1/responses, and the credential name must be the start of that URL. An
      existing credential of that name is kept; to change its key, use ALTER DATABASE SCOPED CREDENTIAL. */
DECLARE @Endpoint nvarchar(400) = (SELECT Endpoint FROM #Setup);
DECLARE @Credential sysname = CASE WHEN RIGHT(@Endpoint, 1) = N'/' THEN LEFT(@Endpoint, LEN(@Endpoint) - 1) ELSE @Endpoint END;
IF NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = @Credential)
BEGIN
    DECLARE @Identity nvarchar(100), @Secret nvarchar(max);
    SELECT @Identity = CASE WHEN UseManagedIdentity = 1 THEN N'Managed Identity' ELSE N'HTTPEndpointHeaders' END,
           @Secret = CASE WHEN UseManagedIdentity = 1 THEN JSON_OBJECT('resourceid': N'https://cognitiveservices.azure.com')
                          ELSE JSON_OBJECT('api-key': ApiKey) END
    FROM #Setup;
    DECLARE @Sql nvarchar(max) = CONCAT(N'CREATE DATABASE SCOPED CREDENTIAL ', QUOTENAME(@Credential),
                                        N' WITH IDENTITY = N''', @Identity, N''', SECRET = N''', REPLACE(@Secret, N'''', N''''''), N''';');
    EXEC (@Sql);
END;
GO

/* 4. Whoever runs the proc needs to call external endpoints and use the credential.
-- GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [<user or role>];
-- GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://<your-resource>.openai.azure.com] TO [<user or role>];
*/

/* 5. The configuration row. */
MERGE AIIndexTuner.Config AS t
USING (SELECT 1 AS ConfigId, Endpoint, Deployment,
              CAST(CASE WHEN RIGHT(Endpoint, 1) = N'/' THEN LEFT(Endpoint, LEN(Endpoint) - 1) ELSE Endpoint END AS sysname) AS CredentialName
       FROM #Setup) AS s
ON t.ConfigId = s.ConfigId
WHEN MATCHED THEN UPDATE SET Endpoint = s.Endpoint, Deployment = s.Deployment, CredentialName = s.CredentialName
WHEN NOT MATCHED THEN INSERT (ConfigId, Endpoint, Deployment, CredentialName) VALUES (s.ConfigId, s.Endpoint, s.Deployment, s.CredentialName);
GO

/* 6. Check the result. Every column should read OK. */
SELECT c.Endpoint, c.Deployment, c.CredentialName,
       CASE WHEN EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = c.CredentialName)
            THEN 'OK' ELSE 'MISSING' END AS CredentialExists,
       CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) NOT IN (1, 2, 3, 4, 8) THEN 'OK (on by default here)'
            WHEN EXISTS (SELECT 1 FROM sys.configurations WHERE name = N'external rest endpoint enabled' AND value_in_use = 1) THEN 'OK'
            ELSE 'OFF: run step 1' END AS RestEndpointFeature
FROM AIIndexTuner.Config AS c
WHERE c.ConfigId = 1;
GO

SET NOEXEC OFF;
GO
DROP TABLE IF EXISTS #Setup;   -- it holds the API key
GO

/* Optional settings (defaults shown):
UPDATE AIIndexTuner.Config SET
    ReasoningEffort     = 'medium',  -- low | medium | high
    MaxOutputTokens     = 32000,
    UseBackgroundMode   = 1,         -- poll for the response so long runs are not cut off at 230 seconds
    MaxWaitSec          = 900,
    UseStructuredOutput = 1,         -- schema-constrained JSON; set 0 for a model that rejects it
    IncludeQueryText    = 1,         -- 0 leaves plan cache query text out of the prompt
    KeepRunDetail       = 1,         -- keep the collected data and raw response on AIIndexTuner.Run
    MaxPayloadChars     = 500000,    -- larger collected data fails before the request; NULL = no limit
    EnableLogging       = 1          -- log each step of a run to AIIndexTuner.RunLog
WHERE ConfigId = 1;
*/
