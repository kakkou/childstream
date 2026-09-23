BeforeAll {
    . "$PSScriptRoot\..\scripts\setup.ps1"
}

Describe 'Sunshine配布物検証' {
    It 'バージョンとSHA-256を固定する' {
        $script:SunshineVersion | Should -Be 'v2026.914.233613'
        $script:SunshineAsset | Should -Be 'Sunshine-Windows-AMD64-lite.zip'
        $script:SunshineSha256 | Should -Be '233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b'
        $script:SunshineUri | Should -Be 'https://github.com/LizardByte/Sunshine/releases/download/v2026.914.233613/Sunshine-Windows-AMD64-lite.zip'
    }

    It 'ハッシュ不一致では展開しない' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = ('0' * 64) } }
        Mock Expand-Archive {}
        { Expand-VerifiedSunshine -ArchivePath "$TestDrive\sunshine.zip" -Destination "$TestDrive\Sunshine" } | Should -Throw
        Should -Invoke Expand-Archive -Times 0
    }

    It '一致するアーカイブだけ展開しバージョン情報を保存する' {
        Mock Get-FileHash { [pscustomobject]@{ Hash = $script:SunshineSha256 } }
        Mock Expand-Archive { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
        Expand-VerifiedSunshine -ArchivePath "$TestDrive\sunshine.zip" -Destination "$TestDrive\Sunshine"
        Should -Invoke Expand-Archive -Times 1
        (Get-Content "$TestDrive\Sunshine\childstream-version.json" -Raw | ConvertFrom-Json).version | Should -Be $script:SunshineVersion
    }
}

Describe 'Firewall' {
    It 'PrivateかつLocalSubnetだけを許可する' {
        Mock Get-NetFirewallRule { @() }
        Mock New-NetFirewallRule {}
        Set-ChildStreamFirewall -SunshineExe 'C:\ChildStream\Sunshine\Sunshine\sunshine.exe'
        Should -Invoke New-NetFirewallRule -Times 1 -ParameterFilter {
            $Name -eq 'ChildStream-Sunshine' -and $Profile -eq 'Private' -and
            $RemoteAddress -eq 'LocalSubnet' -and $Direction -eq 'Inbound' -and $Action -eq 'Allow'
        }
    }
}

Describe '自動起動' {
    It 'HighestTaskはInteractiveかつHighestで対象ユーザーへ登録する' {
        Mock New-ScheduledTaskAction {
            [pscustomobject]@{ PSTypeName='Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskAction' }
        }
        Mock New-ScheduledTaskTrigger {
            [pscustomobject]@{ PSTypeName='Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger' }
        }
        Mock New-ScheduledTaskPrincipal {
            [pscustomobject]@{ PSTypeName='Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskPrincipal2' }
        }
        Mock Register-ScheduledTask {}
        Set-ChildStreamScheduledTask -Root 'C:\ChildStream' -UserName 'HOST\user'
        Should -Invoke New-ScheduledTaskPrincipal -Times 1 -ParameterFilter { $LogonType -eq 'Interactive' -and $RunLevel -eq 'Highest' -and $UserId -eq 'HOST\user' }
        Should -Invoke New-ScheduledTaskAction -Times 1 -ParameterFilter { $Argument -like '*-LaunchMode HighestTask*' }
    }

    It 'PromptedStartupフックはRunAsモードだけを指定する' {
        $path = Join-Path $TestDrive 'childstream-sunshine.cmd'
        Set-ChildStreamStartupHook -Root 'C:\ChildStream' -Path $path
        (Get-Content -LiteralPath $path -Raw) | Should -Match '-LaunchMode PromptedStartup'
    }
}

Describe 'セットアップ順序とrollback' {
    It '変更前にpendingを記録し変更後に完了する' {
        Mock Start-ChildStreamChange {}
        Mock Complete-ChildStreamChange {}
        Mock Set-ItemProperty {}
        Mock Get-ItemProperty { [pscustomobject]@{ Value = 8 } }
        Set-VerifiedRegistryValue -Path 'HKCU:\Software\ChildStreamTest' -Name 'Value' -Value 8 -JournalPath "$TestDrive\journal.json" -Change 'registry:Value'
        Should -Invoke Start-ChildStreamChange -Times 1
        Should -Invoke Complete-ChildStreamChange -Times 1
    }

    It '変更開始後の失敗ではjournalから復元する' {
        Mock Assert-ChildStreamAdministrator {}
        Mock New-ChildStreamSetupStage { [pscustomobject]@{ Root=$TestDrive; Launcher="$TestDrive\ChildStream.exe"; Sunshine="$TestDrive\Sunshine" } }
        Mock New-ChildStreamInstallState { [pscustomobject]@{ schemaVersion=1; installRoot=$TestDrive; startupHook=$null; desktopShortcut=$null; sunshine=$null } }
        Mock Save-ChildStreamInstallStateOnce {}
        Mock Save-ChildStreamInstallJournalOnce {}
        Mock Start-ChildStreamChange {}
        Mock Complete-ChildStreamChange {}
        Mock Set-VerifiedRegistryValue { throw 'simulated failure' }
        Mock Restore-ChildStreamState {}
        { Invoke-ChildStreamSetup -InstallRoot $TestDrive -Confirm:$false } | Should -Throw
        Should -Invoke Restore-ChildStreamState -Times 1 -ParameterFilter { $JournalPath -like '*install-journal.json' }
    }
}
