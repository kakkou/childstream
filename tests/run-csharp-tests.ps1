[CmdletBinding()]
param([ValidateSet('DisplayConfig','ChildSessionAuthorization','ChildSessionSafety','All')][string]$Test = 'All')

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw 'C#コンパイラが見つかりません。' }
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
if ($Test -in @('ChildSessionSafety','All')) {
    Invoke-CSharpTest -Name 'ChildSessionSafetyTests' -References @('System.Runtime.Serialization.dll') -Sources @(
        (Join-Path $repo 'src\ChildSessionNative.cs'),
        (Join-Path $repo 'src\ChildSessionAuthorization.cs'),
        (Join-Path $repo 'tests\csharp\ChildSessionSafetyTests.cs'))
}
