# ChildStream 安全性強化 実装計画

> **エージェント作業者向け:** 必須サブスキルとして superpowers:subagent-driven-development（推奨）または superpowers:executing-plans を使用し、この計画をタスク単位で実行する。進捗はチェックボックスで管理する。

**目標:** ChildStreamが正しいChild Sessionだけを操作し、検証済みSunshineの導入、限定的なFirewall公開、正確なロールバック、厳格な設定検証を提供する。

**アーキテクチャ:** コンソール側ランチャーがWTSGetChildSessionIdで取得したSession IDを短時間有効なJSONへ発行し、Child側PowerShellがSession ID・有効期限・ランチャープロセスを照合してからSunshineを起動する。セットアップとアンインストールは共通PowerShellモジュールを利用し、変更前スナップショットと適用済み変更一覧に基づいて復元する。

**技術スタック:** C#／.NET Framework 4.x、WinForms、RDP ActiveX、WTS API、Windows PowerShell 5.1、Pester 5.7.1、GitHub Actions windows-latest

**設計書:** docs/superpowers/specs/2026-09-22-childstream-safety-hardening-design.md

## 全体制約

- Windows 10／11 Proと.NET Framework 4.xを維持し、追加ランタイムを要求しない。
- Sunshineはv2026.914.233613のSunshine-Windows-AMD64-lite.zipへ固定する。
- SHA-256は233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824bへ固定する。
- FirewallはPrivateプロファイルかつRemoteAddress=LocalSubnetとする。
- display.cfgの幅は640～8192、高さは480～8192、スケールは100～500とする。
- 起動許可の有効期限は120秒、Child側の待機時間は最大60秒とする。
- セッション判定に「非コンソール」、ユーザー名検索、qwinsta解析を使用しない。
- 不明・不正・不一致の場合は処理しない側へ倒す。
- 資格情報やDPAPIデータを状態ファイル・ログへ書き込まない。
- 設計書、実装計画、コミットメッセージ、Pull Request本文は日本語で記述する。

## ファイル構成

- 新規 src/DisplayConfig.cs: display.cfgの純粋な解析と検証。
- 新規 src/ChildSessionNative.cs: WTS APIのP/Invokeと正しいSession IDの検証。
- 新規 src/ChildSessionAuthorization.cs: 起動許可JSONの型、原子的保存、削除。
- 変更 src/ChildStream.cs: UI、RDP接続、許可発行、正確なログオフを統合。
- 新規 scripts/ChildStream.Runtime.psm1: Child側の起動許可検証とSunshine起動。
- 変更 scripts/childsession-autostart.ps1: Runtimeモジュールを呼ぶ薄いエントリーポイント。
- 新規 scripts/ChildStream.Setup.psm1: スナップショット、復元、Firewall、Task、ファイル退避の共通処理。
- 変更 scripts/setup.ps1: ステージング、固定配布物検証、変更適用、失敗時ロールバック。
- 新規 scripts/uninstall.ps1: 保存済み状態からの復元。
- 新規 tests/csharp/DisplayConfigTests.cs: 設定解析テスト。
- 新規 tests/csharp/ChildSessionAuthorizationTests.cs: 許可JSONテスト。
- 新規 tests/Runtime.Tests.ps1: Child側認可テスト。
- 新規 tests/SetupState.Tests.ps1: スナップショットと復元テスト。
- 新規 tests/Setup.Tests.ps1: セットアップ計画・固定値・変更順序テスト。
- 新規 tests/Uninstall.Tests.ps1: 安全なアンインストールテスト。
- 新規 tests/run-csharp-tests.ps1: C#テストのコンパイルと実行。
- 新規 .github/workflows/windows-ci.yml: Windows CI。
- 変更 README.md: 安全性、設定、導入、復元、実機確認手順。

## レビュー重点項目

- Child Session IDがWindowsによって再利用された場合でも、古い許可ファイルだけではSunshineを起動しないこと。
- 同名Firewallルールが複数、または想定外の条件で存在する場合に、黙って上書きしないこと。
- セットアップを2回実行しても、最初の変更前スナップショットを上書きしないこと。
- setupがステージング後・システム変更途中で失敗しても、今回適用した変更だけを復元すること。
- Scheduled Taskがコンソールまたは通常RDPで実行されても、Sunshineを誤起動しないこと。

---

### Task 1: display.cfgを厳格に解析する

**対象ファイル:**
- 新規: src/DisplayConfig.cs
- 新規: tests/csharp/DisplayConfigTests.cs
- 新規: tests/run-csharp-tests.ps1
- 変更: src/ChildStream.cs

**インターフェース:**
- 生成: DisplayConfig.Load(string path) -> DisplayConfig。ファイルなしは既定値、不正時はFormatException。
- 生成: DisplayConfig.Width、Height、Scale。Scale=0は明示指定なし。
- 利用: タスク2以降のChildStream.csがRDP接続前に1回だけ呼び出す。

- [ ] **手順1: 失敗する設定解析テストを書く**

tests/csharp/DisplayConfigTests.csへ、既定値、正常値、境界値、大文字X、不正な項目数、負数、小数、オーバーフロー、範囲外を列挙する。

~~~csharp
using System;
using System.IO;

static class DisplayConfigTests
{
    static int failures;

    static void Equal(int expected, int actual, string name)
    {
        if (expected != actual) { Console.Error.WriteLine(name + ": expected " + expected + ", actual " + actual); failures++; }
    }

    static void Invalid(string value, string name)
    {
        string path = Path.GetTempFileName();
        try {
            File.WriteAllText(path, value);
            try { DisplayConfig.Load(path); Console.Error.WriteLine(name + ": FormatExceptionにならなかった"); failures++; }
            catch (FormatException) { }
        } finally { File.Delete(path); }
    }

    public static int Main()
    {
        string missing = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        DisplayConfig defaults = DisplayConfig.Load(missing);
        Equal(1920, defaults.Width, "既定幅");
        Equal(1080, defaults.Height, "既定高さ");
        Equal(0, defaults.Scale, "既定スケール");

        string valid = Path.GetTempFileName();
        File.WriteAllText(valid, "2800X1272x225\r\n");
        DisplayConfig parsed = DisplayConfig.Load(valid);
        Equal(2800, parsed.Width, "指定幅");
        Equal(1272, parsed.Height, "指定高さ");
        Equal(225, parsed.Scale, "指定スケール");
        File.Delete(valid);

        Invalid("639x1080", "幅下限未満");
        Invalid("1920x8193", "高さ上限超過");
        Invalid("1920x1080x99", "スケール下限未満");
        Invalid("1920x1080x501", "スケール上限超過");
        Invalid("1920x1080x100x1", "余分な項目");
        Invalid("-1920x1080", "負数");
        Invalid("1920.5x1080", "小数");
        Invalid("999999999999x1080", "整数オーバーフロー");
        Invalid("1920x1080 trailing", "末尾文字");
        return failures == 0 ? 0 : 1;
    }
}
~~~

- [ ] **手順2: テストが未実装で失敗することを確認する**

実行:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-csharp-tests.ps1 -Test DisplayConfig
~~~

期待結果: DisplayConfig型が存在しないためコンパイルが失敗する。

- [ ] **手順3: 最小の設定解析を実装する**

src/DisplayConfig.csへ次の公開契約を実装する。

~~~csharp
using System;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

public sealed class DisplayConfig
{
    static readonly Regex Pattern = new Regex(@"^(\d+)[xX](\d+)(?:[xX](\d+))?$", RegexOptions.CultureInvariant);
    public int Width { get; private set; }
    public int Height { get; private set; }
    public int Scale { get; private set; }

    DisplayConfig(int width, int height, int scale) { Width = width; Height = height; Scale = scale; }

    public static DisplayConfig Load(string path)
    {
        if (!File.Exists(path)) return new DisplayConfig(1920, 1080, 0);
        string text = File.ReadAllText(path).Trim();
        Match match = Pattern.Match(text);
        if (!match.Success) throw new FormatException("display.cfgは WIDTHxHEIGHT または WIDTHxHEIGHTxSCALE で指定してください。");
        int width, height, scale = 0;
        if (!Int32.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out width) ||
            !Int32.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out height) ||
            (match.Groups[3].Success && !Int32.TryParse(match.Groups[3].Value, NumberStyles.None, CultureInfo.InvariantCulture, out scale)))
            throw new FormatException("display.cfgに32ビット整数として解釈できない値があります。");
        if (width < 640 || width > 8192 || height < 480 || height > 8192 ||
            (match.Groups[3].Success && (scale < 100 || scale > 500)))
            throw new FormatException("display.cfgの許容範囲は幅640～8192、高さ480～8192、スケール100～500です。");
        return new DisplayConfig(width, height, scale);
    }
}
~~~

ChildStream.csではパスワード入力前にLoadを呼び、FormatExceptionをMessageBoxで表示して終了する。接続ラムダ内のint.Parseと例外握り潰しを削除する。

tests/run-csharp-tests.ps1はテスト名を受け取り、テストごとに必要な製品ソースとテストソースを同じ実行ファイルへコンパイルする。タスク2でChildSessionAuthorizationを追加し、Allでは両方を順番に実行する。

~~~powershell
[CmdletBinding()]
param([ValidateSet('DisplayConfig','ChildSessionAuthorization','All')][string]$Test = 'All')

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$output = Join-Path $env:TEMP 'ChildStreamTests'
New-Item -ItemType Directory -Path $output -Force | Out-Null

function Invoke-CSharpTest {
    param([string]$Name, [string[]]$Sources, [string[]]$References = @())
    $exe = Join-Path $output ($Name + '.exe')
    $referenceArgs = $References | ForEach-Object { '/r:' + $_ }
    & $csc /nologo /target:exe "/out:$exe" $referenceArgs $Sources
    if ($LASTEXITCODE -ne 0) { throw "$Name のコンパイルに失敗しました。" }
    & $exe
    if ($LASTEXITCODE -ne 0) { throw "$Name が失敗しました。" }
}

if ($Test -eq 'All') {
    $launcherSources = Get-ChildItem (Join-Path $repo 'src\*.cs') | ForEach-Object FullName
    $launcher = Join-Path $output 'ChildStream.exe'
    & $csc /nologo /target:winexe "/out:$launcher" /r:System.Windows.Forms.dll /r:System.Drawing.dll `
        /r:System.Security.dll /r:System.Runtime.Serialization.dll /r:Microsoft.CSharp.dll $launcherSources
    if ($LASTEXITCODE -ne 0) { throw 'ChildStream.exeのコンパイルに失敗しました。' }
}

if ($Test -in @('DisplayConfig','All')) {
    Invoke-CSharpTest -Name 'DisplayConfigTests' -Sources @(
        (Join-Path $repo 'src\DisplayConfig.cs'),
        (Join-Path $repo 'tests\csharp\DisplayConfigTests.cs'))
}
if ($Test -in @('ChildSessionAuthorization','All')) {
    Invoke-CSharpTest -Name 'ChildSessionAuthorizationTests' -References @('System.Runtime.Serialization.dll') -Sources @(
        (Join-Path $repo 'src\ChildSessionAuthorization.cs'),
        (Join-Path $repo 'tests\csharp\ChildSessionAuthorizationTests.cs'))
}
~~~

- [ ] **手順4: 設定解析テストと本体コンパイルを成功させる**

実行:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-csharp-tests.ps1 -Test DisplayConfig
~~~

期待結果: 終了コード0。正常値・境界値・異常値テストがすべて成功する。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add src/DisplayConfig.cs src/ChildStream.cs tests/csharp/DisplayConfigTests.cs tests/run-csharp-tests.ps1
git commit -m "設定: display.cfgの厳格な検証を追加"
~~~

### Task 2: WTS APIと起動許可発行を実装する

**対象ファイル:**
- 新規: src/ChildSessionNative.cs
- 新規: src/ChildSessionAuthorization.cs
- 新規: tests/csharp/ChildSessionAuthorizationTests.cs
- 変更: src/ChildStream.cs
- 変更: tests/run-csharp-tests.ps1

**インターフェース:**
- 生成: ChildSessionNative.TryGetChildSessionId(out uint id, out int error)。有効IDだけtrue。
- 生成: ChildSessionNative.TryLogoffChildSession(out uint id, out int error)。列挙せず対象1件だけを終了。
- 生成: ChildStream.exe -enable／-disable／-check。アンインストールが変更前のChild Sessions有効状態を復元するために使用する。
- 生成: ChildSessionAuthorizationStore.Write(string path, uint sessionId, int processId, DateTime processStartUtc, DateTime issuedUtc)。
- 生成: ChildSessionAuthorizationStore.Delete(string path)。存在しなくても成功扱い。
- 利用: タスク3のPowerShellがJSONフィールドschemaVersion、childSessionId、launcherProcessId、launcherStartTimeUtc、issuedAtUtcを読む。

- [ ] **手順1: 起動許可JSONの失敗するテストを書く**

tests/csharp/ChildSessionAuthorizationTests.csで、JSONフィールド、原子的な上書き、一時ファイル非残存、削除の冪等性を検証する。

~~~csharp
using System;
using System.IO;

static class ChildSessionAuthorizationTests
{
    public static int Main()
    {
        string dir = Path.Combine(Path.GetTempPath(), "ChildStreamTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "active-child-session.json");
        DateTime started = new DateTime(638941248000000000L, DateTimeKind.Utc);
        DateTime issued = started.AddSeconds(10);
        ChildSessionAuthorizationStore.Write(path, 42, 1234, started, issued);
        string json = File.ReadAllText(path);
        if (!json.Contains("\"schemaVersion\":1") || !json.Contains("\"childSessionId\":42") ||
            !json.Contains("\"launcherProcessId\":1234") || Directory.GetFiles(dir, "*.tmp").Length != 0) return 1;
        ChildSessionAuthorizationStore.Write(path, 43, 1234, started, issued);
        if (!File.ReadAllText(path).Contains("\"childSessionId\":43")) return 1;
        ChildSessionAuthorizationStore.Delete(path);
        ChildSessionAuthorizationStore.Delete(path);
        if (File.Exists(path)) return 1;
        Directory.Delete(dir, true);
        return 0;
    }
}
~~~

- [ ] **手順2: 起動許可テストが未実装で失敗することを確認する**

実行:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-csharp-tests.ps1 -Test ChildSessionAuthorization
~~~

期待結果: ChildSessionAuthorizationStoreが存在しないため失敗する。

- [ ] **手順3: WTSラッパーと起動許可ストアを実装する**

ChildSessionNative.csではWTSGetChildSessionIdとWTSLogoffSessionをSetLastError=trueで宣言し、Process.GetCurrentProcess().SessionIdと同じID、またはUInt32.MaxValueを拒否する。WTSLogoffSessionにはIntPtr.Zero、検証済みID、falseを渡す。

ChildSessionAuthorization.csではDataContractJsonSerializerを使用し、ISO 8601のUTC文字列を保存する。

~~~csharp
[DataContract]
sealed class ChildSessionAuthorization
{
    [DataMember(Order = 1)] public int schemaVersion = 1;
    [DataMember(Order = 2)] public uint childSessionId;
    [DataMember(Order = 3)] public int launcherProcessId;
    [DataMember(Order = 4)] public string launcherStartTimeUtc;
    [DataMember(Order = 5)] public string issuedAtUtc;
}
~~~

Writeは同一ディレクトリのGUID付き.tmpへ書き込み、既存ファイルがあればFile.Replace、なければFile.Moveを使用する。finallyで残った一時ファイルを削除する。

ChildStream.csではConnectedが1へ変化した時に許可を発行し、Connectedが0へ戻った時、終了要求時、FormClosing時、ApplicationExit時に削除する。許可パスは次で作る。

~~~csharp
string authorizationPath = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "ChildStream", "active-child-session.json");
~~~

「End session」はTryLogoffChildSessionだけを呼び、失敗時にWin32エラーを表示する。qwinsta、Regex、logoff.exe処理を削除する。

既存の-enableと-checkに加えて-disableを実装する。-disableはWTSEnableChildSessions(false)を呼び、WTSIsChildSessionsEnabledがfalseを返した場合だけ終了コード0とする。

- [ ] **手順4: JSONテスト、ランチャーコンパイル、禁止文字列検査を実行する**

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-csharp-tests.ps1 -Test All
$source = Get-Content .\src\ChildStream.cs -Raw
if ($source -match 'qwinsta|ProcessStartInfo\("logoff"|line\.Contains\(Environment\.UserName') { throw '曖昧なセッション終了処理が残っています。' }
~~~

期待結果: テストとコンパイルが成功し、禁止文字列検査が例外を出さない。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add src/ChildSessionNative.cs src/ChildSessionAuthorization.cs src/ChildStream.cs tests/csharp/ChildSessionAuthorizationTests.cs tests/run-csharp-tests.ps1
git commit -m "セッション: WTS APIによる正確な識別と終了を追加"
~~~

### Task 3: Child Session側の起動認可を失敗側へ閉じる

**対象ファイル:**
- 新規: scripts/ChildStream.Runtime.psm1
- 変更: scripts/childsession-autostart.ps1
- 新規: tests/Runtime.Tests.ps1

**インターフェース:**
- 生成: Read-ChildSessionAuthorization -Path string -> PSCustomObject。破損時は理由付き例外。
- 生成: Test-ChildSessionAuthorization -State object -CurrentSessionId int -NowUtc DateTime -ProcessLookup scriptblock -> PSCustomObject { Authorized, Reason }。
- 生成: Invoke-ChildSessionSunshine -Root string -LaunchMode HighestTask|PromptedStartup -WaitSeconds int。
- 利用: タスク5のScheduled Taskとスタートアップフックがchildsession-autostart.ps1を呼ぶ。

- [ ] **手順1: 認可条件の失敗するPesterテストを書く**

tests/Runtime.Tests.ps1へ、一致、通常RDP相当のID不一致、121秒経過、未来時刻、PID不存在、PID再利用相当の起動時刻不一致、Sunshine重複を追加する。

~~~powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\ChildStream.Runtime.psm1" -Force
    $now = [DateTime]::Parse('2026-09-22T12:00:00.0000000Z').ToUniversalTime()
    $state = [pscustomobject]@{
        schemaVersion = 1
        childSessionId = 42
        launcherProcessId = 1234
        launcherStartTimeUtc = '2026-09-22T11:59:00.0000000Z'
        issuedAtUtc = '2026-09-22T11:59:30.0000000Z'
    }
    $matchingProcess = [pscustomobject]@{ StartTime = [DateTime]::Parse($state.launcherStartTimeUtc).ToLocalTime() }
}

It '一致する新しい許可を受理する' {
    $result = Test-ChildSessionAuthorization -State $state -CurrentSessionId 42 -NowUtc $now -ProcessLookup { param($id) $matchingProcess }
    $result.Authorized | Should -BeTrue
}

It '通常RDP相当の異なるSession IDを拒否する' {
    $result = Test-ChildSessionAuthorization -State $state -CurrentSessionId 99 -NowUtc $now -ProcessLookup { param($id) $matchingProcess }
    $result.Authorized | Should -BeFalse
    $result.Reason | Should -Be 'session-mismatch'
}

It 'PIDが再利用され起動時刻が異なる場合に拒否する' {
    $other = [pscustomobject]@{ StartTime = [DateTime]::Parse('2026-09-22T11:58:00Z').ToLocalTime() }
    $result = Test-ChildSessionAuthorization -State $state -CurrentSessionId 42 -NowUtc $now -ProcessLookup { param($id) $other }
    $result.Reason | Should -Be 'launcher-start-time-mismatch'
}
~~~

- [ ] **手順2: Runtimeモジュール未実装による失敗を確認する**

~~~powershell
Invoke-Pester .\tests\Runtime.Tests.ps1 -Output Detailed
~~~

期待結果: モジュールが存在せず失敗する。

- [ ] **手順3: 純粋な認可関数と起動処理を実装する**

Test-ChildSessionAuthorizationは、スキーマ、必須プロパティ、ID一致、発行時刻が未来5秒以内、有効期限120秒以内、プロセス存在、UTC起動時刻の1秒以内一致を順番に検証する。ProcessLookupの既定値はGet-Process -Idとする。

~~~powershell
function New-AuthorizationResult {
    param([bool]$Authorized, [string]$Reason)
    [pscustomobject]@{ Authorized = $Authorized; Reason = $Reason }
}

function Test-ChildSessionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$CurrentSessionId,
        [Parameter(Mandatory)][DateTime]$NowUtc,
        [scriptblock]$ProcessLookup = { param($id) Get-Process -Id $id -ErrorAction Stop }
    )
    if ($State.schemaVersion -ne 1) { return New-AuthorizationResult $false 'schema-mismatch' }
    if ([int]$State.childSessionId -ne $CurrentSessionId) { return New-AuthorizationResult $false 'session-mismatch' }
    $issued = [DateTime]::Parse($State.issuedAtUtc).ToUniversalTime()
    $age = ($NowUtc.ToUniversalTime() - $issued).TotalSeconds
    if ($age -lt -5) { return New-AuthorizationResult $false 'issued-in-future' }
    if ($age -gt 120) { return New-AuthorizationResult $false 'authorization-expired' }
    try { $process = & $ProcessLookup ([int]$State.launcherProcessId) }
    catch { return New-AuthorizationResult $false 'launcher-not-running' }
    $expectedStart = [DateTime]::Parse($State.launcherStartTimeUtc).ToUniversalTime()
    if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds) -gt 1) {
        return New-AuthorizationResult $false 'launcher-start-time-mismatch'
    }
    return New-AuthorizationResult $true 'authorized'
}
~~~

Invoke-ChildSessionSunshineは許可を最大60秒待ち、認可後に同一Session IDのsunshineプロセスがない場合だけ起動する。HighestTaskでは通常起動、PromptedStartupではStart-Process -Verb RunAsを使用する。

childsession-autostart.ps1はparamでLaunchModeを受け、Runtimeモジュールの関数1個だけを呼ぶ薄いスクリプトにする。WTSGetActiveConsoleSessionIdによる判定を削除する。

- [ ] **手順4: 全認可テストと禁止ヒューリスティック検査を成功させる**

~~~powershell
Invoke-Pester .\tests\Runtime.Tests.ps1 -Output Detailed
$source = Get-Content .\scripts\childsession-autostart.ps1 -Raw
if ($source -match 'WTSGetActiveConsoleSessionId|consoleSid|mySid -eq') { throw '非コンソール判定が残っています。' }
~~~

期待結果: Pesterがすべて成功し、禁止検査が例外を出さない。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add scripts/ChildStream.Runtime.psm1 scripts/childsession-autostart.ps1 tests/Runtime.Tests.ps1
git commit -m "起動: Child Session認可を厳格化"
~~~

### Task 4: 変更前状態と共通復元処理を実装する

**対象ファイル:**
- 新規: scripts/ChildStream.Setup.psm1
- 新規: tests/SetupState.Tests.ps1

**インターフェース:**
- 生成: New-ChildStreamInstallState -InstallRoot string -> PSCustomObject。
- 生成: Save-ChildStreamInstallStateOnce -State object -Path string。既存の有効な状態を上書きしない。
- 生成: Get-RegistryValueSnapshot、Restore-RegistryValueSnapshot。
- 生成: Restore-ChildSessionEnabledState -Enabled bool -LauncherPath string。
- 生成: Get-FirewallRuleSnapshot、Restore-FirewallRuleSnapshot。
- 生成: Backup-FileResource、Restore-FileResource。
- 生成: Restore-ChildStreamState -State object -AppliedChanges string[]。
- 利用: タスク5のsetup.ps1とタスク6のuninstall.ps1。

- [ ] **手順1: スナップショット維持と正確な復元の失敗テストを書く**

tests/SetupState.Tests.ps1で、存在するDWORD、存在しない値、最初の状態ファイルの不変性、複数Firewallルール、ファイルバックアップ、適用済み項目だけの逆順復元をテストする。対象レジストリは次の3件を完全なパスと名前で固定する。

- HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server の fDenyTSConnections
- HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations の DWMFRAMEINTERVAL
- HKCU:\Software\Microsoft\Terminal Server Client の RemoteDesktop_SuppressWhenMinimized

~~~powershell
BeforeAll { Import-Module "$PSScriptRoot\..\scripts\ChildStream.Setup.psm1" -Force }

Describe 'Save-ChildStreamInstallStateOnce' {
    It '2回目の実行で最初のスナップショットを上書きしない' {
        $path = Join-Path $TestDrive 'install-state.json'
        Save-ChildStreamInstallStateOnce -State ([pscustomobject]@{ schemaVersion = 1; marker = 'before' }) -Path $path
        { Save-ChildStreamInstallStateOnce -State ([pscustomobject]@{ schemaVersion = 1; marker = 'after' }) -Path $path } | Should -Throw
        (Get-Content $path -Raw | ConvertFrom-Json).marker | Should -Be 'before'
    }
}

Describe 'Restore-RegistryValueSnapshot' {
    It '元々存在しない値は削除する' {
        Mock Remove-ItemProperty {}
        Restore-RegistryValueSnapshot -Snapshot ([pscustomobject]@{ Path='HKCU:\Software\ChildStreamTest'; Name='Value'; Existed=$false })
        Should -Invoke Remove-ItemProperty -Times 1 -ParameterFilter { $Name -eq 'Value' }
    }
}
~~~

- [ ] **手順2: 共通モジュール未実装による失敗を確認する**

~~~powershell
Invoke-Pester .\tests\SetupState.Tests.ps1 -Output Detailed
~~~

期待結果: ChildStream.Setup.psm1が存在せず失敗する。

- [ ] **手順3: 状態型、取得、保存、復元を実装する**

New-ChildStreamInstallStateはschemaVersion=1、installRoot、capturedAtUtc、childSessionsEnabled、registry、firewall、startupHook、scheduledTask、desktopShortcut、sunshine、createdArtifactsを持つオブジェクトを返す。

Save-ChildStreamInstallStateOnceは親ディレクトリを作成し、FileMode.CreateNewで一時ファイルを確保してUTF-8 JSONを書き、同一ボリューム内でMoveする。既存状態が有効なら上書きせず例外とする。

レジストリスナップショットはGetValueKindを含める。復元時はExisted=falseならRemove-ItemProperty -ErrorAction SilentlyContinue、trueなら元の型をSet-ItemPropertyで指定する。

Firewallスナップショットは同名ルールを配列として保存し、各要素にDisplayName、Enabled、Direction、Action、Profile、Program、RemoteAddressを含める。復元前にChildStreamが作成した同名ルールだけを削除し、保存済み配列をNew-NetFirewallRuleで再作成する。想定外に複数存在する場合も配列として保持する。

Restore-ChildStreamStateはAppliedChangesを逆順に処理する。未記録項目を推測して変更しない。

Child Sessionsの復元は、変更前が有効ならChildStream.exe -enable、無効ならChildStream.exe -disableを実行し、その後-checkの終了コードが期待状態と一致することを確認する。

- [ ] **手順4: 状態と復元テストを成功させる**

~~~powershell
Invoke-Pester .\tests\SetupState.Tests.ps1 -Output Detailed
~~~

期待結果: 初回状態維持、存在有無、型、複数ルール、逆順復元のテストがすべて成功する。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add scripts/ChildStream.Setup.psm1 tests/SetupState.Tests.ps1
git commit -m "復元: セットアップ前状態の保存処理を追加"
~~~

### Task 5: 検証済み配布物と限定公開でセットアップする

**対象ファイル:**
- 変更: scripts/setup.ps1
- 変更: scripts/ChildStream.Setup.psm1
- 新規: tests/Setup.Tests.ps1

**インターフェース:**
- setup.ps1引数: -AutostartMode HighestTask|PromptedStartup、-ReplaceExistingSunshine、共通-WhatIf。
- 状態保存先: %ProgramData%\ChildStream\install-state.json。
- Scheduled Task名: ChildStream Sunshine。
- Firewall DisplayName: ChildStream Sunshine。
- Sunshineバージョン情報: Sunshine\childstream-version.json。

- [ ] **手順1: 固定配布物、Firewall、Task、失敗時復元の失敗テストを書く**

tests/Setup.Tests.ps1ではsetup.ps1をドットソースし、Invoke-WebRequest、Get-FileHash、Expand-Archive、New-NetFirewallRule、Register-ScheduledTask、Restore-ChildStreamStateをMockする。

~~~powershell
It 'PrivateかつLocalSubnetだけを許可する' {
    Mock New-NetFirewallRule {}
    Set-ChildStreamFirewall -SunshineExe 'C:\ChildStream\Sunshine\Sunshine\sunshine.exe'
    Should -Invoke New-NetFirewallRule -Times 1 -ParameterFilter {
        $Profile -eq 'Private' -and $RemoteAddress -eq 'LocalSubnet' -and $Direction -eq 'Inbound' -and $Action -eq 'Allow'
    }
}

It 'ハッシュ不一致では展開しない' {
    Mock Get-FileHash { [pscustomobject]@{ Hash = ('0' * 64) } }
    Mock Expand-Archive {}
    { Expand-VerifiedSunshine -ArchivePath "$TestDrive\sunshine.zip" -Destination "$TestDrive\Sunshine" } | Should -Throw
    Should -Invoke Expand-Archive -Times 0
}

It '変更開始後の失敗では今回の適用項目を復元する' {
    Mock Set-ItemProperty { throw 'simulated failure' }
    Mock Restore-ChildStreamState {}
    { Invoke-ChildStreamSetup -InstallRoot $TestDrive -Confirm:$false } | Should -Throw
    Should -Invoke Restore-ChildStreamState -Times 1
}
~~~

Scheduled Taskのテストでは、LogonTrigger、Interactive、Highest、対象ユーザー、-LaunchMode HighestTaskを含むことを検証する。PromptedStartupではTaskを作成せず、スタートアップフックが-LaunchMode PromptedStartupを指定することを検証する。

- [ ] **手順2: 現行setup.ps1がテストに失敗することを確認する**

~~~powershell
Invoke-Pester .\tests\Setup.Tests.ps1 -Output Detailed
~~~

期待結果: latest取得、Profile Any、RemoteAddress未指定、状態保存なしのため失敗する。

- [ ] **手順3: setup.ps1を高度なスクリプトへ変更する**

先頭を次の契約にする。

~~~powershell
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('HighestTask','PromptedStartup')]
    [string]$AutostartMode = 'HighestTask',
    [switch]$ReplaceExistingSunshine
)

$SunshineVersion = 'v2026.914.233613'
$SunshineAsset = 'Sunshine-Windows-AMD64-lite.zip'
$SunshineUri = "https://github.com/LizardByte/Sunshine/releases/download/$SunshineVersion/$SunshineAsset"
$SunshineSha256 = '233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b'
~~~

処理順を、事前検証、temp配下へのC#コンパイル、Sunshineダウンロード・SHA-256検証・ステージング展開、既存資源検査、状態保存、システム変更、成果物移動、完了記録とする。

状態保存後、fDenyTSConnections=0、DWMFRAMEINTERVAL=8、RemoteDesktop_SuppressWhenMinimized=2を設定する。各値は設定直後に読み戻し、期待値と一致しなければ例外として今回の変更をロールバックする。

C#コンパイルはsrc配下の全.csを対象にし、System.Runtime.Serialization.dllを参照へ追加する。

~~~powershell
$sources = Get-ChildItem (Join-Path $root 'src\*.cs') | ForEach-Object FullName
& $csc /nologo /target:winexe $iconArg /out:$stagedExe `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Security.dll `
    /r:System.Runtime.Serialization.dll /r:Microsoft.CSharp.dll $sources
if ($LASTEXITCODE -ne 0) { throw 'ChildStream.exeのコンパイルに失敗しました。' }
~~~

既存Sunshineに一致するchildstream-version.jsonがなければ既定で停止する。-ReplaceExistingSunshine時だけProgramDataのBackupsへMoveし、状態へ保存する。

FirewallはPrivate／LocalSubnetで作る。HighestTaskではNew-ScheduledTaskPrincipal -LogonType Interactive -RunLevel Highestを使う。PromptedStartupでは全ユーザーStartupへ厳格認可付きスクリプトの呼び出しだけを配置する。

try/catchで、変更開始後の例外時にAppliedChangesを渡してRestore-ChildStreamStateを呼び、元の例外を再送出する。

- [ ] **手順4: セットアップテストと-WhatIfを成功させる**

~~~powershell
Invoke-Pester .\tests\Setup.Tests.ps1 -Output Detailed
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -WhatIf
~~~

期待結果: Pesterが成功する。-WhatIfは予定する操作だけを表示し、レジストリ、Firewall、Task、ファイルを変更しない。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add scripts/setup.ps1 scripts/ChildStream.Setup.psm1 tests/Setup.Tests.ps1
git commit -m "導入: Sunshine検証と限定Firewallを追加"
~~~

### Task 6: 保存済み状態から安全にアンインストールする

**対象ファイル:**
- 新規: scripts/uninstall.ps1
- 変更: scripts/ChildStream.Setup.psm1
- 新規: tests/Uninstall.Tests.ps1

**インターフェース:**
- uninstall.ps1引数: 共通-WhatIf。
- 読み取り: %ProgramData%\ChildStream\install-state.json。
- 退避先: %ProgramData%\ChildStream\Backups\yyyyMMdd-HHmmss。

- [ ] **手順1: 状態欠落・破損・完全復元の失敗テストを書く**

~~~powershell
It '状態ファイルがない場合はシステム変更を行わない' {
    Mock Set-ItemProperty {}
    Mock Remove-NetFirewallRule {}
    { Invoke-ChildStreamUninstall -StatePath "$TestDrive\missing.json" -Confirm:$false } | Should -Throw
    Should -Invoke Set-ItemProperty -Times 0
    Should -Invoke Remove-NetFirewallRule -Times 0
}

It 'Sunshineデータを削除せずバックアップへ移動する' {
    Mock Move-Item {}
    Invoke-ChildStreamUninstall -StatePath "$TestDrive\install-state.json" -Confirm:$false
    Should -Invoke Move-Item -ParameterFilter { $Destination -match 'Backups' }
}
~~~

さらに、元々無効だったChild Sessions、存在しなかったレジストリ値、既存Firewall、既存Task XML、既存ショートカットが保存値へ戻ることをMockで検証する。

- [ ] **手順2: uninstall未実装による失敗を確認する**

~~~powershell
Invoke-Pester .\tests\Uninstall.Tests.ps1 -Output Detailed
~~~

期待結果: uninstall.ps1またはInvoke-ChildStreamUninstallが存在せず失敗する。

- [ ] **手順3: 破壊的推測をしないuninstallを実装する**

~~~powershell
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChildStream.Setup.psm1') -Force
$statePath = Join-Path $env:ProgramData 'ChildStream\install-state.json'
Invoke-ChildStreamUninstall -StatePath $statePath -WhatIf:$WhatIfPreference -Confirm:$false
~~~

Invoke-ChildStreamUninstallはJSONのschemaVersion、installRoot、必須スナップショットを検証してから変更する。検証失敗時は何も変更しない。Sunshine、実行ファイル、ログなど現行配置から外すファイルはバックアップへMoveし、完了時にパスを表示する。

復元成功後もinstall-state.jsonを削除せず、同じバックアップディレクトリへ移動して監査可能にする。

- [ ] **手順4: アンインストールテストと-WhatIfを成功させる**

~~~powershell
Invoke-Pester .\tests\Uninstall.Tests.ps1 -Output Detailed
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -WhatIf
~~~

期待結果: Pesterが成功する。状態ファイルのないCI環境では-WhatIfが安全に理由を表示して非ゼロ終了し、システム変更を行わない。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add scripts/uninstall.ps1 scripts/ChildStream.Setup.psm1 tests/Uninstall.Tests.ps1
git commit -m "復元: 安全なアンインストール処理を追加"
~~~

### Task 7: Windows CIでビルドとテストを自動化する

**対象ファイル:**
- 新規: .github/workflows/windows-ci.yml
- 変更: tests/run-csharp-tests.ps1

**インターフェース:**
- GitHub Actionsジョブ名: windows-ci。
- 実行環境: windows-latest、Windows PowerShell 5.1。
- Pester固定バージョン: 5.7.1。

- [ ] **手順1: ローカル集約テストを実行し、CI未作成を確認する**

~~~powershell
Test-Path .\.github\workflows\windows-ci.yml | Should -BeFalse
~~~

期待結果: ワークフローが存在しない。

- [ ] **手順2: Windowsワークフローを追加する**

~~~yaml
name: Windows CI

on:
  push:
    paths:
      - 'src/**'
      - 'scripts/**'
      - 'tests/**'
      - '.github/workflows/windows-ci.yml'
  pull_request:
    paths:
      - 'src/**'
      - 'scripts/**'
      - 'tests/**'
      - '.github/workflows/windows-ci.yml'

jobs:
  windows-ci:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: Pesterを固定バージョンで導入
        shell: powershell
        run: Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope CurrentUser
      - name: PowerShell構文を検証
        shell: powershell
        run: |
          $errors = @()
          Get-ChildItem scripts,tests -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
            $errors += $parseErrors
          }
          if ($errors.Count) { $errors | Format-List; exit 1 }
      - name: C#をビルドして単体テスト
        shell: powershell
        run: .\tests\run-csharp-tests.ps1 -Test All
      - name: PowerShell単体テスト
        shell: powershell
        run: Invoke-Pester .\tests -Output Detailed
~~~

PowerShell構文検証では各ファイルごとに$parseErrors=@()を初期化してから配列へ追加する実装にする。actions/checkoutはメジャーバージョン固定、Pesterは完全バージョン固定とする。

- [ ] **手順3: ローカルでCI相当コマンドを実行する**

~~~powershell
$allErrors = @()
Get-ChildItem scripts,tests -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    $allErrors += $parseErrors
}
if ($allErrors.Count) { $allErrors | Format-List; exit 1 }
.\tests\run-csharp-tests.ps1 -Test All
Invoke-Pester .\tests -Output Detailed
~~~

期待結果: 構文エラー0、C#テスト終了コード0、Pester全成功。

- [ ] **手順4: 日本語コミットを作成する**

~~~bash
git add .github/workflows/windows-ci.yml tests/run-csharp-tests.ps1
git commit -m "CI: Windows向けビルドと自動テストを追加"
~~~

### Task 8: 利用・復元・実機確認手順を文書化する

**対象ファイル:**
- 変更: README.md
- 変更: docs/superpowers/specs/2026-09-22-childstream-safety-hardening-design.md

**インターフェース:**
- READMEのSetup、display.cfg、Security、Uninstall、Manual verification節。
- 設計書の状態を「実装済み・実機確認待ち」へ変更するのは自動テスト成功後だけ。

- [ ] **手順1: READMEに必要な安全情報が未記載であることを検査する**

~~~powershell
$readme = Get-Content .\README.md -Raw
$required = @('v2026.914.233613','LocalSubnet','display.cfg','uninstall.ps1','install-state.json','通常のRDP')
$missing = $required | Where-Object { $readme -notmatch [regex]::Escape($_) }
if ($missing.Count -eq 0) { throw '更新前READMEに全項目が既に存在しています。検査条件を見直してください。' }
~~~

期待結果: 少なくとも1項目が未記載である。

- [ ] **手順2: READMEを日本語で更新する**

次を具体的なコマンドとともに記載する。

- setup.ps1の既定HighestTaskと、-AutostartMode PromptedStartupフォールバック。
- -ReplaceExistingSunshineが既存配置をバックアップしてから置換すること。
- 固定SunshineバージョンとSHA-256。
- FirewallがPrivate／LocalSubnet限定であること。
- display.cfgの形式・範囲・不正時に接続しないこと。
- %LOCALAPPDATA%の起動許可状態と%ProgramData%のインストール状態。
- uninstall.ps1と-WhatIf。
- 通常RDP・コンソール・Child Sessionでの起動確認。
- UACなしの最高権限タスクは実機確認が必要で、失敗時はPromptedStartupへ切り替えること。
- バックアップの保存先と復旧方法。

- [ ] **手順3: 全自動検証を再実行する**

~~~powershell
.\tests\run-csharp-tests.ps1 -Test All
Invoke-Pester .\tests -Output Detailed
$readme = Get-Content .\README.md -Raw
@('v2026.914.233613','LocalSubnet','display.cfg','uninstall.ps1','install-state.json','通常のRDP') | ForEach-Object {
    if ($readme -notmatch [regex]::Escape($_)) { throw "README必須項目がありません: $_" }
}
~~~

期待結果: 全テスト成功、README必須項目がすべて存在する。

- [ ] **手順4: 設計書の状態と実機未確認項目を正確に更新する**

自動検証が成功した場合、設計書の状態を「実装済み・Windows実機確認待ち」とする。実機で確認していないTask Scheduler配置、WGC、NVENC、Moonlight、昇格アプリ入力を成功済みと記載しない。

- [ ] **手順5: 日本語コミットを作成する**

~~~bash
git add README.md docs/superpowers/specs/2026-09-22-childstream-safety-hardening-design.md
git commit -m "文書: 安全な導入と復元手順を追加"
~~~

## ブランチ全体の最終検証

- [ ] masterとの差分に意図しないバイナリ、Sunshineアーカイブ、資格情報、ログが含まれていないことを確認する。
- [ ] すべてのコミットメッセージが日本語であることを確認する。
- [ ] windows-ciの成功結果を確認する。
- [ ] qwinsta、ユーザー名によるセッション検索、WTSGetActiveConsoleSessionIdによるChild判定、releases/latest、Profile Anyが残っていないことを確認する。
- [ ] superpowers:requesting-code-reviewでブランチ全体をレビューする。
- [ ] レビュー指摘を修正し、superpowers:verification-before-completionで検証を再実行する。
- [ ] 日本語のタイトルと本文でkakkou/childstream内にPull Requestを作成する。
