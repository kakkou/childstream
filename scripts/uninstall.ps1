[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChildStream.Setup.psm1') -Force

function Read-ValidatedChildStreamInstallState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try { $state = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "インストール状態を読み取れません。システムは変更していません: $($_.Exception.Message)" }
    foreach ($name in @('schemaVersion','installRoot','childSessionsEnabled','registry','firewall','startupHook','scheduledTask','desktopShortcut','sunshine','launcher')) {
        if ($null -eq $state.PSObject.Properties[$name]) { throw "インストール状態に必須項目がありません: $name" }
    }
    if ($state.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$state.installRoot)) { throw 'インストール状態の形式が不正です。' }
    $requiredRegistryNames = @('fDenyTSConnections','DWMFRAMEINTERVAL','RemoteDesktop_SuppressWhenMinimized')
    foreach ($name in $requiredRegistryNames) {
        if ($null -eq (@($state.registry) | Where-Object { $_.Name -eq $name } | Select-Object -First 1)) {
            throw "インストール状態にレジストリ項目がありません: $name"
        }
    }
    return $state
}

function Invoke-ChildStreamUninstall {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'install-state.jsonがありません。システムは変更していません。' }
    $journalPath = Join-Path (Split-Path -Parent $StatePath) 'install-journal.json'
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'install-journal.jsonがありません。システムは変更していません。' }
    $state = Read-ValidatedChildStreamInstallState -Path $StatePath
    $journal = Read-ChildStreamInstallJournal -Path $journalPath
    foreach ($entry in @($journal.entries)) {
        $change = [string]$entry.change
        if ($change -like 'registry:*' -or @('firewall','childSessions') -contains $change) { continue }
        if (@('launcher','startupHook','scheduledTask','desktopShortcut','sunshine','sunshineConfig') -notcontains $change) {
            throw "ジャーナルに不明な変更があります。システムは変更していません: $change"
        }
        if ($null -eq $state.PSObject.Properties[$change] -or $null -eq $state.$change) {
            throw "復元に必要な状態がありません。システムは変更していません: $change"
        }
    }
    if (-not $PSCmdlet.ShouldProcess($state.installRoot, 'ChildStreamを保存状態へ復元してアンインストール')) { return }

    $stateDirectory = Split-Path -Parent $StatePath
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path (Join-Path $stateDirectory 'Backups') $timestamp
    if (Test-Path -LiteralPath $backupDirectory) { $backupDirectory = "$backupDirectory-$([Guid]::NewGuid().ToString('N'))" }
    [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null

    $sunshinePath = [string]$state.sunshine.Path
    $sunshineWasInstalled = $null -ne (@($journal.entries) | Where-Object { $_.change -eq 'sunshine' } | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($sunshinePath) -and (Test-Path -LiteralPath $sunshinePath -PathType Container)) {
        $destination = Join-Path $backupDirectory 'Current-Sunshine'
        if ($sunshineWasInstalled) { Move-Item -LiteralPath $sunshinePath -Destination $destination -ErrorAction Stop }
        else { Copy-Item -LiteralPath $sunshinePath -Destination $destination -Recurse -Force -ErrorAction Stop }
    }
    foreach ($fileName in @('ChildStream.exe','autostart.log')) {
        $path = Join-Path ([string]$state.installRoot) $fileName
        if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination (Join-Path $backupDirectory $fileName) -Force -ErrorAction Stop }
    }

    Restore-ChildStreamState -State $state -JournalPath $journalPath

    Move-Item -LiteralPath $StatePath -Destination (Join-Path $backupDirectory 'install-state.json') -ErrorAction Stop
    Move-Item -LiteralPath $journalPath -Destination (Join-Path $backupDirectory 'install-journal.json') -ErrorAction Stop
    Write-Host "アンインストールと復元が完了しました。監査バックアップ: $backupDirectory"
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { throw 'ProgramDataが利用できません。' }
    $statePath = Join-Path $env:ProgramData 'ChildStream\install-state.json'
    Invoke-ChildStreamUninstall -StatePath $statePath -WhatIf:$WhatIfPreference -Confirm:$false
}
