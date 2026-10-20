/*
    Runs the test workload against AIIndexTunerTest. Rerun it after a restart or a plan cache flush,
    since the collectors read the plan cache and the missing-index DMVs.

    sqlcmd -S localhost -E -C -f 65001 -d AIIndexTunerTest -i tests\02_Run-Workload.sql
*/
SET NOCOUNT ON;
USE AIIndexTunerTest;
GO

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

SELECT OBJECT_NAME(d.object_id) AS TableName, d.equality_columns, d.inequality_columns, d.included_columns,
       CAST(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans) AS bigint) AS ImpactScore
FROM sys.dm_db_missing_index_details AS d
INNER JOIN sys.dm_db_missing_index_groups AS g ON d.index_handle = g.index_handle
INNER JOIN sys.dm_db_missing_index_group_stats AS s ON g.index_group_handle = s.group_handle
WHERE d.database_id = DB_ID();
GO
