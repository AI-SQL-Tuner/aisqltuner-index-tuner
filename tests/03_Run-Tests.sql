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
   -- The Orders suggestions include TotalDue decimal(12, 2) and CustomerId int, with their types.
   OR @Data NOT LIKE N'%=== MISSING INDEX RECOMMENDATIONS ===%"IncludedColumnTypes":"TotalDue decimal(12, 2)"%=== INDEX USAGE STATISTICS ===%'
   OR @Data NOT LIKE N'%=== MISSING INDEX OVERLAP SIGNALS ===%"IncludedColumnTypes":"%=== DUPLICATE AND OVERLAPPING INDEXES ===%'
   OR @Data NOT LIKE N'%=== SKEWED LOW-CARDINALITY COLUMNS ===%'
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
IF @Data NOT LIKE N'%Query Store object scope: % queries reference \[dbo\].\[Customers\] (confirmed from plan XML;%' ESCAPE N'\'
   OR @Data LIKE N'%Query Store object scope: 0 queries%'
    THROW 50999, N'FAIL T1b: Query Store scope was not resolved from plan XML, or matched nothing.', 1;
-- The plan cache section stays database-wide, so check only the Query Store workload section.
DECLARE @QsStart int = CHARINDEX(N'=== QUERY STORE WORKLOAD INSIGHTS ===', @Data),
        @QsEnd int = CHARINDEX(N'=== QUERY STORE WRITE WORKLOAD MIX ===', @Data);
DECLARE @QsSection nvarchar(max) = SUBSTRING(@Data, @QsStart, @QsEnd - @QsStart);
IF @QsSection NOT LIKE N'%"QueryId"%' OR @QsSection LIKE N'%AuditLog%'
    THROW 50999, N'FAIL T1b: the scoped Query Store workload is empty or includes a query that does not touch the scoped table.', 1;
PRINT 'PASS T1b: table scope filters object-level sections and resolves the Query Store scope from plan XML';
GO

/* ===== T11: the sections added after the first prototype ===== */
DECLARE @Data nvarchar(max);
EXEC AIIndexTuner.usp_CollectData @Data = @Data OUTPUT;
DECLARE @Missing nvarchar(max) = CONCAT(
    CASE WHEN @Data NOT LIKE N'%=== INDEX OPERATIONAL HOTSPOTS ===%"IndexName":"PK_Orders"%' THEN N' operational-hotspots' END,
    CASE WHEN @Data NOT LIKE N'%=== INDEX PAGE DENSITY ===%"IndexName":"PK_Orders"%"SizeMB"%' THEN N' page-density' END,
    CASE WHEN @Data NOT LIKE N'%OPTIMIZED_SP_EXECUTESQL: %ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY: %' THEN N' sp_executesql-settings' END,
    CASE WHEN @Data NOT LIKE N'%=== QUERY STORE WORKLOAD INSIGHTS ===%"QueryId"%"TotalWaitSecs"%' THEN N' qs-workload' END,
    CASE WHEN @Data NOT LIKE N'%=== QUERY STORE WRITE WORKLOAD MIX ===%"StatementType":"INSERT"%' THEN N' qs-write-mix' END,
    -- The workload's UPDATE is auto-parameterized: "(@1 tinyint,@2 tinyint)UPDATE ...".
    CASE WHEN SUBSTRING(@Data, CHARINDEX(N'=== QUERY STORE WRITE WORKLOAD MIX ===', @Data), 2000) NOT LIKE N'%"StatementType":"UPDATE"%' THEN N' qs-write-mix-parameterized-update' END,
    CASE WHEN @Data NOT LIKE N'%=== QUERY STORE FORCED PLAN FAILURES ===%"LastFailureReason":"NO_INDEX"%' THEN N' qs-forced-plan-failures' END,
    CASE WHEN @Data NOT LIKE N'%=== AUTOMATIC TUNING OPTIONS ===%FORCE_LAST_GOOD_PLAN%' THEN N' automatic-tuning' END,
    CASE WHEN @Data NOT LIKE N'%=== CARDINALITY ESTIMATION FEEDBACK ===%CE feedback: %CE feedback for expressions: %' THEN N' ce-feedback' END,
    CASE WHEN @Data NOT LIKE N'%Database Usage Statistics Since: %"Starting up database" message in the SQL Server error log%' THEN N' error-log-usage-window' END);
IF @Missing <> N''
BEGIN
    SET @Missing = N'FAIL T11: missing or empty:' + @Missing;
    THROW 50999, @Missing, 1;
END;
IF @Data LIKE N'%unavailable: %' OR @Data LIKE N'%could not be read: %' OR @Data LIKE N'%Warning: section skipped%'
    THROW 50999, N'FAIL T11: a section reported an error.', 1;
PRINT 'PASS T11: hotspots, page density, sp_executesql settings, Query Store workload / write mix / forced plan failures, automatic tuning, CE feedback, error-log usage window';
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
CREATE TABLE #Applied (RecommendationId int, RunId int, Priority int, PriorityLevel varchar(10), Confidence varchar(10), Category varchar(30), Title nvarchar(400), SchemaName sysname NULL,
                       TableName sysname NULL, IndexName sysname NULL, Status varchar(20), StatusReason nvarchar(4000), AppliedDDL nvarchar(max), AppliedAt datetime2(0),
                       UndoDDL nvarchar(max));
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = @RecId;
IF (SELECT Status FROM AIIndexTuner.Recommendation WHERE RecommendationId = @RecId) <> 'Skipped'
   OR (SELECT StatusReason FROM AIIndexTuner.Recommendation WHERE RecommendationId = @RecId) NOT LIKE N'Index drops are recommend-only%@AllowDropIndex = 1.'
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Region_Dup')
    THROW 50999, N'FAIL T6: a DropIndex recommendation was applied, or skipped without saying how to allow it.', 1;
PRINT 'PASS T6: DropIndex is recommend-only by default';
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

/* ===== T12: @CollectedData pins the input ===== */
DECLARE @Pinned nvarchar(max) = N'Server Name: pinned' + NCHAR(10) + N'=== MISSING INDEX RECOMMENDATIONS ===' + NCHAR(10) + N'(none)';
DECLARE @Answer nvarchar(max) = N'{"summary": "pinned", "recommendations": []}';
EXEC dbo.sp_AIIndexTuner @CollectedData = @Pinned, @TestResponse = @Answer;
EXEC dbo.sp_AIIndexTuner @CollectedData = @Pinned, @TestResponse = @Answer;
DECLARE @A int = (SELECT MAX(RunId) FROM AIIndexTuner.Run) - 1, @B int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
IF EXISTS (SELECT 1 FROM AIIndexTuner.Run WHERE RunId IN (@A, @B)
           AND (Status <> 'Succeeded' OR PayloadSupplied <> 1 OR CollectedData <> @Pinned OR CollectedChars <> LEN(@Pinned)
                OR CollectMs IS NOT NULL OR ModelMs IS NULL
                OR PayloadHash <> CONVERT(char(64), HASHBYTES('SHA2_256', @Pinned), 2)))
    THROW 50999, N'FAIL T12: a pinned run did not record the supplied payload, its hash and timings.', 1;
IF (SELECT COUNT(DISTINCT PayloadHash) FROM AIIndexTuner.Run WHERE RunId IN (@A, @B)) <> 1
    THROW 50999, N'FAIL T12: two runs with the same payload have different hashes.', 1;
IF (SELECT PayloadSupplied FROM AIIndexTuner.Run WHERE RunId = (SELECT MIN(RunId) FROM AIIndexTuner.Run)) <> 0
   OR (SELECT CollectMs FROM AIIndexTuner.Run WHERE RunId = (SELECT MIN(RunId) FROM AIIndexTuner.Run)) IS NULL
    THROW 50999, N'FAIL T12: a collecting run is not marked as collected, or has no collect time.', 1;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @CollectedData = N'', @TestResponse = @Answer;
    THROW 50999, N'FAIL T12: an empty @CollectedData was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50208 THROW;
END CATCH;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @CollectedData = @Pinned, @CollectOnly = 1;
    THROW 50999, N'FAIL T12: @CollectedData with @CollectOnly = 1 was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50208 THROW;
END CATCH;
PRINT 'PASS T12: @CollectedData pins the input, with its hash and timings recorded';
GO

/* ===== T13: the collector leaves out this tool's own statements =====
   By now the tests have run sp_AIIndexTuner many times, so its statements are in the plan cache
   and Query Store. */
DECLARE @Data nvarchar(max);
EXEC AIIndexTuner.usp_CollectData @Data = @Data OUTPUT;
DECLARE @PlanCache nvarchar(max) = SUBSTRING(@Data, CHARINDEX(N'=== PLAN CACHE QUERY STATISTICS ===', @Data), CHARINDEX(N'=== HEAP TABLE ANALYSIS ===', @Data) - CHARINDEX(N'=== PLAN CACHE QUERY STATISTICS ===', @Data)),
        @QueryStore nvarchar(max) = SUBSTRING(@Data, CHARINDEX(N'=== QUERY STORE WORKLOAD INSIGHTS ===', @Data), CHARINDEX(N'=== AUTOMATIC TUNING OPTIONS ===', @Data) - CHARINDEX(N'=== QUERY STORE WORKLOAD INSIGHTS ===', @Data));
IF @PlanCache LIKE N'%AIIndexTuner%' OR @QueryStore LIKE N'%AIIndexTuner%'
    THROW 50999, N'FAIL T13: the plan cache or Query Store sections include this tool''s own statements.', 1;
IF @QueryStore NOT LIKE N'%"QueryId"%'
    THROW 50999, N'FAIL T13: the Query Store section is empty, so the check above proves nothing.', 1;
PRINT 'PASS T13: the plan cache, Query Store workload and write mix leave out this tool''s own statements';
GO

/* ===== T14: change controls go into the prompt and onto the run ===== */
IF AIIndexTuner.fn_ChangeRules(NULL, NULL, NULL) <> N'' OR AIIndexTuner.fn_ChangeRules(1, 1, NULL) <> N''
    THROW 50999, N'FAIL T14: settings that restrict nothing changed the prompt.', 1;
DECLARE @Rules nvarchar(max) = AIIndexTuner.fn_ChangeRules(0, 0, 2);
IF @Rules NOT LIKE N'%Do not recommend columnstore indexes%' OR @Rules NOT LIKE N'%Do not recommend dropping or disabling any existing index%'
   OR @Rules NOT LIKE N'%at most 2 new indexes%' OR AIIndexTuner.fn_ChangeRules(NULL, NULL, 0) NOT LIKE N'%Do not recommend any new indexes%'
    THROW 50999, N'FAIL T14: the change rules are missing an instruction.', 1;

DECLARE @Answer nvarchar(max) = N'{"summary": "controls", "recommendations": []}';
EXEC dbo.sp_AIIndexTuner @CollectedData = N'pinned', @TestResponse = @Answer, @AllowColumnstore = 0, @AllowDropIndex = 0, @MaxNewIndexes = 2;
IF NOT EXISTS (SELECT 1 FROM AIIndexTuner.Run
               WHERE RunId = (SELECT MAX(RunId) FROM AIIndexTuner.Run)
                 AND AllowColumnstore = 0 AND AllowDropIndex = 0 AND MaxNewIndexes = 2
                 AND SystemPromptHash = CONVERT(char(64), HASHBYTES('SHA2_256', AIIndexTuner.fn_SystemPrompt() + @Rules), 2))
    THROW 50999, N'FAIL T14: the run did not record its settings, or the prompt did not carry the rules.', 1;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @CollectOnly = 1, @MaxNewIndexes = -1;
    THROW 50999, N'FAIL T14: a negative @MaxNewIndexes was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50209 THROW;
END CATCH;
PRINT 'PASS T14: change controls add their rules to the prompt and are recorded on the run';
GO

/* ===== T15: settings are enforced when the model ignores them ===== */
DECLARE @Answer nvarchar(max) = N'{"summary": "ignores the controls", "recommendations": [
  {"priority": 1, "category": "CreateIndex", "title": "Columnstore", "schema_name": "dbo", "table_name": "Orders", "index_name": "NCCI_Orders_T15",
   "index_type": "NONCLUSTERED COLUMNSTORE", "key_columns": [{"column": "OrderDate", "descending": false}, {"column": "TotalDue", "descending": false}],
   "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 2, "category": "CreateIndex", "title": "Within the limit", "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_Status_OrderDate_T15",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "Status", "descending": false}, {"column": "OrderDate", "descending": false}],
   "include_columns": ["TotalDue"], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 3, "category": "CreateIndex", "title": "Over the limit", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Email_T15",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "Email", "descending": false}],
   "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Medium", "rationale": "t", "script": ""},
  {"priority": 4, "category": "DropIndex", "title": "Drop", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Region_Dup",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Medium", "rationale": "t",
   "script": "DROP INDEX IX_Customers_Region_Dup ON dbo.Customers;"}]}';
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @TestResponse = @Answer, @AllowColumnstore = 0, @AllowDropIndex = 0, @MaxNewIndexes = 1;

DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
DECLARE @Expected TABLE (Priority int PRIMARY KEY, Status varchar(20), ReasonLike nvarchar(200));
INSERT @Expected VALUES
    (1, 'Skipped', N'Columnstore indexes are not allowed (@AllowColumnstore = 0).'),
    (2, 'Applied', NULL),
    (3, 'Skipped', N'The limit of 1 new index(es)%'),
    (4, 'Skipped', N'Index drops are not allowed (@AllowDropIndex = 0).');
IF EXISTS (SELECT 1 FROM @Expected AS e
           LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority
           WHERE r.Status IS NULL OR r.Status <> e.Status
              OR (e.ReasonLike IS NOT NULL AND ISNULL(r.StatusReason, N'') NOT LIKE e.ReasonLike))
BEGIN
    SELECT e.Priority, e.Status AS Expected, r.Status AS Actual, r.StatusReason, r.AppliedDDL
    FROM @Expected AS e LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority;
    THROW 50999, N'FAIL T15: statuses differ from expected (see the result set above).', 1;
END;
IF (SELECT UndoDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 2) <> N'DROP INDEX [IX_Orders_Status_OrderDate_T15] ON [dbo].[Orders];'
    THROW 50999, N'FAIL T15: a created index has no DROP to undo it.', 1;

-- A run that did not allow drops cannot be overridden when applying.
DECLARE @DropId int = (SELECT RecommendationId FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 4);
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = @DropId, @AllowDropIndex = 1;
IF (SELECT Status FROM AIIndexTuner.Recommendation WHERE RecommendationId = @DropId) <> 'Skipped'
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Region_Dup')
   OR EXISTS (SELECT 1 FROM sys.indexes WHERE name IN (N'NCCI_Orders_T15', N'IX_Customers_Email_T15'))
    THROW 50999, N'FAIL T15: a change the run did not allow was made.', 1;
PRINT 'PASS T15: columnstore, drops and the new-index limit are enforced even when the model ignores them, and @AllowDropIndex = 0 cannot be overridden';
GO

-- sqlcmd starts with QUOTED_IDENTIFIER OFF, and filtered indexes need it ON.
SET QUOTED_IDENTIFIER ON;
GO

/* ===== T16: allowed columnstore indexes and drops, with their safety checks ===== */
-- Things a drop must not break: an index hint in a module, a unique constraint, and a forced plan.
-- The plan 02_Run-Workload.sql forced uses IX_Orders_Status_Probe, so put that index back; it also
-- reads dbo.Customers through IX_Customers_Region_Dup. IX_Customers_Name_Wide makes the filtered
-- IX_Customers_Name_T16 redundant, so that one may go however short the usage history, and it has
-- options for the UndoDDL to restore. Nothing covers IX_Customers_Name_Wide itself.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Email_Hinted')
    CREATE INDEX IX_Customers_Email_Hinted ON dbo.Customers (Email);
IF OBJECT_ID(N'dbo.UQ_Customers_Email', N'UQ') IS NULL
    ALTER TABLE dbo.Customers ADD CONSTRAINT UQ_Customers_Email UNIQUE (Email);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_Wide')
    CREATE INDEX IX_Customers_Name_Wide ON dbo.Customers (CustomerName, Region) INCLUDE (Email);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_T16')
    CREATE INDEX IX_Customers_Name_T16 ON dbo.Customers (CustomerName) INCLUDE (Email) WHERE Region = 'AB' WITH (FILLFACTOR = 90, DATA_COMPRESSION = PAGE);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Orders_Status_Probe')
    CREATE INDEX IX_Orders_Status_Probe ON dbo.Orders (Status) INCLUDE (CustomerId, TotalDue);
GO
CREATE OR ALTER PROCEDURE dbo.usp_T16_Hinted AS
    SELECT CustomerId FROM dbo.Customers WITH (INDEX (IX_Customers_Email_Hinted)) WHERE Email = N'c1@example.com';
GO
DECLARE @Answer nvarchar(max) = N'{"summary": "allowed", "recommendations": [
  {"priority": 1, "category": "CreateIndex", "title": "NCCI", "schema_name": "dbo", "table_name": "Orders", "index_name": "NCCI_Orders_T16",
   "index_type": "NONCLUSTERED COLUMNSTORE", "key_columns": [{"column": "OrderDate", "descending": false}, {"column": "Status", "descending": false}],
   "include_columns": ["TotalDue"], "filter_predicate": null, "is_unique": false, "fill_factor": 80, "data_compression": "PAGE", "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 2, "category": "CreateIndex", "title": "Second columnstore", "schema_name": "dbo", "table_name": "Orders", "index_name": null,
   "index_type": "CLUSTERED COLUMNSTORE", "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 3, "category": "CreateIndex", "title": "CCI over a clustered PK", "schema_name": "dbo", "table_name": "Customers", "index_name": null,
   "index_type": "CLUSTERED COLUMNSTORE", "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 4, "category": "CreateIndex", "title": "CCI on the heap", "schema_name": "dbo", "table_name": "AuditLog", "index_name": null,
   "index_type": "CLUSTERED COLUMNSTORE", "key_columns": [{"column": "LoggedAt", "descending": false}], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Medium", "rationale": "t", "script": ""},
  {"priority": 5, "category": "DropIndex", "title": "Unused", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Name_T16",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 6, "category": "DropIndex", "title": "Clustered PK", "schema_name": "dbo", "table_name": "Customers", "index_name": "PK_Customers",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 7, "category": "DropIndex", "title": "Unique constraint", "schema_name": "dbo", "table_name": "Customers", "index_name": "UQ_Customers_Email",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 8, "category": "DropIndex", "title": "Hinted", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Email_Hinted",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 9, "category": "DropIndex", "title": "Forced plan", "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_Status_Probe",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""},
  {"priority": 10, "category": "DropIndex", "title": "Injection", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Region]; DROP TABLE dbo.Customers; --",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": "DROP TABLE dbo.Customers;"},
  {"priority": 11, "category": "DropIndex", "title": "Duplicate", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Region_Dup",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 12, "category": "DropIndex", "title": "Unused, short history", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Name_Wide",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Low", "rationale": "t", "script": ""}]}';
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @TestResponse = @Answer, @AllowColumnstore = 1, @AllowDropIndex = 1;

DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
DECLARE @Expected TABLE (Priority int PRIMARY KEY, Status varchar(20), ReasonLike nvarchar(200));
INSERT @Expected VALUES
    (1, 'Applied', NULL),
    (2, 'Skipped', N'The table already has columnstore index \[NCCI_Orders_T16\]%'),
    (3, 'Skipped', N'The table has a clustered rowstore index%'),
    (4, 'Applied', NULL),
    (5, 'Applied', N'Redundant: \[IX_Customers_Name_Wide\] has the same leading keys and covers it.'),
    (6, 'Skipped', N'Only nonclustered indexes are dropped here; \[PK_Customers\] is CLUSTERED.'),
    (7, 'Skipped', N'\[UQ_Customers_Email\] enforces a primary key or unique constraint.'),
    (8, 'Skipped', N'\[IX_Customers_Email_Hinted\] is named by module \[dbo\].\[usp_T16_Hinted\]%'),
    (9, 'Skipped', N'\[IX_Orders_Status_Probe\] is named by the forced Query Store plan_id%'),
    (10, 'Skipped', N'Index %does not exist on \[dbo\].\[Customers\].'),
    (11, 'Skipped', N'\[IX_Customers_Region_Dup\] is named by the forced Query Store plan_id%'),
    (12, 'Skipped', N'No other index covers \[IX_Customers_Name_Wide\], and the usage statistics cover only %at least 7 days of them.');
IF EXISTS (SELECT 1 FROM @Expected AS e
           LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority
           WHERE r.Status IS NULL OR r.Status <> e.Status
              OR (e.ReasonLike IS NOT NULL AND ISNULL(r.StatusReason, N'') NOT LIKE e.ReasonLike ESCAPE N'\'))
BEGIN
    SELECT e.Priority, e.Status AS Expected, r.Status AS Actual, r.StatusReason, r.AppliedDDL
    FROM @Expected AS e LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority;
    THROW 50999, N'FAIL T16: statuses differ from expected (see the result set above).', 1;
END;

-- The DDL is built from the validated fields: the include goes into the column list, and
-- rowstore-only options are dropped.
IF (SELECT AppliedDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1)
   NOT LIKE N'CREATE NONCLUSTERED COLUMNSTORE INDEX \[NCCI_Orders_T16\] ON \[dbo\].\[Orders\] (\[OrderDate\], \[Status\], \[TotalDue\])%;' ESCAPE N'\'
   OR (SELECT AppliedDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1) LIKE N'%FILLFACTOR%'
   OR (SELECT AppliedDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 4)
      NOT LIKE N'CREATE CLUSTERED COLUMNSTORE INDEX \[CCI\_AIT\_AuditLog\_%\] ON \[dbo\].\[AuditLog\]%;' ESCAPE N'\'
    THROW 50999, N'FAIL T16: unexpected columnstore DDL.', 1;
IF OBJECT_ID(N'dbo.Customers', N'U') IS NULL OR EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_T16')
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Region_Dup')
    THROW 50999, N'FAIL T16: dbo.Customers is gone, the allowed drop did not run, or a blocked one did.', 1;

-- Each UndoDDL reverses its change: the dropped index comes back as it was, the heap comes back.
DECLARE @Undo nvarchar(max) = (SELECT UndoDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 5);
IF @Undo NOT LIKE N'CREATE NONCLUSTERED INDEX \[IX_Customers_Name_T16\] ON \[dbo\].\[Customers\] (\[CustomerName\] ASC) INCLUDE (\[Email\]) WHERE (\[Region\]=''AB'') WITH (FILLFACTOR = 90, DATA_COMPRESSION = PAGE) ON \[PRIMARY\];' ESCAPE N'\'
BEGIN
    SELECT @Undo AS UndoDDL;
    THROW 50999, N'FAIL T16: unexpected UndoDDL for the dropped index (see the result set above).', 1;
END;
EXEC sys.sp_executesql @Undo;
SET @Undo = (SELECT UndoDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 4);
EXEC sys.sp_executesql @Undo;
SET @Undo = (SELECT UndoDDL FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1);
EXEC sys.sp_executesql @Undo;
IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i
               INNER JOIN sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id
               WHERE i.object_id = OBJECT_ID(N'dbo.Customers') AND i.name = N'IX_Customers_Name_T16' AND i.type = 2
                 AND i.fill_factor = 90 AND i.filter_definition = N'([Region]=''AB'')' AND p.data_compression_desc = N'PAGE')
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AuditLog') AND type = 0)
   OR EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Orders') AND type IN (5, 6))
    THROW 50999, N'FAIL T16: an UndoDDL did not reverse its change.', 1;

DROP PROCEDURE dbo.usp_T16_Hinted;
DROP INDEX IX_Customers_Email_Hinted ON dbo.Customers;
ALTER TABLE dbo.Customers DROP CONSTRAINT UQ_Customers_Email;
DROP INDEX IX_Orders_Status_Probe ON dbo.Orders;
PRINT 'PASS T16: allowed columnstore indexes and drops are applied with UndoDDL that restores them; drops that would break a constraint, index hint or forced plan, or that rest on a usage history under 7 days, are skipped';
GO

/* ===== T17: recommend-only changes can be applied after review ===== */
DECLARE @Answer nvarchar(max) = N'{"summary": "review first", "recommendations": [
  {"priority": 1, "category": "CreateIndex", "title": "NCCI", "schema_name": "dbo", "table_name": "Customers", "index_name": "NCCI_Customers_T17",
   "index_type": "NONCLUSTERED COLUMNSTORE", "key_columns": [{"column": "Region", "descending": false}],
   "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Medium", "rationale": "t", "script": ""},
  {"priority": 2, "category": "DropIndex", "title": "Unused", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Name_T16",
   "index_type": null, "key_columns": [], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""}]}';
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @TestResponse = @Answer;   -- both settings NULL: recommend-only

DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
IF (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status = 'Recommended') <> 2
   OR (SELECT IndexType FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1) <> 'NONCLUSTERED COLUMNSTORE'
    THROW 50999, N'FAIL T17: CREATE mode touched a recommend-only change.', 1;

-- Without the setting, applying it explains how; with it, it runs.
DECLARE @CsId int = (SELECT RecommendationId FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1);
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = @CsId;
IF (SELECT StatusReason FROM AIIndexTuner.Recommendation WHERE RecommendationId = @CsId) NOT LIKE N'Columnstore indexes are recommend-only%@AllowColumnstore = 1.'
    THROW 50999, N'FAIL T17: a recommend-only columnstore index was not skipped with a way to allow it.', 1;
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RunId = @RunId, @AllowColumnstore = 1, @AllowDropIndex = 1;
IF (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status = 'Applied') <> 2
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NCCI_Customers_T17' AND type = 6)
   OR EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_T16')
    THROW 50999, N'FAIL T17: sp_AIIndexTuner_Apply with the settings did not apply both changes.', 1;

DECLARE @Undo nvarchar(max) = (SELECT STRING_AGG(UndoDDL, N' ') FROM AIIndexTuner.Recommendation WHERE RunId = @RunId);
EXEC sys.sp_executesql @Undo;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_T16') OR EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NCCI_Customers_T17')
    THROW 50999, N'FAIL T17: the UndoDDL did not restore the table.', 1;
-- A low-use drop needs the error log to confirm the usage period, and INSERT ... EXEC cannot read it.
DECLARE @WideId int = (SELECT MAX(RecommendationId) FROM AIIndexTuner.Recommendation WHERE Category = 'DropIndex' AND IndexName = N'IX_Customers_Name_Wide');
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = @WideId;
IF (SELECT StatusReason FROM AIIndexTuner.Recommendation WHERE RecommendationId = @WideId) NOT LIKE N'%the error log could not be read%'
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_Wide')
    THROW 50999, N'FAIL T17: a low-use drop went ahead without the error log to confirm the usage period.', 1;

DROP INDEX IX_Customers_Name_T16 ON dbo.Customers;
DROP INDEX IX_Customers_Name_Wide ON dbo.Customers;
PRINT 'PASS T17: recommend-only columnstore indexes and drops stay for review, then apply with sp_AIIndexTuner_Apply and the setting';
GO

/* ===== T18: column types and skewed low-cardinality columns ===== */
IF AIIndexTuner.fn_ColumnType(OBJECT_ID(N'dbo.Orders'), COLUMNPROPERTY(OBJECT_ID(N'dbo.Orders'), N'Notes', 'ColumnId')) <> N'nvarchar(200)'
   OR AIIndexTuner.fn_ColumnType(OBJECT_ID(N'dbo.Orders'), COLUMNPROPERTY(OBJECT_ID(N'dbo.Orders'), N'TotalDue', 'ColumnId')) <> N'decimal(12, 2)'
   OR AIIndexTuner.fn_ColumnType(OBJECT_ID(N'dbo.Orders'), COLUMNPROPERTY(OBJECT_ID(N'dbo.Orders'), N'OrderDate', 'ColumnId')) <> N'date'
   OR AIIndexTuner.fn_ColumnType(OBJECT_ID(N'dbo.Customers'), COLUMNPROPERTY(OBJECT_ID(N'dbo.Customers'), N'Region', 'ColumnId')) <> N'char(2)'
    THROW 50999, N'FAIL T18: fn_ColumnType does not format a type as DDL would.', 1;

-- Orders.Notes is NULL in 90% of rows and 'Gift wrap' in 10%: skewed. Orders.Status has five
-- equally common values: not skewed.
IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'ST_T18_Notes')
    CREATE STATISTICS ST_T18_Notes ON dbo.Orders (Notes) WITH FULLSCAN;
IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'ST_T18_Status')
    CREATE STATISTICS ST_T18_Status ON dbo.Orders (Status) WITH FULLSCAN;
DECLARE @Data nvarchar(max);
EXEC AIIndexTuner.usp_CollectData @Data = @Data OUTPUT;
DECLARE @Skew nvarchar(max) = SUBSTRING(@Data, CHARINDEX(N'=== SKEWED LOW-CARDINALITY COLUMNS ===', @Data),
                                        CHARINDEX(N'=== LARGE TABLES ===', @Data) - CHARINDEX(N'=== SKEWED LOW-CARDINALITY COLUMNS ===', @Data));
IF @Skew NOT LIKE N'%"TableName":"\[dbo\].\[Orders\]","ColumnName":"Notes","ColumnType":"nvarchar(200)","HistogramRows":300000,%"ValueShares":"NULL: 90.00\%, Gift wrap: 10.00\%"%' ESCAPE N'\'
   OR @Skew LIKE N'%"ColumnName":"Status"%'
BEGIN
    SELECT @Skew AS SkewSection;
    THROW 50999, N'FAIL T18: the skewed-column section is missing Notes, or lists the evenly spread Status (see the result set above).', 1;
END;
DROP STATISTICS dbo.Orders.ST_T18_Notes, dbo.Orders.ST_T18_Status;
PRINT 'PASS T18: column types are formatted as in DDL, and a skewed column is reported with each value''s share while an even one is not';
GO

/* ===== T19: @MinPriority and @MinConfidence apply only recommendations at those levels or above ===== */
IF AIIndexTuner.fn_SystemPrompt() NOT LIKE N'%priority_level is High, Medium or Low%'
   OR AIIndexTuner.fn_ResponseSchema() NOT LIKE N'%"required": \["priority", "priority_level",%' ESCAPE N'\'
   OR ISJSON(AIIndexTuner.fn_ResponseSchema()) = 0
    THROW 50999, N'FAIL T19: the prompt or the response schema does not ask for priority_level.', 1;

DECLARE @Answer nvarchar(max) = N'{"summary": "thresholds", "recommendations": [
  {"priority": 1, "priority_level": "High", "category": "CreateIndex", "title": "High, High", "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_TotalDue_T19",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "TotalDue", "descending": false}], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 2, "priority_level": "Medium", "category": "CreateIndex", "title": "Medium, High", "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_Notes_T19",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "Notes", "descending": false}], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 3, "priority_level": "Medium", "category": "CreateIndex", "title": "Medium, Medium", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Name_T19",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "CustomerName", "descending": false}], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "Medium", "rationale": "t", "script": ""},
  {"priority": 4, "priority_level": "Low", "category": "CreateIndex", "title": "Low, High", "schema_name": "dbo", "table_name": "Customers", "index_name": "IX_Customers_Email_Region_T19",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "Email", "descending": false}, {"column": "Region", "descending": false}], "include_columns": [], "filter_predicate": null, "is_unique": false, "confidence": "High", "rationale": "t", "script": ""},
  {"priority": 5, "category": "CreateIndex", "title": "No levels", "schema_name": "dbo", "table_name": "Orders", "index_name": "IX_Orders_Notes_OrderDate_T19",
   "index_type": "NONCLUSTERED", "key_columns": [{"column": "Notes", "descending": false}, {"column": "OrderDate", "descending": false}], "include_columns": [], "filter_predicate": null, "is_unique": false, "rationale": "t", "script": ""}]}';
-- Lower case is accepted and stored as High, Medium or Low.
EXEC dbo.sp_AIIndexTuner @Mode = 'CREATE', @TestResponse = @Answer, @MinPriority = 'medium', @MinConfidence = 'HIGH';

DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run);
IF NOT EXISTS (SELECT 1 FROM AIIndexTuner.Run WHERE RunId = @RunId AND MinPriority = 'Medium' AND MinConfidence = 'High')
   OR (SELECT PriorityLevel FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 1) <> 'High'
   OR (SELECT PriorityLevel FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 5) IS NOT NULL
    THROW 50999, N'FAIL T19: the run did not record its minimums, or the priority levels were not stored.', 1;

DECLARE @Expected TABLE (Priority int PRIMARY KEY, Status varchar(20), ReasonLike nvarchar(400));
INSERT @Expected VALUES
    (1, 'Applied', NULL),
    (2, 'Applied', NULL),
    (3, 'Skipped', N'Confidence Medium is below the minimum of High (@MinConfidence)%@MinConfidence = ''Low''.'),
    (4, 'Skipped', N'Priority level Low is below the minimum of Medium (@MinPriority)%@MinPriority = ''Low''.'),
    (5, 'Skipped', N'Priority level (none) is below the minimum of Medium%');
IF EXISTS (SELECT 1 FROM @Expected AS e
           LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority
           WHERE r.Status IS NULL OR r.Status <> e.Status
              OR (e.ReasonLike IS NOT NULL AND ISNULL(r.StatusReason, N'') NOT LIKE e.ReasonLike))
BEGIN
    SELECT e.Priority, e.Status AS Expected, r.Status AS Actual, r.StatusReason
    FROM @Expected AS e LEFT JOIN AIIndexTuner.Recommendation AS r ON r.RunId = @RunId AND r.Priority = e.Priority;
    THROW 50999, N'FAIL T19: CREATE with @MinPriority = Medium and @MinConfidence = High gave unexpected statuses (see the result set above).', 1;
END;

-- Applying the run again keeps its minimums.
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RunId = @RunId;
IF (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status = 'Applied') <> 2
    THROW 50999, N'FAIL T19: sp_AIIndexTuner_Apply without minimums did not keep the run''s.', 1;

-- After review, a lower minimum from the caller replaces the run's: here only the confidence one,
-- so the run's @MinPriority = Medium still holds.
DECLARE @MediumId int = (SELECT RecommendationId FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Priority = 3);
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RecommendationId = @MediumId, @MinConfidence = 'Low';
IF (SELECT Status FROM AIIndexTuner.Recommendation WHERE RecommendationId = @MediumId) <> 'Applied'
   OR NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customers_Name_T19')
    THROW 50999, N'FAIL T19: a reviewed recommendation was not applied with @MinConfidence = ''Low''.', 1;

-- Low, Low applies everything else allows, including a recommendation with no levels.
INSERT #Applied EXEC dbo.sp_AIIndexTuner_Apply @RunId = @RunId, @MinPriority = 'Low', @MinConfidence = 'Low';
IF (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status = 'Applied') <> 5
    THROW 50999, N'FAIL T19: @MinPriority = Low and @MinConfidence = Low did not apply every recommendation.', 1;
IF NOT EXISTS (SELECT 1 FROM #Applied WHERE RunId = @RunId AND Priority = 1 AND PriorityLevel = 'High' AND Confidence = 'High')
    THROW 50999, N'FAIL T19: sp_AIIndexTuner_Apply does not return the priority level and confidence.', 1;

BEGIN TRY
    EXEC dbo.sp_AIIndexTuner @CollectOnly = 1, @MinPriority = 'Critical';
    THROW 50999, N'FAIL T19: an unknown @MinPriority was accepted.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50210 THROW;
END CATCH;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner_Apply @RunId = @RunId, @MinConfidence = 'Sure';
    THROW 50999, N'FAIL T19: an unknown @MinConfidence was accepted by sp_AIIndexTuner_Apply.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50303 THROW;
END CATCH;

DECLARE @Undo nvarchar(max) = (SELECT STRING_AGG(UndoDDL, N' ') FROM AIIndexTuner.Recommendation WHERE RunId = @RunId);
EXEC sys.sp_executesql @Undo;
PRINT 'PASS T19: @MinPriority and @MinConfidence apply only recommendations at those levels or above, the rest wait for review, and a lower minimum applies them later';
GO

PRINT 'ALL TESTS PASSED';
GO
