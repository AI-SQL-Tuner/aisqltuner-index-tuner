/*
    Builds the challenge tables in schema [bench] of the current database. Run it in
    IndexTunerChallenge on SQL Server, or in the Dev EMS database on Azure SQL Database. Rerunnable:
    it drops and rebuilds the challenge tables, and leaves the rubric objects alone.

    Data is deterministic: every value comes from the row number, so every build is identical.
    Row counts scale with AIIndexTunerBench.ChallengeSettings.Scale (default 1). The two fact tables never go
    below 1,200,000 rows, because the large-table cases need more than 1,000,000.

    Case     Tables                       What it sets up (see bench/CASES.md)
    C1       LowCardOrders, StatusCodes   low-cardinality Status declared before the selective CustomerId
    C2       SkewTickets                  State is 99.5% Closed, 0.5% Open
    C3       FactSales                    10M-row fact table, analytic aggregates
    C4       FactEvents                   5M-row fact table, aggregates plus single-row updates
    C5       AuditQueue                   write-heavy queue
    C6       CustomerContacts             three queries that give overlapping missing-index suggestions
    C7       Shipments                    equality + range + ORDER BY
    C8       Documents                    nvarchar(max) column that missing-index suggestions include
    C9       Invoices                     non-SARGable predicates
    C10      Accounts                     exact duplicate, left-prefix overlap, index duplicating a UNIQUE constraint
    C11/C16  Products                     fully covered workload; one never-read index
    C12      StagingRows                  heap that gets forwarded records
    C13      Payments, Payers             untrusted foreign key blocking join elimination
    C14      Readings                     forced plan that fails (set up by the workload script)
    (all)    Ref                          small lookup table: joins keep plans out of TRIVIAL optimization,
                                          which records no missing-index suggestions
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF SCHEMA_ID(N'bench') IS NULL EXEC (N'CREATE SCHEMA bench AUTHORIZATION dbo;');
-- The settings live with the rubric objects, in a schema the collector skips (AIIndexTuner*).
IF SCHEMA_ID(N'AIIndexTunerBench') IS NULL EXEC (N'CREATE SCHEMA AIIndexTunerBench AUTHORIZATION dbo;');
GO
-- Scale: row counts (1 = full size). Reps: workload repetitions per query; NULL = 200 / Scale, at most 2,000,
-- which keeps missing-index impact scores above the collector's 100,000 threshold at any scale.
IF OBJECT_ID(N'AIIndexTunerBench.ChallengeSettings', N'U') IS NULL
    CREATE TABLE AIIndexTunerBench.ChallengeSettings (Id tinyint NOT NULL PRIMARY KEY CHECK (Id = 1),
                                          Scale float NOT NULL CHECK (Scale > 0 AND Scale <= 1),
                                          Reps int NULL CHECK (Reps > 0));
IF NOT EXISTS (SELECT 1 FROM AIIndexTunerBench.ChallengeSettings)
    INSERT AIIndexTunerBench.ChallengeSettings (Id, Scale) VALUES (1, 1);
GO

/* Drop the challenge tables (child tables first). */
DROP TABLE IF EXISTS bench.Payments, bench.Payers, bench.LowCardOrders, bench.StatusCodes, bench.SkewTickets,
    bench.FactSales, bench.FactEvents, bench.AuditQueue, bench.CustomerContacts, bench.Shipments, bench.Documents,
    bench.Invoices, bench.Accounts, bench.Products, bench.StagingRows, bench.Readings, bench.Ref;
GO

DECLARE @Scale float = (SELECT Scale FROM AIIndexTunerBench.ChallengeSettings WHERE Id = 1);
DECLARE @N2M int = CEILING(2000000 * @Scale), @N1M int = CEILING(1000000 * @Scale),
        @N10M int = CASE WHEN 10000000 * @Scale < 1200000 THEN 1200000 ELSE CEILING(10000000 * @Scale) END,
        @N5M int = CASE WHEN 5000000 * @Scale < 1200000 THEN 1200000 ELSE CEILING(5000000 * @Scale) END,
        @N300K int = CEILING(300000 * @Scale), @N200K int = CEILING(200000 * @Scale), @N100K int = CEILING(100000 * @Scale),
        @N50K int = CEILING(50000 * @Scale);

/* ----- Ref: small lookup, 50,000 rows ----- */
CREATE TABLE bench.Ref (RefId int NOT NULL CONSTRAINT PK_Ref PRIMARY KEY, Name nvarchar(40) NOT NULL);
INSERT bench.Ref (RefId, Name) SELECT value, CONCAT(N'Ref ', value) FROM GENERATE_SERIES(1, 50000);

/* ----- C1: low-cardinality Status, declared before the selective CustomerId, so missing-index
   suggestions list it first ----- */
CREATE TABLE bench.StatusCodes (Status tinyint NOT NULL CONSTRAINT PK_StatusCodes PRIMARY KEY, Name nvarchar(20) NOT NULL);
INSERT bench.StatusCodes VALUES (0, N'New'), (1, N'Paid'), (2, N'Packed'), (3, N'Shipped'), (4, N'Delivered');

CREATE TABLE bench.LowCardOrders
(
    OrderId    int           NOT NULL CONSTRAINT PK_LowCardOrders PRIMARY KEY,
    Status     tinyint       NOT NULL,
    CustomerId int           NOT NULL,
    OrderDate  date          NOT NULL,
    Amount     decimal(12,2) NOT NULL,
    Notes      nvarchar(100) NULL
);
INSERT bench.LowCardOrders (OrderId, Status, CustomerId, OrderDate, Amount, Notes)
SELECT value, value % 5, 1 + (CAST(value AS bigint) * 7919) % 200000, DATEADD(DAY, -(value % 1500), '2026-10-01'),
       (value % 997) + 0.5, CASE WHEN value % 7 = 0 THEN N'Gift' END
FROM GENERATE_SERIES(1, @N2M);

/* ----- C2: skewed State. 0.5% Open, the rest Closed ----- */
CREATE TABLE bench.SkewTickets
(
    TicketId int           NOT NULL CONSTRAINT PK_SkewTickets PRIMARY KEY,
    QueueId  int           NOT NULL,
    State    varchar(10)   NOT NULL,
    OpenedAt datetime2(0)  NOT NULL,
    Subject  nvarchar(120) NOT NULL
);
INSERT bench.SkewTickets (TicketId, QueueId, State, OpenedAt, Subject)
SELECT value, 1 + value % 200, CASE WHEN value % 200 = 0 THEN 'Open' ELSE 'Closed' END,
       DATEADD(MINUTE, -value, '2026-10-01'), CONCAT(N'Ticket ', value)
FROM GENERATE_SERIES(1, @N2M);

/* ----- C3: large analytic fact table ----- */
CREATE TABLE bench.FactSales
(
    SaleId    bigint        NOT NULL CONSTRAINT PK_FactSales PRIMARY KEY,
    SaleDate  date          NOT NULL,
    StoreId   int           NOT NULL,
    ProductId int           NOT NULL,
    Quantity  int           NOT NULL,
    Amount    decimal(12,2) NOT NULL,
    Discount  decimal(5,2)  NOT NULL
);
INSERT bench.FactSales (SaleId, SaleDate, StoreId, ProductId, Quantity, Amount, Discount)
SELECT value, DATEADD(DAY, -(value % 1095), '2026-10-01'), 1 + value % 500, 1 + (CAST(value AS bigint) * 31) % 5000,
       1 + value % 9, (value % 500) + 0.99, (value % 4) * 2.5
FROM GENERATE_SERIES(CAST(1 AS bigint), CAST(@N10M AS bigint));

/* ----- C4: large fact table with analytic reads and a trickle of single-row updates ----- */
CREATE TABLE bench.FactEvents
(
    EventId   bigint       NOT NULL CONSTRAINT PK_FactEvents PRIMARY KEY,
    EventDate date         NOT NULL,
    EventType smallint     NOT NULL,
    SourceId  int          NOT NULL,
    Status    tinyint      NOT NULL,
    Value     float        NOT NULL
);
INSERT bench.FactEvents (EventId, EventDate, EventType, SourceId, Status, Value)
SELECT value, DATEADD(DAY, -(value % 730), '2026-10-01'), 1 + value % 40, 1 + (CAST(value AS bigint) * 17) % 20000, value % 3, (value % 1000) / 10.0
FROM GENERATE_SERIES(CAST(1 AS bigint), CAST(@N5M AS bigint));

/* ----- C5: write-heavy queue ----- */
CREATE TABLE bench.AuditQueue
(
    QueueItemId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AuditQueue PRIMARY KEY,
    QueueId     int           NOT NULL,
    EnqueuedAt  datetime2(3)  NOT NULL,
    ProcessedAt datetime2(3)  NULL,
    Payload     nvarchar(400) NOT NULL
);
INSERT bench.AuditQueue (QueueId, EnqueuedAt, ProcessedAt, Payload)
SELECT 1 + value % 20, DATEADD(SECOND, -value, '2026-10-01'), CASE WHEN value % 10 <> 0 THEN DATEADD(SECOND, -value + 5, '2026-10-01') END,
       REPLICATE(N'x', 200)
FROM GENERATE_SERIES(1, @N100K);

/* ----- C6: three queries on LastName that give three overlapping suggestions ----- */
CREATE TABLE bench.CustomerContacts
(
    ContactId int           NOT NULL CONSTRAINT PK_CustomerContacts PRIMARY KEY,
    CityId    int           NOT NULL,
    FirstName nvarchar(40)  NOT NULL,
    LastName  nvarchar(40)  NOT NULL,
    Email     nvarchar(100) NOT NULL,
    Phone     varchar(20)   NOT NULL
);
INSERT bench.CustomerContacts (ContactId, CityId, FirstName, LastName, Email, Phone)
SELECT value, 1 + value % 3000, CONCAT(N'First', value % 400), CONCAT(N'Last', (CAST(value AS bigint) * 13) % 50000),
       CONCAT(N'c', value, N'@example.com'), CONCAT('555-', RIGHT(CONCAT('000000', value), 7))
FROM GENERATE_SERIES(1, @N1M);

/* ----- C7: equality + range + ORDER BY ----- */
CREATE TABLE bench.Shipments
(
    ShipmentId int          NOT NULL CONSTRAINT PK_Shipments PRIMARY KEY,
    ShippedAt  datetime2(0) NOT NULL,
    CarrierId  int          NOT NULL,
    Weight     decimal(9,2) NOT NULL,
    TrackingNo varchar(30)  NOT NULL
);
INSERT bench.Shipments (ShipmentId, ShippedAt, CarrierId, Weight, TrackingNo)
SELECT value, DATEADD(MINUTE, -value, '2026-10-01'), 1 + (CAST(value AS bigint) * 7) % 50, (value % 300) + 0.25, CONCAT('TRK', value)
FROM GENERATE_SERIES(1, @N2M);

/* ----- C8: nvarchar(max) body that missing-index suggestions put in INCLUDE ----- */
CREATE TABLE bench.Documents
(
    DocId   int            NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,
    OwnerId int            NOT NULL,
    Title   nvarchar(200)  NOT NULL,
    Body    nvarchar(max)  NOT NULL
);
INSERT bench.Documents (DocId, OwnerId, Title, Body)
SELECT value, 1 + (CAST(value AS bigint) * 11) % 20000, CONCAT(N'Document ', value), REPLICATE(CAST(N'Lorem ipsum dolor sit amet. ' AS nvarchar(max)), 15)
FROM GENERATE_SERIES(1, @N200K);

/* ----- C9: non-SARGable predicates on dates ----- */
CREATE TABLE bench.Invoices
(
    InvoiceId   int           NOT NULL CONSTRAINT PK_Invoices PRIMARY KEY,
    CustomerId  int           NOT NULL,
    InvoiceDate date          NOT NULL,
    CreatedAt   datetime2(0)  NOT NULL,
    Total       decimal(12,2) NOT NULL
);
INSERT bench.Invoices (InvoiceId, CustomerId, InvoiceDate, CreatedAt, Total)
SELECT value, 1 + value % 50000, DATEADD(DAY, -(value % 1460), '2026-10-01'), DATEADD(MINUTE, -value, '2026-10-01'), (value % 2000) + 0.75
FROM GENERATE_SERIES(1, @N2M);

/* ----- C10: an exact duplicate, a left-prefix overlap, and an index duplicating a UNIQUE constraint ----- */
CREATE TABLE bench.Accounts
(
    AccountId     int           NOT NULL CONSTRAINT PK_Accounts PRIMARY KEY,
    AccountNumber varchar(20)   NOT NULL CONSTRAINT UQ_Accounts_AccountNumber UNIQUE,
    AccountTypeId int           NOT NULL,
    Region        char(2)       NOT NULL,
    Email         nvarchar(100) NOT NULL,
    Status        tinyint       NOT NULL
);
INSERT bench.Accounts (AccountId, AccountNumber, AccountTypeId, Region, Email, Status)
SELECT value, CONCAT('AC', RIGHT(CONCAT('0000000000', value), 10)), 1 + value % 12,
       CHAR(65 + value % 26) + CHAR(65 + (value / 26) % 26), CONCAT(N'a', value, N'@example.com'), value % 4
FROM GENERATE_SERIES(1, @N1M);
CREATE INDEX IX_Accounts_Region ON bench.Accounts (Region);
CREATE INDEX IX_Accounts_Region_Dup ON bench.Accounts (Region);                    -- exact duplicate
CREATE INDEX IX_Accounts_Email ON bench.Accounts (Email);                          -- left prefix of the next one
CREATE INDEX IX_Accounts_Email_Status ON bench.Accounts (Email, Status);
CREATE INDEX IX_Accounts_AccountNumber ON bench.Accounts (AccountNumber);          -- duplicates UQ_Accounts_AccountNumber

/* ----- C11 and C16: a fully covered workload, plus one index nothing reads ----- */
CREATE TABLE bench.Products
(
    ProductId    int           NOT NULL CONSTRAINT PK_Products PRIMARY KEY,
    CategoryId   int           NOT NULL,
    Name         nvarchar(100) NOT NULL,
    Price        decimal(10,2) NOT NULL,
    SupplierCode varchar(12)   NOT NULL
);
INSERT bench.Products (ProductId, CategoryId, Name, Price, SupplierCode)
SELECT value, 1 + value % 400, CONCAT(N'Product ', value), (value % 900) + 0.99, CONCAT('S', value % 5000)
FROM GENERATE_SERIES(1, @N200K);
CREATE INDEX IX_Products_Category_Price ON bench.Products (CategoryId, Price) INCLUDE (Name);
CREATE INDEX IX_Products_Unused ON bench.Products (SupplierCode);                  -- never read by the workload

/* ----- C12: heap whose rows the workload widens, creating forwarded records ----- */
CREATE TABLE bench.StagingRows
(
    BatchId  int            NOT NULL,
    RowNo    int            NOT NULL,
    LoadedAt datetime2(0)   NOT NULL,
    Payload  varchar(2000)  NOT NULL
);
INSERT bench.StagingRows (BatchId, RowNo, LoadedAt, Payload)
SELECT 1 + value % 300, value, DATEADD(SECOND, -value, '2026-10-01'), CONCAT('row ', value)
FROM GENERATE_SERIES(1, @N300K);

/* ----- C13: an untrusted foreign key that blocks join elimination ----- */
CREATE TABLE bench.Payers (PayerId int NOT NULL CONSTRAINT PK_Payers PRIMARY KEY, Name nvarchar(60) NOT NULL);
INSERT bench.Payers (PayerId, Name) SELECT value, CONCAT(N'Payer ', value) FROM GENERATE_SERIES(1, @N50K);

CREATE TABLE bench.Payments
(
    PaymentId int           NOT NULL CONSTRAINT PK_Payments PRIMARY KEY,
    PayerId   int           NOT NULL,
    PaidOn    date          NOT NULL,
    Amount    decimal(12,2) NOT NULL
);
INSERT bench.Payments (PaymentId, PayerId, PaidOn, Amount)
SELECT value, 1 + (CAST(value AS bigint) * 3) % @N50K, DATEADD(DAY, -(value % 1000), '2026-10-01'), (value % 800) + 0.10
FROM GENERATE_SERIES(1, @N1M);
ALTER TABLE bench.Payments WITH NOCHECK ADD CONSTRAINT FK_Payments_Payers FOREIGN KEY (PayerId) REFERENCES bench.Payers (PayerId);

/* ----- C14: readings for the forced-plan failure (the workload script forces and breaks the plan) ----- */
CREATE TABLE bench.Readings
(
    ReadingId int          NOT NULL CONSTRAINT PK_Readings PRIMARY KEY,
    SensorId  int          NOT NULL,
    Kind      tinyint      NOT NULL,
    ReadAt    datetime2(0) NOT NULL,
    Value     float        NOT NULL
);
INSERT bench.Readings (ReadingId, SensorId, Kind, ReadAt, Value)
SELECT value, 1 + value % 5000, value % 6, DATEADD(SECOND, -value, '2026-10-01'), (value % 500) / 5.0
FROM GENERATE_SERIES(1, @N1M);
GO

SELECT t.name AS TableName, SUM(p.rows) AS Rows
FROM sys.tables AS t
INNER JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.schema_id = SCHEMA_ID(N'bench')
GROUP BY t.name
ORDER BY t.name;
GO
