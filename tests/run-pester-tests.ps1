[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw 'Pesterテストファイルがありません。' }

foreach ($testFile in $testFiles) {
    $escapedPath = $testFile.FullName.Replace("'", "''")
    $command = @"
Import-Module Pester -RequiredVersion 5.7.1 -Force
`$result = Invoke-Pester -Path '$escapedPath' -Output Detailed -PassThru
if (`$result.FailedCount -ne 0 -or `$result.FailedContainers.Count -ne 0) { exit 1 }
"@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    if ($LASTEXITCODE -ne 0) { throw "Pesterテストが失敗しました: $($testFile.Name)" }
}
