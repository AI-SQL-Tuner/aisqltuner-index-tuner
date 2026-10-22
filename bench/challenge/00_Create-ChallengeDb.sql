/*
    Creates the IndexTunerChallenge database on SQL Server (VMEnt), with Query Store capturing every
    query. Drops it first if it exists. On Azure SQL Database, skip this script: the challenge tables
    go into an existing database (the Dev EMS database) through 01_Create-ChallengeTables.sql.

    sqlcmd -S VMEnt -E -C -f 65001 -b -i bench\challenge\00_Create-ChallengeDb.sql
*/
SET NOCOUNT ON;
USE master;
GO
IF DB_ID(N'IndexTunerChallenge') IS NOT NULL
BEGIN
    ALTER DATABASE IndexTunerChallenge SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE IndexTunerChallenge;
END;
GO
CREATE DATABASE IndexTunerChallenge;
GO
ALTER DATABASE IndexTunerChallenge SET RECOVERY SIMPLE;
ALTER DATABASE IndexTunerChallenge SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL);
GO
