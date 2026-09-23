[CmdletBinding()]
param(
    [ValidateSet('HighestTask', 'PromptedStartup')]
    [string]$LaunchMode = 'HighestTask'
)

Import-Module (Join-Path $PSScriptRoot 'ChildStream.Runtime.psm1') -Force

$root = Split-Path $PSScriptRoot -Parent
Invoke-ChildSessionSunshine -Root $root -LaunchMode $LaunchMode -WaitSeconds 60
