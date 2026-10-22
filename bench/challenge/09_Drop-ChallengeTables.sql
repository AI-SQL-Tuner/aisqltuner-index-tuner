/*
    Removes everything the benchmark added to the current database: the [bench] challenge tables,
    the [AIIndexTunerBench] rubric objects and settings, and both schemas. Use it to clean up the
    Dev EMS database after a run.

    It does NOT remove aisqltuner-index-tuner itself (the AIIndexTuner schema, dbo.sp_AIIndexTuner,
    dbo.sp_AIIndexTuner_Apply) or the database scoped credential; remove those separately if they
    were installed only for the benchmark.

    Query Store keeps the workload's queries and the forced probe plan, so this script unforces
    the probe plan first.
*/
SET NOCOUNT ON;
GO
DECLARE @fq bigint, @fp bigint;
DECLARE forced_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.query_id, p.plan_id
    FROM sys.query_store_plan AS p
    INNER JOIN sys.query_store_query AS q ON q.query_id = p.query_id
    INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE p.is_forced_plan = 1 AND qt.query_sql_text LIKE N'%forced_plan_probe%';
OPEN forced_cur;
FETCH NEXT FROM forced_cur INTO @fq, @fp;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_unforce_plan @query_id = @fq, @plan_id = @fp;
    FETCH NEXT FROM forced_cur INTO @fq, @fp;
END;
CLOSE forced_cur;
DEALLOCATE forced_cur;
GO

DECLARE @sql nvarchar(max) = N'';

-- Views, procedures and functions in both schemas.
SELECT @sql += CASE o.type WHEN 'V' THEN N'DROP VIEW ' WHEN 'P' THEN N'DROP PROCEDURE ' ELSE N'DROP FUNCTION ' END
             + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';'
FROM sys.objects AS o
WHERE SCHEMA_NAME(o.schema_id) IN (N'bench', N'AIIndexTunerBench') AND o.type IN ('V', 'P', 'FN', 'IF', 'TF');
EXEC sys.sp_executesql @sql;

-- Foreign keys, then tables.
SET @sql = N'';
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';'
FROM sys.foreign_keys AS fk
INNER JOIN sys.tables AS t ON t.object_id = fk.parent_object_id
WHERE SCHEMA_NAME(t.schema_id) IN (N'bench', N'AIIndexTunerBench');
EXEC sys.sp_executesql @sql;

SET @sql = N'';
SELECT @sql += N'DROP TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N';'
FROM sys.tables AS t
WHERE SCHEMA_NAME(t.schema_id) IN (N'bench', N'AIIndexTunerBench');
EXEC sys.sp_executesql @sql;

IF SCHEMA_ID(N'bench') IS NOT NULL DROP SCHEMA bench;
IF SCHEMA_ID(N'AIIndexTunerBench') IS NOT NULL DROP SCHEMA AIIndexTunerBench;
PRINT 'The bench and AIIndexTunerBench schemas and everything in them were removed.';
GO
