# Rebuilds the install script, recreates AIIndexTunerTest, installs, runs the workload, then the tests.
# A fresh database each time: dropping an index clears SQL Server's missing-index statistics for the
# table, so the tests cannot reuse a database an earlier run changed.
#
#   .\tests\Run-All.ps1                 # local default instance, Windows authentication
#   .\tests\Run-All.ps1 -Server sql01
param([string]$Server = 'localhost')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Invoke-Sql([string]$File, [string]$Database = 'master', [string]$Output) {
    $sqlArgs = @('-S', $Server, '-E', '-C', '-f', '65001', '-b', '-d', $Database, '-i', $File)
    if ($Output) { $sqlArgs += @('-o', $Output) }
    $output = & sqlcmd @sqlArgs
    if ($LASTEXITCODE -ne 0) {
        $output | Where-Object { $_ } | ForEach-Object { Write-Host $_ }
        throw "sqlcmd failed on $File (exit $LASTEXITCODE)"
    }
}

& (Join-Path $root 'build.ps1') | Out-Null
Write-Host 'Creating AIIndexTunerTest...'
Invoke-Sql (Join-Path $PSScriptRoot '01_Create-TestDb.sql')
Write-Host 'Installing...'
Invoke-Sql (Join-Path $root 'aisqltuner-index-tuner.sql') 'AIIndexTunerTest'
Write-Host 'Running the workload...'
Invoke-Sql (Join-Path $PSScriptRoot '02_Run-Workload.sql') 'AIIndexTunerTest'

Write-Host 'Running the tests...'
$out = Join-Path ([IO.Path]::GetTempPath()) 'aisqltuner-index-tuner-tests.txt'
& sqlcmd -S $Server -E -C -f 65001 -b -d AIIndexTunerTest -i (Join-Path $PSScriptRoot '03_Run-Tests.sql') -o $out -W
$code = $LASTEXITCODE
Get-Content $out -Encoding utf8 | Where-Object { $_ -match '^(PASS|FAIL|SKIP|ALL TESTS)|^Msg ' } | ForEach-Object { Write-Host $_ }
if ($code -ne 0) { Write-Host "Tests failed. Full output: $out"; exit 1 }
