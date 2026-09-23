BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\ChildStream.Runtime.psm1" -Force

    $script:now = [DateTime]::Parse('2026-09-22T12:00:00.0000000Z').ToUniversalTime()
    $script:state = [pscustomobject]@{
        schemaVersion = 1
        childSessionId = 42
        launcherProcessId = 1234
        launcherStartTimeUtc = '2026-09-22T11:59:00.0000000Z'
        issuedAtUtc = '2026-09-22T11:59:30.0000000Z'
    }
    $script:matchingProcess = [pscustomobject]@{
        StartTime = [DateTime]::Parse($script:state.launcherStartTimeUtc).ToLocalTime()
    }

    function New-TestRuntimeHooks {
        $state = [pscustomobject]@{
        ActiveStopwatch = $null
        NextStopwatchElapsedMilliseconds = [long]0
        SleepAdvanceMilliseconds = $null
        SleepRequests = @()
        Mutex = [pscustomobject]@{ Name = 'test-session-mutex' }
        MutexAcquired = $true
        MutexName = $null
        OnWaitMutex = $null
        ReleaseCount = 0
        DisposeCount = 0
        ReleaseThrows = $false
        NowUtc = [DateTime]::Parse('2026-09-22T12:00:00.0000000Z').ToUniversalTime()
        AuthorizationPath = $null
        SunshineStarted = $false
    }

        [pscustomobject]@{
            State = $state
        NewStopwatch = {
            param($hooks)
            $watch = [pscustomobject]@{
                ElapsedMilliseconds = [long]$hooks.State.NextStopwatchElapsedMilliseconds
            }
            $hooks.State.NextStopwatchElapsedMilliseconds = [long]0
            $hooks.State.ActiveStopwatch = $watch
            return $watch
        }
        Sleep = {
            param($hooks, [int]$milliseconds)
            $hooks.State.SleepRequests += $milliseconds
            $advance = $milliseconds
            if ($null -ne $hooks.State.SleepAdvanceMilliseconds) {
                $advance = [int]$hooks.State.SleepAdvanceMilliseconds
            }
            $hooks.State.ActiveStopwatch.ElapsedMilliseconds += [long]$advance
        }
        NowUtc = {
            param($hooks)
            return $hooks.State.NowUtc
        }
        CreateMutex = {
            param($hooks, [string]$name)
            $hooks.State.MutexName = $name
            return $hooks.State.Mutex
        }
        WaitMutex = {
            param($hooks, $mutex, [int]$milliseconds)
            if ($null -ne $hooks.State.OnWaitMutex) {
                & $hooks.State.OnWaitMutex $hooks
            }
            return [bool]$hooks.State.MutexAcquired
        }
        ReleaseMutex = {
            param($hooks, $mutex)
            $hooks.State.ReleaseCount++
            if ($hooks.State.ReleaseThrows) { throw 'release failed' }
        }
        DisposeMutex = {
            param($hooks, $mutex)
            $hooks.State.DisposeCount++
        }
        }
    }

    function Install-TestRuntimeHooks {
        param([Parameter(Mandatory)]$Hooks)

        InModuleScope ChildStream.Runtime -Parameters @{ TestHooks = $Hooks } {
            $script:ChildStreamRuntimeHooks = $TestHooks
        }
    }
}

Describe 'Read-ChildSessionAuthorization' {
    It 'JSONの許可状態を読み取る' {
        $path = Join-Path $TestDrive 'authorization.json'
        $script:state | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

        $actual = Read-ChildSessionAuthorization -Path $path

        $actual.childSessionId | Should -Be 42
        $actual.launcherProcessId | Should -Be 1234
    }

    It '壊れたJSONを理由付き例外で拒否する' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{not-json' -Encoding UTF8

        { Read-ChildSessionAuthorization -Path $path } |
            Should -Throw -ExpectedMessage 'authorization-read-failed:*'
    }

    It '実JSONの数値型を認可判定へ保持する' {
        $path = Join-Path $TestDrive 'numeric.json'
        $json = '{"schemaVersion":1,"childSessionId":42,"launcherProcessId":1234,"launcherStartTimeUtc":"2026-09-22T11:59:00.0000000Z","issuedAtUtc":"2026-09-22T11:59:30.0000000Z"}'
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8

        $actual = Read-ChildSessionAuthorization -Path $path
        $result = Test-ChildSessionAuthorization -State $actual -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeTrue
    }

    It '実JSONの<propertyName>文字列型を拒否する' -TestCases @(
        @{
            propertyName = 'schemaVersion'
            json = '{"schemaVersion":"1","childSessionId":42,"launcherProcessId":1234,"launcherStartTimeUtc":"2026-09-22T11:59:00.0000000Z","issuedAtUtc":"2026-09-22T11:59:30.0000000Z"}'
        }
        @{
            propertyName = 'childSessionId'
            json = '{"schemaVersion":1,"childSessionId":"42","launcherProcessId":1234,"launcherStartTimeUtc":"2026-09-22T11:59:00.0000000Z","issuedAtUtc":"2026-09-22T11:59:30.0000000Z"}'
        }
        @{
            propertyName = 'launcherProcessId'
            json = '{"schemaVersion":1,"childSessionId":42,"launcherProcessId":"1234","launcherStartTimeUtc":"2026-09-22T11:59:00.0000000Z","issuedAtUtc":"2026-09-22T11:59:30.0000000Z"}'
        }
    ) {
        param($propertyName, $json)
        $path = Join-Path $TestDrive "$propertyName.json"
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8

        $actual = Read-ChildSessionAuthorization -Path $path
        $result = Test-ChildSessionAuthorization -State $actual -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be "invalid-property:$propertyName"
    }
}

Describe 'Test-ChildSessionAuthorization' {
    It '一致する新しい許可を受理する' {
        $result = Test-ChildSessionAuthorization -State $script:state -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            if ($id -ne 1234) { throw "unexpected process id: $id" }
            $script:matchingProcess
        }

        $result.Authorized | Should -BeTrue
        $result.Reason | Should -Be 'authorized'
    }

    It '通常RDP相当の異なるSession IDを拒否する' {
        $result = Test-ChildSessionAuthorization -State $script:state -CurrentSessionId 99 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'session-mismatch'
    }

    It '未知のスキーマを拒否する' {
        $unknownSchemaState = $script:state.PSObject.Copy()
        $unknownSchemaState.schemaVersion = 2

        $result = Test-ChildSessionAuthorization -State $unknownSchemaState -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'schema-mismatch'
    }

    It '<propertyName>の文字列数値を拒否する' -TestCases @(
        @{ propertyName = 'schemaVersion' }
        @{ propertyName = 'childSessionId' }
        @{ propertyName = 'launcherProcessId' }
    ) {
        param($propertyName)
        $stringNumberState = $script:state.PSObject.Copy()
        $stringNumberState.$propertyName = [string]$stringNumberState.$propertyName

        $result = Test-ChildSessionAuthorization -State $stringNumberState -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be "invalid-property:$propertyName"
    }

    It '<propertyName>の非UTCラウンドトリップ日時を拒否する' -TestCases @(
        @{ propertyName = 'issuedAtUtc'; value = '2026-09-22T11:59:30.0000000' }
        @{ propertyName = 'issuedAtUtc'; value = '2026-09-22T11:59:30.0000000+00:00' }
        @{ propertyName = 'launcherStartTimeUtc'; value = '2026-09-22T11:59:00.0000000' }
        @{ propertyName = 'launcherStartTimeUtc'; value = '2026-09-22T11:59:00.0000000+00:00' }
    ) {
        param($propertyName, $value)
        $nonUtcState = $script:state.PSObject.Copy()
        $nonUtcState.$propertyName = $value

        $result = Test-ChildSessionAuthorization -State $nonUtcState -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be "invalid-property:$propertyName"
    }

    It '発行から121秒経過した許可を拒否する' {
        $expiredState = $script:state.PSObject.Copy()
        $expiredState.issuedAtUtc = '2026-09-22T11:57:59.0000000Z'

        $result = Test-ChildSessionAuthorization -State $expiredState -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'authorization-expired'
    }

    It '5秒を超えて未来に発行された許可を拒否する' {
        $futureState = $script:state.PSObject.Copy()
        $futureState.issuedAtUtc = '2026-09-22T12:00:06.0000000Z'

        $result = Test-ChildSessionAuthorization -State $futureState -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $script:matchingProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'issued-in-future'
    }

    It 'ランチャーPIDが存在しない許可を拒否する' {
        $result = Test-ChildSessionAuthorization -State $script:state -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            throw 'process not found'
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'launcher-not-running'
    }

    It 'PIDが再利用され起動時刻が異なる場合に拒否する' {
        $otherProcess = [pscustomobject]@{
            StartTime = [DateTime]::Parse('2026-09-22T11:58:00.0000000Z').ToLocalTime()
        }

        $result = Test-ChildSessionAuthorization -State $script:state -CurrentSessionId 42 -NowUtc $script:now -ProcessLookup {
            param($id)
            $otherProcess
        }

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'launcher-start-time-mismatch'
    }

    It '必須プロパティが欠けた状態を例外なしで拒否する' {
        $missingPropertyState = [pscustomobject]@{
            schemaVersion = 1
            childSessionId = 42
            launcherProcessId = 1234
            launcherStartTimeUtc = '2026-09-22T11:59:00.0000000Z'
        }

        $result = Test-ChildSessionAuthorization -State $missingPropertyState -CurrentSessionId 42 -NowUtc $script:now

        $result.Authorized | Should -BeFalse
        $result.Reason | Should -Be 'missing-property:issuedAtUtc'
    }
}

Describe 'Invoke-ChildSessionSunshine' {
    BeforeEach {
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
        $authorizationDirectory = Join-Path $env:LOCALAPPDATA 'ChildStream'
        New-Item -ItemType Directory -Path $authorizationDirectory -Force | Out-Null
        $script:authorizationPath = Join-Path $authorizationDirectory 'active-child-session.json'
        $script:state | ConvertTo-Json | Set-Content -LiteralPath $script:authorizationPath -Encoding UTF8

        $script:runtimeHooks = New-TestRuntimeHooks
        $script:runtimeHooks.State.AuthorizationPath = $script:authorizationPath
        Install-TestRuntimeHooks -Hooks $script:runtimeHooks

        $script:root = Join-Path $TestDrive 'repo'
        $sunshineDirectory = Join-Path $script:root 'Sunshine\Sunshine'
        New-Item -ItemType Directory -Path $sunshineDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sunshineDirectory 'sunshine.exe') -Value 'test executable'

        Mock Get-Date -ModuleName ChildStream.Runtime {
            [DateTime]::Parse('2026-09-22T12:00:00.0000000Z').ToUniversalTime()
        }
        Mock Add-Content -ModuleName ChildStream.Runtime {}
        Mock Start-Process -ModuleName ChildStream.Runtime {
            $script:runtimeHooks.State.SunshineStarted = $true
        }
    }

    AfterEach {
        InModuleScope ChildStream.Runtime { $script:ChildStreamRuntimeHooks = $null }
        $env:LOCALAPPDATA = $script:originalLocalAppData
    }

    It '同じSession IDのSunshineが実行中なら重複起動しない' {
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) {
                return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 42 }
            }
            if ($Id -eq 1234) {
                return [pscustomobject]@{
                    StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                }
            }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 0 -Exactly
    }

    It '現在のSession IDと許可が異なる場合は起動しない' {
        $otherSessionState = $script:state.PSObject.Copy()
        $otherSessionState.childSessionId = 99
        $otherSessionState | ConvertTo-Json | Set-Content -LiteralPath $script:authorizationPath -Encoding UTF8
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) { return @() }
            if ($Id -eq 1234) {
                return [pscustomobject]@{
                    StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                }
            }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 0 -Exactly
    }

    It 'Sunshine列挙の非終端エラーを空集合として扱わない' {
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if ($PesterBoundParameters.ContainsKey('Id')) {
                if ($Id -eq 1234) {
                    return [pscustomobject]@{
                        StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                    }
                }
                return [pscustomobject]@{ SessionId = 42 }
            }
            throw 'process enumeration failed'
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 0 -Exactly
    }

    It '別のSession IDのSunshineだけが実行中なら起動する' {
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) {
                if ($script:runtimeHooks.State.SunshineStarted) {
                    return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 42 }
                }
                return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 99 }
            }
            if ($Id -eq 1234) {
                return [pscustomobject]@{
                    StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                }
            }
            return [pscustomobject]@{ SessionId = 42 }
        }
        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 1 -Exactly
    }

    It '排他取得後の再検査で同じSession IDの競合起動を防ぐ' {
        $script:sunshineEnumerationCount = 0
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if ($PesterBoundParameters.ContainsKey('Id')) {
                if ($Id -eq 1234) {
                    return [pscustomobject]@{
                        StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                    }
                }
                return [pscustomobject]@{ SessionId = 42 }
            }
            $script:sunshineEnumerationCount++
            if ($script:sunshineEnumerationCount -eq 1) { return @() }
            return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        $script:sunshineEnumerationCount | Should -Be 2
        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 0 -Exactly
    }

    It '排他待機中に認可が削除された場合は起動しない' {
        $script:runtimeHooks.State.OnWaitMutex = {
            param($hooks)
            Remove-Item -LiteralPath $hooks.State.AuthorizationPath -Force
        }
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) { return @() }
            if ($Id -eq 1234) { return $script:matchingProcess }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 0 -Exactly
        $script:runtimeHooks.State.ReleaseCount | Should -Be 1
        $script:runtimeHooks.State.DisposeCount | Should -Be 1
    }

    It '起動後5秒以内に同一SessionのSunshineを確認できなければ成功扱いしない' {
        $script:runtimeHooks.State.SleepAdvanceMilliseconds = 5000
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) { return @() }
            if ($Id -eq 1234) { return $script:matchingProcess }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 1 -Exactly
        Assert-MockCalled Add-Content -ModuleName ChildStream.Runtime -ParameterFilter {
            $Value -like '*launch failed: sunshine-start-timeout*'
        }
    }

    It 'Mutex解放失敗時もDisposeを試行する' {
        $script:runtimeHooks.State.ReleaseThrows = $true
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) {
                if ($script:runtimeHooks.State.SunshineStarted) {
                    return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 42 }
                }
                return @()
            }
            if ($Id -eq 1234) { return $script:matchingProcess }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        $script:runtimeHooks.State.ReleaseCount | Should -Be 1
        $script:runtimeHooks.State.DisposeCount | Should -Be 1
    }

    It '認可待機で残り時間を超えるsleepを要求しない' {
        Remove-Item -LiteralPath $script:authorizationPath -Force

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 1

        $script:runtimeHooks.State.SleepRequests.Count | Should -Be 1
        $script:runtimeHooks.State.SleepRequests[0] | Should -BeLessOrEqual 1000
    }

    It 'HighestTaskではRunAsを使わず通常起動する' {
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) {
                if ($script:runtimeHooks.State.SunshineStarted) {
                    return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 42 }
                }
                return @()
            }
            if ($Id -eq 1234) {
                return [pscustomobject]@{
                    StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                }
            }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode HighestTask -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 1 -Exactly -ParameterFilter {
            $null -eq $Verb
        }
    }

    It 'PromptedStartupだけRunAsで起動する' {
        Mock Get-Process -ModuleName ChildStream.Runtime {
            if (-not $PesterBoundParameters.ContainsKey('Id')) {
                if ($script:runtimeHooks.State.SunshineStarted) {
                    return [pscustomobject]@{ ProcessName = 'sunshine'; SessionId = 42 }
                }
                return @()
            }
            if ($Id -eq 1234) {
                return [pscustomobject]@{
                    StartTime = [DateTime]::Parse('2026-09-22T11:59:00.0000000Z').ToLocalTime()
                }
            }
            return [pscustomobject]@{ SessionId = 42 }
        }

        Invoke-ChildSessionSunshine -Root $script:root -LaunchMode PromptedStartup -WaitSeconds 0

        Assert-MockCalled Start-Process -ModuleName ChildStream.Runtime -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs'
        }
    }
}

Describe 'Get-ChildStreamRetryDelayMilliseconds' {
    It '残り250ミリ秒なら1秒ではなく250ミリ秒だけ待つ' {
        InModuleScope ChildStream.Runtime {
            Get-ChildStreamRetryDelayMilliseconds -ElapsedMilliseconds 750 -WaitMilliseconds 1000 |
                Should -Be 250
        }
    }

    It '単調時計が期限へ達した後は待たない' {
        InModuleScope ChildStream.Runtime {
            Get-ChildStreamRetryDelayMilliseconds -ElapsedMilliseconds 1000 -WaitMilliseconds 1000 |
                Should -Be 0
        }
    }
}
