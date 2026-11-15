/*
    Sets up what setup/Uninstall.sql removes (issue #53): a Config row naming a database scoped
    credential, the credential (and a master key if there is none), and an index tagged as built by
    the tool. Run-All.ps1 runs it after the tests, then Uninstall.sql, then 05_Check-Uninstall.sql.
*/
SET NOCOUNT ON;
GO
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
BEGIN
    DECLARE @Sql nvarchar(max) = CONCAT(N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''', NEWID(), N'Aa1!'';');
    EXEC (@Sql);
END;
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'https://uninstall-test.invalid')
    DROP DATABASE SCOPED CREDENTIAL [https://uninstall-test.invalid];
CREATE DATABASE SCOPED CREDENTIAL [https://uninstall-test.invalid] WITH IDENTITY = N'HTTPEndpointHeaders', SECRET = N'{"api-key":"not-a-key"}';
DELETE AIIndexTuner.Config;
INSERT AIIndexTuner.Config (ConfigId, Endpoint, Deployment, CredentialName)
VALUES (1, N'https://uninstall-test.invalid/', N'none', N'https://uninstall-test.invalid');

IF INDEXPROPERTY(OBJECT_ID(N'dbo.AuditLog'), N'IX_AuditLog_UninstallTest', 'IndexID') IS NULL
    CREATE INDEX IX_AuditLog_UninstallTest ON dbo.AuditLog (EventType);
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 7 AND major_id = OBJECT_ID(N'dbo.AuditLog') AND name = N'AIIndexTuner'
               AND minor_id = INDEXPROPERTY(OBJECT_ID(N'dbo.AuditLog'), N'IX_AuditLog_UninstallTest', 'IndexID'))
    EXEC sys.sp_addextendedproperty @name = N'AIIndexTuner', @value = N'Uninstall test',
        @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'AuditLog',
        @level2type = N'INDEX', @level2name = N'IX_AuditLog_UninstallTest';
GO
