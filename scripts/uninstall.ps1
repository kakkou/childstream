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

function Assert-ChildStreamUninstallPreconditions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Journal)

    if ($State.childSessionsEnabled -isnot [bool]) { throw 'Child Sessionsの保存状態が不正です。' }
    foreach ($registry in @($State.registry)) {
        foreach ($name in @('Path','Name','Existed')) {
            if ($null -eq $registry.PSObject.Properties[$name]) { throw "レジストリ状態に必須項目がありません: $name" }
        }
        if ($registry.Existed -isnot [bool]) { throw "レジストリ状態のExistedが不正です: $($registry.Name)" }
        if ([bool]$registry.Existed -and ($null -eq $registry.PSObject.Properties['Value'] -or [string]::IsNullOrWhiteSpace([string]$registry.Kind))) {
            throw "レジストリ状態に復元値がありません: $($registry.Name)"
        }
    }
    foreach ($firewall in @($State.firewall)) {
        foreach ($name in @('Name','DisplayName','Enabled','Direction','Action','Profile')) {
            if ($null -eq $firewall.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$firewall.$name)) {
                throw "Firewall状態に必須項目がありません: $name"
            }
        }
    }

    $changedResourceNames = @($Journal.entries | ForEach-Object { [string]$_.change })
    $resourceNames = @('launcher','startupHook','desktopShortcut','sunshine')
    if ($null -ne $State.PSObject.Properties['sunshineConfig'] -or $changedResourceNames -contains 'sunshineConfig') { $resourceNames += 'sunshineConfig' }
    foreach ($resourceName in $resourceNames) {
        $resource = $State.$resourceName
        foreach ($name in @('Path','Existed')) {
            if ($null -eq $resource -or $null -eq $resource.PSObject.Properties[$name] -or
                ($name -eq 'Path' -and [string]::IsNullOrWhiteSpace([string]$resource.Path))) {
                throw "$resourceName の状態に必須項目がありません: $name"
            }
        }
        if ($resource.Existed -isnot [bool]) { throw "$resourceName のExistedが不正です。" }
        if ([bool]$resource.Existed -and $changedResourceNames -contains $resourceName) {
            if ($null -eq $resource.PSObject.Properties['BackupPath'] -or [string]::IsNullOrWhiteSpace([string]$resource.BackupPath)) {
                throw "$resourceName のバックアップ先がありません。"
            }
            $backupExists = if ($resourceName -eq 'sunshine') {
                Test-Path -LiteralPath $resource.BackupPath -PathType Container
            } else {
                Test-Path -LiteralPath $resource.BackupPath -PathType Leaf
            }
            if (-not $backupExists) { throw "$resourceName のバックアップが見つかりません。" }
        }
    }

    foreach ($name in @('TaskName','Existed')) {
        if ($null -eq $State.scheduledTask -or $null -eq $State.scheduledTask.PSObject.Properties[$name]) {
            throw "Scheduled Task状態に必須項目がありません: $name"
        }
    }
    if ($State.scheduledTask.Existed -isnot [bool]) { throw 'Scheduled Task状態のExistedが不正です。' }
    if ([bool]$State.scheduledTask.Existed -and [string]::IsNullOrWhiteSpace([string]$State.scheduledTask.Xml)) {
        throw 'Scheduled Task状態のXMLがありません。'
    }
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
    Assert-ChildStreamUninstallPreconditions -State $state -Journal $journal
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
