BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\ChildStream.Setup.psm1" -Force
}

Describe 'Save-ChildStreamInstallStateOnce' {
    It '2回目の保存で最初の状態を上書きしない' {
        $path = Join-Path $TestDrive 'install-state.json'
        Save-ChildStreamInstallStateOnce -State ([pscustomobject]@{ schemaVersion = 1; marker = 'before' }) -Path $path
        { Save-ChildStreamInstallStateOnce -State ([pscustomobject]@{ schemaVersion = 1; marker = 'after' }) -Path $path } | Should -Throw
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).marker | Should -Be 'before'
    }

    It '失敗時に一時ファイルを残さない' {
        $path = Join-Path $TestDrive 'state.json'
        Save-ChildStreamInstallStateOnce -State ([pscustomobject]@{ schemaVersion = 1 }) -Path $path
        { Save-ChildStreamInstallStateOnce -State ([pscustomobject]@{ schemaVersion = 1 }) -Path $path } | Should -Throw
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'インストールジャーナル' {
    It '変更前予約と変更後完了を永続化する' {
        $path = Join-Path $TestDrive 'install-journal.json'
        Save-ChildStreamInstallJournalOnce -Path $path
        Start-ChildStreamChange -Path $path -Change 'firewall' -CreatedFirewallRuleNames @('ChildStream Sunshine')
        (Read-ChildStreamInstallJournal -Path $path).entries[0].status | Should -Be 'pending'
        Complete-ChildStreamChange -Path $path -Change 'firewall'
        $journal = Read-ChildStreamInstallJournal -Path $path
        $journal.entries[0].status | Should -Be 'applied'
        $journal.entries[0].createdFirewallRuleNames | Should -Contain 'ChildStream Sunshine'
    }

    It '同じ変更のFirewall名を増分かつ重複なしで記録する' {
        $path = Join-Path $TestDrive 'incremental-install-journal.json'
        Save-ChildStreamInstallJournalOnce -Path $path
        Start-ChildStreamChange -Path $path -Change 'firewall' -CreatedFirewallRuleNames @('rule-a')
        Start-ChildStreamChange -Path $path -Change 'firewall' -CreatedFirewallRuleNames @('rule-b', 'rule-a')
        $entry = (Read-ChildStreamInstallJournal -Path $path).entries[0]
        @($entry.createdFirewallRuleNames).Count | Should -Be 2
        $entry.createdFirewallRuleNames | Should -Contain 'rule-a'
        $entry.createdFirewallRuleNames | Should -Contain 'rule-b'
    }

    It '壊れたジャーナルを拒否する' {
        $path = Join-Path $TestDrive 'broken-install-journal.json'
        Set-Content -LiteralPath $path -Value '{broken' -Encoding UTF8
        { Read-ChildStreamInstallJournal -Path $path } | Should -Throw
    }
}

Describe 'Restore-RegistryValueSnapshot' {
    It '元々存在しない値を削除し不存在を確認する' {
        Mock Remove-ItemProperty -ModuleName ChildStream.Setup {}
        Mock Get-ItemProperty -ModuleName ChildStream.Setup { throw [Management.Automation.ItemNotFoundException]::new('missing') }
        Restore-RegistryValueSnapshot -Snapshot ([pscustomobject]@{ Path='HKCU:\Software\ChildStreamTest'; Name='Value'; Existed=$false })
        Should -Invoke Remove-ItemProperty -ModuleName ChildStream.Setup -Times 1 -ParameterFilter { $Name -eq 'Value' }
    }

    It '削除後も値が残る場合は失敗する' {
        Mock Remove-ItemProperty -ModuleName ChildStream.Setup {}
        Mock Get-ItemProperty -ModuleName ChildStream.Setup { [pscustomobject]@{ Value = 1 } }
        { Restore-RegistryValueSnapshot -Snapshot ([pscustomobject]@{ Path='HKCU:\Software\ChildStreamTest'; Name='Value'; Existed=$false }) } | Should -Throw
    }

    It '存在したDWORDを元の型で復元する' {
        Mock Set-ItemProperty -ModuleName ChildStream.Setup {}
        Restore-RegistryValueSnapshot -Snapshot ([pscustomobject]@{ Path='HKCU:\Software\ChildStreamTest'; Name='Value'; Existed=$true; Value=2; Kind='DWord' })
        Should -Invoke Set-ItemProperty -ModuleName ChildStream.Setup -Times 1 -ParameterFilter { $Type -eq 'DWord' -and $Value -eq 2 }
    }
}

Describe 'Firewallスナップショット' {
    It '同名の複数ルールとポートフィルターを配列で保存する' {
        Mock Get-NetFirewallRule -ModuleName ChildStream.Setup {
            @(
                [pscustomobject]@{ Name='rule-1'; DisplayName='ChildStream Sunshine'; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Private'; EdgeTraversalPolicy='Block'; Description=''; Group='' },
                [pscustomobject]@{ Name='rule-2'; DisplayName='ChildStream Sunshine'; Enabled='False'; Direction='Outbound'; Action='Block'; Profile='Private'; EdgeTraversalPolicy='Block'; Description=''; Group='' }
            )
        }
        Mock Get-ChildStreamFirewallApplicationFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Program='C:\Sunshine\sunshine.exe'; Package=$null } }
        Mock Get-ChildStreamFirewallAddressFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ LocalAddress='Any'; RemoteAddress='LocalSubnet' } }
        Mock Get-ChildStreamFirewallPortFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Protocol='TCP'; LocalPort='47989'; RemotePort='Any'; IcmpType='Any'; DynamicTarget='Any' } }
        Mock Get-ChildStreamFirewallServiceFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Service='Any' } }
        Mock Get-ChildStreamFirewallInterfaceFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ InterfaceAlias='Any'; InterfaceType='Any' } }
        Mock Get-ChildStreamFirewallSecurityFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Authentication='NotRequired'; Encryption='NotRequired'; OverrideBlockRules='False'; LocalUser='Any'; RemoteUser='Any'; RemoteMachine='Any' } }

        $snapshot = Get-FirewallRuleSnapshot -DisplayName 'ChildStream Sunshine'

        @($snapshot).Count | Should -Be 2
        $snapshot[0].Protocol | Should -Be 'TCP'
        $snapshot[0].LocalPort | Should -Be '47989'
        $snapshot[1].Direction | Should -Be 'Outbound'
    }

    It '復元不能な高度設定を取得時点で拒否する' {
        Mock Get-NetFirewallRule -ModuleName ChildStream.Setup { [pscustomobject]@{ Name='rule-1'; DisplayName='ChildStream Sunshine'; Enabled='True'; Direction='Inbound'; Action='Allow'; Profile='Private'; EdgeTraversalPolicy='Block'; Description='unsupported'; Group='' } }
        Mock Get-ChildStreamFirewallApplicationFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Program='Any'; Package=$null } }
        Mock Get-ChildStreamFirewallAddressFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ LocalAddress='Any'; RemoteAddress='Any' } }
        Mock Get-ChildStreamFirewallPortFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Protocol='Any'; LocalPort='Any'; RemotePort='Any'; IcmpType='Any'; DynamicTarget='Any' } }
        Mock Get-ChildStreamFirewallServiceFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Service='Any' } }
        Mock Get-ChildStreamFirewallInterfaceFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ InterfaceAlias='Any'; InterfaceType='Any' } }
        Mock Get-ChildStreamFirewallSecurityFilter -ModuleName ChildStream.Setup { [pscustomobject]@{ Authentication='NotRequired'; Encryption='NotRequired'; OverrideBlockRules='False'; LocalUser='Any'; RemoteUser='Any'; RemoteMachine='Any' } }
        { Get-FirewallRuleSnapshot -DisplayName 'ChildStream Sunshine' } | Should -Throw
    }

    It 'Outbound復元ではEdgeTraversalPolicyを渡さない' {
        Mock Get-NetFirewallRule -ModuleName ChildStream.Setup { @() }
        Mock New-NetFirewallRule -ModuleName ChildStream.Setup {}
        $snapshot = @([pscustomobject]@{
            Name='rule-out'; DisplayName='ChildStream Sunshine'; Enabled='True'; Direction='Outbound'; Action='Block'; Profile='Private';
            Program='Any'; LocalAddress='Any'; RemoteAddress='LocalSubnet'; Protocol='TCP'; LocalPort='Any'; RemotePort='Any';
            IcmpType='Any'; Service='Any'; InterfaceAlias='Any'; InterfaceType='Any'; EdgeTraversalPolicy='Block';
            Description=''; Group=''; Package=$null; DynamicTarget='Any'
        })
        Restore-FirewallRuleSnapshot -Snapshot $snapshot -CreatedRuleNames @()
        Should -Invoke New-NetFirewallRule -ModuleName ChildStream.Setup -Times 1 -ParameterFilter { $Direction -eq 'Outbound' -and $null -eq $EdgeTraversalPolicy }
    }
}

Describe 'Backup-FileResource' {
    It '既存バックアップを上書きしない' {
        $source = Join-Path $TestDrive 'source.txt'
        $backup = Join-Path $TestDrive 'backup.txt'
        Set-Content -LiteralPath $source -Value 'new'
        Set-Content -LiteralPath $backup -Value 'original'
        { Backup-FileResource -Path $source -BackupPath $backup } | Should -Throw
        (Get-Content -LiteralPath $backup -Raw).Trim() | Should -Be 'original'
    }
}

Describe 'Restore-DirectoryResource' {
    It '置換したディレクトリをバックアップから戻す' {
        $path = Join-Path $TestDrive 'Sunshine'
        $backup = Join-Path $TestDrive 'Sunshine.backup'
        New-Item -ItemType Directory -Path $path,$backup -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'new.txt') -Value 'new'
        Set-Content -LiteralPath (Join-Path $backup 'old.txt') -Value 'old'
        Restore-DirectoryResource -Snapshot ([pscustomobject]@{ Path=$path; BackupPath=$backup; Existed=$true })
        Test-Path (Join-Path $path 'old.txt') | Should -BeTrue
        Test-Path $backup | Should -BeFalse
    }

    It '既存ディレクトリのバックアップ欠落時は現行データを削除しない' {
        $path = Join-Path $TestDrive 'Current-Sunshine'
        $backup = Join-Path $TestDrive 'Missing-Sunshine.backup'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'current.txt') -Value 'current'

        { Restore-DirectoryResource -Snapshot ([pscustomobject]@{ Path=$path; BackupPath=$backup; Existed=$true }) } |
            Should -Throw

        Test-Path (Join-Path $path 'current.txt') | Should -BeTrue
    }
}

Describe 'Restore-ChildSessionEnabledState' {
    It '無効状態へ戻した後check終了コード1を確認する' {
        Mock Start-Process -ModuleName ChildStream.Setup {
            if ($ArgumentList -contains '-disable') { return [pscustomobject]@{ ExitCode = 0 } }
            return [pscustomobject]@{ ExitCode = 1 }
        }
        Restore-ChildSessionEnabledState -Enabled $false -LauncherPath 'C:\ChildStream.exe'
        Should -Invoke Start-Process -ModuleName ChildStream.Setup -Times 2
    }
}

Describe 'Restore-ChildStreamState' {
    It 'pendingを含む記録済み変更だけを逆順に復元する' {
        $journalPath = Join-Path $TestDrive 'restore-install-journal.json'
        Save-ChildStreamInstallJournalOnce -Path $journalPath
        Start-ChildStreamChange -Path $journalPath -Change 'registry:fDenyTSConnections'
        Complete-ChildStreamChange -Path $journalPath -Change 'registry:fDenyTSConnections'
        Start-ChildStreamChange -Path $journalPath -Change 'firewall' -CreatedFirewallRuleNames @('rule-a')
        Mock Restore-RegistryValueSnapshot -ModuleName ChildStream.Setup {}
        Mock Restore-FirewallRuleSnapshot -ModuleName ChildStream.Setup {}
        $state = [pscustomobject]@{
            registry = @([pscustomobject]@{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; Name='fDenyTSConnections'; Existed=$true; Value=1; Kind='DWord' })
            firewall = @()
        }

        Restore-ChildStreamState -State $state -JournalPath $journalPath

        Should -Invoke Restore-FirewallRuleSnapshot -ModuleName ChildStream.Setup -Times 1 -ParameterFilter { $CreatedRuleNames -contains 'rule-a' }
        Should -Invoke Restore-RegistryValueSnapshot -ModuleName ChildStream.Setup -Times 1
    }
}
