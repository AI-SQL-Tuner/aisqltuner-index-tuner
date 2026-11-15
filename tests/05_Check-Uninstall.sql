/*
    Checks what setup/Uninstall.sql left (issue #53), after 04_Prepare-Uninstall.sql and the
    uninstall with its default choices: everything the install created and the credential are gone;
    the index the tool built is kept, with its tag.
*/
SET NOCOUNT ON;
GO
DECLARE @Left nvarchar(max) = CONCAT_WS(N', ',
    CASE WHEN SCHEMA_ID(N'AIIndexTuner') IS NOT NULL THEN N'the AIIndexTuner schema' END,
    CASE WHEN OBJECT_ID(N'dbo.sp_AIIndexTuner', N'P') IS NOT NULL THEN N'dbo.sp_AIIndexTuner' END,
    CASE WHEN OBJECT_ID(N'dbo.sp_AIIndexTuner_Apply', N'P') IS NOT NULL THEN N'dbo.sp_AIIndexTuner_Apply' END,
    CASE WHEN EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'https://uninstall-test.invalid') THEN N'the credential' END,
    CASE WHEN INDEXPROPERTY(OBJECT_ID(N'dbo.AuditLog'), N'IX_AuditLog_UninstallTest', 'IndexID') IS NULL THEN N'(the tagged index is missing)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 7 AND major_id = OBJECT_ID(N'dbo.AuditLog') AND name = N'AIIndexTuner'
                         AND minor_id = INDEXPROPERTY(OBJECT_ID(N'dbo.AuditLog'), N'IX_AuditLog_UninstallTest', 'IndexID')) THEN N'(the index tag is missing)' END);
IF @Left <> N''
BEGIN
    DECLARE @Msg nvarchar(2048) = N'FAIL uninstall: left or removed the wrong things: ' + @Left;
    THROW 50999, @Msg, 1;
END;
PRINT 'PASS uninstall: dropped the schema, both dbo procedures and the credential, and kept the tagged index';
GO
