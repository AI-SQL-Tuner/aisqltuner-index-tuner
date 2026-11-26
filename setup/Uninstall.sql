/*
    Remove aisqltuner-index-tuner from this database (issue #53).

    Run in the database where you installed aisqltuner-index-tuner.sql. It drops:

        - dbo.sp_AIIndexTuner, dbo.sp_AIIndexTuner_Apply, dbo.sp_AIIndexTuner_Purge and
          dbo.sp_AIIndexTuner_Impact
        - every object in the AIIndexTuner schema (tables, with all runs and recommendations, and
          the procedures and functions), then the schema
        - the database scoped credential named in AIIndexTuner.Config, if DropCredential is 1 below
        - the AIIndexTuner extended property on indexes the tool built, if RemoveIndexTags is 1

    It leaves in place the indexes the tool created or widened, the database master key, and the
    server settings Configure-Endpoint.sql turned on ('external rest endpoint enabled'), which other
    code may use. Drop an index the tool created with the UndoDDL recorded in
    AIIndexTuner.Recommendation, before uninstalling if you want that record.

    The script stops before changing anything if the database has none of these objects, or if the
    AIIndexTuner schema holds an object it does not recognise as the tool's.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* 0. Your choices. */
DROP TABLE IF EXISTS #Uninstall;
SELECT
    CAST(1 AS bit) AS DropCredential,    -- 1: drop the credential named in AIIndexTuner.Config.CredentialName
    CAST(0 AS bit) AS RemoveIndexTags    -- 1: remove the AIIndexTuner extended property from the indexes the tool built
INTO #Uninstall;
GO

DECLARE @DropCredential bit, @RemoveIndexTags bit;
SELECT @DropCredential = DropCredential, @RemoveIndexTags = RemoveIndexTags FROM #Uninstall;

IF SCHEMA_ID(N'AIIndexTuner') IS NULL
   AND OBJECT_ID(N'dbo.sp_AIIndexTuner', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_AIIndexTuner_Apply', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_AIIndexTuner_Purge', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_AIIndexTuner_Impact', N'P') IS NULL
BEGIN
    PRINT N'aisqltuner-index-tuner is not installed in ' + QUOTENAME(DB_NAME()) + N'. Nothing was changed.';
    RETURN;
END;

/* Anything in the schema that is not a table, procedure, scalar or table-valued function, or a
   constraint, index or default of a table, was not made by the install script. */
DECLARE @Foreign nvarchar(max) =
    (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(QUOTENAME(o.name), N' (', o.type_desc COLLATE DATABASE_DEFAULT, N')')), N', ')
     FROM sys.objects AS o
     WHERE o.schema_id = SCHEMA_ID(N'AIIndexTuner')
       AND o.type NOT IN ('U', 'P', 'FN', 'IF', 'TF', 'PK', 'UQ', 'F', 'C', 'D'));
IF @Foreign IS NULL
    SET @Foreign = (SELECT STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(t.name) + N' (type)'), N', ') FROM sys.types AS t WHERE t.schema_id = SCHEMA_ID(N'AIIndexTuner'));
IF @Foreign IS NOT NULL
BEGIN
    DECLARE @Msg nvarchar(2048) = LEFT(CONCAT(N'The AIIndexTuner schema holds objects the install script does not create: ', @Foreign,
                                              N'. Move or drop them first. Nothing was changed.'), 2048);
    THROW 50901, @Msg, 1;
END;

DECLARE @Credential sysname = NULL;
IF @DropCredential = 1 AND OBJECT_ID(N'AIIndexTuner.Config', N'U') IS NOT NULL
    SELECT @Credential = CredentialName FROM AIIndexTuner.Config;

DECLARE @Sql nvarchar(max), @Dropped int = 0, @Tags int = 0;

BEGIN TRANSACTION;

/* The index tags, while the tables they name are still known. */
IF @RemoveIndexTags = 1
BEGIN
    DECLARE @Schema sysname, @Table sysname, @Index sysname;
    DECLARE tag_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT OBJECT_SCHEMA_NAME(i.object_id), OBJECT_NAME(i.object_id), i.name
        FROM sys.extended_properties AS ep
        INNER JOIN sys.indexes AS i ON i.object_id = ep.major_id AND i.index_id = ep.minor_id
        INNER JOIN sys.objects AS o ON o.object_id = i.object_id AND o.type = 'U'
        WHERE ep.class = 7 AND ep.name = N'AIIndexTuner';
    OPEN tag_cur;
    FETCH NEXT FROM tag_cur INTO @Schema, @Table, @Index;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sys.sp_dropextendedproperty
            @name = N'AIIndexTuner',
            @level0type = N'SCHEMA', @level0name = @Schema,
            @level1type = N'TABLE', @level1name = @Table,
            @level2type = N'INDEX', @level2name = @Index;
        SET @Tags += 1;
        FETCH NEXT FROM tag_cur INTO @Schema, @Table, @Index;
    END;
    CLOSE tag_cur;
    DEALLOCATE tag_cur;
END;

/* The dbo procedures. */
IF OBJECT_ID(N'dbo.sp_AIIndexTuner_Impact', N'P') IS NOT NULL BEGIN DROP PROCEDURE dbo.sp_AIIndexTuner_Impact; SET @Dropped += 1; END;
IF OBJECT_ID(N'dbo.sp_AIIndexTuner_Purge', N'P') IS NOT NULL BEGIN DROP PROCEDURE dbo.sp_AIIndexTuner_Purge; SET @Dropped += 1; END;
IF OBJECT_ID(N'dbo.sp_AIIndexTuner_Apply', N'P') IS NOT NULL BEGIN DROP PROCEDURE dbo.sp_AIIndexTuner_Apply; SET @Dropped += 1; END;
IF OBJECT_ID(N'dbo.sp_AIIndexTuner', N'P') IS NOT NULL BEGIN DROP PROCEDURE dbo.sp_AIIndexTuner; SET @Dropped += 1; END;

/* The schema's own foreign keys first, so its tables can go in any order; then procedures, functions
   and tables. A foreign key or schema-bound module elsewhere that depends on them makes a DROP fail,
   which rolls everything back. */
SET @Sql = (SELECT STRING_AGG(CONVERT(nvarchar(max), N'ALTER TABLE AIIndexTuner.' + QUOTENAME(OBJECT_NAME(fk.parent_object_id))
                                                     + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';'), N' ')
            FROM sys.foreign_keys AS fk WHERE fk.schema_id = SCHEMA_ID(N'AIIndexTuner'));
IF @Sql IS NOT NULL EXEC sys.sp_executesql @Sql;

SELECT @Sql = STRING_AGG(CONVERT(nvarchar(max), CASE o.type WHEN 'P' THEN N'DROP PROCEDURE ' WHEN 'U' THEN N'DROP TABLE ' ELSE N'DROP FUNCTION ' END
                                                + N'AIIndexTuner.' + QUOTENAME(o.name) + N';'), N' ')
                  WITHIN GROUP (ORDER BY CASE o.type WHEN 'P' THEN 1 WHEN 'U' THEN 3 ELSE 2 END, o.name),
       @Dropped += COUNT(*)
FROM sys.objects AS o
WHERE o.schema_id = SCHEMA_ID(N'AIIndexTuner') AND o.type IN ('P', 'FN', 'IF', 'TF', 'U');
IF @Sql IS NOT NULL EXEC sys.sp_executesql @Sql;

IF SCHEMA_ID(N'AIIndexTuner') IS NOT NULL
    DROP SCHEMA AIIndexTuner;

COMMIT;

PRINT CONCAT(N'Dropped the AIIndexTuner schema and ', @Dropped, N' objects from ', QUOTENAME(DB_NAME()), N'.');
IF @RemoveIndexTags = 1
    PRINT CONCAT(N'Removed the AIIndexTuner tag from ', @Tags, N' indexes. The indexes are kept.');
ELSE
    PRINT N'Indexes the tool built are kept, with their AIIndexTuner extended property.';

/* The credential, outside the transaction: DROP DATABASE SCOPED CREDENTIAL fails while anything
   still uses it, and that should not undo the rest. */
IF @Credential IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = @Credential)
    BEGIN
        BEGIN TRY
            SET @Sql = N'DROP DATABASE SCOPED CREDENTIAL ' + QUOTENAME(@Credential) + N';';
            EXEC sys.sp_executesql @Sql;
            PRINT N'Dropped the database scoped credential ' + QUOTENAME(@Credential) + N'.';
        END TRY
        BEGIN CATCH
            PRINT N'Could not drop the database scoped credential ' + QUOTENAME(@Credential) + N': ' + ERROR_MESSAGE();
        END CATCH;
    END;
    ELSE
        PRINT N'The credential ' + QUOTENAME(@Credential) + N' named in AIIndexTuner.Config does not exist; nothing to drop.';
END;
ELSE IF @DropCredential = 1
    PRINT N'No credential was configured; none dropped.';
ELSE
    PRINT N'The database scoped credential was kept (DropCredential = 0).';
GO

DROP TABLE IF EXISTS #Uninstall;
GO
