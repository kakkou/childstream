<#
.SYNOPSIS
  One-shot setup for ChildStream: second-desktop game streaming via Windows child sessions.
.NOTES
  Run from an elevated PowerShell in the repo root:  .\scripts\setup.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

# 1. Compile the launcher
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$iconArg = if (Test-Path "$root\app.ico") { "/win32icon:$root\app.ico" } else { $null }
$launcherSources = Get-ChildItem (Join-Path $root 'src\*.cs') | ForEach-Object FullName
& $csc /nologo /target:winexe $iconArg /out:"$root\ChildStream.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Security.dll /r:Microsoft.CSharp.dll $launcherSources
Write-Host 'Compiled ChildStream.exe'

# 2. Enable child sessions
& "$root\ChildStream.exe" -enable
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable child sessions.' }
Write-Host 'Child sessions enabled'

# 3. Allow RDP connections (loopback requirement for child sessions)
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

# 4. Raise session composition rate (~120 fps). Remove the value to restore default (~30 fps).
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name DWMFRAMEINTERVAL -Value 8 -Type DWord
Write-Host 'RDP composition rate raised'

# 4b. Keep rendering the session while the viewer window is minimized (prevents black stream)
New-Item -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Microsoft\Terminal Server Client' -Name RemoteDesktop_SuppressWhenMinimized -Value 2 -Type DWord

# 5. Download portable Sunshine if missing
$sunshineExe = "$root\Sunshine\Sunshine\sunshine.exe"
if (-not (Test-Path $sunshineExe)) {
    Write-Host 'Downloading Sunshine (portable lite)...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/LizardByte/Sunshine/releases/latest'
    $asset = $rel.assets | Where-Object name -eq 'Sunshine-Windows-AMD64-lite.zip'
    Invoke-WebRequest $asset.browser_download_url -OutFile "$root\sunshine-lite.zip"
    Expand-Archive "$root\sunshine-lite.zip" "$root\Sunshine" -Force
    Remove-Item "$root\sunshine-lite.zip"
}

# 6. Sunshine config: distinct name + ports so it can coexist with another host (e.g. Apollo/Vibepollo on 47989)
$confDir = "$root\Sunshine\Sunshine\config"
New-Item -ItemType Directory -Path $confDir -Force | Out-Null
@"
sunshine_name = $env:COMPUTERNAME-Child
port = 48989
capture = wgc
"@ | Set-Content "$confDir\sunshine.conf"
Write-Host 'Sunshine configured (base port 48989). Set web UI credentials with: sunshine.exe --creds <user> <pass>'

# 7. Firewall rule
if (-not (Get-NetFirewallRule -DisplayName 'ChildStream Sunshine' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'ChildStream Sunshine' -Direction Inbound -Program $sunshineExe -Action Allow -Profile Any | Out-Null
}

# 8. Startup hook (all users) so Sunshine starts inside child sessions automatically
$hook = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\childstream-sunshine.cmd'
Set-Content $hook "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\scripts\childsession-autostart.ps1`""

# 9. Desktop shortcut
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$env:USERPROFILE\Desktop\Child Session.lnk")
$lnk.TargetPath = "$root\ChildStream.exe"
$lnk.WorkingDirectory = $root
$lnk.Description = 'Second desktop for game streaming'
$lnk.Save()

Write-Host ''
Write-Host 'Done. Launch "Child Session" from the desktop, enter your Windows password once,'
Write-Host 'then pair Moonlight/Artemis with <host-ip>:48989.'
