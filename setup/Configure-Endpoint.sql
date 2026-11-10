/*
    Point aisqltuner-index-tuner at your Azure OpenAI deployment.

    Run in the database where you installed aisqltuner-index-tuner.sql. Fill in step 0 only, then
    run the whole script in one session: every later step reads the values from step 0, so the
    endpoint is typed once and the credential name always matches it. If a <placeholder> is left,
    the script stops before changing anything.

    Scope: this script creates the initial endpoint configuration only. It does not change the key
    of an existing credential: when a credential with the endpoint's name already exists, step 3
    keeps it as it is, key included, and re-running the script with a new key has no effect on it.
    To change the key, run ALTER DATABASE SCOPED CREDENTIAL yourself (see step 3).

    Step 0 holds your API key and master key password as literals. SQL Server hides the text of
    CREATE MASTER KEY and CREATE DATABASE SCOPED CREDENTIAL, but not of the SELECT in step 0, so the
    plan cache and Query Store could otherwise keep a copy of them. Step 7 removes the plans and
    Query Store entries of the batches marked "AIIndexTuner setup" (issue #47). It cannot reach a
    copy already recorded elsewhere: an Extended Events session, a trace or an audit that captures
    statement text. Run the script where none of those is capturing, or clear them afterwards.
*/

/* 0. Your values. */
DROP TABLE IF EXISTS #Setup;
SELECT /* AIIndexTuner setup: step 0 */
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
        -- The credential name is the endpoint without its trailing slash, and a name is a sysname: at most 128 characters.
        (CASE WHEN LEN(CASE WHEN RIGHT(s.Endpoint, 1) = N'/' THEN LEFT(s.Endpoint, LEN(s.Endpoint) - 1) ELSE s.Endpoint END) > 128
              THEN N'Endpoint without its trailing slash must be at most 128 characters, the limit for a credential name' END),
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
    DECLARE @Sql nvarchar(max) = CONCAT(N'/* AIIndexTuner setup: step 2 */ CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''',
                                        REPLACE((SELECT MasterKeyPassword FROM #Setup), N'''', N''''''), N''';');
    EXEC (@Sql);
END;
GO

/* 3. The credential. Its name is the endpoint's root URL with no trailing slash: the proc calls
      <endpoint>/openai/v1/responses, and the credential name must be the start of that URL.
      Initial setup only: an existing credential of that name is kept unchanged, and the key in
      step 0 is not applied to it. To change its key, run for example
          ALTER DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com]
              WITH IDENTITY = N'HTTPEndpointHeaders', SECRET = N'{"api-key":"<new key>"}'; */
DECLARE @Endpoint nvarchar(400) = (SELECT Endpoint FROM #Setup);
DECLARE @Credential sysname = CASE WHEN RIGHT(@Endpoint, 1) = N'/' THEN LEFT(@Endpoint, LEN(@Endpoint) - 1) ELSE @Endpoint END;
IF NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = @Credential)
BEGIN
    DECLARE @Identity nvarchar(100), @Secret nvarchar(max);
    SELECT @Identity = CASE WHEN UseManagedIdentity = 1 THEN N'Managed Identity' ELSE N'HTTPEndpointHeaders' END,
           @Secret = CASE WHEN UseManagedIdentity = 1 THEN JSON_OBJECT('resourceid': N'https://cognitiveservices.azure.com')
                          ELSE JSON_OBJECT('api-key': ApiKey) END
    FROM #Setup;
    DECLARE @Sql nvarchar(max) = CONCAT(N'/* AIIndexTuner setup: step 3 */ CREATE DATABASE SCOPED CREDENTIAL ', QUOTENAME(@Credential),
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

/* 6. Check the result. Every column should read OK. CredentialExists says only that the credential
      is there: if it existed before this run, its key is the one it already had (see step 3). */
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

/* 7. Remove the copies of step 0, which holds the API key and master key password as literals
      (issue #47): the cached plans of every batch marked "AIIndexTuner setup", and the Query Store
      queries whose text carries that mark. Runs even when step 0 stopped the script. The mark is
      built from two pieces, so this batch's own text does not match it. Each part reports what it
      did; one it cannot do (for want of VIEW SERVER STATE or ALTER ANY DATABASE SCOPED
      CONFIGURATION, or ALTER on the database for Query Store) says so, and you can clear the
      plan cache or Query Store yourself. */
DECLARE @Mark nvarchar(100) = N'%AIIndexTuner' + N' setup:%',
        @Handle varbinary(64), @Evicted int = 0, @QueryId bigint, @Removed int = 0,
        @PlanCache nvarchar(400), @QueryStore nvarchar(400), @Sql nvarchar(400);

BEGIN TRY
    DECLARE plan_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT cp.plan_handle
        FROM sys.dm_exec_cached_plans AS cp
        CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
        -- Plans compiled in this database only: CLEAR PROCEDURE_CACHE reaches no other.
        CROSS APPLY sys.dm_exec_plan_attributes(cp.plan_handle) AS pa
        WHERE st.[text] LIKE @Mark AND pa.attribute = N'dbid' AND CAST(pa.value AS int) = DB_ID();
    OPEN plan_cur;
    FETCH NEXT FROM plan_cur INTO @Handle;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Works on SQL Server 2019 and later, Azure SQL Database and Managed Instance; scoped to this database.
        SET @Sql = N'ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE ' + CONVERT(nvarchar(130), @Handle, 1) + N';';
        EXEC (@Sql);
        SET @Evicted += 1;
        FETCH NEXT FROM plan_cur INTO @Handle;
    END;
    CLOSE plan_cur;
    DEALLOCATE plan_cur;
    SET @PlanCache = CONCAT(N'OK: ', @Evicted, N' cached plan(s) removed');
END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'plan_cur') >= -1 DEALLOCATE plan_cur;
    SET @PlanCache = CONCAT(N'NOT DONE after ', @Evicted, N' plan(s): ', ERROR_MESSAGE());
END CATCH;

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc <> N'OFF')
    BEGIN
        DECLARE qs_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT q.query_id
            FROM sys.query_store_query AS q
            INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
            WHERE qt.query_sql_text LIKE @Mark;
        OPEN qs_cur;
        FETCH NEXT FROM qs_cur INTO @QueryId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC sys.sp_query_store_remove_query @query_id = @QueryId;
            SET @Removed += 1;
            FETCH NEXT FROM qs_cur INTO @QueryId;
        END;
        CLOSE qs_cur;
        DEALLOCATE qs_cur;
        SET @QueryStore = CONCAT(N'OK: ', @Removed, N' Query Store quer(ies) removed');
    END
    ELSE
        SET @QueryStore = N'OK: Query Store is off in this database';
END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'qs_cur') >= -1 DEALLOCATE qs_cur;
    SET @QueryStore = CONCAT(N'NOT DONE after ', @Removed, N' quer(ies): ', ERROR_MESSAGE());
END CATCH;

SELECT @PlanCache AS SetupTextPlanCache, @QueryStore AS SetupTextQueryStore;
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
