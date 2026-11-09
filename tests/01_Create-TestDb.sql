/*
    Creates the test database (default AIIndexTunerTest): a small database with the problems the collectors look for.

        - dbo.Orders (300,000 rows) queried by CustomerId and OrderDate with no index to support it,
          so the missing-index DMVs fill up
        - an exact duplicate nonclustered index on dbo.Customers
        - an untrusted foreign key
        - a 20,000-row heap

    TestCollation sets the database's collation:
        Different  a collation other than the instance's (the default in Run-All.ps1), so the tests
                   catch comparisons between instance-collated DMV columns and database-collated
                   catalog columns, which fail with error 468 (issue #42)
        Instance   the instance's collation
        any other  that collation, for example Turkish_100_CI_AS

    sqlcmd -S localhost -E -C -f 65001 -v TestDb=AIIndexTunerTest TestCollation=Different -i tests\01_Create-TestDb.sql
*/
SET NOCOUNT ON;
USE master;
GO
IF DB_ID(N'$(TestDb)') IS NOT NULL
BEGIN
    ALTER DATABASE $(TestDb) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE $(TestDb);
END;
GO
DECLARE @Collation sysname = N'$(TestCollation)',
        @Instance sysname = CAST(SERVERPROPERTY('Collation') AS sysname);
IF @Collation = N'Different'
    SET @Collation = CASE WHEN @Instance = N'Latin1_General_100_CI_AI' THEN N'SQL_Latin1_General_CP1_CI_AS' ELSE N'Latin1_General_100_CI_AI' END;
ELSE IF @Collation = N'Instance'
    SET @Collation = @Instance;
IF NOT EXISTS (SELECT 1 FROM sys.fn_helpcollations() WHERE name = @Collation)
BEGIN
    DECLARE @Msg nvarchar(400) = N'Unknown collation: ' + @Collation;
    THROW 50999, @Msg, 1;
END;
DECLARE @Create nvarchar(max) = N'CREATE DATABASE $(TestDb) COLLATE ' + @Collation + N';';
EXEC (@Create);
PRINT N'Created $(TestDb) with collation ' + @Collation + N' (instance: ' + @Instance + N').';
GO
ALTER DATABASE $(TestDb) SET RECOVERY SIMPLE;
-- Capture every query, so the Query Store sections see the setup writes and the small workload.
ALTER DATABASE $(TestDb) SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL);
GO
USE $(TestDb);
GO

CREATE TABLE dbo.Customers
(
    CustomerId   int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Customers PRIMARY KEY,
    CustomerName nvarchar(100) NOT NULL,
    Region       char(2) NOT NULL,
    Email        nvarchar(200) NULL
);

CREATE TABLE dbo.Orders
(
    OrderId    int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY,
    CustomerId int NOT NULL,
    OrderDate  date NOT NULL,
    Status     tinyint NOT NULL,
    TotalDue   decimal(12, 2) NOT NULL,
    Notes      nvarchar(200) NULL
);

CREATE TABLE dbo.AuditLog   -- a heap
(
    LoggedAt  datetime2(0) NOT NULL,
    EventType varchar(20) NOT NULL,
    Detail    nvarchar(400) NULL
);
GO

INSERT dbo.Customers (CustomerName, Region, Email)
SELECT TOP (20000) CONCAT(N'Customer ', n), CHAR(65 + n % 5) + CHAR(65 + n % 3), CONCAT(N'c', n, N'@example.com')
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b) AS x;

INSERT dbo.Orders (CustomerId, OrderDate, Status, TotalDue, Notes)
SELECT TOP (300000) 1 + n % 20000, DATEADD(DAY, -(n % 1500), '2026-10-01'), n % 5, (n % 1000) + 0.99,
       CASE WHEN n % 10 = 0 THEN N'Gift wrap' END
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b) AS x;

-- Lowercase on purpose: T11b checks that the Query Store write mix counts it as an INSERT. Under
-- a Turkish collation, upper-casing "insert" with the database's collation gives "İNSERT".
insert dbo.AuditLog (LoggedAt, EventType, Detail)
SELECT TOP (20000) DATEADD(MINUTE, -n, '2026-10-01'), CASE n % 3 WHEN 0 THEN 'LOGIN' WHEN 1 THEN 'ORDER' ELSE 'EXPORT' END, CONCAT(N'Event ', n)
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b) AS x;
GO

-- Exact duplicate indexes.
CREATE INDEX IX_Customers_Region ON dbo.Customers (Region);
CREATE INDEX IX_Customers_Region_Dup ON dbo.Customers (Region);

-- Untrusted foreign key.
ALTER TABLE dbo.Orders WITH NOCHECK ADD CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerId) REFERENCES dbo.Customers (CustomerId);
GO

-- The workload is in 02_Run-Workload.sql.
