# Windows実機確認フロー

この文書は、ChildStreamの安全性に関わる第1段階の改修をWindows実機で確認するためのチェックリストです。コマンドは、特記がない限りリポジトリのルートで起動した**管理者権限のWindows PowerShell 5.1**から実行します。

## 0. 安全条件とテスト構成

次の条件を満たさない場合は、確認を開始しないでください。

- Windows 10／11 Proのテスト用PC、または復元可能なバックアップがあるPCを使用する。
- 物理コンソール、通常RDP、Child Sessionを区別して確認できるようにする。
- Moonlightを動かす同一LAN内の別端末を用意する。
- BitLocker回復キーなど、Windowsへ再入場するために必要な情報を確保する。
- 実行中のアプリを保存し、テスト中にログオフしても問題ない状態にする。
- 唯一のリモート接続経路しかないPCでは、Firewall、End session、uninstall／rollbackの試験を行わない。

次のいずれかが発生した場合は、その時点で後続試験を中止し、[異常時の証跡採取](#11-異常時の証跡採取)へ進みます。

- 物理コンソールまたは通常RDPでChildStream用Sunshineが起動した。
- Firewall規則がPublic、Any、インターネット全体のいずれかに公開されている。
- 「End session」でChild Session以外がログオフされた。
- SunshineのバージョンまたはSHA-256が固定値と一致しない。
- `install-state.json`または`install-journal.json`がない、壊れている、内容が想定と異なる。
- setup／uninstallがエラーを表示し、rollbackの完了も確認できない。

## 1. 証跡フォルダーを作成する

以降のPowerShellを同じウィンドウで実行します。

```powershell
$EvidenceRoot = Join-Path $env:USERPROFILE ("Desktop\ChildStream-Verification-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$EvidenceRoot
```

期待結果:

- デスクトップに日時付きの証跡フォルダーが作成される。
- 以降の出力ファイルをこのフォルダーへ保存できる。

## 2. インストール前の状態を記録する

### 2.1 基本情報とセッション

```powershell
Get-ComputerInfo | Out-File (Join-Path $EvidenceRoot 'before-computer-info.txt')
whoami /all | Out-File (Join-Path $EvidenceRoot 'before-whoami.txt')
query session | Out-File (Join-Path $EvidenceRoot 'before-sessions.txt')
Get-Process -Name sunshine -ErrorAction SilentlyContinue |
    Select-Object Id, SessionId, Path, StartTime |
    Format-List | Out-File (Join-Path $EvidenceRoot 'before-sunshine-processes.txt')
```

### 2.2 レジストリ、Firewall、タスク、ファイル

```powershell
function Get-ChildStreamRegistryEvidence {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Existed = $false; Value = $null; Kind = $null }
    }
    $Key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (@($Key.GetValueNames()) -notcontains $Name) {
        return [pscustomobject]@{ Existed = $false; Value = $null; Kind = $null }
    }
    [pscustomobject]@{
        Existed = $true
        Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind = [string]$Key.GetValueKind($Name)
    }
}

$Before = [ordered]@{
    fDenyTSConnections = Get-ChildStreamRegistryEvidence -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
    DWMFRAMEINTERVAL = Get-ChildStreamRegistryEvidence -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name DWMFRAMEINTERVAL
    RemoteDesktop_SuppressWhenMinimized = Get-ChildStreamRegistryEvidence -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name RemoteDesktop_SuppressWhenMinimized
}
$Before | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $EvidenceRoot 'before-registry.json') -Encoding UTF8

Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
    Where-Object DisplayName -eq 'ChildStream Sunshine' |
    Format-List * | Out-File (Join-Path $EvidenceRoot 'before-firewall.txt')

Get-ScheduledTask -TaskName 'ChildStream Sunshine' -ErrorAction SilentlyContinue |
    Export-Clixml (Join-Path $EvidenceRoot 'before-scheduled-task.xml')

Get-Item '.\ChildStream.exe', '.\Sunshine', "$env:ProgramData\ChildStream\install-state.json", "$env:ProgramData\ChildStream\install-journal.json" -Force -ErrorAction SilentlyContinue |
    Select-Object FullName, PSIsContainer, Length, LastWriteTimeUtc |
    Export-Csv (Join-Path $EvidenceRoot 'before-files.csv') -NoTypeInformation -Encoding UTF8
```

合格条件:

- `before-*`の証跡が作成される。
- 既存のChildStreamインストールが見つかった場合は、新規setupを重ねず、先にその導入元と状態を確認する。

## 3. setupの事前確認とインストール

### 3.1 `-WhatIf`を確認する

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\setup.ps1 -AutostartMode HighestTask -WhatIf *>&1 |
    Tee-Object -FilePath (Join-Path $EvidenceRoot 'setup-whatif.txt')
```

期待結果:

- ChildStreamをセットアップする対象が表示される。
- `ChildStream.exe`、Sunshine、レジストリ、Firewall、タスクなどの実変更は行われない。

### 3.2 インストールする

```powershell
.\scripts\setup.ps1 -AutostartMode HighestTask *>&1 |
    Tee-Object -FilePath (Join-Path $EvidenceRoot 'setup.txt')
```

setup開始前からリポジトリ直下の`<リポジトリ>\Sunshine`（この文書では`.\Sunshine`）が存在し、固定配布物と一致せず停止した場合は正常な安全動作です。Windowsへ別途インストールしたSunshineや`Program Files`配下を指すものではありません。setupがエラーなく完了した場合、この確認と`-ReplaceExistingSunshine`は不要です。

不一致エラーが表示された場合だけ、既存配置に残したい設定、資格情報、証明書、独自ファイルがないか確認します。また、既存ディレクトリ全体を`%ProgramData%\ChildStream\Backups\Sunshine`へ退避できる空き容量と、同名バックアップがまだないことを確認します。

```powershell
$ExistingSunshine = '.\Sunshine'
$ExistingBytes = (Get-ChildItem $ExistingSunshine -Recurse -File -ErrorAction Stop |
    Measure-Object Length -Sum).Sum
$ProgramDataDriveName = [IO.Path]::GetPathRoot($env:ProgramData).TrimEnd('\').TrimEnd(':')
$ProgramDataDrive = Get-PSDrive -Name $ProgramDataDriveName

Get-ChildItem $ExistingSunshine -Force
Get-ChildItem (Join-Path $ExistingSunshine 'Sunshine\config') -Force -ErrorAction SilentlyContinue
Get-Content (Join-Path $ExistingSunshine 'childstream-version.json') -Raw -ErrorAction SilentlyContinue
[pscustomobject]@{
    ExistingSunshineMiB = [math]::Round($ExistingBytes / 1MB, 2)
    BackupDriveFreeMiB = [math]::Round($ProgramDataDrive.Free / 1MB, 2)
    BackupAlreadyExists = Test-Path "$env:ProgramData\ChildStream\Backups\Sunshine"
}
```

置換を選ぶ条件は、必要なファイルを別途確保済みで、`BackupDriveFreeMiB`が`ExistingSunshineMiB`より大きく、`BackupAlreadyExists=False`であることです。条件を満たし、既存配置を固定配布物へ置き換えると判断した場合だけ次を実行します。

```powershell
.\scripts\setup.ps1 -AutostartMode HighestTask -ReplaceExistingSunshine
```

合格条件:

- setupがエラーなく完了する。
- `%ProgramData%\ChildStream\install-state.json`と`install-journal.json`が存在する。
- 既存Sunshineの不一致時に、明示指定なしで上書きされない。

状態ファイルには環境固有のパスや設定が含まれるため、公開場所へそのまま添付しないでください。

```powershell
Get-Content "$env:ProgramData\ChildStream\install-state.json" -Raw |
    Set-Content (Join-Path $EvidenceRoot 'after-install-state.json') -Encoding UTF8
Get-Content "$env:ProgramData\ChildStream\install-journal.json" -Raw |
    Set-Content (Join-Path $EvidenceRoot 'after-install-journal.json') -Encoding UTF8
```

## 4. 固定SunshineとFirewallを確認する

### 4.1 バージョン情報

```powershell
$VersionFile = '.\Sunshine\childstream-version.json'
$Version = Get-Content $VersionFile -Raw | ConvertFrom-Json
$Version | Format-List | Out-File (Join-Path $EvidenceRoot 'sunshine-version.txt')
$Version
```

合格条件:

- `version`が`v2026.914.233613`である。
- `asset`が`Sunshine-Windows-AMD64-lite.zip`である。
- `sha256`が`233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b`である。

このSHA-256はダウンロードしたZIPに対する値です。setupは展開前に照合し、不一致ならシステム変更前に停止します。`sunshine.exe`自体のハッシュ値ではありません。

### 4.2 Firewall

```powershell
$Rule = Get-NetFirewallRule -Name 'ChildStream-Sunshine' -PolicyStore PersistentStore
$Address = $Rule | Get-NetFirewallAddressFilter
$Application = $Rule | Get-NetFirewallApplicationFilter

$Rule | Select-Object Name, DisplayName, Enabled, Direction, Action, Profile |
    Format-List | Tee-Object -FilePath (Join-Path $EvidenceRoot 'firewall-rule.txt')
$Address | Select-Object RemoteAddress |
    Format-List | Tee-Object -FilePath (Join-Path $EvidenceRoot 'firewall-address.txt')
$Application | Select-Object Program |
    Format-List | Tee-Object -FilePath (Join-Path $EvidenceRoot 'firewall-program.txt')
```

合格条件:

- `Enabled=True`、`Direction=Inbound`、`Action=Allow`である。
- `Profile=Private`であり、Publicを含まない。
- `RemoteAddress=LocalSubnet`である。
- `Program`がこのリポジトリ配下の`Sunshine\Sunshine\sunshine.exe`である。

## 5. HighestTaskと非Child Sessionでの不起動を確認する

### 5.1 タスク設定

```powershell
$Task = Get-ScheduledTask -TaskName 'ChildStream Sunshine'
$Task | Select-Object TaskName, State |
    Format-List | Tee-Object -FilePath (Join-Path $EvidenceRoot 'scheduled-task.txt')
$Task.Principal | Select-Object UserId, LogonType, RunLevel |
    Format-List | Tee-Object -FilePath (Join-Path $EvidenceRoot 'scheduled-task-principal.txt')
$Task.Triggers | Format-List * |
    Tee-Object -FilePath (Join-Path $EvidenceRoot 'scheduled-task-triggers.txt')
$Task.Actions | Format-List * |
    Tee-Object -FilePath (Join-Path $EvidenceRoot 'scheduled-task-actions.txt')

$ExpectedUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Checks = [ordered]@{
    PrincipalUser = [string]$Task.Principal.UserId -ieq $ExpectedUser
    LogonTypeInteractive = [string]$Task.Principal.LogonType -eq 'Interactive'
    RunLevelHighest = [string]$Task.Principal.RunLevel -eq 'Highest'
    LogonTriggerUser = @($Task.Triggers | Where-Object { [string]$_.UserId -ieq $ExpectedUser }).Count -gt 0
    PowerShellAction = @($Task.Actions | Where-Object { [string]$_.Execute -match '(^|\\)powershell\.exe$' }).Count -gt 0
    ChildSessionAutostart = [string]$Task.Actions.Arguments -match 'childsession-autostart\.ps1'
    HighestTaskMode = [string]$Task.Actions.Arguments -match '-LaunchMode HighestTask'
}
$Checks.GetEnumerator() | Select-Object Name, Value |
    Format-Table -AutoSize | Tee-Object -FilePath (Join-Path $EvidenceRoot 'scheduled-task-checks.txt')
$FailedChecks = @($Checks.GetEnumerator() | Where-Object { -not [bool]$_.Value })
if ($FailedChecks.Count -gt 0) {
    throw "Scheduled Taskの確認に失敗しました: $($FailedChecks.Name -join ', ')"
}
```

`Out-File`は画面に表示せずファイルだけへ保存します。この手順では`Tee-Object`を使用するため、内容を画面で確認しながら同じ証跡ファイルへ保存できます。最後の表がすべて`True`なら合格です。`False`があれば例外で停止します。

合格条件:

- `LogonType=Interactive`、`RunLevel=Highest`である。
- ログオントリガーが現在のWindowsユーザーに限定される。
- 実行引数に`childsession-autostart.ps1`と`-LaunchMode HighestTask`が含まれる。

### 5.2 物理コンソール

1. PCを再起動し、物理コンソールで同じWindowsユーザーへサインインする。
2. 60秒待つ。
3. 通常権限のPowerShellで次を実行する。

```powershell
$CurrentSessionId = (Get-Process -Id $PID).SessionId
Get-Process -Name sunshine -ErrorAction SilentlyContinue |
    Select-Object Id, SessionId, Path, StartTime
"CurrentSessionId=$CurrentSessionId"
```

合格条件:

- 現在のSession IDでChildStream配下の`sunshine.exe`が起動していない。

### 5.3 通常RDP

1. `mstsc.exe`などで通常のRDP接続を行い、同じWindowsユーザーへサインインする。
2. 60秒待つ。
3. RDP内のPowerShellで5.2と同じコマンドを実行する。

合格条件:

- 通常RDPのSession IDでChildStream配下の`sunshine.exe`が起動していない。
- 物理コンソール側にもChildStream用Sunshineが新たに起動していない。

不合格の場合は通常RDPをChild Sessionと誤認している可能性があるため、後続試験を中止します。

## 6. Child SessionでのみSunshineが起動することを確認する

1. 物理コンソールでデスクトップの「Child Session」を起動する。
2. `display.cfg`が有効な値、または未配置であることを確認する。
3. Windowsアカウントのパスワードを入力して接続する。
4. Child Session内でサインイン完了後、最大60秒待つ。
5. Child Session内のPowerShellで次を実行する。

```powershell
$CurrentSessionId = (Get-Process -Id $PID).SessionId
$Sunshine = Get-Process -Name sunshine -ErrorAction Stop
$Sunshine | Select-Object Id, SessionId, Path, StartTime
"CurrentSessionId=$CurrentSessionId"
```

合格条件:

- Sunshineの`SessionId`がChild Session内の`CurrentSessionId`と一致する。
- Sunshineの`Path`がChildStream配下を指す。
- ログオン時にUACプロンプトが表示されない。
- 物理コンソールと通常RDPのSession IDではChildStream用Sunshineが起動していない。

物理コンソール側では起動許可も確認します。値そのものにはプロセス情報が含まれるため、公開前に内容を確認してください。

```powershell
$AuthorizationPath = "$env:LOCALAPPDATA\ChildStream\active-child-session.json"
$Authorization = Get-Content $AuthorizationPath -Raw | ConvertFrom-Json
$Launcher = Get-Process -Id $Authorization.launcherProcessId -ErrorAction Stop

[pscustomobject]@{
    SchemaVersion = $Authorization.schemaVersion
    AuthorizedSessionId = $Authorization.childSessionId
    LauncherProcessId = $Authorization.launcherProcessId
    LauncherStartTimeUtc = $Authorization.launcherStartTimeUtc
    ActualLauncherStartTimeUtc = $Launcher.StartTime.ToUniversalTime().ToString('o')
    IssuedAtUtc = $Authorization.issuedAtUtc
    AgeSeconds = ((Get-Date).ToUniversalTime() - [datetime]$Authorization.issuedAtUtc).TotalSeconds
} | Format-List | Tee-Object -FilePath (Join-Path $EvidenceRoot 'child-session-authorization.txt')
```

確認時点によって`AgeSeconds`は120秒を超えることがあります。重要なのは、Sunshine起動時に発行から120秒以内であり、Session ID、ランチャーPID、ランチャー起動時刻が一致しなければ起動しないことです。

## 7. 配信機能を確認する

1. Child Session内でSunshine Web UIの資格情報を設定する。
2. 同一LAN内のMoonlight／Artemisから`<PC名>-Child`へペアリングする。
3. 配信を開始し、Sunshineログを証跡フォルダーへコピーする。
4. 次を順に確認する。

| 確認項目 | 合格条件 |
| --- | --- |
| WGC | Child Sessionのデスクトップが表示され、黒画面にならない |
| ハードウェアエンコーダー | 使用GPUに応じてNVENC／AMF／QSVの初期化が成功する |
| 映像・音声 | 継続的に配信でき、意図しないコンソール画面が映らない |
| 入力 | Moonlightからマウス、キーボード、ゲームパッドを操作できる |
| 昇格アプリ | 管理者権限で起動したテストアプリへ意図した入力が届く |

この試験では実際のWindowsパスワードやSunshine Web UIパスワードを証跡へ記録しないでください。

## 8. End sessionの隔離を確認する

1. 可能なら物理コンソール、通常RDP、Child Sessionを同時に維持する。
2. 各画面で`(Get-Process -Id $PID).SessionId`を実行し、Session IDを記録する。
3. ChildStreamのトレイメニューから「End session」を選択する。
4. 物理コンソールと通常RDPが操作可能か確認する。
5. 管理者PowerShellで次を実行する。

```powershell
query session | Tee-Object -FilePath (Join-Path $EvidenceRoot 'after-end-session-sessions.txt')
Get-Process -Name sunshine -ErrorAction SilentlyContinue |
    Select-Object Id, SessionId, Path, StartTime |
    Format-List | Out-File (Join-Path $EvidenceRoot 'after-end-session-sunshine.txt')
```

合格条件:

- 記録したChild Sessionだけが終了する。
- 物理コンソールと通常RDPはログオフされず、操作を継続できる。
- Child Sessionで動いていたChildStream用Sunshineが終了する。

Child Session IDの取得に失敗した場合は、別セッションを推測してログオフせず、エラーで停止することが合格です。

## 9. 不正なdisplay.cfgで安全停止することを確認する

ChildStreamとChild Sessionが終了している状態で実行します。

```powershell
if (Test-Path '.\display.cfg') { Copy-Item '.\display.cfg' '.\display.cfg.verification-backup' -Force }
'639x1080' | Set-Content '.\display.cfg' -Encoding ASCII
Remove-Item "$env:LOCALAPPDATA\ChildStream\active-child-session.json" -Force -ErrorAction SilentlyContinue
.\ChildStream.exe
```

合格条件:

- 幅の許容範囲が640～8192である旨のエラーが表示される。
- Windowsパスワードの入力画面へ進まない。
- RDP接続が開始されない。
- `active-child-session.json`が新規作成されない。

確認後に元へ戻します。

```powershell
Remove-Item '.\display.cfg' -Force
if (Test-Path '.\display.cfg.verification-backup') {
    Move-Item '.\display.cfg.verification-backup' '.\display.cfg' -Force
}
```

必要に応じて、`1920x479`、`1920x1080x99`、`1920x1080x501`、`1920x1080x100x1`、`+1920x1080`でも同じ安全停止を確認します。

## 10. uninstall／rollbackを確認する

この試験は、物理コンソールまたは別の復旧経路を確保してから行います。

### 10.1 復元予定を確認する

```powershell
.\scripts\uninstall.ps1 -WhatIf *>&1 |
    Tee-Object -FilePath (Join-Path $EvidenceRoot 'uninstall-whatif.txt')
```

合格条件:

- `install-state.json`と`install-journal.json`を利用する復元対象が表示される。
- `-WhatIf`では実際の変更が行われない。

状態ファイルの片方を一時的に別名へ変更した破損系試験を行う場合、`uninstall.ps1`がシステムを変更せず停止することを確認し、必ず元の名前へ戻してから先へ進みます。

### 10.2 アンインストールする

```powershell
.\scripts\uninstall.ps1 *>&1 |
    Tee-Object -FilePath (Join-Path $EvidenceRoot 'uninstall.txt')
```

### 10.3 インストール前と比較する

```powershell
function Get-ChildStreamRegistryEvidence {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Existed = $false; Value = $null; Kind = $null }
    }
    $Key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (@($Key.GetValueNames()) -notcontains $Name) {
        return [pscustomobject]@{ Existed = $false; Value = $null; Kind = $null }
    }
    [pscustomobject]@{
        Existed = $true
        Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind = [string]$Key.GetValueKind($Name)
    }
}

$After = [ordered]@{
    fDenyTSConnections = Get-ChildStreamRegistryEvidence -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
    DWMFRAMEINTERVAL = Get-ChildStreamRegistryEvidence -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name DWMFRAMEINTERVAL
    RemoteDesktop_SuppressWhenMinimized = Get-ChildStreamRegistryEvidence -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name RemoteDesktop_SuppressWhenMinimized
}
$After | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $EvidenceRoot 'after-registry.json') -Encoding UTF8

Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
    Where-Object DisplayName -eq 'ChildStream Sunshine' |
    Format-List * | Out-File (Join-Path $EvidenceRoot 'after-firewall.txt')
Get-ScheduledTask -TaskName 'ChildStream Sunshine' -ErrorAction SilentlyContinue |
    Export-Clixml (Join-Path $EvidenceRoot 'after-scheduled-task.xml')
Get-ChildItem "$env:ProgramData\ChildStream\Backups" -Recurse -Force -ErrorAction SilentlyContinue |
    Select-Object FullName, PSIsContainer, Length, LastWriteTimeUtc |
    Export-Csv (Join-Path $EvidenceRoot 'after-backups.csv') -NoTypeInformation -Encoding UTF8

Compare-Object (Get-Content (Join-Path $EvidenceRoot 'before-registry.json')) (Get-Content (Join-Path $EvidenceRoot 'after-registry.json'))
```

合格条件:

- setupで変更したレジストリ、Child Sessions設定、Firewall、タスク、Startupファイル、ショートカットが変更前状態へ戻る。
- 変更前に存在した同名リソースは保存内容から復元される。
- 現行Sunshine、`install-state.json`、`install-journal.json`などの監査資料が`%ProgramData%\ChildStream\Backups\<日時>`へ移動され、削除されない。
- 復元に必要な状態やバックアップが欠ける場合は、推測で処理を続けず停止する。

## 11. 異常時の証跡採取

異常が発生したら再setupや手動削除を行わず、まず次を保存します。

```powershell
query session | Out-File (Join-Path $EvidenceRoot 'failure-sessions.txt')
Get-Process -Name ChildStream, sunshine, powershell -ErrorAction SilentlyContinue |
    Select-Object Id, SessionId, Path, StartTime |
    Format-List | Out-File (Join-Path $EvidenceRoot 'failure-processes.txt')
Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
    Where-Object DisplayName -eq 'ChildStream Sunshine' |
    Format-List * | Out-File (Join-Path $EvidenceRoot 'failure-firewall.txt')
Get-ScheduledTask -TaskName 'ChildStream Sunshine' -ErrorAction SilentlyContinue |
    Export-Clixml (Join-Path $EvidenceRoot 'failure-scheduled-task.xml')
Copy-Item '.\autostart.log' $EvidenceRoot -Force -ErrorAction SilentlyContinue
Copy-Item "$env:ProgramData\ChildStream\install-state.json" $EvidenceRoot -Force -ErrorAction SilentlyContinue
Copy-Item "$env:ProgramData\ChildStream\install-journal.json" $EvidenceRoot -Force -ErrorAction SilentlyContinue
```

さらに次を記録します。

- 発生日時と直前に実行した操作
- 物理コンソール、通常RDP、Child Sessionの各Session ID
- 表示されたエラーメッセージ全文
- UACプロンプトの有無
- Sunshineログの該当時刻
- 再起動や手動修正を行った場合は、その内容と時刻

証跡を共有する前に、Windowsユーザー名、PC名、ローカルパス、IPアドレスなどを確認し、必要に応じてマスキングしてください。パスワードや回復キーは共有しないでください。

## 12. 結果記録表

各項目を`Pass`、`Fail`、`Blocked`のいずれかで記録します。`Fail`または`Blocked`の場合は、証跡ファイル名と理由を必ず残します。

| ID | 確認項目 | 結果 | 証跡／備考 |
| --- | --- | --- | --- |
| V01 | インストール前状態の記録 |  |  |
| V02 | setup `-WhatIf` |  |  |
| V03 | 固定Sunshineバージョン／SHA-256 |  |  |
| V04 | Firewall Private／LocalSubnet |  |  |
| V05 | HighestTaskの登録内容 |  |  |
| V06 | 物理コンソールでSunshine不起動 |  |  |
| V07 | 通常RDPでSunshine不起動 |  |  |
| V08 | Child SessionだけでSunshine起動 |  |  |
| V09 | Child Sessionログオン時UACなし |  |  |
| V10 | WGCとハードウェアエンコード |  |  |
| V11 | Moonlight／Artemisと入力 |  |  |
| V12 | End sessionのログオフ隔離 |  |  |
| V13 | 不正なdisplay.cfgで安全停止 |  |  |
| V14 | uninstall `-WhatIf` |  |  |
| V15 | uninstall／rollbackで変更前状態へ復元 |  |  |

`HighestTask`だけが環境依存で失敗した場合は、uninstallで変更前状態へ戻してから`PromptedStartup`で再setupします。Child Sessionログオン時に1回UACが必要になる点以外は、V06～V08とV10～V15を同様に再確認してください。
