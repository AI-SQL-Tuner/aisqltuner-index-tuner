/*
    Checks that a second session cannot apply a run's recommendations while another holds its apply
    lock (issue #51). 06_Hold-ApplyLock.sql, running in the background, creates the run and holds the
    lock; this waits for it, tries to apply, and expects error 50102 with nothing changed.
*/
SET NOCOUNT ON;
DECLARE @RunId int, @Lock nvarchar(255), @Tries int = 0;
WHILE @Tries < 60
BEGIN
    SET @RunId = (SELECT MAX(RunId) FROM AIIndexTuner.Run WHERE Summary = N'T51 lock holder.');
    SET @Lock = CONCAT(N'AIIndexTuner.Apply.Run.', @RunId);
    IF @RunId IS NOT NULL AND APPLOCK_TEST(N'public', @Lock, N'Exclusive', N'Session') = 0
        BREAK;
    WAITFOR DELAY '00:00:00.500';
    SET @Tries += 1;
END;
IF @Tries >= 60
    THROW 50999, N'FAIL concurrent apply: the lock holder did not start within 30 seconds.', 1;

DECLARE @Error int = NULL;
BEGIN TRY
    EXEC dbo.sp_AIIndexTuner_Apply @RunId = @RunId;
END TRY
BEGIN CATCH
    SET @Error = ERROR_NUMBER();
END CATCH;
IF ISNULL(@Error, 0) <> 50102
BEGIN
    DECLARE @Msg nvarchar(400) = CONCAT(N'FAIL concurrent apply: applying a locked run returned error ', ISNULL(CONVERT(varchar(12), @Error), 'none'), N', not 50102.');
    THROW 50999, @Msg, 1;
END;
IF EXISTS (SELECT 1 FROM AIIndexTuner.Recommendation WHERE RunId = @RunId AND Status <> 'Recommended')
   OR INDEXPROPERTY(OBJECT_ID(N'dbo.AuditLog'), N'IX_AuditLog_T51', 'IndexID') IS NOT NULL
    THROW 50999, N'FAIL concurrent apply: the locked run was changed.', 1;
PRINT 'PASS concurrent apply: a second session gets error 50102 and changes nothing while another holds the run''s lock';
