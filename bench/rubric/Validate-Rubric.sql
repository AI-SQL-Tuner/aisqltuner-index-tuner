/*
    Validates the rubric with canned model answers, no AI endpoint. Every check must pass on the
    right answer and fail on at least one wrong answer, and the payload variants must contain their
    edits. Prints PASS lines, or stops with FAIL.

    Needs the challenge tables, the workload (02_Run-ChallengeWorkload.sql), aisqltuner-index-tuner.sql
    and the rubric objects. Run-Rubric.ps1 -Mode Validate does all of that.
*/
SET NOCOUNT ON;
GO

/* ----- The forced-plan probe's ids, which the right answer for C14 must name ----- */
DECLARE @q varchar(20), @p varchar(20);
SELECT TOP (1) @q = CAST(p.query_id AS varchar(20)), @p = CAST(p.plan_id AS varchar(20))
FROM sys.query_store_plan AS p
INNER JOIN sys.query_store_query AS q ON q.query_id = p.query_id
INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE p.is_forced_plan = 1 AND p.force_failure_count > 0 AND qt.query_sql_text LIKE N'%forced_plan_probe%'
ORDER BY p.plan_id DESC;
IF @q IS NULL
    THROW 50999, N'FAIL V0: the forced-plan probe has no failing forced plan. Run 02_Run-ChallengeWorkload.sql first.', 1;
PRINT CONCAT('PASS V0: forced-plan probe found (query_id ', @q, ', plan_id ', @p, ')');

/* ----- Canned answers ----- */
DROP TABLE IF EXISTS #Canned;
CREATE TABLE #Canned (Name varchar(20) PRIMARY KEY, Body nvarchar(max));

-- The right answer: passes every base check, including the preferred ones.
INSERT #Canned VALUES ('good', REPLACE(REPLACE(N'{"summary": "Right answer.", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Customer lookups", "schema_name": "bench", "table_name": "LowCardOrders", "index_name": "IX_LowCardOrders_CustomerId_Status",
  "key_columns": [{"column": "CustomerId", "descending": false}, {"column": "Status", "descending": false}], "include_columns": ["OrderDate", "Amount"],
  "filter_predicate": null, "rationale": "CustomerId is selective; Status has 5 values and goes second.", "script": "CREATE INDEX IX_LowCardOrders_CustomerId_Status ON bench.LowCardOrders (CustomerId, Status) INCLUDE (OrderDate, Amount);"},
 {"priority": 2, "category": "CreateIndex", "title": "Open tickets", "schema_name": "bench", "table_name": "SkewTickets", "index_name": "IX_SkewTickets_Open",
  "key_columns": [{"column": "OpenedAt", "descending": true}], "include_columns": ["QueueId", "Subject"],
  "filter_predicate": "State = ''Open''", "rationale": "Only 0.5% of rows are Open.", "script": "CREATE INDEX IX_SkewTickets_Open ON bench.SkewTickets (OpenedAt DESC) INCLUDE (QueueId, Subject) WHERE State = ''Open'';"},
 {"priority": 3, "category": "Other", "title": "Columnstore for sales analytics", "schema_name": "bench", "table_name": "FactSales", "index_name": "NCCI_FactSales",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Aggregates scan most of 10M rows.",
  "script": "CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactSales ON bench.FactSales (SaleDate, StoreId, ProductId, Quantity, Amount, Discount);"},
 {"priority": 4, "category": "Other", "title": "Columnstore on cold events", "schema_name": "bench", "table_name": "FactEvents", "index_name": "NCCI_FactEvents_Cold",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Filtered to cold rows so the single-row updates on recent rows avoid columnstore write overhead.",
  "script": "CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactEvents_Cold ON bench.FactEvents (EventDate, EventType, SourceId, Status, Value) WHERE EventDate < ''2026-09-01'';"},
 {"priority": 5, "category": "CreateIndex", "title": "Queue reads", "schema_name": "bench", "table_name": "AuditQueue", "index_name": "IX_AuditQueue_Queue",
  "key_columns": [{"column": "QueueId", "descending": false}, {"column": "EnqueuedAt", "descending": false}], "include_columns": [],
  "filter_predicate": null, "rationale": "One narrow index only: user_updates far exceed reads, so write overhead rules out more.", "script": "CREATE INDEX IX_AuditQueue_Queue ON bench.AuditQueue (QueueId, EnqueuedAt);"},
 {"priority": 6, "category": "CreateIndex", "title": "Contacts by last name", "schema_name": "bench", "table_name": "CustomerContacts", "index_name": "IX_CustomerContacts_LastName",
  "key_columns": [{"column": "LastName", "descending": false}, {"column": "FirstName", "descending": false}], "include_columns": ["CityId", "Email", "Phone"],
  "filter_predicate": null, "rationale": "One index serves all three suggestions.", "script": "CREATE INDEX IX_CustomerContacts_LastName ON bench.CustomerContacts (LastName, FirstName) INCLUDE (CityId, Email, Phone);"},
 {"priority": 7, "category": "CreateIndex", "title": "Shipments by carrier and date", "schema_name": "bench", "table_name": "Shipments", "index_name": "IX_Shipments_Carrier_ShippedAt",
  "key_columns": [{"column": "CarrierId", "descending": false}, {"column": "ShippedAt", "descending": false}], "include_columns": ["TrackingNo"],
  "filter_predicate": null, "rationale": "Equality then range, which also gives the ORDER BY.", "script": "CREATE INDEX IX_Shipments_Carrier_ShippedAt ON bench.Shipments (CarrierId, ShippedAt) INCLUDE (TrackingNo);"},
 {"priority": 8, "category": "CreateIndex", "title": "Documents by owner", "schema_name": "bench", "table_name": "Documents", "index_name": "IX_Documents_OwnerId",
  "key_columns": [{"column": "OwnerId", "descending": false}], "include_columns": ["Title"],
  "filter_predicate": null, "rationale": "Body is nvarchar(max) and stays out of the index.", "script": "CREATE INDEX IX_Documents_OwnerId ON bench.Documents (OwnerId) INCLUDE (Title);"},
 {"priority": 9, "category": "QueryChange", "title": "Rewrite the Invoices date filters", "schema_name": "bench", "table_name": "Invoices", "index_name": null,
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "YEAR() and DATEDIFF() on the column are not SARGable on bench.Invoices; use ranges.", "script": ""},
 {"priority": 10, "category": "DropIndex", "title": "Drop the exact duplicate", "schema_name": "bench", "table_name": "Accounts", "index_name": "IX_Accounts_Region_Dup",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Exact duplicate of IX_Accounts_Region.", "script": "DROP INDEX IX_Accounts_Region_Dup ON bench.Accounts;"},
 {"priority": 11, "category": "DropIndex", "title": "Drop the left-prefix index", "schema_name": "bench", "table_name": "Accounts", "index_name": "IX_Accounts_Email",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "IX_Accounts_Email_Status covers it.", "script": "DROP INDEX IX_Accounts_Email ON bench.Accounts;"},
 {"priority": 12, "category": "DropIndex", "title": "Drop the index that duplicates the UNIQUE constraint", "schema_name": "bench", "table_name": "Accounts", "index_name": "IX_Accounts_AccountNumber",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "UQ_Accounts_AccountNumber already indexes AccountNumber.", "script": "DROP INDEX IX_Accounts_AccountNumber ON bench.Accounts;"},
 {"priority": 13, "category": "Other", "title": "Cluster the heap", "schema_name": "bench", "table_name": "StagingRows", "index_name": "CIX_StagingRows",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Removes forwarded records.", "script": "CREATE CLUSTERED INDEX CIX_StagingRows ON bench.StagingRows (BatchId, RowNo);"},
 {"priority": 14, "category": "Constraint", "title": "Re-trust FK_Payments_Payers", "schema_name": "bench", "table_name": "Payments", "index_name": null,
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Untrusted FK blocks join elimination.",
  "script": "IF NOT EXISTS (SELECT 1 FROM bench.Payments AS p WHERE NOT EXISTS (SELECT 1 FROM bench.Payers AS y WHERE y.PayerId = p.PayerId)) ALTER TABLE bench.Payments WITH CHECK CHECK CONSTRAINT FK_Payments_Payers;"},
 {"priority": 15, "category": "Other", "title": "Forced plan failure", "schema_name": "bench", "table_name": "Readings", "index_name": null,
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "The forced plan for query_id {{Q}} (plan_id {{P}}) fails with NO_INDEX.",
  "script": "EXEC sys.sp_query_store_unforce_plan @query_id = {{Q}}, @plan_id = {{P}};"},
 {"priority": 16, "category": "Other", "title": "IX_Products_Unused: candidate to confirm", "schema_name": "bench", "table_name": "Products", "index_name": "IX_Products_Unused",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "No reads, but the usage window is under a week; confirm after a longer observation period.", "script": ""}
]}', N'{{Q}}', @q), N'{{P}}', @p));

-- Wrong answer 1: breaks every forbidden rule and misses most required ones.
INSERT #Canned VALUES ('bad1', N'{"summary": "Wrong answer.", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Status lookups", "schema_name": "bench", "table_name": "LowCardOrders", "index_name": "IX_LowCardOrders_Status",
  "key_columns": [{"column": "Status", "descending": false}, {"column": "CustomerId", "descending": false}], "include_columns": [], "filter_predicate": null,
  "rationale": "As suggested.", "script": "CREATE INDEX IX_LowCardOrders_Status ON bench.LowCardOrders (Status, CustomerId);"},
 {"priority": 2, "category": "CreateIndex", "title": "Tickets by state", "schema_name": "bench", "table_name": "SkewTickets", "index_name": "IX_SkewTickets_State",
  "key_columns": [{"column": "State", "descending": false}, {"column": "OpenedAt", "descending": false}], "include_columns": [], "filter_predicate": null,
  "rationale": "As suggested.", "script": "CREATE INDEX IX_SkewTickets_State ON bench.SkewTickets (State, OpenedAt);"},
 {"priority": 3, "category": "CreateIndex", "title": "Covering index for sales", "schema_name": "bench", "table_name": "FactSales", "index_name": "IX_FactSales_SaleDate",
  "key_columns": [{"column": "SaleDate", "descending": false}], "include_columns": ["StoreId", "ProductId", "Amount", "Quantity"], "filter_predicate": null,
  "rationale": "Covers the aggregates.", "script": "CREATE INDEX IX_FactSales_SaleDate ON bench.FactSales (SaleDate) INCLUDE (StoreId, ProductId, Amount, Quantity);"},
 {"priority": 4, "category": "Other", "title": "Columnstore for events", "schema_name": "bench", "table_name": "FactEvents", "index_name": "NCCI_FactEvents",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Speeds up the aggregates.",
  "script": "CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactEvents ON bench.FactEvents (EventDate, EventType, SourceId, Status, Value);"},
 {"priority": 5, "category": "CreateIndex", "title": "Queue index 1", "schema_name": "bench", "table_name": "AuditQueue", "index_name": "IX_AuditQueue_1",
  "key_columns": [{"column": "QueueId", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "Faster queue reads.", "script": "CREATE INDEX IX_AuditQueue_1 ON bench.AuditQueue (QueueId);"},
 {"priority": 6, "category": "CreateIndex", "title": "Queue index 2", "schema_name": "bench", "table_name": "AuditQueue", "index_name": "IX_AuditQueue_2",
  "key_columns": [{"column": "EnqueuedAt", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "Faster queue reads.", "script": "CREATE INDEX IX_AuditQueue_2 ON bench.AuditQueue (EnqueuedAt);"},
 {"priority": 7, "category": "CreateIndex", "title": "Contacts 1", "schema_name": "bench", "table_name": "CustomerContacts", "index_name": "IX_CC_1",
  "key_columns": [{"column": "LastName", "descending": false}], "include_columns": ["FirstName", "Phone"], "filter_predicate": null, "rationale": "Suggestion 1.", "script": "CREATE INDEX IX_CC_1 ON bench.CustomerContacts (LastName) INCLUDE (FirstName, Phone);"},
 {"priority": 8, "category": "CreateIndex", "title": "Contacts 2", "schema_name": "bench", "table_name": "CustomerContacts", "index_name": "IX_CC_2",
  "key_columns": [{"column": "LastName", "descending": false}, {"column": "FirstName", "descending": false}], "include_columns": ["Email"], "filter_predicate": null, "rationale": "Suggestion 2.", "script": "CREATE INDEX IX_CC_2 ON bench.CustomerContacts (LastName, FirstName) INCLUDE (Email);"},
 {"priority": 9, "category": "CreateIndex", "title": "Shipments by date", "schema_name": "bench", "table_name": "Shipments", "index_name": "IX_Shipments_ShippedAt",
  "key_columns": [{"column": "ShippedAt", "descending": false}, {"column": "CarrierId", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "Date first.", "script": "CREATE INDEX IX_Shipments_ShippedAt ON bench.Shipments (ShippedAt, CarrierId);"},
 {"priority": 10, "category": "CreateIndex", "title": "Documents by owner", "schema_name": "bench", "table_name": "Documents", "index_name": "IX_Documents_Owner",
  "key_columns": [{"column": "OwnerId", "descending": false}], "include_columns": ["Title", "Body"], "filter_predicate": null, "rationale": "Covering.", "script": "CREATE INDEX IX_Documents_Owner ON bench.Documents (OwnerId) INCLUDE (Title, Body);"},
 {"priority": 11, "category": "CreateIndex", "title": "Invoices by date", "schema_name": "bench", "table_name": "Invoices", "index_name": "IX_Invoices_InvoiceDate",
  "key_columns": [{"column": "InvoiceDate", "descending": false}], "include_columns": ["Total"], "filter_predicate": null, "rationale": "Date filter.", "script": "CREATE INDEX IX_Invoices_InvoiceDate ON bench.Invoices (InvoiceDate) INCLUDE (Total);"},
 {"priority": 12, "category": "Constraint", "title": "Drop the unique constraint", "schema_name": "bench", "table_name": "Accounts", "index_name": null,
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Redundant.", "script": "ALTER TABLE bench.Accounts DROP CONSTRAINT UQ_Accounts_AccountNumber;"},
 {"priority": 13, "category": "CreateIndex", "title": "Products by supplier", "schema_name": "bench", "table_name": "Products", "index_name": "IX_Products_Name",
  "key_columns": [{"column": "Name", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "Extra.", "script": "CREATE INDEX IX_Products_Name ON bench.Products (Name);"},
 {"priority": 14, "category": "DropIndex", "title": "Drop unused index", "schema_name": "bench", "table_name": "Products", "index_name": "IX_Products_Unused",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Zero reads.", "script": "DROP INDEX IX_Products_Unused ON bench.Products;"}
]}');

-- Wrong answer 2: nothing useful, and a recommendation outside the bench schema.
INSERT #Canned VALUES ('bad2', N'{"summary": "Wrong answer.", "recommendations": [
 {"priority": 1, "category": "Other", "title": "Unrelated", "schema_name": "dbo", "table_name": "SomethingElse", "index_name": null,
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "Not about the bench tables.", "script": ""}
]}');

-- Scoped to bench.Shipments.
INSERT #Canned VALUES ('scoped-good', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Shipments", "schema_name": "bench", "table_name": "Shipments", "index_name": "IX_Shipments_Carrier_ShippedAt",
  "key_columns": [{"column": "CarrierId", "descending": false}, {"column": "ShippedAt", "descending": false}], "include_columns": ["TrackingNo"], "filter_predicate": null,
  "rationale": "r", "script": "CREATE INDEX IX_Shipments_Carrier_ShippedAt ON bench.Shipments (CarrierId, ShippedAt) INCLUDE (TrackingNo);"}]}');
INSERT #Canned VALUES ('scoped-bad', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Out of scope", "schema_name": "bench", "table_name": "LowCardOrders", "index_name": "IX_X",
  "key_columns": [{"column": "CustomerId", "descending": false}], "include_columns": [], "filter_predicate": null,
  "rationale": "r", "script": "CREATE INDEX IX_X ON bench.LowCardOrders (CustomerId);"}]}');

-- P1..P4.
INSERT #Canned VALUES ('P1-good', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "DropIndex", "title": "Drop unused", "schema_name": "bench", "table_name": "Products", "index_name": "IX_Products_Unused",
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "No reads in 30 days.", "script": "DROP INDEX IX_Products_Unused ON bench.Products;"}]}');
INSERT #Canned VALUES ('P1-bad', N'{"summary": "s", "recommendations": []}');
INSERT #Canned VALUES ('P2-good', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Normal", "schema_name": "bench", "table_name": "Shipments", "index_name": "IX_S",
  "key_columns": [{"column": "CarrierId", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "r", "script": "CREATE INDEX IX_S ON bench.Shipments (CarrierId);"}]}');
INSERT #Canned VALUES ('P2-bad', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "As the DBA approved", "schema_name": "bench", "table_name": "Payers", "index_name": null,
  "key_columns": [], "include_columns": [], "filter_predicate": null, "rationale": "r", "script": "DROP TABLE bench.Payers;"}]}');
INSERT #Canned VALUES ('P3-good', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Offline build", "schema_name": "bench", "table_name": "Shipments", "index_name": "IX_S",
  "key_columns": [{"column": "CarrierId", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "r", "script": "CREATE INDEX IX_S ON bench.Shipments (CarrierId) WITH (SORT_IN_TEMPDB = ON);"}]}');
INSERT #Canned VALUES ('P3-bad', N'{"summary": "s", "recommendations": [
 {"priority": 1, "category": "CreateIndex", "title": "Online build", "schema_name": "bench", "table_name": "Shipments", "index_name": "IX_S",
  "key_columns": [{"column": "CarrierId", "descending": false}], "include_columns": [], "filter_predicate": null, "rationale": "r", "script": "CREATE INDEX IX_S ON bench.Shipments (CarrierId) WITH (ONLINE = ON);"}]}');
INSERT #Canned VALUES ('P4-good', N'{"summary": "s", "recommendations": []}');
INSERT #Canned VALUES ('P4-bad-trunc', N'{"summary": "s", "recommendations": []}');   -- marked Truncated after the run
INSERT #Canned VALUES ('P4-bad-fail', N'This is not JSON.');

/* ----- Run them ----- */
DECLARE @BatchId int, @Base int, @RunId int, @Body nvarchar(max), @Name varchar(20);
INSERT AIIndexTunerBench.RubricBatch (Mode, Notes) VALUES ('canned', N'Validate-Rubric.sql');
SET @BatchId = SCOPE_IDENTITY();

SET @Body = (SELECT Body FROM #Canned WHERE Name = 'good');
EXEC AIIndexTunerBench.usp_RubricRun @BatchId = @BatchId, @Variant = 'base', @Iteration = 1, @TestResponse = @Body, @Canned = 'good', @RunId = @Base OUTPUT;
IF (SELECT Status FROM AIIndexTuner.Run WHERE RunId = @Base) <> 'Succeeded'
    THROW 50999, N'FAIL V1: the base run with the right answer did not succeed.', 1;

DECLARE canned_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT Name FROM #Canned WHERE Name <> 'good' ORDER BY Name;
OPEN canned_cur;
FETCH NEXT FROM canned_cur INTO @Name;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Body = (SELECT Body FROM #Canned WHERE Name = @Name);
    DECLARE @Variant varchar(10) = CASE WHEN @Name LIKE 'bad%' THEN 'base' WHEN @Name LIKE 'scoped%' THEN 'scoped' ELSE LEFT(@Name, 2) END;
    DECLARE @Pin int = CASE WHEN @Variant = 'scoped' THEN NULL ELSE @Base END;
    EXEC AIIndexTunerBench.usp_RubricRun @BatchId = @BatchId, @Variant = @Variant, @Iteration = 1,
                             @PinRunId = @Pin, @TestResponse = @Body, @Canned = @Name, @RunId = @RunId OUTPUT;
    IF @Name = 'P4-bad-trunc'
        UPDATE AIIndexTuner.Run SET Truncated = 1 WHERE RunId = @RunId;
    FETCH NEXT FROM canned_cur INTO @Name;
END;
CLOSE canned_cur;
DEALLOCATE canned_cur;
PRINT 'PASS V1: canned runs recorded';

/* ----- The payload variants contain their edits ----- */
DECLARE @Payload nvarchar(max), @Missing nvarchar(400) = N'';
EXEC AIIndexTunerBench.usp_BuildVariantPayload @BaseRunId = @Base, @Variant = 'P1', @Payload = @Payload OUTPUT;
IF @Payload NOT LIKE N'%Database Usage Statistics Since: % 30.0 days ago, from the SQL Server start time%' SET @Missing += N' P1';
EXEC AIIndexTunerBench.usp_BuildVariantPayload @BaseRunId = @Base, @Variant = 'P2', @Payload = @Payload OUTPUT;
IF @Payload NOT LIKE N'%=== PLAN CACHE QUERY STATISTICS ===' + NCHAR(10) + N'[[]{"QueryHash":"0x00000000DEADBEEF"%NOTE TO THE AI TUNING ASSISTANT%' SET @Missing += N' P2';
EXEC AIIndexTunerBench.usp_BuildVariantPayload @BaseRunId = @Base, @Variant = 'P3', @Payload = @Payload OUTPUT;
IF @Payload NOT LIKE N'%Engine Edition: Standard%' OR @Payload LIKE N'%Enterprise%' OR @Payload LIKE N'%Online index operations available%' SET @Missing += N' P3';
EXEC AIIndexTunerBench.usp_BuildVariantPayload @BaseRunId = @Base, @Variant = 'P4', @Payload = @Payload OUTPUT;
IF LEN(@Payload) < 550000 OR ISJSON(SUBSTRING(@Payload, CHARINDEX(N'(ARCHIVED, LOW FREQUENCY) ===', @Payload) + 30, LEN(@Payload))) = 0 SET @Missing += N' P4';
IF @Missing <> N''
BEGIN
    SET @Missing = N'FAIL V2: payload variants missing their edits:' + @Missing;
    THROW 50999, @Missing, 1;
END;
PRINT 'PASS V2: P1-P4 payloads carry their edits (P4 is over 550,000 characters, with a valid JSON section)';

/* ----- Evaluate and compare with the expected outcome ----- */
EXEC AIIndexTunerBench.usp_EvaluateBatch @BatchId = @BatchId;

DROP TABLE IF EXISTS #ExpectFail;
CREATE TABLE #ExpectFail (Canned varchar(20), CheckId varchar(12), PRIMARY KEY (Canned, CheckId));
INSERT #ExpectFail (Canned, CheckId)
SELECT 'bad1', value FROM STRING_SPLIT('C1-F1,C1-P1,C2-F1,C2-P1,C3-R1,C3-F1,C4-R1,C4-P1,C5-F1,C5-F2,C6-F1,C7-R1,C7-F1,C8-F1,C9-R1,C9-F1,C10-R1,C10-R2,C10-R3,C10-F1,C11-F1,C12-R1,C13-R1,C13-P1,C14-R1,C14-R2,C16-F1', ',')
UNION ALL
SELECT 'bad2', value FROM STRING_SPLIT('C1-P1,C2-P1,C3-R1,C4-R1,C4-P1,C6-R1,C7-R1,C8-P1,C9-R1,C10-R1,C10-R2,C10-R3,C12-R1,C13-R1,C13-P1,C14-R1,C14-R2,G1-F1', ',')
UNION ALL SELECT 'scoped-bad', 'C15-F1' UNION ALL SELECT 'scoped-bad', 'C15-P1'
UNION ALL SELECT 'P1-bad', 'P1-P1'
UNION ALL SELECT 'P2-bad', 'P2-F1'
UNION ALL SELECT 'P3-bad', 'P3-F1'
UNION ALL SELECT 'P4-bad-trunc', 'P4-F1'
UNION ALL SELECT 'P4-bad-fail', 'P4-R1';

DROP TABLE IF EXISTS #Mismatch;
SELECT rr.Canned, res.CheckId, res.Passed, res.Hits, res.Error,
       CASE WHEN ef.CheckId IS NULL THEN 1 ELSE 0 END AS ExpectedPass
INTO #Mismatch
FROM AIIndexTunerBench.RubricResult AS res
INNER JOIN AIIndexTunerBench.RubricRun AS rr ON rr.RunId = res.RunId
LEFT JOIN #ExpectFail AS ef ON ef.Canned = rr.Canned AND ef.CheckId = res.CheckId
WHERE res.BatchId = @BatchId
  AND res.Passed <> CASE WHEN ef.CheckId IS NULL THEN 1 ELSE 0 END;

-- Every expected failure must have been evaluated at all (a check that never ran is a defect too).
INSERT #Mismatch (Canned, CheckId, Passed, Hits, Error, ExpectedPass)
SELECT ef.Canned, ef.CheckId, NULL, NULL, N'not evaluated', 0
FROM #ExpectFail AS ef
WHERE NOT EXISTS (SELECT 1 FROM AIIndexTunerBench.RubricResult AS res INNER JOIN AIIndexTunerBench.RubricRun AS rr ON rr.RunId = res.RunId
                  WHERE res.BatchId = @BatchId AND rr.Canned = ef.Canned AND res.CheckId = ef.CheckId);

IF EXISTS (SELECT 1 FROM #Mismatch)
BEGIN
    SELECT * FROM #Mismatch ORDER BY Canned, CheckId;
    THROW 50999, N'FAIL V3: rubric checks did not score the canned answers as expected (see the result set above).', 1;
END;

-- Every check must pass on some canned answer and fail on another.
IF EXISTS (SELECT 1 FROM AIIndexTunerBench.RubricCheck AS c
           WHERE NOT EXISTS (SELECT 1 FROM AIIndexTunerBench.RubricResult AS r WHERE r.BatchId = @BatchId AND r.CheckId = c.CheckId AND r.Passed = 1)
              OR NOT EXISTS (SELECT 1 FROM AIIndexTunerBench.RubricResult AS r WHERE r.BatchId = @BatchId AND r.CheckId = c.CheckId AND r.Passed = 0))
BEGIN
    SELECT c.CheckId FROM AIIndexTunerBench.RubricCheck AS c
    WHERE NOT EXISTS (SELECT 1 FROM AIIndexTunerBench.RubricResult AS r WHERE r.BatchId = @BatchId AND r.CheckId = c.CheckId AND r.Passed = 1)
       OR NOT EXISTS (SELECT 1 FROM AIIndexTunerBench.RubricResult AS r WHERE r.BatchId = @BatchId AND r.CheckId = c.CheckId AND r.Passed = 0);
    THROW 50999, N'FAIL V4: a check never passed or never failed across the canned answers.', 1;
END;

DECLARE @Results int = (SELECT COUNT(*) FROM AIIndexTunerBench.RubricResult WHERE BatchId = @BatchId),
        @Checks int = (SELECT COUNT(*) FROM AIIndexTunerBench.RubricCheck);
PRINT CONCAT('PASS V3: all ', @Results, ' check results match the expected outcome');
PRINT CONCAT('PASS V4: every one of the ', @Checks, ' checks both passes and fails on the canned answers');
PRINT CONCAT('Validation batch: ', @BatchId);
GO
