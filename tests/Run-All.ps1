# Rebuilds the install script, recreates the test database, installs, runs the workload, then the tests.
# A fresh database each time: dropping an index clears SQL Server's missing-index statistics for the
# table, so the tests cannot reuse a database an earlier run changed.
#
#   .\tests\Run-All.ps1                 # local default instance, Windows authentication
#   .\tests\Run-All.ps1 -Server sql01
#   .\tests\Run-All.ps1 -Database AIIndexTunerTest2
#
# The test database is dropped and recreated, which also removes any endpoint credential set up in
# it. If it has a database scoped credential, the runner stops, unless -Force is passed.
param(
    [string]$Server = 'localhost',
    [string]$Database = 'AIIndexTunerTest',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if ($Database -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Use a plain database name (letters, digits, underscores): $Database" }

function Invoke-Sql([string]$File, [string]$Db = 'master', [string]$Output) {
    $sqlArgs = @('-S', $Server, '-E', '-C', '-f', '65001', '-b', '-d', $Db, '-v', "TestDb=$Database", '-i', $File)
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
