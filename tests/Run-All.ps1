# Rebuilds the install script, recreates the test database, installs, runs the workload, then the tests.
# A fresh database each time: dropping an index clears SQL Server's missing-index statistics for the
# table, so the tests cannot reuse a database an earlier run changed.
#
#   .\tests\Run-All.ps1                 # local default instance, Windows authentication
#   .\tests\Run-All.ps1 -Server sql01
#   .\tests\Run-All.ps1 -Database AIIndexTunerTest2
#   .\tests\Run-All.ps1 -Collation Turkish_100_CI_AS
#
# -Collation sets the test database's collation: Different (the default) picks one other than the
# instance's, so collation conflicts between DMVs and catalog views show up (issue #42); Instance
# uses the instance's; any other value is used as the collation name.
#
# The test database is dropped and recreated, which also removes any endpoint credential set up in
# it. If it has a database scoped credential, the runner stops, unless -Force is passed.
param(
    [string]$Server = 'localhost',
    [string]$Database = 'AIIndexTunerTest',
    [string]$Collation = 'Different',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if ($Database -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Use a plain database name (letters, digits, underscores): $Database" }
if ($Collation -notmatch '^[A-Za-z0-9_]+$') { throw "Use a collation name (letters, digits, underscores): $Collation" }

function Invoke-Sql([string]$File, [string]$Db = 'master', [string]$Output) {
    $sqlArgs = @('-S', $Server, '-E', '-C', '-f', '65001', '-b', '-d', $Db, '-v', "TestDb=$Database", "TestCollation=$Collation", '-i', $File)
    if ($Output) { $sqlArgs += @('-o', $Output) }
    $output = & sqlcmd @sqlArgs
    if ($LASTEXITCODE -ne 0) {
        $output | Where-Object { $_ } | ForEach-Object { Write-Host $_ }
        throw "sqlcmd failed on $File (exit $LASTEXITCODE)"
    }
}

if (-not $Force) {
    $credentials = & sqlcmd -S $Server -E -C -h -1 -W -Q "SET NOCOUNT ON; IF DB_ID(N'$Database') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM [$Database].sys.database_scoped_credentials;"
    if ($LASTEXITCODE -ne 0) { throw "Could not check $Database for credentials." }
    if ([int]($credentials | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1) -gt 0) {
        throw "$Database has a database scoped credential, which recreating it would delete. Use -Database to test in another database, or -Force to recreate it anyway."
    }
}

& (Join-Path $root 'build.ps1') | Out-Null
Write-Host "Creating $Database..."
Invoke-Sql (Join-Path $PSScriptRoot '01_Create-TestDb.sql')
Write-Host 'Installing...'
Invoke-Sql (Join-Path $root 'aisqltuner-index-tuner.sql') $Database
Write-Host 'Running the workload...'
Invoke-Sql (Join-Path $PSScriptRoot '02_Run-Workload.sql') $Database

Write-Host 'Running the tests...'
$out = Join-Path ([IO.Path]::GetTempPath()) 'aisqltuner-index-tuner-tests.txt'
& sqlcmd -S $Server -E -C -f 65001 -b -d $Database -i (Join-Path $PSScriptRoot '03_Run-Tests.sql') -o $out -W
$code = $LASTEXITCODE
Get-Content $out -Encoding utf8 | Where-Object { $_ -match '^(PASS|FAIL|SKIP|ALL TESTS)|^Msg ' } | ForEach-Object { Write-Host $_ }
if ($code -ne 0) { Write-Host "Tests failed. Full output: $out"; exit 1 }

# Two sessions applying one run (issue #51): a background session holds the run's apply lock while
# this one tries to apply it.
Write-Host 'Checking concurrent applies...'
$holderArgs = @('-S', $Server, '-E', '-C', '-f', '65001', '-b', '-d', $Database, '-v', 'HoldSeconds=20', '-i', (Join-Path $PSScriptRoot '06_Hold-ApplyLock.sql'))
$holder = Start-Job -ScriptBlock { param($a) & sqlcmd @a 2>&1; "exit $LASTEXITCODE" } -ArgumentList (,$holderArgs)
try {
    Invoke-Sql (Join-Path $PSScriptRoot '06_Check-ConcurrentApply.sql') $Database
    Write-Host 'PASS concurrent apply: a second session gets error 50102 and changes nothing while another holds the run''s lock'
} finally {
    # The holder waits 20 seconds; 60 allows for a slow start. Wait-Job returns nothing on a timeout.
    $finished = $holder | Wait-Job -Timeout 60
    $held = $holder | Receive-Job
    $holderState = $holder.State
    $holder | Remove-Job -Force
}
if (-not $finished) { $held | Write-Host; throw "The lock holder session was still running after 60 seconds (job state: $holderState)." }
if (($held | Select-Object -Last 1) -ne 'exit 0') { $held | Write-Host; throw 'The lock holder session failed.' }
