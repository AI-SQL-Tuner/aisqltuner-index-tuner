SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    AIIndexTuner.usp_ApplyRecommendation

    Applies one stored CreateIndex recommendation. The model's own script is never executed: plan
    cache text goes into the prompt, so a crafted query could steer what the model writes. The DDL
    is built here from the structured fields, after every name is checked against the catalog, with
    QUOTENAME and an allow-list for each option.

    Only CreateIndex is applied. Every other category, and any filtered index, is left for review.
    The outcome is written to the recommendation row: Applied, Skipped (with the reason) or Failed
    (with the error).
*/
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_ApplyRecommendation
    @RecommendationId int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Category varchar(30), @Status varchar(20), @SchemaName sysname, @TableName sysname, @IndexName sysname,
            @KeyColumns nvarchar(max), @IncludeColumns nvarchar(max), @Filter nvarchar(4000), @IsUnique bit,
            @FillFactor tinyint, @Compression varchar(10), @RunId int;

    SELECT @Category = Category, @Status = Status, @SchemaName = SchemaName, @TableName = TableName, @IndexName = IndexName,
           @KeyColumns = KeyColumns, @IncludeColumns = IncludeColumns, @Filter = FilterPredicate, @IsUnique = IsUnique,
           @FillFactor = [FillFactor], @Compression = DataCompression, @RunId = RunId
    FROM AIIndexTuner.Recommendation
    WHERE RecommendationId = @RecommendationId;

    IF @Category IS NULL
        THROW 50101, N'No recommendation with that RecommendationId.', 1;

    IF @Status NOT IN ('Recommended', 'Failed')
        RETURN;   -- already applied or skipped

    DECLARE @Reason nvarchar(4000) = NULL, @ObjectId int, @Ddl nvarchar(max);

    /* ----- Validation: each failed check skips the recommendation with a reason ----- */
    IF @Category <> 'CreateIndex'
        SET @Reason = CONCAT(N'Category ', @Category, N' is recommend-only; review the script and apply it yourself.');
    ELSE IF NULLIF(LTRIM(@Filter), N'') IS NOT NULL
        SET @Reason = N'Filtered indexes are recommend-only: the filter predicate is free text from the model. Review the script and apply it yourself.';
    ELSE IF @SchemaName IS NULL OR @TableName IS NULL
        SET @Reason = N'The recommendation does not name a schema and table.';
    ELSE
    BEGIN
        SET @ObjectId = OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName), N'U');
        IF @ObjectId IS NULL
            SET @Reason = CONCAT(N'Table ', QUOTENAME(@SchemaName), N'.', QUOTENAME(@TableName), N' does not exist in this database.');
    END;

    DECLARE @Keys TABLE (ordinal int PRIMARY KEY, column_name nvarchar(4000), is_descending bit, column_id int);
    DECLARE @Includes TABLE (ordinal int PRIMARY KEY, column_name nvarchar(4000), column_id int);

    IF @Reason IS NULL
    BEGIN
        IF ISJSON(@KeyColumns) = 0 OR ISJSON(ISNULL(@IncludeColumns, N'[]')) = 0
            SET @Reason = N'The key or include column list is not valid JSON.';
        ELSE
        BEGIN
            INSERT @Keys (ordinal, column_name, is_descending)
            SELECT CAST(k.[key] AS int), JSON_VALUE(k.value, '$.column'), ISNULL(CAST(JSON_VALUE(k.value, '$.descending') AS bit), 0)
            FROM OPENJSON(@KeyColumns) AS k;

            INSERT @Includes (ordinal, column_name)
            SELECT CAST(i.[key] AS int), i.value
            FROM OPENJSON(ISNULL(@IncludeColumns, N'[]')) AS i;

            -- Exact catalog names only: no brackets, no expressions.
            UPDATE k SET column_id = c.column_id
            FROM @Keys AS k INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.name = k.column_name;
            UPDATE i SET column_id = c.column_id
            FROM @Includes AS i INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.name = i.column_name;

            IF NOT EXISTS (SELECT 1 FROM @Keys)
                SET @Reason = N'The recommendation has no key columns.';
            ELSE IF (SELECT COUNT(*) FROM @Keys) > 32
                SET @Reason = N'More than 32 key columns.';
            ELSE IF EXISTS (SELECT 1 FROM @Keys WHERE column_id IS NULL) OR EXISTS (SELECT 1 FROM @Includes WHERE column_id IS NULL)
                SET @Reason = CONCAT(N'Unknown column(s) on ', QUOTENAME(@SchemaName), N'.', QUOTENAME(@TableName), N': ',
                    (SELECT STRING_AGG(column_name, N', ') FROM (SELECT column_name FROM @Keys WHERE column_id IS NULL
                                                                 UNION ALL SELECT column_name FROM @Includes WHERE column_id IS NULL) AS u), N'.');
            ELSE IF EXISTS (SELECT column_id FROM @Keys GROUP BY column_id HAVING COUNT(*) > 1)
                 OR EXISTS (SELECT column_id FROM @Includes GROUP BY column_id HAVING COUNT(*) > 1)
                 OR EXISTS (SELECT 1 FROM @Keys AS k INNER JOIN @Includes AS i ON i.column_id = k.column_id)
                SET @Reason = N'A column appears more than once in the key and include lists.';
        END;
    END;

    -- An existing index with the same leading keys that already covers the includes makes this one redundant.
    IF @Reason IS NULL
    BEGIN
        DECLARE @KeySig nvarchar(max) = (SELECT STRING_AGG(CONCAT(column_id, CASE WHEN is_descending = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY ordinal) FROM @Keys);
        DECLARE @Covering sysname;

        SELECT TOP (1) @Covering = i.name
        FROM sys.indexes AS i
        CROSS APPLY (SELECT STRING_AGG(CONCAT(ic.column_id, CASE WHEN ic.is_descending_key = 1 THEN 'D' ELSE 'A' END), ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS sig
                     FROM sys.index_columns AS ic
                     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0 AND ic.key_ordinal > 0) AS k
        WHERE i.object_id = @ObjectId AND i.type IN (1, 2) AND i.is_disabled = 0 AND i.is_hypothetical = 0 AND i.has_filter = 0
          AND (k.sig = @KeySig OR LEFT(k.sig, LEN(@KeySig) + 1) = @KeySig + ',')
          AND (i.type = 1   -- the clustered index covers every column
               OR NOT EXISTS (SELECT 1 FROM @Includes AS inc
                              WHERE NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic
                                                WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.column_id = inc.column_id)));

        IF @Covering IS NOT NULL
            SET @Reason = CONCAT(N'Existing index ', QUOTENAME(@Covering), N' already has these leading keys and covers the included columns.');
    END;

    -- Name: the model's when it is free, otherwise a generated one.
    IF @Reason IS NULL
    BEGIN
        IF NULLIF(LTRIM(@IndexName), N'') IS NULL OR LEN(@IndexName) > 128
            SET @IndexName = LEFT(CONCAT(N'IX_AIT_', @TableName, N'_', @RecommendationId), 128);

        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = @ObjectId AND name = @IndexName)
            SET @Reason = CONCAT(N'An index named ', QUOTENAME(@IndexName), N' already exists on the table.');
    END;

    IF @Reason IS NOT NULL
    BEGIN
        UPDATE AIIndexTuner.Recommendation SET Status = 'Skipped', StatusReason = @Reason WHERE RecommendationId = @RecommendationId;
        RETURN;
    END;

    /* ----- Build the DDL from validated parts ----- */
    DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int),
            @Options nvarchar(400) = N'';

    -- Online index operations: Enterprise (and Developer), Azure SQL Database and Managed Instance.
    IF @EngineEdition IN (3, 5, 8)
        SET @Options += N', ONLINE = ON';
    IF @FillFactor BETWEEN 1 AND 100
        SET @Options += CONCAT(N', FILLFACTOR = ', @FillFactor);
    IF @Compression IN ('NONE', 'ROW', 'PAGE')
        SET @Options += CONCAT(N', DATA_COMPRESSION = ', @Compression);

    SET @Ddl = CONCAT(
        N'CREATE ', CASE WHEN @IsUnique = 1 THEN N'UNIQUE ' ELSE N'' END, N'NONCLUSTERED INDEX ', QUOTENAME(@IndexName),
        N' ON ', QUOTENAME(@SchemaName), N'.', QUOTENAME(@TableName), N' (',
        (SELECT STRING_AGG(QUOTENAME(c.name) + CASE WHEN k.is_descending = 1 THEN N' DESC' ELSE N' ASC' END, N', ') WITHIN GROUP (ORDER BY k.ordinal)
         FROM @Keys AS k INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.column_id = k.column_id),
        N')',
        CASE WHEN EXISTS (SELECT 1 FROM @Includes)
             THEN N' INCLUDE (' + (SELECT STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY i.ordinal)
                                   FROM @Includes AS i INNER JOIN sys.columns AS c ON c.object_id = @ObjectId AND c.column_id = i.column_id) + N')'
             ELSE N'' END,
        CASE WHEN @Options <> N'' THEN N' WITH (' + STUFF(@Options, 1, 2, N'') + N')' ELSE N'' END,
        N';');

    BEGIN TRY
        EXEC sys.sp_executesql @Ddl;
    END TRY
    BEGIN CATCH
        UPDATE AIIndexTuner.Recommendation
        SET Status = 'Failed', StatusReason = ERROR_MESSAGE(), AppliedDDL = @Ddl
        WHERE RecommendationId = @RecommendationId;
        RETURN;
    END CATCH;

    -- Tag the index so it can be found and rolled back later. The index exists either way, so a
    -- tagging failure is noted but does not mark the recommendation Failed.
    DECLARE @TagNote nvarchar(4000) = NULL;
    BEGIN TRY
        DECLARE @Tag sql_variant = CONCAT(N'Created by aisqltuner-index-tuner, run ', @RunId, N', recommendation ', @RecommendationId, N', ', CONVERT(varchar(19), SYSDATETIME(), 120));
        EXEC sys.sp_addextendedproperty
            @name = N'AIIndexTuner', @value = @Tag,
            @level0type = N'SCHEMA', @level0name = @SchemaName,
            @level1type = N'TABLE', @level1name = @TableName,
            @level2type = N'INDEX', @level2name = @IndexName;
    END TRY
    BEGIN CATCH
        SET @TagNote = CONCAT(N'Index created, but tagging it failed: ', ERROR_MESSAGE());
    END CATCH;

    UPDATE AIIndexTuner.Recommendation
    SET Status = 'Applied', StatusReason = @TagNote, IndexName = @IndexName, AppliedDDL = @Ddl,
        AppliedAt = SYSDATETIME(), AppliedBy = ORIGINAL_LOGIN()
    WHERE RecommendationId = @RecommendationId;
END;
GO
