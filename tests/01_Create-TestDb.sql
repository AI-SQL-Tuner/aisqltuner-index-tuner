/*
    Creates the test database (default AIIndexTunerTest): a small database with the problems the collectors look for.

        - dbo.Orders (300,000 rows) queried by CustomerId and OrderDate with no index to support it,
          so the missing-index DMVs fill up
        - an exact duplicate nonclustered index on dbo.Customers
        - an untrusted foreign key
        - a 20,000-row heap

    sqlcmd -S localhost -E -C -f 65001 -v TestDb=AIIndexTunerTest -i tests\01_Create-TestDb.sql
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
CREATE DATABASE $(TestDb);
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

INSERT dbo.AuditLog (LoggedAt, EventType, Detail)
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
