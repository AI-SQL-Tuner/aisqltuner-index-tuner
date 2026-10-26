/*
    Runs the test workload against the test database (default AIIndexTunerTest). Rerun it after a restart or a plan cache flush,
    since the collectors read the plan cache and the missing-index DMVs.

    sqlcmd -S localhost -E -C -f 65001 -d AIIndexTunerTest -i tests\02_Run-Workload.sql
*/
SET NOCOUNT ON;

-- A forced plan that fails: force a plan that uses an index, then drop the index, so the next
-- compile cannot use the forced plan (NO_INDEX). This runs before the workload below because
-- dropping an index on dbo.Orders clears its missing-index statistics.
--
-- The probe needs a join: a single-table query gets a TRIVIAL, auto-parameterized plan, and a
-- forced trivial plan whose index is gone is silently replaced without counting a failure.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Orders_Status_Probe' AND object_id = OBJECT_ID(N'dbo.Orders'))
    DROP INDEX IX_Orders_Status_Probe ON dbo.Orders;
CREATE INDEX IX_Orders_Status_Probe ON dbo.Orders (Status) INCLUDE (CustomerId, TotalDue);
GO
SELECT c.Region, SUM(o.TotalDue) AS t /* forced_plan_probe */
FROM dbo.Orders AS o INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
WHERE o.Status = 3 GROUP BY c.Region;
GO
DECLARE @q bigint, @p bigint;
SELECT TOP (1) @q = q.query_id, @p = p.plan_id
FROM sys.query_store_query_text AS qt
INNER JOIN sys.query_store_query AS q ON q.query_text_id = qt.query_text_id
INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
WHERE qt.query_sql_text LIKE N'%forced_plan_probe%' AND qt.query_sql_text NOT LIKE N'%query_store%'
  AND CAST(p.query_plan AS nvarchar(max)) LIKE N'%IX_Orders_Status_Probe%'
ORDER BY p.plan_id DESC;
IF @q IS NULL
    THROW 50998, N'The forced-plan probe did not produce a Query Store plan that uses IX_Orders_Status_Probe.', 1;
EXEC sys.sp_query_store_force_plan @query_id = @q, @plan_id = @p;
GO
DROP INDEX IX_Orders_Status_Probe ON dbo.Orders;
GO
SELECT c.Region, SUM(o.TotalDue) AS t /* forced_plan_probe */
FROM dbo.Orders AS o INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
WHERE o.Status = 3 GROUP BY c.Region;
GO

-- An ad hoc write that simple parameterization rewrites with a parameter-declaration prefix,
-- (@1 tinyint,@2 tinyint)UPDATE [dbo].[Orders] set [Status] = @1 WHERE [OrderId]=@2, so the
-- write mix must read past the prefix to count it as an UPDATE.
UPDATE dbo.Orders SET Status = 4 WHERE OrderId = 5;
GO 3

-- Workload: selective lookups with no supporting index, repeated so the impact score passes 100,000.
-- The joins matter: a single-table aggregate gets a TRIVIAL plan, and trivial plans record no
-- missing-index suggestions.
DECLARE @i int = 0, @c int, @t decimal(18, 2), @n nvarchar(100);
WHILE @i < 1000
BEGIN
    SELECT @n = MAX(c.CustomerName), @t = SUM(o.TotalDue)
    FROM dbo.Orders AS o INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
    WHERE o.CustomerId = 1 + (@i * 37) % 20000;

    SELECT @c = COUNT(*)
    FROM dbo.Orders AS o INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
    WHERE o.OrderDate = DATEADD(DAY, -(@i % 1500), '2026-10-01') AND o.Status = 2 AND c.Region = 'AB';

    SET @i += 1;
END;
GO

-- A query that returns Notes, an nvarchar(200) column: 400 bytes is wide, so its missing-index
-- suggestion makes the collector sample Notes' width with dynamic SQL, which T13 checks it leaves out.
DECLARE @i int = 0, @notes nvarchar(200), @cust int;
WHILE @i < 50
BEGIN
    SELECT @notes = MAX(o.Notes), @cust = MAX(c.CustomerId)
    FROM dbo.Orders AS o INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
    WHERE o.Status = 1 AND o.OrderDate > DATEADD(DAY, -(@i % 30) - 7, '2026-10-01') AND o.OrderDate <= DATEADD(DAY, -(@i % 30), '2026-10-01');

    SET @i += 1;
END;
GO

SELECT OBJECT_NAME(d.object_id) AS TableName, d.equality_columns, d.inequality_columns, d.included_columns,
       CAST(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans) AS bigint) AS ImpactScore
FROM sys.dm_db_missing_index_details AS d
INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
INNER JOIN sys.dm_db_missing_index_group_stats AS s ON g.index_group_handle = s.group_handle
WHERE d.database_id = DB_ID();
GO
