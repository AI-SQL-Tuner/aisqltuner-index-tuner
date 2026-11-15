/*
    Holds the apply lock of a new run for $(HoldSeconds) seconds, as a second session applying its
    recommendations would (issue #51). Run-All.ps1 starts it in the background, and
    06_Check-ConcurrentApply.sql then tries to apply the same run from another session.
*/
SET NOCOUNT ON;
EXEC dbo.sp_AIIndexTuner @CollectedData = N'{"t51": true}', @TestResponse = N'{ "summary": "T51 lock holder.", "recommendations": [
  { "priority": 1, "category": "CreateIndex", "title": "EventType", "schema_name": "dbo", "table_name": "AuditLog", "index_name": "IX_AuditLog_T51",
    "key_columns": [ { "column": "EventType", "descending": false } ], "include_columns": [], "filter_predicate": null, "is_unique": false,
    "fill_factor": null, "data_compression": null, "estimated_size_mb": 1, "confidence": "High", "rationale": "t", "benefiting_queries": [],
    "script": "CREATE INDEX IX_AuditLog_T51 ON dbo.AuditLog (EventType);" } ] }';
DECLARE @RunId int = (SELECT MAX(RunId) FROM AIIndexTuner.Run WHERE Summary = N'T51 lock holder.');
DECLARE @Lock nvarchar(255) = CONCAT(N'AIIndexTuner.Apply.Run.', @RunId), @Got int;
EXEC @Got = sys.sp_getapplock @Resource = @Lock, @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
IF @Got < 0 THROW 50999, N'The lock holder could not take the lock.', 1;
WAITFOR DELAY '00:00:$(HoldSeconds)';
EXEC sys.sp_releaseapplock @Resource = @Lock, @LockOwner = 'Session';
