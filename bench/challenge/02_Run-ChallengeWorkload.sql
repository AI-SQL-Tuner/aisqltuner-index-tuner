/*
    Runs the challenge workload against the [bench] tables in the current database.

    Every query goes through sp_executesql with parameters, so Query Store and the plan cache see
    one parameterized statement per query with many executions, as an application would send it.
    Every read joins a lookup table: single-table queries get TRIVIAL plans, and trivial plans
    record no missing-index suggestions and no forced-plan failures.

    Run after 01_Create-ChallengeTables.sql and after installing aisqltuner-index-tuner.sql. Rerunning
    is safe; usage counters and Query Store simply accumulate.
*/
SET NOCOUNT ON;
GO

DECLARE @Scale float, @Reps int;
SELECT @Scale = Scale, @Reps = Reps FROM AIIndexTunerBench.ChallengeSettings WHERE Id = 1;
SET @Reps = ISNULL(@Reps, CASE WHEN 200 / @Scale > 2000 THEN 2000 ELSE CEILING(200 / @Scale) END);
DECLARE @FactReps int = CASE WHEN @Reps / 10 < 5 THEN 5 ELSE @Reps / 10 END;
DECLARE @N2M int = CEILING(2000000 * @Scale), @N1M int = CEILING(1000000 * @Scale), @N200K int = CEILING(200000 * @Scale);
PRINT CONCAT('Workload: Reps = ', @Reps, ', FactReps = ', @FactReps);

-- EXEC takes only constants and variables as parameter values, so each loop sets these first.
DECLARE @i int, @n1 int, @n2 int, @b1 bigint, @t1 tinyint, @sm smallint, @s1 nvarchar(100), @s2 nvarchar(100),
        @v1 varchar(20), @d1 date, @d2 date, @dt1 datetime2(0), @dt2 datetime2(0), @m1 decimal(10, 2), @m2 decimal(10, 2);

/* ----- C1: Status (low cardinality) with CustomerId, and CustomerId alone ----- */
DECLARE @c1a nvarchar(max) = N'SELECT o.OrderId, o.OrderDate, o.Amount, s.Name FROM bench.LowCardOrders AS o INNER JOIN bench.StatusCodes AS s ON s.Status = o.Status WHERE o.Status = @s AND o.CustomerId = @c;',
        @c1b nvarchar(max) = N'SELECT o.OrderId, o.Status, o.Amount, s.Name FROM bench.LowCardOrders AS o INNER JOIN bench.StatusCodes AS s ON s.Status = o.Status WHERE o.CustomerId = @c;';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SELECT @t1 = @i % 5, @n1 = 1 + (@i * 37) % 200000, @n2 = 1 + (@i * 53) % 200000;
    EXEC sys.sp_executesql @c1a, N'@s tinyint, @c int', @s = @t1, @c = @n1;
    EXEC sys.sp_executesql @c1b, N'@c int', @c = @n2;
    SET @i += 1;
END;

/* ----- C2: the rare Open state, as a literal (a filtered index needs the literal), plus state changes ----- */
DECLARE @c2 nvarchar(max) = N'SELECT t.TicketId, t.Subject, t.OpenedAt, r.Name FROM bench.SkewTickets AS t INNER JOIN bench.Ref AS r ON r.RefId = t.QueueId WHERE t.State = ''Open'' ORDER BY t.OpenedAt DESC;',
        @c2close nvarchar(max) = N'UPDATE bench.SkewTickets SET State = ''Closed'' WHERE TicketId = @id;',
        @c2open nvarchar(max) = N'UPDATE bench.SkewTickets SET State = ''Open'' WHERE TicketId = @id;';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    EXEC sys.sp_executesql @c2;
    -- Close one open ticket and open one closed ticket, so the Open share stays about 0.5%.
    SELECT @n1 = 200 * (1 + @i % (@N2M / 200)), @n2 = 200 * (1 + @i % (@N2M / 200)) + 1;
    EXEC sys.sp_executesql @c2close, N'@id int', @id = @n1;
    EXEC sys.sp_executesql @c2open, N'@id int', @id = @n2;
    SET @i += 1;
END;

/* ----- C3: analytic aggregates over most of FactSales ----- */
DECLARE @c3a nvarchar(max) = N'SELECT r.Name, SUM(f.Amount) AS Revenue, COUNT_BIG(*) AS Sales FROM bench.FactSales AS f INNER JOIN bench.Ref AS r ON r.RefId = f.StoreId WHERE f.SaleDate >= @from GROUP BY r.Name ORDER BY Revenue DESC;',
        @c3b nvarchar(max) = N'SELECT TOP (50) f.ProductId, SUM(f.Quantity) AS Units, SUM(f.Amount - f.Discount) AS Net FROM bench.FactSales AS f INNER JOIN bench.Ref AS r ON r.RefId = f.StoreId WHERE f.SaleDate >= @from AND f.SaleDate < @to GROUP BY f.ProductId ORDER BY Net DESC;';
SELECT @d1 = '2024-01-01', @d2 = '2025-01-01';
SET @i = 0;
WHILE @i < @FactReps
BEGIN
    EXEC sys.sp_executesql @c3a, N'@from date', @from = @d1;
    EXEC sys.sp_executesql @c3b, N'@from date, @to date', @from = @d2, @to = '2026-01-01';
    SET @i += 1;
END;

/* ----- C4: aggregates over FactEvents, plus single-row updates and inserts ----- */
DECLARE @c4a nvarchar(max) = N'SELECT f.EventType, f.Status, COUNT_BIG(*) AS Events, AVG(f.Value) AS AvgValue FROM bench.FactEvents AS f INNER JOIN bench.Ref AS r ON r.RefId = f.EventType WHERE f.EventDate >= @from GROUP BY f.EventType, f.Status;',
        @c4b nvarchar(max) = N'SELECT TOP (100) f.SourceId, r.Name, SUM(f.Value) AS Total FROM bench.FactEvents AS f INNER JOIN bench.Ref AS r ON r.RefId = f.SourceId GROUP BY f.SourceId, r.Name ORDER BY Total DESC;',
        @c4u nvarchar(max) = N'UPDATE bench.FactEvents SET Status = (Status + 1) % 3, Value = Value + 1 WHERE EventId = @id;',
        @c4i nvarchar(max) = N'INSERT bench.FactEvents (EventId, EventDate, EventType, SourceId, Status, Value) VALUES (@id, ''2026-10-01'', @t, @s, 0, 1.0);';
DECLARE @NextEvent bigint = (SELECT MAX(EventId) FROM bench.FactEvents) + 1;
SET @d1 = '2026-07-01';
SET @i = 0;
WHILE @i < @FactReps
BEGIN
    EXEC sys.sp_executesql @c4a, N'@from date', @from = @d1;
    EXEC sys.sp_executesql @c4b;
    SET @i += 1;
END;
SET @i = 0;
WHILE @i < @Reps * 10
BEGIN
    SET @b1 = 1 + (@i * 97) % 50000;   -- the same hot rows, as recent rows are in practice
    EXEC sys.sp_executesql @c4u, N'@id bigint', @id = @b1;
    IF @i % 2 = 0
    BEGIN
        SELECT @sm = 1 + @i % 40, @n1 = 1 + @i % 20000;
        EXEC sys.sp_executesql @c4i, N'@id bigint, @t smallint, @s int', @id = @NextEvent, @t = @sm, @s = @n1;
        SET @NextEvent += 1;
    END;
    SET @i += 1;
END;

/* ----- C5: a write-heavy queue: insert, process and delete continuously, with occasional reads ----- */
DECLARE @c5ins nvarchar(max) = N'INSERT bench.AuditQueue (QueueId, EnqueuedAt, Payload) VALUES (@q, SYSDATETIME(), @p);',
        @c5upd nvarchar(max) = N'UPDATE bench.AuditQueue SET ProcessedAt = SYSDATETIME() WHERE QueueItemId = @id;',
        @c5del nvarchar(max) = N'DELETE FROM bench.AuditQueue WHERE QueueItemId = @id;',
        @c5sel nvarchar(max) = N'SELECT TOP (50) q.QueueItemId, q.EnqueuedAt, r.Name FROM bench.AuditQueue AS q INNER JOIN bench.Ref AS r ON r.RefId = q.QueueId WHERE q.QueueId = @q AND q.ProcessedAt IS NULL ORDER BY q.EnqueuedAt;';
DECLARE @FirstQueueItem bigint = (SELECT MIN(QueueItemId) FROM bench.AuditQueue), @b2 bigint;
SET @s1 = N'event';
SET @i = 0;
WHILE @i < @Reps * 10
BEGIN
    SELECT @n1 = 1 + @i % 20, @b1 = @FirstQueueItem + @i * 2 + 1, @b2 = @FirstQueueItem + @i * 2;
    EXEC sys.sp_executesql @c5ins, N'@q int, @p nvarchar(400)', @q = @n1, @p = @s1;
    EXEC sys.sp_executesql @c5upd, N'@id bigint', @id = @b1;
    EXEC sys.sp_executesql @c5del, N'@id bigint', @id = @b2;
    IF @i % 25 = 0
        EXEC sys.sp_executesql @c5sel, N'@q int', @q = @n1;
    SET @i += 1;
END;

/* ----- C6: three queries on LastName that give three overlapping suggestions ----- */
DECLARE @c6a nvarchar(max) = N'SELECT c.FirstName, c.Phone, r.Name FROM bench.CustomerContacts AS c INNER JOIN bench.Ref AS r ON r.RefId = c.CityId WHERE c.LastName = @l;',
        @c6b nvarchar(max) = N'SELECT c.Email, r.Name FROM bench.CustomerContacts AS c INNER JOIN bench.Ref AS r ON r.RefId = c.CityId WHERE c.LastName = @l AND c.FirstName = @f;',
        @c6c nvarchar(max) = N'SELECT c.Phone, r.Name FROM bench.CustomerContacts AS c INNER JOIN bench.Ref AS r ON r.RefId = c.CityId WHERE c.LastName = @l AND c.CityId = @city;';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SELECT @s1 = CONCAT(N'Last', (@i * 131) % 50000), @s2 = CONCAT(N'First', @i % 400);
    EXEC sys.sp_executesql @c6a, N'@l nvarchar(40)', @l = @s1;
    SET @s1 = CONCAT(N'Last', (@i * 137) % 50000);
    EXEC sys.sp_executesql @c6b, N'@l nvarchar(40), @f nvarchar(40)', @l = @s1, @f = @s2;
    SELECT @s1 = CONCAT(N'Last', (@i * 139) % 50000), @n1 = 1 + @i % 3000;
    EXEC sys.sp_executesql @c6c, N'@l nvarchar(40), @city int', @l = @s1, @city = @n1;
    SET @i += 1;
END;

/* ----- C7: equality on CarrierId, range on ShippedAt, ORDER BY ShippedAt ----- */
DECLARE @c7 nvarchar(max) = N'SELECT s.ShipmentId, s.ShippedAt, s.TrackingNo, r.Name FROM bench.Shipments AS s INNER JOIN bench.Ref AS r ON r.RefId = s.CarrierId WHERE s.CarrierId = @c AND s.ShippedAt >= @from AND s.ShippedAt < @to ORDER BY s.ShippedAt;';
SET @dt2 = '2026-10-01';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SELECT @n1 = 1 + @i % 50, @dt1 = DATEADD(DAY, -(@i % 60) - 7, '2026-10-01');
    EXEC sys.sp_executesql @c7, N'@c int, @from datetime2(0), @to datetime2(0)', @c = @n1, @from = @dt1, @to = @dt2;
    SET @i += 1;
END;

/* ----- C8: a query that returns the nvarchar(max) Body ----- */
DECLARE @c8 nvarchar(max) = N'SELECT d.DocId, d.Title, d.Body, r.Name FROM bench.Documents AS d INNER JOIN bench.Ref AS r ON r.RefId = d.OwnerId WHERE d.OwnerId = @o;';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SET @n1 = 1 + (@i * 71) % 20000;
    EXEC sys.sp_executesql @c8, N'@o int', @o = @n1;
    SET @i += 1;
END;

/* ----- C9: non-SARGable predicates on InvoiceDate and CreatedAt ----- */
DECLARE @c9a nvarchar(max) = N'SELECT r.Name, SUM(i.Total) AS Billed FROM bench.Invoices AS i INNER JOIN bench.Ref AS r ON r.RefId = i.CustomerId WHERE YEAR(i.InvoiceDate) = @y AND MONTH(i.InvoiceDate) = @m GROUP BY r.Name;',
        @c9b nvarchar(max) = N'SELECT i.InvoiceId, i.Total, r.Name FROM bench.Invoices AS i INNER JOIN bench.Ref AS r ON r.RefId = i.CustomerId WHERE DATEDIFF(DAY, i.CreatedAt, @d) = 0;';
SET @i = 0;
WHILE @i < @Reps / 4 + 1
BEGIN
    SELECT @n1 = 2023 + @i % 3, @n2 = 1 + @i % 12, @d1 = DATEADD(DAY, -(@i % 30), '2026-09-30');
    EXEC sys.sp_executesql @c9a, N'@y int, @m int', @y = @n1, @m = @n2;
    EXEC sys.sp_executesql @c9b, N'@d date', @d = @d1;
    SET @i += 1;
END;

/* ----- C10: reads that use the Region, Email and AccountNumber indexes ----- */
DECLARE @c10a nvarchar(max) = N'SELECT a.AccountId, a.AccountNumber, r.Name FROM bench.Accounts AS a INNER JOIN bench.Ref AS r ON r.RefId = a.AccountTypeId WHERE a.Region = @r;',
        @c10b nvarchar(max) = N'SELECT a.AccountId, a.Region, r.Name FROM bench.Accounts AS a INNER JOIN bench.Ref AS r ON r.RefId = a.AccountTypeId WHERE a.Email = @e AND a.Status = @s;',
        @c10c nvarchar(max) = N'SELECT a.AccountId, a.Email, r.Name FROM bench.Accounts AS a INNER JOIN bench.Ref AS r ON r.RefId = a.AccountTypeId WHERE a.AccountNumber = @n;',
        @c10d nvarchar(max) = N'SELECT a.AccountId, a.Status, r.Name FROM bench.Accounts AS a INNER JOIN bench.Ref AS r ON r.RefId = a.AccountTypeId WHERE a.Email = @e;';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SELECT @n1 = 1 + (@i * 997) % @N1M;
    SELECT @v1 = CHAR(65 + @i % 26) + CHAR(65 + (@i / 26) % 26),
           @s1 = CONCAT(N'a', @n1, N'@example.com'),
           @t1 = @n1 % 4,
           @s2 = CONCAT(N'a', @n1 + 1, N'@example.com');
    EXEC sys.sp_executesql @c10a, N'@r char(2)', @r = @v1;
    EXEC sys.sp_executesql @c10b, N'@e nvarchar(100), @s tinyint', @e = @s1, @s = @t1;
    SET @v1 = CONCAT('AC', RIGHT(CONCAT('0000000000', @n1), 10));
    EXEC sys.sp_executesql @c10c, N'@n varchar(20)', @n = @v1;
    EXEC sys.sp_executesql @c10d, N'@e nvarchar(100)', @e = @s2;
    SET @i += 1;
END;

/* ----- C11: a workload the existing indexes already cover ----- */
DECLARE @c11a nvarchar(max) = N'SELECT p.ProductId, p.Name, p.Price, r.Name AS Category FROM bench.Products AS p INNER JOIN bench.Ref AS r ON r.RefId = p.CategoryId WHERE p.CategoryId = @c AND p.Price BETWEEN @lo AND @hi;',
        @c11b nvarchar(max) = N'SELECT p.Name, p.Price, r.Name AS Category FROM bench.Products AS p INNER JOIN bench.Ref AS r ON r.RefId = p.CategoryId WHERE p.ProductId = @id;';
SELECT @m1 = 10, @m2 = 200;
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SELECT @n1 = 1 + @i % 400, @n2 = 1 + (@i * 389) % @N200K;
    EXEC sys.sp_executesql @c11a, N'@c int, @lo decimal(10,2), @hi decimal(10,2)', @c = @n1, @lo = @m1, @hi = @m2;
    EXEC sys.sp_executesql @c11b, N'@id int', @id = @n2;
    SET @i += 1;
END;

/* ----- C12: widen a third of the heap's rows (once), then read by batch ----- */
DECLARE @c12u nvarchar(max) = N'UPDATE bench.StagingRows SET Payload = REPLICATE(''y'', 1500) WHERE BatchId = @b;',
        @c12s nvarchar(max) = N'SELECT s.RowNo, s.Payload, r.Name FROM bench.StagingRows AS s INNER JOIN bench.Ref AS r ON r.RefId = s.BatchId WHERE s.BatchId = @b;';
IF NOT EXISTS (SELECT 1 FROM bench.StagingRows WHERE LEN(Payload) > 100)
BEGIN
    SET @i = 1;
    WHILE @i <= 100
    BEGIN
        SET @n1 = @i * 3;
        EXEC sys.sp_executesql @c12u, N'@b int', @b = @n1;
        SET @i += 1;
    END;
END;
SET @i = 0;
WHILE @i < @Reps / 2 + 1
BEGIN
    SET @n1 = 1 + @i % 300;
    EXEC sys.sp_executesql @c12s, N'@b int', @b = @n1;
    SET @i += 1;
END;

/* ----- C13: a join the optimizer could eliminate if FK_Payments_Payers were trusted ----- */
DECLARE @c13 nvarchar(max) = N'SELECT p.PaymentId, p.Amount FROM bench.Payments AS p INNER JOIN bench.Payers AS y ON y.PayerId = p.PayerId WHERE p.PaidOn = @d;';
SET @i = 0;
WHILE @i < @Reps
BEGIN
    SET @d1 = DATEADD(DAY, -(@i % 1000), '2026-10-01');
    EXEC sys.sp_executesql @c13, N'@d date', @d = @d1;
    SET @i += 1;
END;
GO

/* ----- C14: a forced plan that fails with NO_INDEX -----
   Force a plan that uses an index, then drop the index. The probe joins a lookup table: a forced
   TRIVIAL plan whose index is gone is replaced without counting a failure. Plans forced by an
   earlier run of this script are unforced first, so reruns start clean. */
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

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Readings_Kind_Probe' AND object_id = OBJECT_ID(N'bench.Readings'))
    DROP INDEX IX_Readings_Kind_Probe ON bench.Readings;
CREATE INDEX IX_Readings_Kind_Probe ON bench.Readings (Kind) INCLUDE (SensorId, Value);
GO
SELECT r.Name, SUM(x.Value) AS Total /* forced_plan_probe */
FROM bench.Readings AS x INNER JOIN bench.Ref AS r ON r.RefId = x.SensorId
WHERE x.Kind = 3 GROUP BY r.Name;
GO
DECLARE @q bigint, @p bigint;
SELECT TOP (1) @q = q.query_id, @p = p.plan_id
FROM sys.query_store_query_text AS qt
INNER JOIN sys.query_store_query AS q ON q.query_text_id = qt.query_text_id
INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
WHERE qt.query_sql_text LIKE N'%forced_plan_probe%' AND qt.query_sql_text NOT LIKE N'%query_store%'
  AND CAST(p.query_plan AS nvarchar(max)) LIKE N'%IX_Readings_Kind_Probe%'
ORDER BY p.plan_id DESC;
IF @q IS NULL
    THROW 50990, N'The forced-plan probe did not produce a Query Store plan that uses IX_Readings_Kind_Probe.', 1;
EXEC sys.sp_query_store_force_plan @query_id = @q, @plan_id = @p;
GO
DROP INDEX IX_Readings_Kind_Probe ON bench.Readings;
GO
SELECT r.Name, SUM(x.Value) AS Total /* forced_plan_probe */
FROM bench.Readings AS x INNER JOIN bench.Ref AS r ON r.RefId = x.SensorId
WHERE x.Kind = 3 GROUP BY r.Name;
GO
PRINT 'Workload complete.';
GO
