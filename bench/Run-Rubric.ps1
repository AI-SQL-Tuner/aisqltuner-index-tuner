<#
.SYNOPSIS
    Part 1 of the benchmark (issue #2): builds the challenge tables, runs the workload, runs
    sp_AIIndexTuner against them and scores every run with the rubric checks.

.DESCRIPTION
    -Mode Validate  canned model answers only, no AI endpoint: proves every check scores right and
                    wrong answers correctly. Run it after changing a check or the payload variants.
    -Mode Live      the real model. Checks the prerequisites in bench/PREREQUISITES.md first and stops
                    on the first one that fails. Per iteration it runs:
                      base    the whole database (or schema bench on Azure SQL Database)
                      scoped  bench.Shipments only
                      P1..P4  edited copies of the first base run's collected data
                    Iterations 2..k of base and scoped reuse iteration 1's collected data, so every
                    iteration answers the same input and the spread is the model's own.
                    Writes bench/results/rubric-<date>-<server>.md.

.EXAMPLE
    .\bench\Run-Rubric.ps1 -Server localhost -Mode Validate -Scale 0.1 -Reps 50
    .\bench\Run-Rubric.ps1 -Server VMEnt -Mode Live
    .\bench\Run-Rubric.ps1 -Server myserver.database.windows.net -Database DevEms -Azure -AuthArgs '-G' -Mode Live
#>
param(
    [Parameter(Mandatory)] [string]$Server,
    [string]$Database = 'IndexTunerChallenge',
    [ValidateSet('Live', 'Validate')] [string]$Mode = 'Live',
    [int]$Iterations = 5,
    [ValidateRange(0.01, 1.0)] [double]$Scale = 1.0,
    [int]$Reps = 0,                       # 0 = the workload default (200 / Scale, at most 2,000)
    [string]$ExpectedDeployment = 'gpt-5.6-luna',
    [string]$ExpectedEffort = 'medium',
    [switch]$Azure,                       # Azure SQL Database: base runs scoped to schema bench, no sp_configure check
    [string[]]$AuthArgs = @('-E'),        # sqlcmd authentication arguments, e.g. '-G' or '-U','user','-P','pwd'
    [switch]$SkipBuild,                   # reuse the existing tables and workload
    [switch]$SkipWorkload,
    [switch]$DryRun                       # Live flow end to end with a canned empty answer; prerequisites reported, not enforced
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bench = $PSScriptRoot
$baseSchema = if ($Azure) { 'bench' } else { $null }

# sqlcmd writes some messages to stderr; under Stop, Windows PowerShell turns each one into an
# exception, so the sqlcmd calls run under Continue and are judged by their exit code.
function Invoke-SqlFile([string]$File, [string]$Label) {
    $ErrorActionPreference = 'Continue'
    Write-Host "  $Label"
    $out = & sqlcmd -S $Server -d $Database @AuthArgs -C -f 65001 -b -t 0 -i $File 2>&1
    if ($LASTEXITCODE -ne 0) { $out | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" }; throw "sqlcmd failed on $File" }
    return $out
}

function Invoke-SqlQuery([string]$Query) {
    $ErrorActionPreference = 'Continue'
    $tmp = [IO.Path]::GetTempFileName() + '.sql'
    [IO.File]::WriteAllText($tmp, "SET NOCOUNT ON;`r`n$Query", (New-Object Text.UTF8Encoding $false))
    try {
        $out = & sqlcmd -S $Server -d $Database @AuthArgs -C -f 65001 -b -t 0 -y 0 -i $tmp 2>&1
        if ($LASTEXITCODE -ne 0) { $out | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" }; throw "sqlcmd query failed" }
        return ($out -join "`n").Trim()
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# Runs $Prefix (any statements), then $JsonSelect (one SELECT ... FOR JSON ...) into a variable, and
# prints it once after a marker. A bare FOR JSON result can arrive split across several rows, and
# the prefix (sp_AIIndexTuner, for one) may print result sets of its own, so only the text after the
# marker is parsed.
function Get-Json([string]$JsonSelect, [string]$Prefix = '') {
    $text = Invoke-SqlQuery @"
$Prefix
DECLARE @__json nvarchar(max) = ($($JsonSelect.Trim().TrimEnd(';')));
SELECT N'@@JSON@@' + ISNULL(@__json, N'null');
"@
    $flat = ($text -split "`n") -join ''
    $at = $flat.LastIndexOf('@@JSON@@')
    if ($at -lt 0) { throw "No JSON in the output: $text" }
    $json = $flat.Substring($at + 8).Trim()
    if ($json -eq 'null') { return $null }
    return $json | ConvertFrom-Json
}

function Assert-Prerequisite([string]$Item, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "  OK    $Item" }
    elseif ($DryRun) { Write-Host "  SKIP  $Item - $Detail (dry run)" -ForegroundColor Yellow }
    else { Write-Host "  FAIL  $Item - $Detail" -ForegroundColor Red; throw "Prerequisite not met: $Item. See bench/PREREQUISITES.md." }
}

Write-Host "Server $Server, database $Database, mode $Mode$(if ($Azure) { ', Azure SQL Database' })"

# ----- Prerequisites 1 and 2 (before changing anything) -----
if ($Mode -eq 'Live') {
    Write-Host 'Prerequisites:'
    $p = Get-Json @"
SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS EngineEdition,
       (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'external rest endpoint enabled') AS RestEnabled
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
"@
    if ($Azure) {
        Assert-Prerequisite '1. Azure SQL Database' ($p.EngineEdition -eq 5) "EngineEdition is $($p.EngineEdition), expected 5"
        Write-Host '  OK    2. REST endpoint (always on in Azure SQL Database)'
    } else {
        Assert-Prerequisite '1. Enterprise-capable edition (EngineEdition 3)' ($p.EngineEdition -eq 3) "EngineEdition is $($p.EngineEdition)"
        Assert-Prerequisite "2. 'external rest endpoint enabled' = 1" ($p.RestEnabled -eq 1) "value_in_use is $($p.RestEnabled)"
    }
}

# ----- Build -----
if (-not $SkipBuild) {
    Write-Host 'Build:'
    & (Join-Path $root 'build.ps1') | Out-Null
    Invoke-SqlFile (Join-Path $root 'aisqltuner-index-tuner.sql') 'install aisqltuner-index-tuner' | Out-Null
    $repsValue = if ($Reps -gt 0) { $Reps } else { 'NULL' }
    Invoke-SqlQuery @"
IF SCHEMA_ID(N'AIIndexTunerBench') IS NULL EXEC (N'CREATE SCHEMA AIIndexTunerBench AUTHORIZATION dbo;');
IF OBJECT_ID(N'AIIndexTunerBench.ChallengeSettings', N'U') IS NULL
    CREATE TABLE AIIndexTunerBench.ChallengeSettings (Id tinyint NOT NULL PRIMARY KEY CHECK (Id = 1),
                                          Scale float NOT NULL CHECK (Scale > 0 AND Scale <= 1),
                                          Reps int NULL CHECK (Reps > 0));
MERGE AIIndexTunerBench.ChallengeSettings AS t USING (SELECT 1 AS Id) AS s ON t.Id = s.Id
WHEN MATCHED THEN UPDATE SET Scale = $Scale, Reps = $repsValue
WHEN NOT MATCHED THEN INSERT (Id, Scale, Reps) VALUES (1, $Scale, $repsValue);
"@ | Out-Null
    Invoke-SqlFile (Join-Path $bench 'rubric\01_Rubric.sql') 'rubric objects' | Out-Null
    Invoke-SqlFile (Join-Path $bench 'rubric\02_Rubric-Checks.sql') 'rubric checks' | Out-Null
    Invoke-SqlFile (Join-Path $bench 'challenge\01_Create-ChallengeTables.sql') "challenge tables (scale $Scale)" | ForEach-Object { if ($_ -match '^\S+\s+\d+$') { Write-Host "    $_" } }
}
if (-not $SkipBuild -and -not $SkipWorkload) {
    # The bulk loads would otherwise sit in Query Store and the plan cache as the heaviest "workload".
    # Clearing them is safe on the dedicated challenge database, but not on the shared Dev EMS
    # database, where the base runs are scoped to the bench schema instead.
    if (-not $Azure) {
        Invoke-SqlQuery 'ALTER DATABASE CURRENT SET QUERY_STORE CLEAR; ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;' | Out-Null
        Write-Host '  cleared Query Store and the plan cache of the build'
    }
    Invoke-SqlFile (Join-Path $bench 'challenge\02_Run-ChallengeWorkload.sql') 'workload' | Where-Object { $_ -match '^Workload' } | ForEach-Object { Write-Host "    $_" }
}

# ----- Validate -----
if ($Mode -eq 'Validate') {
    Write-Host 'Validate:'
    $ErrorActionPreference = 'Continue'
    $out = & sqlcmd -S $Server -d $Database @AuthArgs -C -f 65001 -b -t 0 -i (Join-Path $bench 'rubric\Validate-Rubric.sql') 2>&1
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match '^(PASS|FAIL|Validation)|^Msg ' } | ForEach-Object { Write-Host "  $_" }
    if ($code -ne 0) {
        $out | Where-Object { $_ -and $_ -notmatch '^(PASS|Validation)' } | Select-Object -First 60 | ForEach-Object { Write-Host "    $_" }
        throw 'Validation failed.'
    }
    Write-Host 'Validation passed.'
    return
}

# ----- Prerequisites 3 and 5 (need the installed objects) -----
$cfg = Get-Json @"
SELECT c.Deployment, c.ReasoningEffort, c.UseBackgroundMode, c.KeepRunDetail, c.CredentialName,
       CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = c.CredentialName) THEN 1 ELSE 0 END AS bit) AS CredentialExists,
       CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END AS bit) AS MasterKeyExists
FROM AIIndexTuner.Config AS c WHERE c.ConfigId = 1
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
"@
Assert-Prerequisite '5. AIIndexTuner.Config row' ($null -ne $cfg -and $cfg.Deployment) 'no configuration row; run setup/Configure-Endpoint.sql'
Assert-Prerequisite '3. Database master key' ([bool]$cfg.MasterKeyExists) 'CREATE MASTER KEY first'
Assert-Prerequisite "3. Credential $($cfg.CredentialName)" ([bool]$cfg.CredentialExists) 'the credential named in AIIndexTuner.Config does not exist'
Assert-Prerequisite "5. Deployment $ExpectedDeployment" ($cfg.Deployment -eq $ExpectedDeployment) "configured deployment is $($cfg.Deployment)"
Assert-Prerequisite "5. Reasoning effort $ExpectedEffort" ($cfg.ReasoningEffort -eq $ExpectedEffort) "configured effort is $($cfg.ReasoningEffort)"
Assert-Prerequisite '5. UseBackgroundMode = 1' ([bool]$cfg.UseBackgroundMode) 'set UseBackgroundMode = 1'
Assert-Prerequisite '5. KeepRunDetail = 1' ([bool]$cfg.KeepRunDetail) 'set KeepRunDetail = 1; the payload variants need the base run''s collected data'

# ----- Live runs -----
$schemaLiteral = if ($baseSchema) { "N'$baseSchema'" } else { 'NULL' }
$batchMode = if ($DryRun) { 'dryrun' } else { 'live' }
$batchId = [int](Get-Json -Prefix @"
INSERT AIIndexTunerBench.RubricBatch (Mode, Deployment, Effort, Iterations, BaseSchema, PromptHash)
VALUES ('$batchMode',
        (SELECT Deployment FROM AIIndexTuner.Config WHERE ConfigId = 1),
        (SELECT ReasoningEffort FROM AIIndexTuner.Config WHERE ConfigId = 1),
        $Iterations, $schemaLiteral,
        CONVERT(char(64), HASHBYTES('SHA2_256', AIIndexTuner.fn_SystemPrompt()), 2));
DECLARE @b int = SCOPE_IDENTITY();
"@ -JsonSelect 'SELECT @b AS BatchId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER').BatchId
Write-Host "$(if ($DryRun) { 'Dry' } else { 'Live' }) runs (batch $batchId):"
# A dry run answers every run with an empty recommendation list, which exercises the whole flow:
# pinning, the payload variants, evaluation and the report.
$testResponse = if ($DryRun) { "N'{""summary"": ""dry run"", ""recommendations"": []}'" } else { 'NULL' }

function Invoke-RubricRun([string]$Variant, [int]$Iteration, [int]$PinRunId) {
    $pin = if ($PinRunId -gt 0) { $PinRunId } else { 'NULL' }
    $started = Get-Date
    $r = Get-Json -Prefix @"
DECLARE @r int;
EXEC AIIndexTunerBench.usp_RubricRun @BatchId = $batchId, @Variant = '$Variant', @Iteration = $Iteration, @BaseSchema = $schemaLiteral, @PinRunId = $pin, @TestResponse = $testResponse, @RunId = @r OUTPUT;
"@ -JsonSelect @"
SELECT RunId, Status, InputTokens, OutputTokens, ModelMs, PollCount, CollectedChars, LEFT(ErrorMessage, 300) AS ErrorMessage,
       (SELECT COUNT(*) FROM AIIndexTuner.Recommendation WHERE RunId = @r) AS Recommendations
FROM AIIndexTuner.Run WHERE RunId = @r
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
"@
    $secs = [int]((Get-Date) - $started).TotalSeconds
    $line = "  {0,-6} #{1}  run {2,-5} {3,-9} {4,3} recs  in/out tokens {5}/{6}  {7}s" -f $Variant, $Iteration, $r.RunId, $r.Status, $r.Recommendations, $r.InputTokens, $r.OutputTokens, $secs
    if ($r.Status -ne 'Succeeded') { $line += "  $($r.ErrorMessage)" }
    Write-Host $line
    return $r
}

$base1 = $null; $scoped1 = $null
for ($i = 1; $i -le $Iterations; $i++) {
    $b = Invoke-RubricRun 'base' $i ($(if ($base1) { $base1.RunId } else { 0 }))
    if ($i -eq 1) {
        if ($b.Status -ne 'Succeeded') { throw "The first base run failed: $($b.ErrorMessage)" }
        $base1 = $b
    }
    $s = Invoke-RubricRun 'scoped' $i ($(if ($scoped1) { $scoped1.RunId } else { 0 }))
    if ($i -eq 1) { $scoped1 = $s }
}
foreach ($v in 'P1', 'P2', 'P3', 'P4') {
    for ($i = 1; $i -le $Iterations; $i++) { Invoke-RubricRun $v $i $base1.RunId | Out-Null }
}

Write-Host 'Evaluating...'
Invoke-SqlQuery "EXEC AIIndexTunerBench.usp_EvaluateBatch @BatchId = $batchId;" | Out-Null

# ----- Report -----
$batch = Get-Json "SELECT * FROM AIIndexTunerBench.RubricBatch WHERE BatchId = $batchId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;"
$settings = Get-Json "SELECT Scale, Reps FROM AIIndexTunerBench.ChallengeSettings WHERE Id = 1 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;"
$summary = Get-Json "SELECT CaseId, CheckId, Kind, Variant, Description, Runs, Passed, PassPct, Errors FROM AIIndexTunerBench.vRubricSummary WHERE BatchId = $batchId ORDER BY Variant, CaseId, CheckId FOR JSON PATH;"
$runs = Get-Json @"
SELECT rr.Variant, rr.Iteration, r.RunId, r.Status, r.ModelUsed, r.InputTokens, r.OutputTokens, r.ModelMs, r.PollCount, r.CollectedChars,
       r.PayloadSupplied, LEFT(r.PayloadHash, 12) AS PayloadHash, LEFT(r.ErrorMessage, 200) AS ErrorMessage,
       (SELECT COUNT(*) FROM AIIndexTuner.Recommendation AS rec WHERE rec.RunId = r.RunId) AS Recommendations,
       (SELECT SUM(CAST(res.Passed AS int)) FROM AIIndexTunerBench.RubricResult AS res INNER JOIN AIIndexTunerBench.RubricCheck AS c ON c.CheckId = res.CheckId
        WHERE res.RunId = r.RunId AND c.Kind <> 'preferred') AS ScoredPassed,
       (SELECT COUNT(*) FROM AIIndexTunerBench.RubricResult AS res INNER JOIN AIIndexTunerBench.RubricCheck AS c ON c.CheckId = res.CheckId
        WHERE res.RunId = r.RunId AND c.Kind <> 'preferred') AS ScoredChecks
FROM AIIndexTunerBench.RubricRun AS rr INNER JOIN AIIndexTuner.Run AS r ON r.RunId = rr.RunId
WHERE rr.BatchId = $batchId ORDER BY rr.Variant, rr.Iteration FOR JSON PATH;
"@

$scored = @($summary | Where-Object { $_.Kind -ne 'preferred' })
$preferred = @($summary | Where-Object { $_.Kind -eq 'preferred' })
$scoredPct = if ($scored.Count) { [math]::Round(100.0 * ($scored | Measure-Object Passed -Sum).Sum / ($scored | Measure-Object Runs -Sum).Sum, 1) } else { 0 }
$prefPct = if ($preferred.Count) { [math]::Round(100.0 * ($preferred | Measure-Object Passed -Sum).Sum / ($preferred | Measure-Object Runs -Sum).Sum, 1) } else { 0 }

$md = New-Object Text.StringBuilder
[void]$md.AppendLine("# Rubric run: $($batch.ServerName) / $($batch.DatabaseName), $($batch.StartedAt)")
[void]$md.AppendLine()
[void]$md.AppendLine("| | |")
[void]$md.AppendLine("|---|---|")
[void]$md.AppendLine("| Batch | $batchId |")
[void]$md.AppendLine("| Engine edition | $($batch.EngineEdition) |")
[void]$md.AppendLine("| Deployment / effort | $($batch.Deployment) / $($batch.Effort) |")
[void]$md.AppendLine("| Iterations | $Iterations |")
[void]$md.AppendLine("| Base scope | $(if ($baseSchema) { "schema $baseSchema" } else { 'whole database' }) |")
[void]$md.AppendLine("| System prompt SHA-256 | ``$($batch.PromptHash)`` |")
[void]$md.AppendLine("| Scale | $($settings.Scale) (workload reps: $(if ($settings.Reps) { $settings.Reps } else { 'default' })) |")
[void]$md.AppendLine("| **Required + forbidden pass rate** | **$scoredPct%** |")
[void]$md.AppendLine("| Preferred pass rate | $prefPct% |")
[void]$md.AppendLine()
[void]$md.AppendLine('## Checks')
[void]$md.AppendLine()
[void]$md.AppendLine('| Check | Kind | Variant | Passed | Description |')
[void]$md.AppendLine('|---|---|---|---:|---|')
foreach ($c in $summary) {
    $flag = if ($c.Passed -lt $c.Runs -and $c.Kind -ne 'preferred') { ' (!)' } else { '' }
    [void]$md.AppendLine("| $($c.CheckId)$flag | $($c.Kind) | $($c.Variant) | $($c.Passed)/$($c.Runs) | $($c.Description) |")
}
[void]$md.AppendLine()
[void]$md.AppendLine('## Runs')
[void]$md.AppendLine()
[void]$md.AppendLine('| Variant | # | Run | Status | Recs | Scored checks passed | Input / output tokens | Model s | Polls | Payload chars | Payload |')
[void]$md.AppendLine('|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---|')
foreach ($r in $runs) {
    $payload = "$(if ($r.PayloadSupplied) { 'supplied' } else { 'collected' }) $($r.PayloadHash)"
    $status = if ($r.Status -ne 'Succeeded') { "$($r.Status): $($r.ErrorMessage)" } else { $r.Status }
    [void]$md.AppendLine("| $($r.Variant) | $($r.Iteration) | $($r.RunId) | $status | $($r.Recommendations) | $(if ($r.ScoredChecks -gt 0) { "$($r.ScoredPassed)/$($r.ScoredChecks)" } else { '-' }) | $($r.InputTokens) / $($r.OutputTokens) | $([math]::Round($r.ModelMs / 1000.0, 1)) | $($r.PollCount) | $($r.CollectedChars) | $payload |")
}
[void]$md.AppendLine()
[void]$md.AppendLine('Every failure must be read before a check is changed: a model can find a better answer than the expected one. See bench/CASES.md.')

$resultsDir = Join-Path $bench 'results'
New-Item -ItemType Directory -Force $resultsDir | Out-Null
$serverTag = ($batch.ServerName -replace '[^A-Za-z0-9]', '-')
$file = Join-Path $resultsDir ("rubric-{0}-{1}-batch{2}.md" -f (Get-Date -Format 'yyyyMMdd-HHmm'), $serverTag, $batchId)
[IO.File]::WriteAllText($file, $md.ToString(), (New-Object Text.UTF8Encoding $false))
Write-Host "Required + forbidden: $scoredPct%   preferred: $prefPct%"
Write-Host "Report: $file"
