Set-StrictMode -Version 2.0

function Write-ChildStreamJsonAtomic {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$temporaryPath.bak"
    try {
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try { $writer.Write(($Value | ConvertTo-Json -Depth 20)); $writer.Flush(); $stream.Flush($true) }
            finally { $writer.Dispose() }
        }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
    }
}

function Save-ChildStreamInstallStateOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Path)
    if ([IO.File]::Exists($Path)) {
        try { $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "既存のインストール状態を検証できません: $($_.Exception.Message)" }
        if ($existing.schemaVersion -ne 1) { throw '既存のインストール状態のスキーマが不正です。' }
        throw '最初のインストール状態は上書きできません。'
    }
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try { $writer.Write(($State | ConvertTo-Json -Depth 20)); $writer.Flush(); $stream.Flush($true) }
            finally { $writer.Dispose() }
        }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
        [IO.File]::Move($temporaryPath, $Path)
    }
    finally { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } }
}

function New-ChildStreamJournal {
    [pscustomobject]@{ schemaVersion = 1; entries = @() }
}

function Save-ChildStreamInstallJournalOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Save-ChildStreamInstallStateOnce -State (New-ChildStreamJournal) -Path $Path
}

function Read-ChildStreamInstallJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try { $journal = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "インストールジャーナルを読み取れません: $($_.Exception.Message)" }
    if ($journal.schemaVersion -ne 1 -or $null -eq $journal.PSObject.Properties['entries']) {
        throw 'インストールジャーナルの形式が不正です。'
    }
    foreach ($entry in @($journal.entries)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.change) -or @('pending','applied') -notcontains [string]$entry.status) {
            throw 'インストールジャーナルの項目が不正です。'
        }
    }
    return $journal
}

function Invoke-WithChildStreamJournalLock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Action)
    $lockPath = "$Path.lock"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lockStream = $null
    while ($null -eq $lockStream) {
        try { $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($timer.ElapsedMilliseconds -ge 5000) { throw 'インストールジャーナルのロックを取得できません。' }
            Start-Sleep -Milliseconds 50
        }
    }
    try { & $Action }
    finally { $lockStream.Dispose() }
}

function Start-ChildStreamChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Change,
        [string[]]$CreatedFirewallRuleNames = @()
    )
    Invoke-WithChildStreamJournalLock -Path $Path -Action {
        $journal = Read-ChildStreamInstallJournal -Path $Path
        $entries = @($journal.entries)
        $entry = $entries | Where-Object { $_.change -eq $Change } | Select-Object -First 1
        if ($null -eq $entry) {
            $entry = [pscustomobject]@{ change=$Change; status='pending'; createdFirewallRuleNames=@() }
            $entries += $entry
        }
        $entry.createdFirewallRuleNames = @(@($entry.createdFirewallRuleNames) + @($CreatedFirewallRuleNames) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $journal.entries = $entries
        Write-ChildStreamJsonAtomic -Value $journal -Path $Path
    }
}

function Complete-ChildStreamChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Change)
    Invoke-WithChildStreamJournalLock -Path $Path -Action {
        $journal = Read-ChildStreamInstallJournal -Path $Path
        $entry = @($journal.entries) | Where-Object { $_.change -eq $Change } | Select-Object -First 1
        if ($null -eq $entry) { throw "予約されていない変更です: $Change" }
        $entry.status = 'applied'
        Write-ChildStreamJsonAtomic -Value $journal -Path $Path
    }
}

function Get-RegistryValueSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    $exists = @($key.GetValueNames()) -contains $Name
    if (-not $exists) { return [pscustomobject]@{ Path=$Path; Name=$Name; Existed=$false } }
    [pscustomobject]@{
        Path=$Path; Name=$Name; Existed=$true
        Value=$key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind=[string]$key.GetValueKind($Name)
    }
}

function Restore-RegistryValueSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    if (-not [bool]$Snapshot.Existed) {
        Remove-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -ErrorAction SilentlyContinue
        try {
            $current = Get-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -ErrorAction Stop
            if ($null -ne $current.PSObject.Properties[$Snapshot.Name]) { throw '値が残っています。' }
        }
        catch [Management.Automation.ItemNotFoundException] { return }
        catch {
            if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return }
            throw
        }
        throw "レジストリ値を削除できません: $($Snapshot.Path)\$($Snapshot.Name)"
    }
    Set-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -Value $Snapshot.Value -Type $Snapshot.Kind -ErrorAction Stop
}

function Assert-ChildStreamFirewallSnapshotRestorable {
    param($Snapshot)
    if (-not [string]::IsNullOrWhiteSpace([string]$Snapshot.Description) -or -not [string]::IsNullOrWhiteSpace([string]$Snapshot.Group)) {
        throw "Firewall規則 '$($Snapshot.Name)' には未対応の説明またはグループがあります。"
    }
    if ($null -ne $Snapshot.Package -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.Package)) {
        throw "Firewall規則 '$($Snapshot.Name)' には未対応のPackage条件があります。"
    }
    if (@('Any','') -notcontains [string]$Snapshot.DynamicTarget) {
        throw "Firewall規則 '$($Snapshot.Name)' には未対応のDynamicTargetがあります。"
    }
}

function Get-FirewallRuleSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DisplayName)
    $result = @()
    $allRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop)
    foreach ($rule in @($allRules | Where-Object { $_.DisplayName -eq $DisplayName })) {
        $app = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $address = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $service = Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $interface = Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $security = Get-NetFirewallSecurityFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
        $snapshot = [pscustomobject]@{
            Name=[string]$rule.Name; DisplayName=[string]$rule.DisplayName; Enabled=[string]$rule.Enabled
            Direction=[string]$rule.Direction; Action=[string]$rule.Action; Profile=[string]$rule.Profile
            EdgeTraversalPolicy=[string]$rule.EdgeTraversalPolicy; Description=[string]$rule.Description; Group=[string]$rule.Group
            Program=[string]$app.Program; Package=$app.Package
            LocalAddress=@($address.LocalAddress); RemoteAddress=@($address.RemoteAddress)
            Protocol=[string]$port.Protocol; LocalPort=@($port.LocalPort); RemotePort=@($port.RemotePort)
            IcmpType=@($port.IcmpType); DynamicTarget=[string]$port.DynamicTarget; Service=[string]$service.Service
            InterfaceAlias=@($interface.InterfaceAlias); InterfaceType=[string]$interface.InterfaceType
            Authentication=[string]$security.Authentication; Encryption=[string]$security.Encryption
            OverrideBlockRules=([string]$security.OverrideBlockRules -eq 'True'); LocalUser=[string]$security.LocalUser
            RemoteUser=[string]$security.RemoteUser; RemoteMachine=[string]$security.RemoteMachine
        }
        Assert-ChildStreamFirewallSnapshotRestorable -Snapshot $snapshot
        $result += $snapshot
    }
    return $result
}

function Remove-ChildStreamFirewallRuleByName {
    param([Parameter(Mandatory)][string]$Name)
    $existing = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($null -eq $existing) { return }
    if ($existing.Count -eq 0) { return }
    Remove-NetFirewallRule -Name $Name -PolicyStore PersistentStore -ErrorAction Stop
    $remaining = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($remaining.Count -ne 0) {
        throw "Firewall規則を削除できません: $Name"
    }
}

function Restore-FirewallRuleSnapshot {
    [CmdletBinding()]
    param([object[]]$Snapshot=@(), [string[]]$CreatedRuleNames=@())
    foreach ($item in @($Snapshot)) { Assert-ChildStreamFirewallSnapshotRestorable -Snapshot $item }
    foreach ($name in @($CreatedRuleNames | Select-Object -Unique)) { Remove-ChildStreamFirewallRuleByName -Name $name }
    foreach ($item in @($Snapshot)) { Remove-ChildStreamFirewallRuleByName -Name $item.Name }
    foreach ($item in @($Snapshot)) {
        $parameters = @{
            Name=$item.Name; DisplayName=$item.DisplayName; Enabled=$item.Enabled; Direction=$item.Direction
            Action=$item.Action; Profile=$item.Profile; Program=$item.Program; LocalAddress=$item.LocalAddress
            RemoteAddress=$item.RemoteAddress; Protocol=$item.Protocol; LocalPort=$item.LocalPort
            RemotePort=$item.RemotePort; IcmpType=$item.IcmpType; Service=$item.Service
            InterfaceAlias=$item.InterfaceAlias; InterfaceType=$item.InterfaceType; PolicyStore='PersistentStore'; ErrorAction='Stop'
        }
        foreach ($name in @('Authentication','Encryption','LocalUser','RemoteUser','RemoteMachine')) {
            $value = $item.PSObject.Properties[$name]
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) { $parameters[$name] = $value.Value }
        }
        if ($null -ne $item.PSObject.Properties['OverrideBlockRules'] -and [bool]$item.OverrideBlockRules) {
            $parameters.OverrideBlockRules = $true
        }
        if ([string]$item.Direction -eq 'Inbound') { $parameters.EdgeTraversalPolicy = $item.EdgeTraversalPolicy }
        New-NetFirewallRule @parameters | Out-Null
    }
}

function Backup-FileResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BackupPath)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ Path=$Path; BackupPath=$BackupPath; Existed=$false } }
    $directory = Split-Path -Parent $BackupPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $input = $null; $output = $null
    try {
        $input = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $output = [IO.File]::Open($BackupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $input.CopyTo($output); $output.Flush($true)
    }
    catch { if ([IO.File]::Exists($BackupPath) -and $null -ne $output) { $output.Dispose(); $output=$null; [IO.File]::Delete($BackupPath) }; throw }
    finally { if ($null -ne $output) { $output.Dispose() }; if ($null -ne $input) { $input.Dispose() } }
    [pscustomobject]@{ Path=$Path; BackupPath=$BackupPath; Existed=$true }
}

function Restore-FileResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    if ([bool]$Snapshot.Existed) {
        if (-not [IO.File]::Exists([string]$Snapshot.BackupPath)) { throw "バックアップがありません: $($Snapshot.BackupPath)" }
        Copy-Item -LiteralPath $Snapshot.BackupPath -Destination $Snapshot.Path -Force -ErrorAction Stop
    }
    elseif ([IO.File]::Exists([string]$Snapshot.Path)) { Remove-Item -LiteralPath $Snapshot.Path -Force -ErrorAction Stop }
}

function Restore-ChildSessionEnabledState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][string]$LauncherPath)
    $argument = if ($Enabled) { '-enable' } else { '-disable' }
    $change = Start-Process -FilePath $LauncherPath -ArgumentList $argument -Wait -PassThru -ErrorAction Stop
    if ($change.ExitCode -ne 0) { throw "Child Sessionsの復元に失敗しました: $($change.ExitCode)" }
    $check = Start-Process -FilePath $LauncherPath -ArgumentList '-check' -Wait -PassThru -ErrorAction Stop
    $expected = if ($Enabled) { 0 } else { 1 }
    if ($check.ExitCode -ne $expected) { throw "Child Sessionsの復元確認に失敗しました: $($check.ExitCode)" }
}

function Get-ScheduledTaskSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskName)
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $TaskName })
    if ($tasks.Count -eq 0) { return [pscustomobject]@{ TaskName=$TaskName; Existed=$false } }
    if ($tasks.Count -ne 1) { throw "同名のScheduled Taskが複数あります: $TaskName" }
    $task = $tasks[0]
    [pscustomobject]@{ TaskName=$TaskName; Existed=$true; Xml=(Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop) }
}

function Restore-ScheduledTaskSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    if ([bool]$Snapshot.Existed) {
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.Xml)) { throw 'Scheduled TaskのXMLがありません。' }
        Register-ScheduledTask -TaskName $Snapshot.TaskName -Xml $Snapshot.Xml -Force -ErrorAction Stop | Out-Null
        if ($null -eq (Get-ScheduledTask -TaskName $Snapshot.TaskName -ErrorAction Stop)) { throw 'Scheduled Taskを復元できません。' }
        return
    }
    $current = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $Snapshot.TaskName })
    if ($current.Count -gt 0) { Unregister-ScheduledTask -TaskName $Snapshot.TaskName -Confirm:$false -ErrorAction Stop }
    $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $Snapshot.TaskName })
    if ($remaining.Count -ne 0) { throw 'Scheduled Taskを削除できません。' }
}

function New-ChildStreamInstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$FirewallDisplayName='ChildStream Sunshine',
        [string]$ScheduledTaskName='ChildStream Sunshine'
    )
    $launcherPath = Join-Path $InstallRoot 'ChildStream.exe'
    $check = Start-Process -FilePath $launcherPath -ArgumentList '-check' -Wait -PassThru -ErrorAction Stop
    if (@(0,1) -notcontains $check.ExitCode) { throw "Child Sessionsの状態を取得できません: $($check.ExitCode)" }
    [pscustomobject]@{
        schemaVersion=1; installRoot=$InstallRoot; capturedAtUtc=[DateTime]::UtcNow.ToString('o')
        childSessionsEnabled=($check.ExitCode -eq 0)
        registry=@(
            Get-RegistryValueSnapshot -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections'
            Get-RegistryValueSnapshot -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'DWMFRAMEINTERVAL'
            Get-RegistryValueSnapshot -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name 'RemoteDesktop_SuppressWhenMinimized'
        )
        firewall=@(Get-FirewallRuleSnapshot -DisplayName $FirewallDisplayName)
        startupHook=$null; scheduledTask=(Get-ScheduledTaskSnapshot -TaskName $ScheduledTaskName)
        desktopShortcut=$null; sunshine=$null; createdArtifacts=@()
    }
}

function Restore-ChildStreamState {
    [CmdletBinding(DefaultParameterSetName='Journal')]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory,ParameterSetName='Journal')][string]$JournalPath,
        [Parameter(Mandatory,ParameterSetName='Legacy')][string[]]$AppliedChanges
    )
    $entries = @()
    if ($PSCmdlet.ParameterSetName -eq 'Journal') { $entries = @(Read-ChildStreamInstallJournal -Path $JournalPath).entries }
    else { $entries = @($AppliedChanges | ForEach-Object { [pscustomobject]@{ change=$_; status='applied'; createdFirewallRuleNames=@() } }) }
    [array]::Reverse($entries)
    foreach ($entry in $entries) {
        $change = [string]$entry.change
        switch -Wildcard ($change) {
            'registry:*' {
                $name = $change.Substring('registry:'.Length)
                $snapshot = @($State.registry) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($null -eq $snapshot) { throw "レジストリ状態がありません: $name" }
                Restore-RegistryValueSnapshot -Snapshot $snapshot
            }
            'firewall' { Restore-FirewallRuleSnapshot -Snapshot @($State.firewall) -CreatedRuleNames @($entry.createdFirewallRuleNames) }
            'childSessions' { Restore-ChildSessionEnabledState -Enabled ([bool]$State.childSessionsEnabled) -LauncherPath (Join-Path $State.installRoot 'ChildStream.exe') }
            'startupHook' { Restore-FileResource -Snapshot $State.startupHook }
            'scheduledTask' { Restore-ScheduledTaskSnapshot -Snapshot $State.scheduledTask }
            'desktopShortcut' { Restore-FileResource -Snapshot $State.desktopShortcut }
            'sunshine' { Restore-FileResource -Snapshot $State.sunshine }
            'createdArtifacts' {
                foreach ($path in @($State.createdArtifacts)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -Recurse -ErrorAction Stop } }
            }
            default { throw "不明な変更項目です: $change" }
        }
    }
}

Export-ModuleMember -Function @(
    'New-ChildStreamInstallState','Save-ChildStreamInstallStateOnce','Save-ChildStreamInstallJournalOnce',
    'Read-ChildStreamInstallJournal','Start-ChildStreamChange','Complete-ChildStreamChange',
    'Get-RegistryValueSnapshot','Restore-RegistryValueSnapshot','Restore-ChildSessionEnabledState',
    'Get-FirewallRuleSnapshot','Restore-FirewallRuleSnapshot','Backup-FileResource','Restore-FileResource',
    'Get-ScheduledTaskSnapshot','Restore-ScheduledTaskSnapshot','Restore-ChildStreamState'
)
