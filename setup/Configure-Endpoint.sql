/*
    Point aisqltuner-index-tuner at your Azure OpenAI deployment.

    Run in the database where you installed aisqltuner-index-tuner.sql, after replacing the
    <placeholders>. Run the steps in order.
*/

/* 1. SQL Server 2025 only: allow sp_invoke_external_rest_endpoint (off by default).
      Azure SQL Database has it on already. Needs ALTER SETTINGS (sysadmin or serveradmin).

EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
*/

/* 2. A database master key protects the credential's secret. Skip if the database has one. */
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<a strong password>';
GO

/* 3. The credential. Its name must be your endpoint's root URL with no trailing slash: the proc
      calls <endpoint>/openai/v1/responses, and the credential name must be a prefix of that URL.

      Option A: API key. */
IF NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'https://<your-resource>.openai.azure.com')
    CREATE DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com]
    WITH IDENTITY = 'HTTPEndpointHeaders', SECRET = '{"api-key":"<your Azure OpenAI key>"}';
GO

/*    Option B: managed identity (Azure SQL, or SQL Server 2025 enabled by Azure Arc). Give the
      identity the "Cognitive Services OpenAI User" role on the Azure OpenAI resource. On SQL
      Server 2025, also run: EXEC sp_configure 'allow server scoped db credentials', 1; RECONFIGURE;

CREATE DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com]
WITH IDENTITY = 'Managed Identity', SECRET = '{"resourceid":"https://cognitiveservices.azure.com"}';
*/

/* 4. Whoever runs the proc needs to call external endpoints and use the credential. */
-- GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [<user or role>];
-- GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://<your-resource>.openai.azure.com] TO [<user or role>];

/* 5. The configuration row. */
MERGE AIIndexTuner.Config AS t
USING (SELECT 1 AS ConfigId,
              N'https://<your-resource>.openai.azure.com/' AS Endpoint,
              N'<your deployment name>'                    AS Deployment,
              N'https://<your-resource>.openai.azure.com'  AS CredentialName) AS s
ON t.ConfigId = s.ConfigId
WHEN MATCHED THEN UPDATE SET Endpoint = s.Endpoint, Deployment = s.Deployment, CredentialName = s.CredentialName
WHEN NOT MATCHED THEN INSERT (ConfigId, Endpoint, Deployment, CredentialName) VALUES (s.ConfigId, s.Endpoint, s.Deployment, s.CredentialName);
GO

/* Optional settings (defaults shown):
UPDATE AIIndexTuner.Config SET
    ReasoningEffort     = 'medium',  -- low | medium | high
    MaxOutputTokens     = 32000,
    UseBackgroundMode   = 1,         -- poll for the response so long runs are not cut off at 230 seconds
    MaxWaitSec          = 900,
    UseStructuredOutput = 1,         -- schema-constrained JSON; set 0 for a model that rejects it
    IncludeQueryText    = 1,         -- 0 leaves plan cache query text out of the prompt
    KeepRunDetail       = 1          -- keep the collected data and raw response on AIIndexTuner.Run
WHERE ConfigId = 1;
*/
