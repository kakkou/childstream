BeforeAll {
    . "$PSScriptRoot\..\scripts\uninstall.ps1"
}

Describe 'Invoke-ChildStreamUninstall' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive 'ProgramData\ChildStream\install-state.json'
        $script:journalPath = Join-Path (Split-Path -Parent $script:statePath) 'install-journal.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:statePath) -Force | Out-Null
        $script:state = [pscustomobject]@{
            schemaVersion=1; installRoot=(Join-Path $TestDrive 'install'); childSessionsEnabled=$false
            registry=@(
                [pscustomobject]@{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; Name='fDenyTSConnections'; Existed=$true; Value=1; Kind='DWord' },
                [pscustomobject]@{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations'; Name='DWMFRAMEINTERVAL'; Existed=$false },
                [pscustomobject]@{ Path='HKCU:\Software\Microsoft\Terminal Server Client'; Name='RemoteDesktop_SuppressWhenMinimized'; Existed=$false }
            )
            firewall=@(); startupHook=[pscustomobject]@{ Path='hook'; Existed=$false }
            scheduledTask=[pscustomobject]@{ TaskName='ChildStream Sunshine'; Existed=$false }
            desktopShortcut=[pscustomobject]@{ Path='shortcut'; Existed=$false }
            sunshine=[pscustomobject]@{ Path=(Join-Path $TestDrive 'install\Sunshine'); BackupPath='backup'; Existed=$false }
            launcher=[pscustomobject]@{ Path=(Join-Path $TestDrive 'install\ChildStream.exe'); BackupPath='backup'; Existed=$false }
        }
        $script:state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:statePath -Encoding UTF8
        [pscustomobject]@{ schemaVersion=1; entries=@([pscustomobject]@{ change='childSessions'; status='applied'; createdFirewallRuleNames=@() }) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:journalPath -Encoding UTF8
    }

    It '状態ファイルがない場合はシステム変更を行わない' {
        Mock Restore-ChildStreamState {}
        Remove-Item -LiteralPath $script:statePath
        { Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false } | Should -Throw
        Should -Invoke Restore-ChildStreamState -Times 0
    }

    It 'ジャーナルがない場合はシステム変更を行わない' {
        Mock Restore-ChildStreamState {}
        Remove-Item -LiteralPath $script:journalPath
        { Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false } | Should -Throw
        Should -Invoke Restore-ChildStreamState -Times 0
    }

    It '壊れた状態ではシステム変更を行わない' {
        Mock Restore-ChildStreamState {}
        Set-Content -LiteralPath $script:statePath -Value '{broken' -Encoding UTF8
        { Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false } | Should -Throw
        Should -Invoke Restore-ChildStreamState -Times 0
    }

    It '復元資源の必須項目が欠けた状態では変更しない' {
        Mock Move-Item {}
        Mock Copy-Item {}
        Mock Restore-ChildStreamState {}
        $script:state.sunshine = [pscustomobject]@{ Existed=$false; BackupPath='backup' }
        $script:state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:statePath -Encoding UTF8

        { Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false } | Should -Throw

        Should -Invoke Move-Item -Times 0
        Should -Invoke Copy-Item -Times 0
        Should -Invoke Restore-ChildStreamState -Times 0
    }

    It 'Sunshineデータを削除せずバックアップへ移動する' {
        $sunshine = $script:state.sunshine.Path
        New-Item -ItemType Directory -Path $sunshine -Force | Out-Null
        [pscustomobject]@{ schemaVersion=1; entries=@([pscustomobject]@{ change='sunshine'; status='applied'; createdFirewallRuleNames=@() }) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:journalPath -Encoding UTF8
        Mock Move-Item {}
        Mock Copy-Item {}
        Mock Restore-ChildStreamState {}
        Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false
        Should -Invoke Move-Item -ParameterFilter { $LiteralPath -eq $sunshine -and $Destination -match 'Backups' }
    }

    It '保存状態とjournalだけを共通復元処理へ渡す' {
        Mock Restore-ChildStreamState {}
        Mock Move-Item {}
        Mock Copy-Item {}
        Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false
        Should -Invoke Restore-ChildStreamState -Times 1 -ParameterFilter { $JournalPath -eq $script:journalPath }
    }

    It '復元後に状態とjournalを監査用バックアップへ移す' {
        Mock Restore-ChildStreamState {}
        Invoke-ChildStreamUninstall -StatePath $script:statePath -Confirm:$false
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
        Test-Path -LiteralPath $script:journalPath | Should -BeFalse
        @(Get-ChildItem -Path (Join-Path (Split-Path -Parent $script:statePath) 'Backups') -Recurse -Filter 'install-state.json').Count | Should -Be 1
    }
}
