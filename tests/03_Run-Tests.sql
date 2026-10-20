/*
    Tests for aisqltuner-index-tuner against AIIndexTunerTest, with no AI endpoint: each run passes
    a canned model answer in @TestResponse.

    sqlcmd -S localhost -E -C -f 65001 -b -d AIIndexTunerTest -i tests\03_Run-Tests.sql -o test-output.txt

    Each check prints PASS or stops the script with FAIL.
*/
SET NOCOUNT ON;
GO

/* ----- Clean slate: drop indexes earlier test runs created, and earlier results ----- */
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'DROP INDEX ' + QUOTENAME(i.name) + N' ON ' + QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(i.object_id)) + N';'
FROM sys.indexes AS i
INNER JOIN sys.extended_properties AS ep ON ep.class = 7 AND ep.major_id = i.object_id AND ep.minor_id = i.index_id AND ep.name = N'AIIndexTuner';
EXEC sys.sp_executesql @sql;
DELETE AIIndexTuner.Recommendation;
DELETE AIIndexTuner.Run;
GO

/* ----- The canned model answer ----- */
CREATE TABLE #Canned (Name varchar(20) PRIMARY KEY, Body nvarchar(max));
INSERT #Canned VALUES ('good', N'{
  "summary": "Two new indexes on dbo.Orders support the CustomerId and OrderDate/Status lookups (about 18 MB in total); drop one duplicate index on dbo.Customers.",
  "recommendations": [
    { "priority": 1, "category": "CreateIndex", "title": "Index Orders by CustomerId",
      "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_CustomerId",
      "key_columns": [ { "column": "CustomerId", "descending": false } ], "include_columns": [ "TotalDue" ],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": 6.87,
      "confidence": "High", "rationale": "Missing index with impact score above 270,000.", "benefiting_queries": [ "0xC9E457A08FD8544F" ],
      "script": "CREATE INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId) INCLUDE (TotalDue);" },
    { "priority": 2, "category": "CreateIndex", "title": "Index Orders by OrderDate and Status",
      "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_OrderDate_Status",
      "key_columns": [ { "column": "OrderDate", "descending": false }, { "column": "Status", "descending": false } ], "include_columns": [ "CustomerId" ],
      "filter_predicate": null, "is_unique": false, "fill_factor": 90, "data_compression": "PAGE", "estimated_size_mb": 11.44,
      "confidence": "High", "rationale": "Missing index with impact score above 290,000.", "benefiting_queries": [],
      "script": "CREATE INDEX IX_Orders_OrderDate_Status ON dbo.Orders (OrderDate, Status) INCLUDE (CustomerId) WITH (FILLFACTOR = 90, DATA_COMPRESSION = PAGE);" },
    { "priority": 3, "category": "CreateIndex", "title": "Narrow CustomerId index (covered by priority 1)",
      "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_CustomerId_Narrow",
      "key_columns": [ { "column": "CustomerId", "descending": false } ], "include_columns": [],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": 4.58,
      "confidence": "Low", "rationale": "Redundant once priority 1 exists.", "benefiting_queries": [], "script": "" },
    { "priority": 4, "category": "CreateIndex", "title": "Unknown column",
      "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_Nope",
      "key_columns": [ { "column": "NoSuchColumn", "descending": false } ], "include_columns": [],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": null,
      "confidence": "Low", "rationale": "Hallucinated column.", "benefiting_queries": [], "script": "" },
    { "priority": 5, "category": "CreateIndex", "title": "Filtered index",
      "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_Status_Open",
      "key_columns": [ { "column": "Status", "descending": false } ], "include_columns": [],
      "filter_predicate": "Status = 2", "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": 1.0,
      "confidence": "Medium", "rationale": "Filtered index for open orders.", "benefiting_queries": [], "script": "" },
    { "priority": 6, "category": "CreateIndex", "title": "Injection in the index name",
      "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Evil]; DROP TABLE dbo.Customers; --",
      "key_columns": [ { "column": "Status", "descending": true } ], "include_columns": [],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": 1.0,
      "confidence": "Low", "rationale": "Test.", "benefiting_queries": [], "script": "DROP TABLE dbo.Customers;" },
    { "priority": 7, "category": "CreateIndex", "title": "Injection in the table name",
      "schema_name": "dbo", "table_name": "Orders; DROP TABLE dbo.Customers; --", "index_name": "IX_X",
      "key_columns": [ { "column": "Status", "descending": false } ], "include_columns": [],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": 1.0,
      "confidence": "Low", "rationale": "Test.", "benefiting_queries": [], "script": "" },
    { "priority": 8, "category": "DropIndex", "title": "Drop the exact duplicate IX_Customers_Region_Dup",
      "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Region_Dup",
      "key_columns": [], "include_columns": [],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": -0.3,
      "confidence": "Medium", "rationale": "Exact key duplicate with no reads.", "benefiting_queries": [],
      "script": "DROP INDEX IX_Customers_Region_Dup ON dbo.Customers;" },
    { "priority": 9, "category": "Constraint", "title": "Re-trust FK_Orders_Customers",
      "schema_name": "dbo", "table_name": "Orders", "index_name": null,
      "key_columns": [], "include_columns": [],
      "filter_predicate": null, "is_unique": false, "fill_factor": null, "data_compression": null, "estimated_size_mb": null,
      "confidence": "High", "rationale": "Untrusted foreign key.", "benefiting_queries": [],
      "script": "ALTER TABLE dbo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;" }
  ]
}');
INSERT #Canned VALUES ('fenced', N'```json
{ "summary": "Nothing to do.", "recommendations": [] }
```');
INSERT #Canned VALUES ('broken', N'Here are my recommendations: create an index on Orders.');
GO

/* Warm the plan cache: under memory pressure SQL Server trims it within seconds, and T1 checks
   that the plan cache section finds the workload. The missing-index DMVs come from 02_Run-Workload.sql. */
DECLARE @i int = 0, @t decimal(18, 2), @n nvarchar(100);
WHILE @i < 20
BEGIN
    SELECT @n = MAX(c.CustomerName), @t = SUM(o.TotalDue)
    FROM dbo.Orders AS o INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
    WHERE o.CustomerId = 1 + (@i * 37) % 20000;
    SET @i += 1;
END;
GO

/* ===== T1: collection =====
   Calls the collector directly: INSERT ... EXEC around sp_AIIndexTuner would nest the collector's
   own INSERT ... EXEC of DBCC SHOW_STATISTICS, which SQL Server does not allow. */
DECLARE @Data nvarchar(max);
EXEC AIIndexTuner.usp_CollectData @Data = @Data OUTPUT;
IF @Data NOT LIKE N'%=== MISSING INDEX RECOMMENDATIONS ===%dbo.Orders%'
   OR @Data NOT LIKE N'%=== DUPLICATE AND OVERLAPPING INDEXES ===%IX_Customers_Region_Dup%'
   OR @Data NOT LIKE N'%=== UNTRUSTED OR DISABLED CONSTRAINTS ===%FK_Orders_Customers%'
   OR @Data NOT LIKE N'%=== COLUMN CARDINALITY ===%EstimatedDistinctValues%'
   OR @Data NOT LIKE N'%=== PLAN CACHE QUERY STATISTICS ===%dbo.Orders AS o%'
   OR @Data NOT LIKE N'%Database Usage Statistics Since: 2%'
    THROW 50999, N'FAIL T1: collected data is missing a section or its expected rows.', 1;
IF @Data LIKE N'%Warning: section skipped%'
    THROW 50999, N'FAIL T1: a section was skipped.', 1;
IF @Data LIKE N'%"TableName":"AIIndexTuner.%' OR @Data LIKE N'%"TableName":"\[AIIndexTuner\]%' ESCAPE N'\'
    THROW 50999, N'FAIL T1: the tool''s own tables are in the collected data.', 1;
PRINT 'PASS T1: collection returns every section with the expected rows';
GO

/* ===== T1b: scope to one table ===== */
DECLARE @Data nvarchar(max);
EXEC AIIndexTuner.usp_CollectData @SchemaName = N'dbo', @TableName = N'Customers', @Data = @Data OUTPUT;
IF @Data LIKE N'%"TableName":"dbo.Orders"%' OR @Data LIKE N'%"TableName":"\[dbo\].\[Orders\]"%' ESCAPE N'\'
    THROW 50999, N'FAIL T1b: table-scoped collection includes another table.', 1;
IF @Data NOT LIKE N'%limited to table: \[dbo\].\[Customers\]%' ESCAPE N'\'
    THROW 50999, N'FAIL T1b: the scope note is missing.', 1;
PRINT 'PASS T1b: table scope filters object-level sections';
GO

/* ===== T1c: @CollectOnly writes no run ===== */
EXEC dbo.sp_AIIndexTuner @CollectOnly = 1;
IF EXISTS (SELECT 1 FROM AIIndexTuner.Run)
    THROW 50999, N'FAIL T1c: @CollectOnly = 1 wrote a run row.', 1;
PRINT 'PASS T1c: @CollectOnly = 1 writes no run';
GO

/* ===== T2: RECOMMEND stores everything and changes nothing ===== */
DECLARE @Before int = (SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Orders'));
DECLARE @Body nvarchar(max) = (SELECT Body FROM #Canned WHERE Name = 'good');
EXEC dbo.sp_AIIndexTuner @TestResponse = @Body;

DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
IF (SELECT Status FROM AIIndexTuner.Run WHERE RunId = @RunId) <> 'Succeeded'
    THROW 50999, N'FAIL T2: run did not succeed.', 1;
IF (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status = 'Recommended') <> 9
    THROW 50999, N'FAIL T2: expected 9 stored recommendations.', 1;
IF (SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Orders')) <> @Before
    THROW 50999, N'FAIL T2: RECOMMEND changed the schema.', 1;
IF (SELECT Summary FROM AIIndexTuner.Run WHERE RunId = @RunId) NOT LIKE N'Two new indexes%'
    THROW 50999, N'FAIL T2: summary not stored.', 1;
PRINT 'PASS T2: RECOMMEND stores 9 recommendations and creates nothing';
GO

/* ===== T3: CREATE applies only what passes validation ===== */
DECLARE @Body nvarchar(max) = (SELECT Body FROM #Canned WHERE Name = 'good');
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @TestResponse = @Body;

DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
DECLARE @Expected TABLE (Priority int PRIMARY KEY, Status varchar(20), ReasonLike nvarchar(200));
INSERT @Expected VALUES
    (1, 'Applied', NULL),
    (2, 'Applied', NULL),
    (3, 'Skipped', N'Existing index \[IX_Orders_CustomerId\] already%'),
    (4, 'Skipped', N'Unknown column(s)%NoSuchColumn%'),
    (5, 'Skipped', N'Filtered indexes are recommend-only%'),
    (6, 'Applied', NULL),
    (7, 'Skipped', N'Table %does not exist%'),
    (8, 'Recommended', NULL),
    (9, 'Recommended', NULL);

IF EXISTS (SELECT 1 FROM @Expected AS e
           LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority
           WHERE r.Status IS NULL OR r.Status <> e.Status
              OR (e.ReasonLike IS NOT NULL AND ISNULL(r.StatusReason, N'') NOT LIKE e.ReasonLike ESCAPE N'\'))
BEGIN
    SELECT e.Priority, e.Status AS Expected, r.Status AS Actual, r.StatusReason, r.AppliedDDL
    FROM @Expected AS e LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority;
    THROW 50999, N'FAIL T3: statuses differ from expected (see the result set above).', 1;
END;

IF OBJECT_ID(N'dbo.Customers', N'U') IS NULL
    THROW 50999, N'FAIL T3: dbo.Customers was dropped.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'IX_Evil]; DROP TABLE dbo.Customers; --')
    THROW 50999, N'FAIL T3: the injected index name was not kept as one quoted identifier.', 1;
IF (SELECT AppliedDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 2)
   NOT LIKE N'CREATE NONCLUSTERED INDEX \[IX_Orders_OrderDate_Status\] ON \[dbo\].\[Orders\] (\[OrderDate\] ASC, \[Status\] ASC) INCLUDE (\[CustomerId\]) WITH (%FILLFACTOR = 90, DATA_COMPRESSION = PAGE);' ESCAPE N'\'
    THROW 50999, N'FAIL T3: unexpected DDL for priority 2.', 1;
IF (SELECT COUNT(*) FROM sys.extended_properties AS ep
    INNER JOIN sys.indexes AS i ON ep.class = 7 AND ep.major_id = i.object_id AND ep.minor_id = i.index_id
    WHERE ep.name = N'AIIndexTuner' AND i.object_id = OBJECT_ID(N'dbo.Orders')) <> 3
    THROW 50999, N'FAIL T3: expected 3 tagged indexes.', 1;
PRINT 'PASS T3: CREATE applies 3 indexes, skips 4 with reasons, leaves 2 for review, resists injection';
GO

/* ===== T4: rerun is idempotent: existing indexes are detected ===== */
DECLARE @Body nvarchar(max) = (SELECT Body FROM #Canned WHERE Name = 'good');
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @TestResponse = @Body;
DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
IF EXISTS (SELECT 1 FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status = 'Applied')
    THROW 50999, N'FAIL T4: a rerun applied an index again.', 1;
IF (SELECT StatusReason FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1) NOT LIKE N'Existing index%'
    THROW 50999, N'FAIL T4: rerun did not report the existing index.', 1;
PRINT 'PASS T4: a second CREATE run skips indexes that now exist';
GO

/* ===== T5: a fenced answer parses; an answer that is not JSON fails the run ===== */
DECLARE @Body nvarchar(max) = (SELECT Body FROM #Canned WHERE Name = 'fenced');
EXEC dbo.sp_AIIndexTuner @TestResponse = @Body;
IF (SELECT Status FROM AIIndexTuner.Run WHERE RunId = (SELECT MAX(RunId) FROM AIIndexTuner.Run)) <> 'Succeeded'
    THROW 50999, N'FAIL T5: fenced JSON was not accepted.', 1;

SET @Body = (SELECT Body FROM #Canned WHERE Name = 'broken');
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @TestResponse = @Body;
    THROW 50999, N'FAIL T5: a non-JSON answer did not raise an error.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50207 THROW;
END CATCH;
IF (SELECT Status FROM AIIndexTuner.Run WHERE RunId = (SELECT MAX(RunId) FROM AIIndexTuner.Run)) <> 'Failed'
    THROW 50999, N'FAIL T5: the failed run was not marked Failed.', 1;
PRINT 'PASS T5: fenced JSON parses; a non-JSON answer fails the run with error 50207';
GO

/* ===== T6: sp_AIIndexTuner_Apply leaves non-index categories for review ===== */
DECLARE @RecId int = (SELECT MIN(RecommendationId) FROM AIIndexTuner.Recommendation WHERE Category = 'DropIndex' AND Status = 'Recommended');
CREATE TABLE #Applied (RecommendationId int, RunId int, Priority int, Category varchar(30), Title nvarchar(400), SchemaName sysname NULL,
                       TableName sysname NULL, IndexName sysname NULL, Status varchar(20), StatusReason nvarchar(4000), AppliedDDL nvarchar(max), AppliedAt datetime2(0));
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = @RecId;
IF (SELECT Status FROM AIIndexTuner.Recommendation WHERE RecommendationId = @RecId) <> 'Skipped'
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Region_Dup')
    THROW 50999, N'FAIL T6: a DropIndex recommendation was applied.', 1;
PRINT 'PASS T6: DropIndex is recommend-only';
GO

/* ===== T7: parameter validation ===== */
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @TableName = N'Orders', @CollectOnly = 1;
    THROW 50999, N'FAIL T7: @TableName without @SchemaName was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50202 THROW;
END CATCH;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @Mode = 'DROP', @CollectOnly = 1;
    THROW 50999, N'FAIL T7: an unknown @Mode was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50201 THROW;
END CATCH;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @SchemaName = N'dbo', @TableName = N'NoSuchTable', @CollectOnly = 1;
    THROW 50999, N'FAIL T7: a missing table was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50205 THROW;
END CATCH;
PRINT 'PASS T7: parameter validation';
GO

/* ===== T8: request body (no network call): built and well formed ===== */
-- usp_InvokeModel needs a Config row; without one it must stop before calling out.
IF NOT EXISTS (SELECT 1 FROM AIIndexTuner.Config)
BEGIN
    BEGIN TRY
        EXEC dbo.sp_AIIndexTuner;
        THROW 50999, N'FAIL T8: a run without configuration did not raise an error.', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 50206 THROW;
    END CATCH;
    PRINT 'PASS T8: a run without configuration stops with error 50206';
END
ELSE
    PRINT 'SKIP T8: AIIndexTuner.Config has a row';
GO

/* ===== T9: the Responses API request body ===== */
DECLARE @Body nvarchar(max) = AIIndexTuner.fn_RequestBody(N'gpt-5.6-luna', 'high', 32000, 1, 1, N'system "quoted"', N'user ' + REPLICATE(CAST(N'x' AS nvarchar(max)), 9000));
IF ISJSON(@Body) = 0
   OR JSON_VALUE(@Body, '$.model') <> N'gpt-5.6-luna'
   OR JSON_VALUE(@Body, '$.input[0].role') <> N'developer'
   OR JSON_VALUE(@Body, '$.input[0].content') <> N'system "quoted"'
   OR LEN((SELECT u FROM OPENJSON(@Body, '$.input[1]') WITH (u nvarchar(max) '$.content'))) <> 9005
   OR JSON_VALUE(@Body, '$.reasoning.effort') <> 'high'
   OR JSON_VALUE(@Body, '$.text.format.type') <> 'json_schema'
   OR JSON_QUERY(@Body, '$.text.format.schema.properties.recommendations') IS NULL
   OR @Body NOT LIKE N'%"strict":true%' OR @Body NOT LIKE N'%"background":true%' OR @Body NOT LIKE N'%"store":true%'
   OR CAST(JSON_VALUE(@Body, '$.max_output_tokens') AS int) <> 32000
    THROW 50999, N'FAIL T9: the request body is malformed.', 1;

SET @Body = AIIndexTuner.fn_RequestBody(N'gpt-4o', 'high', 1000, 0, 0, N's', N'u');
IF JSON_QUERY(@Body, '$.reasoning') IS NOT NULL OR JSON_QUERY(@Body, '$.text') IS NOT NULL OR @Body LIKE N'%background%'
    THROW 50999, N'FAIL T9: a gpt-4 body without structured output or background mode carries those fields.', 1;
PRINT 'PASS T9: request body is well formed, escapes text, and drops options a deployment does not take';
GO

/* ===== T10: reading the answer out of a Responses API response ===== */
DECLARE @Long nvarchar(max) = REPLICATE(CAST(N'a' AS nvarchar(max)), 6000);
DECLARE @Response nvarchar(max) = CONCAT(
    CAST(N'{"response":{"status":{"http":{"code":200,"description":"OK"}}},"result":{"id":"resp_1","status":"completed","model":"gpt-5.6-luna-2026-09-01",' AS nvarchar(max)),
    N'"output":[{"type":"reasoning","id":"rs_1","summary":[]},',
    N'{"type":"message","role":"assistant","content":[{"type":"output_text","text":"', @Long, N'"},{"type":"output_text","text":"END"}]}],',
    N'"usage":{"input_tokens":1234,"output_tokens":567}}}');
DECLARE @Text nvarchar(max) = AIIndexTuner.fn_ResponseText(@Response);
IF @Text IS NULL OR LEN(@Text) <> 6003 OR RIGHT(@Text, 3) <> N'END'
    THROW 50999, N'FAIL T10: the answer text was not read whole and in order.', 1;
IF AIIndexTuner.fn_ResponseText(N'{"response":{},"result":{"status":"completed","output":[{"type":"reasoning","summary":[]}]}}') IS NOT NULL
    THROW 50999, N'FAIL T10: a response with no message returned text.', 1;
PRINT 'PASS T10: answer text over 4,000 characters is read whole, in order, skipping reasoning items';
GO

PRINT 'ALL TESTS PASSED';
GO
