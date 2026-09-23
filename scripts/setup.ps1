[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('HighestTask','PromptedStartup')][string]$AutostartMode = 'HighestTask',
    [switch]$ReplaceExistingSunshine
)

$ErrorActionPreference = 'Stop'
$script:SunshineVersion = 'v2026.914.233613'
$script:SunshineAsset = 'Sunshine-Windows-AMD64-lite.zip'
$script:SunshineUri = "https://github.com/LizardByte/Sunshine/releases/download/$script:SunshineVersion/$script:SunshineAsset"
$script:SunshineSha256 = '233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b'
$script:FirewallDisplayName = 'ChildStream Sunshine'
$script:FirewallRuleName = 'ChildStream-Sunshine'
$script:ScheduledTaskName = 'ChildStream Sunshine'
Import-Module (Join-Path $PSScriptRoot 'ChildStream.Setup.psm1') -Force

function Assert-ChildStreamAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'このセットアップは管理者として実行してください。' }
}

function Expand-VerifiedSunshine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$Destination)
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne $script:SunshineSha256) { throw "SunshineのSHA-256が一致しません: $actual" }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -Force -ErrorAction Stop
    [pscustomobject]@{ version=$script:SunshineVersion; asset=$script:SunshineAsset; sha256=$script:SunshineSha256 } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'childstream-version.json') -Encoding UTF8
}

function New-ChildStreamSetupStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("ChildStream-" + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    try {
        $stagedLauncher = Join-Path $stageRoot 'ChildStream.exe'
        $csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw 'C#コンパイラが見つかりません。' }
        $sources = Get-ChildItem (Join-Path $Root 'src\*.cs') -ErrorAction Stop | ForEach-Object FullName
        if (@($sources).Count -eq 0) { throw 'C#ソースが見つかりません。' }
        $iconArg = if (Test-Path (Join-Path $Root 'app.ico')) { "/win32icon:$(Join-Path $Root 'app.ico')" } else { $null }
        & $csc /nologo /target:winexe $iconArg "/out:$stagedLauncher" `
            /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Security.dll `
            /r:System.Runtime.Serialization.dll /r:Microsoft.CSharp.dll $sources
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stagedLauncher -PathType Leaf)) { throw 'ChildStream.exeのコンパイルに失敗しました。' }
        $archive = Join-Path $stageRoot $script:SunshineAsset
        Invoke-WebRequest -Uri $script:SunshineUri -OutFile $archive -UseBasicParsing -ErrorAction Stop
        $stagedSunshine = Join-Path $stageRoot 'Sunshine'
        Expand-VerifiedSunshine -ArchivePath $archive -Destination $stagedSunshine
        if (-not (Test-Path -LiteralPath (Join-Path $stagedSunshine 'Sunshine\sunshine.exe') -PathType Leaf)) { throw '検証済みSunshineにsunshine.exeがありません。' }
        [pscustomobject]@{ Root=$stageRoot; Launcher=$stagedLauncher; Sunshine=$stagedSunshine }
    }
    catch {
        if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function New-ChildStreamFileSnapshot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BackupPath)
    [pscustomobject]@{ ResourceType='File'; Path=$Path; BackupPath=$BackupPath; Existed=(Test-Path -LiteralPath $Path -PathType Leaf) }
}

function Set-VerifiedRegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value,
          [Parameter(Mandatory)][string]$JournalPath, [Parameter(Mandatory)][string]$Change)
    Start-ChildStreamChange -Path $JournalPath -Change $Change
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type DWord -ErrorAction Stop
    $readBack = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    if ([int]$readBack.$Name -ne $Value) { throw "レジストリ値の確認に失敗しました: $Path\$Name" }
    Complete-ChildStreamChange -Path $JournalPath -Change $Change
}

function Set-ChildStreamFirewall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SunshineExe)
    foreach ($rule in @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.DisplayName -eq $script:FirewallDisplayName })) {
        Remove-NetFirewallRule -Name $rule.Name -PolicyStore PersistentStore -ErrorAction Stop
    }
    New-NetFirewallRule -Name $script:FirewallRuleName -DisplayName $script:FirewallDisplayName -Direction Inbound -Action Allow `
        -Profile Private -RemoteAddress LocalSubnet -Program $SunshineExe -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
}

function Set-ChildStreamScheduledTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$UserName)
    $scriptPath = Join-Path $Root 'scripts\childsession-autostart.ps1'
    $argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -LaunchMode HighestTask"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest
    Invoke-ChildStreamRegisterScheduledTask -Action $action -Trigger $trigger -Principal $principal
}

function Invoke-ChildStreamRegisterScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Trigger,
        [Parameter(Mandatory)]$Principal
    )
    Register-ScheduledTask -TaskName $script:ScheduledTaskName -Action $Action -Trigger $Trigger -Principal $Principal -Force -ErrorAction Stop | Out-Null
}

function Set-ChildStreamStartupHook {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $scriptPath = Join-Path $Root 'scripts\childsession-autostart.ps1'
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -LaunchMode PromptedStartup" |
        Set-Content -LiteralPath $Path -Encoding ASCII -ErrorAction Stop
}

function Install-ChildStreamFile {
    param($Snapshot, [Parameter(Mandatory)][string]$Source)
    if ([bool]$Snapshot.Existed) { Backup-FileResource -Path $Snapshot.Path -BackupPath $Snapshot.BackupPath | Out-Null }
    $directory = Split-Path -Parent $Snapshot.Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Snapshot.Path -Force -ErrorAction Stop
}

function Invoke-ChildStreamSetup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$InstallRoot,
          [ValidateSet('HighestTask','PromptedStartup')][string]$AutostartMode='HighestTask', [switch]$ReplaceExistingSunshine)
    if (-not $PSCmdlet.ShouldProcess($InstallRoot, 'ChildStreamを安全にセットアップ')) { return }
    Assert-ChildStreamAdministrator
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { throw 'ProgramDataが利用できません。' }
    $stage = New-ChildStreamSetupStage -Root $InstallRoot
    $stateDirectory = Join-Path $env:ProgramData 'ChildStream'
    $statePath = Join-Path $stateDirectory 'install-state.json'; $journalPath = Join-Path $stateDirectory 'install-journal.json'
    $backupRoot = Join-Path $stateDirectory 'Backups'
    $startupHookPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\childstream-sunshine.cmd'
    $desktopPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Child Session.lnk'
    $launcherPath = Join-Path $InstallRoot 'ChildStream.exe'; $sunshinePath = Join-Path $InstallRoot 'Sunshine'
    $sunshineDirectoryExists = Test-Path -LiteralPath $sunshinePath -PathType Container
    $sunshineExists = Test-Path -LiteralPath (Join-Path $sunshinePath 'Sunshine\sunshine.exe') -PathType Leaf
    $replaceSunshine = $false
    if ($sunshineDirectoryExists) {
        try {
            $version = Get-Content -LiteralPath (Join-Path $sunshinePath 'childstream-version.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $matches = $sunshineExists -and $version.version -eq $script:SunshineVersion -and $version.sha256 -eq $script:SunshineSha256
        } catch { $matches = $false }
        if (-not $matches -and -not $ReplaceExistingSunshine) { throw '既存Sunshineは固定バージョンと一致しません。-ReplaceExistingSunshineを明示してください。' }
        $replaceSunshine = -not $matches
    }
    $state = New-ChildStreamInstallState -InstallRoot $InstallRoot -LauncherPath $stage.Launcher `
        -FirewallDisplayName $script:FirewallDisplayName -ScheduledTaskName $script:ScheduledTaskName
    $state | Add-Member -NotePropertyName launcher -NotePropertyValue (New-ChildStreamFileSnapshot $launcherPath (Join-Path $backupRoot 'ChildStream.exe'))
    $state.startupHook = New-ChildStreamFileSnapshot $startupHookPath (Join-Path $backupRoot 'childstream-sunshine.cmd')
    $state.desktopShortcut = New-ChildStreamFileSnapshot $desktopPath (Join-Path $backupRoot 'Child Session.lnk')
    $state.sunshine = [pscustomobject]@{ ResourceType='Directory'; Path=$sunshinePath; BackupPath=(Join-Path $backupRoot 'Sunshine'); Existed=$sunshineDirectoryExists }
    $sunshineConfigPath = Join-Path $sunshinePath 'Sunshine\config\sunshine.conf'
    $state | Add-Member -NotePropertyName sunshineConfig -NotePropertyValue (New-ChildStreamFileSnapshot $sunshineConfigPath (Join-Path $backupRoot 'sunshine.conf'))
    Save-ChildStreamInstallStateOnce -State $state -Path $statePath
    Save-ChildStreamInstallJournalOnce -Path $journalPath
    $changesStarted = $true
    try {
        Start-ChildStreamChange $journalPath 'launcher'; Install-ChildStreamFile $state.launcher $stage.Launcher; Complete-ChildStreamChange $journalPath 'launcher'
        if (-not $sunshineDirectoryExists -or $replaceSunshine) {
            Start-ChildStreamChange $journalPath 'sunshine'
            if ($replaceSunshine) {
                if (Test-Path $state.sunshine.BackupPath) { throw '既存Sunshineのバックアップ先がすでに存在します。' }
                [IO.Directory]::CreateDirectory((Split-Path -Parent $state.sunshine.BackupPath)) | Out-Null
                Move-Item $sunshinePath $state.sunshine.BackupPath -ErrorAction Stop
            }
            Move-Item $stage.Sunshine $sunshinePath -ErrorAction Stop; Complete-ChildStreamChange $journalPath 'sunshine'
        }
        Set-VerifiedRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0 $journalPath 'registry:fDenyTSConnections'
        Set-VerifiedRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' 'DWMFRAMEINTERVAL' 8 $journalPath 'registry:DWMFRAMEINTERVAL'
        Set-VerifiedRegistryValue 'HKCU:\Software\Microsoft\Terminal Server Client' 'RemoteDesktop_SuppressWhenMinimized' 2 $journalPath 'registry:RemoteDesktop_SuppressWhenMinimized'
        Start-ChildStreamChange $journalPath 'childSessions'
        $enable = Start-Process $launcherPath '-enable' -Wait -PassThru -ErrorAction Stop
        if ($enable.ExitCode -ne 0) { throw 'Child Sessionsを有効化できません。' }
        $check = Start-Process $launcherPath '-check' -Wait -PassThru -ErrorAction Stop
        if ($check.ExitCode -ne 0) { throw 'Child Sessionsの有効化を確認できません。' }
        Complete-ChildStreamChange $journalPath 'childSessions'
        Start-ChildStreamChange $journalPath 'firewall' @($script:FirewallRuleName)
        Set-ChildStreamFirewall (Join-Path $sunshinePath 'Sunshine\sunshine.exe'); Complete-ChildStreamChange $journalPath 'firewall'
        Start-ChildStreamChange $journalPath 'startupHook'
        if ($state.startupHook.Existed) { Backup-FileResource $startupHookPath $state.startupHook.BackupPath | Out-Null }
        if ($AutostartMode -eq 'PromptedStartup') { Set-ChildStreamStartupHook $InstallRoot $startupHookPath }
        elseif (Test-Path $startupHookPath) { Remove-Item $startupHookPath -Force -ErrorAction Stop }
        Complete-ChildStreamChange $journalPath 'startupHook'
        Start-ChildStreamChange $journalPath 'scheduledTask'
        if ($AutostartMode -eq 'HighestTask') { Set-ChildStreamScheduledTask $InstallRoot ([Security.Principal.WindowsIdentity]::GetCurrent().Name) }
        else {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $script:ScheduledTaskName })
            if ($tasks.Count -gt 0) { Unregister-ScheduledTask $script:ScheduledTaskName -Confirm:$false -ErrorAction Stop }
        }
        Complete-ChildStreamChange $journalPath 'scheduledTask'
        $config = Join-Path $sunshinePath 'Sunshine\config'; [IO.Directory]::CreateDirectory($config) | Out-Null
        if ($sunshineDirectoryExists -and -not $replaceSunshine) {
            Start-ChildStreamChange $journalPath 'sunshineConfig'
            if ($state.sunshineConfig.Existed) { Backup-FileResource $sunshineConfigPath $state.sunshineConfig.BackupPath | Out-Null }
        }
        "sunshine_name = $env:COMPUTERNAME-Child`r`nport = 48989`r`ncapture = wgc`r`n" | Set-Content $sunshineConfigPath -Encoding ASCII
        if ($sunshineDirectoryExists -and -not $replaceSunshine) { Complete-ChildStreamChange $journalPath 'sunshineConfig' }
        Start-ChildStreamChange $journalPath 'desktopShortcut'
        if ($state.desktopShortcut.Existed) { Backup-FileResource $desktopPath $state.desktopShortcut.BackupPath | Out-Null }
        $shell = New-Object -ComObject WScript.Shell; $shortcut = $shell.CreateShortcut($desktopPath)
        $shortcut.TargetPath=$launcherPath; $shortcut.WorkingDirectory=$InstallRoot; $shortcut.Description='Second desktop for game streaming'; $shortcut.Save()
        Complete-ChildStreamChange $journalPath 'desktopShortcut'
    }
    catch {
        $original = $_
        if ($changesStarted) {
            try { Restore-ChildStreamState -State $state -JournalPath $journalPath }
            catch { throw "セットアップ失敗後のrollbackにも失敗しました。元: $($original.Exception.Message) / rollback: $($_.Exception.Message)" }
        }
        throw $original
    }
    finally { if ($null -ne $stage -and (Test-Path $stage.Root)) { Remove-Item $stage.Root -Recurse -Force -ErrorAction SilentlyContinue } }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ChildStreamSetup -InstallRoot (Split-Path $PSScriptRoot -Parent) -AutostartMode $AutostartMode `
        -ReplaceExistingSunshine:$ReplaceExistingSunshine -WhatIf:$WhatIfPreference
}
