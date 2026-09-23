Set-StrictMode -Version 2.0

$script:ChildStreamRuntimeHooks = $null

function New-ChildStreamStopwatch {
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        return & $script:ChildStreamRuntimeHooks.NewStopwatch $script:ChildStreamRuntimeHooks
    }
    return [Diagnostics.Stopwatch]::StartNew()
}

function Invoke-ChildStreamSleep {
    param([Parameter(Mandatory)][int]$Milliseconds)
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        & $script:ChildStreamRuntimeHooks.Sleep $script:ChildStreamRuntimeHooks $Milliseconds
        return
    }
    Start-Sleep -Milliseconds $Milliseconds
}

function Get-ChildStreamNowUtc {
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        return (& $script:ChildStreamRuntimeHooks.NowUtc $script:ChildStreamRuntimeHooks).ToUniversalTime()
    }
    return (Get-Date).ToUniversalTime()
}

function New-ChildStreamSessionMutex {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        return & $script:ChildStreamRuntimeHooks.CreateMutex $script:ChildStreamRuntimeHooks $Name
    }
    return [Threading.Mutex]::new($false, $Name)
}

function Wait-ChildStreamSessionMutex {
    param($Mutex, [Parameter(Mandatory)][int]$Milliseconds)
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        return [bool](& $script:ChildStreamRuntimeHooks.WaitMutex $script:ChildStreamRuntimeHooks $Mutex $Milliseconds)
    }
    return $Mutex.WaitOne($Milliseconds)
}

function Release-ChildStreamSessionMutex {
    param($Mutex)
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        & $script:ChildStreamRuntimeHooks.ReleaseMutex $script:ChildStreamRuntimeHooks $Mutex
        return
    }
    $Mutex.ReleaseMutex()
}

function Close-ChildStreamSessionMutex {
    param($Mutex)
    if ($null -ne $script:ChildStreamRuntimeHooks) {
        & $script:ChildStreamRuntimeHooks.DisposeMutex $script:ChildStreamRuntimeHooks $Mutex
        return
    }
    $Mutex.Dispose()
}

function New-AuthorizationResult {
    param(
        [Parameter(Mandatory)][bool]$Authorized,
        [Parameter(Mandatory)][string]$Reason
    )

    [pscustomobject]@{
        Authorized = $Authorized
        Reason = $Reason
    }
}

function Write-ChildStreamRuntimeLog {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        Add-Content -LiteralPath (Join-Path $Root 'autostart.log') -Value "$(Get-Date -Format o) $Message" -ErrorAction Stop
    }
    catch {
        # Logging must never turn a safe refusal into a launch or an interactive error.
    }
}

function Read-ChildSessionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "authorization-read-failed: $($_.Exception.Message)"
    }
}

function Test-ChildStreamJsonInteger {
    param($Value)

    return ($Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64])
}

function Test-TryParseChildStreamUtcTimestamp {
    param(
        $Value,
        [Parameter(Mandatory)][ref]$Result
    )

    if ($Value -isnot [string] -or
        $Value -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$') {
        return $false
    }

    $parsed = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParseExact(
        $Value,
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref]$parsed)) {
        return $false
    }

    $Result.Value = $parsed
    return $true
}

function Get-ChildStreamRetryDelayMilliseconds {
    param(
        [Parameter(Mandatory)][long]$ElapsedMilliseconds,
        [Parameter(Mandatory)][long]$WaitMilliseconds
    )

    $remainingMilliseconds = $WaitMilliseconds - $ElapsedMilliseconds
    if ($remainingMilliseconds -le 0) {
        return 0
    }

    return [int][Math]::Min([long]1000, $remainingMilliseconds)
}

function Find-ChildStreamSunshineInSession {
    param(
        [Parameter(Mandatory)][int]$SessionId
    )

    try {
        $matchingProcesses = @(
            Get-Process -ErrorAction Stop |
                Where-Object {
                    $_.ProcessName -ieq 'sunshine' -and [int]$_.SessionId -eq $SessionId
                }
        )
        return [pscustomobject]@{
            Succeeded = $true
            Processes = $matchingProcesses
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false
            Processes = @()
        }
    }
}

function Test-ChildSessionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$CurrentSessionId,
        [Parameter(Mandatory)][DateTime]$NowUtc,
        [scriptblock]$ProcessLookup = { param($id) Get-Process -Id $id -ErrorAction Stop }
    )

    $requiredProperties = @(
        'schemaVersion',
        'childSessionId',
        'launcherProcessId',
        'launcherStartTimeUtc',
        'issuedAtUtc'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($null -eq $State -or
            $null -eq $State.PSObject.Properties[$propertyName] -or
            $null -eq $State.$propertyName -or
            [string]::IsNullOrWhiteSpace([string]$State.$propertyName)) {
            return New-AuthorizationResult -Authorized $false -Reason "missing-property:$propertyName"
        }
    }

    if (-not (Test-ChildStreamJsonInteger $State.schemaVersion)) {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:schemaVersion'
    }
    try {
        $schemaVersion = [Convert]::ToInt32($State.schemaVersion)
    }
    catch {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:schemaVersion'
    }
    if ($schemaVersion -ne 1) {
        return New-AuthorizationResult -Authorized $false -Reason 'schema-mismatch'
    }

    if (-not (Test-ChildStreamJsonInteger $State.childSessionId)) {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:childSessionId'
    }
    try {
        $childSessionId = [Convert]::ToInt32($State.childSessionId)
    }
    catch {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:childSessionId'
    }
    if ($childSessionId -ne $CurrentSessionId) {
        return New-AuthorizationResult -Authorized $false -Reason 'session-mismatch'
    }

    $issuedAtUtc = [DateTime]::MinValue
    if (-not (Test-TryParseChildStreamUtcTimestamp -Value $State.issuedAtUtc -Result ([ref]$issuedAtUtc))) {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:issuedAtUtc'
    }

    $ageSeconds = ($NowUtc.ToUniversalTime() - $issuedAtUtc).TotalSeconds
    if ($ageSeconds -lt -5) {
        return New-AuthorizationResult -Authorized $false -Reason 'issued-in-future'
    }
    if ($ageSeconds -gt 120) {
        return New-AuthorizationResult -Authorized $false -Reason 'authorization-expired'
    }

    if (-not (Test-ChildStreamJsonInteger $State.launcherProcessId)) {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:launcherProcessId'
    }
    try {
        $launcherProcessId = [Convert]::ToInt32($State.launcherProcessId)
    }
    catch {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:launcherProcessId'
    }
    if ($launcherProcessId -le 0) {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:launcherProcessId'
    }

    try {
        $launcherProcess = & $ProcessLookup $launcherProcessId
        if ($null -eq $launcherProcess) {
            throw 'Process lookup returned no process.'
        }
    }
    catch {
        return New-AuthorizationResult -Authorized $false -Reason 'launcher-not-running'
    }

    $expectedStartUtc = [DateTime]::MinValue
    if (-not (Test-TryParseChildStreamUtcTimestamp -Value $State.launcherStartTimeUtc -Result ([ref]$expectedStartUtc))) {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:launcherStartTimeUtc'
    }
    try {
        $actualStartUtc = ([DateTime]$launcherProcess.StartTime).ToUniversalTime()
    }
    catch {
        return New-AuthorizationResult -Authorized $false -Reason 'invalid-property:launcherStartTimeUtc'
    }

    if ([Math]::Abs(($actualStartUtc - $expectedStartUtc).TotalSeconds) -gt 1) {
        return New-AuthorizationResult -Authorized $false -Reason 'launcher-start-time-mismatch'
    }

    return New-AuthorizationResult -Authorized $true -Reason 'authorized'
}

function Invoke-ChildSessionSunshine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]
        [ValidateSet('HighestTask', 'PromptedStartup')]
        [string]$LaunchMode,
        [ValidateRange(0, 60)]
        [int]$WaitSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Write-ChildStreamRuntimeLog -Root $Root -Message 'authorization refused: local-app-data-unavailable'
        return
    }

    try {
        $currentSessionId = [int](Get-Process -Id $PID -ErrorAction Stop).SessionId
    }
    catch {
        Write-ChildStreamRuntimeLog -Root $Root -Message 'authorization refused: current-session-unavailable'
        return
    }

    $authorizationPath = Join-Path (Join-Path $env:LOCALAPPDATA 'ChildStream') 'active-child-session.json'
    $waitMilliseconds = [long]$WaitSeconds * 1000
    $waitTimer = New-ChildStreamStopwatch
    $authorization = $null
    $lastReason = 'authorization-state-missing'
    $attemptedAuthorization = $false

    while ($true) {
        if ($attemptedAuthorization -and $waitTimer.ElapsedMilliseconds -ge $waitMilliseconds) {
            Write-ChildStreamRuntimeLog -Root $Root -Message "authorization refused: $lastReason"
            return
        }
        $attemptedAuthorization = $true

        if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
            try {
                $state = Read-ChildSessionAuthorization -Path $authorizationPath
                $authorization = Test-ChildSessionAuthorization `
                    -State $state `
                    -CurrentSessionId $currentSessionId `
                    -NowUtc (Get-ChildStreamNowUtc)
                $lastReason = $authorization.Reason
                if ($authorization.Authorized) {
                    break
                }
            }
            catch {
                $lastReason = 'authorization-read-failed'
            }
        }

        $retryDelayMilliseconds = Get-ChildStreamRetryDelayMilliseconds `
            -ElapsedMilliseconds $waitTimer.ElapsedMilliseconds `
            -WaitMilliseconds $waitMilliseconds
        if ($retryDelayMilliseconds -le 0) {
            Write-ChildStreamRuntimeLog -Root $Root -Message "authorization refused: $lastReason"
            return
        }

        Invoke-ChildStreamSleep -Milliseconds $retryDelayMilliseconds
    }

    $sunshinePath = Join-Path (Join-Path (Join-Path $Root 'Sunshine') 'Sunshine') 'sunshine.exe'
    if (-not (Test-Path -LiteralPath $sunshinePath -PathType Leaf)) {
        Write-ChildStreamRuntimeLog -Root $Root -Message 'launch refused: sunshine-executable-missing'
        return
    }

    $initialProcessCheck = Find-ChildStreamSunshineInSession -SessionId $currentSessionId
    if (-not $initialProcessCheck.Succeeded) {
        Write-ChildStreamRuntimeLog -Root $Root -Message 'launch refused: sunshine-process-check-failed'
        return
    }
    if ($initialProcessCheck.Processes.Count -gt 0) {
        Write-ChildStreamRuntimeLog -Root $Root -Message "launch skipped: sunshine-already-running session=$currentSessionId"
        return
    }

    $workingDirectory = Split-Path -Parent $sunshinePath
    $sessionMutex = $null
    $mutexAcquired = $false
    try {
        $mutexName = "Local\ChildStream.Sunshine.Session.$currentSessionId"
        $sessionMutex = New-ChildStreamSessionMutex -Name $mutexName
        try {
            $mutexAcquired = Wait-ChildStreamSessionMutex -Mutex $sessionMutex -Milliseconds 5000
        }
        catch [Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
        if (-not $mutexAcquired) {
            Write-ChildStreamRuntimeLog -Root $Root -Message 'launch refused: sunshine-session-lock-timeout'
            return
        }

        try {
            $lockedSessionId = [int](Get-Process -Id $PID -ErrorAction Stop).SessionId
        }
        catch {
            Write-ChildStreamRuntimeLog -Root $Root -Message 'authorization refused after lock: current-session-unavailable'
            return
        }
        if ($lockedSessionId -ne $currentSessionId) {
            Write-ChildStreamRuntimeLog -Root $Root -Message 'authorization refused after lock: session-changed'
            return
        }

        try {
            $lockedState = Read-ChildSessionAuthorization -Path $authorizationPath
            $lockedAuthorization = Test-ChildSessionAuthorization `
                -State $lockedState `
                -CurrentSessionId $lockedSessionId `
                -NowUtc (Get-ChildStreamNowUtc)
        }
        catch {
            Write-ChildStreamRuntimeLog -Root $Root -Message 'authorization refused after lock: authorization-read-failed'
            return
        }
        if (-not $lockedAuthorization.Authorized) {
            Write-ChildStreamRuntimeLog -Root $Root -Message "authorization refused after lock: $($lockedAuthorization.Reason)"
            return
        }

        $lockedProcessCheck = Find-ChildStreamSunshineInSession -SessionId $lockedSessionId
        if (-not $lockedProcessCheck.Succeeded) {
            Write-ChildStreamRuntimeLog -Root $Root -Message 'launch refused: sunshine-process-check-failed'
            return
        }
        if ($lockedProcessCheck.Processes.Count -gt 0) {
            Write-ChildStreamRuntimeLog -Root $Root -Message "launch skipped: sunshine-already-running session=$lockedSessionId"
            return
        }

        if ($LaunchMode -eq 'PromptedStartup') {
            Start-Process -FilePath $sunshinePath -WorkingDirectory $workingDirectory -WindowStyle Hidden -Verb RunAs -ErrorAction Stop
        }
        else {
            Start-Process -FilePath $sunshinePath -WorkingDirectory $workingDirectory -WindowStyle Hidden -ErrorAction Stop
        }

        $startConfirmationTimer = New-ChildStreamStopwatch
        while ($true) {
            $startedProcessCheck = Find-ChildStreamSunshineInSession -SessionId $lockedSessionId
            if (-not $startedProcessCheck.Succeeded) {
                Write-ChildStreamRuntimeLog -Root $Root -Message 'launch failed: sunshine-start-check-failed'
                return
            }
            if ($startedProcessCheck.Processes.Count -gt 0) {
                Write-ChildStreamRuntimeLog -Root $Root -Message "started sunshine session=$lockedSessionId mode=$LaunchMode"
                return
            }
            if ($startConfirmationTimer.ElapsedMilliseconds -ge 5000) {
                Write-ChildStreamRuntimeLog -Root $Root -Message 'launch failed: sunshine-start-timeout'
                return
            }
            $startDelay = [int][Math]::Min([long]100, 5000 - $startConfirmationTimer.ElapsedMilliseconds)
            Invoke-ChildStreamSleep -Milliseconds $startDelay
        }
    }
    catch {
        Write-ChildStreamRuntimeLog -Root $Root -Message "launch failed: $($_.Exception.Message)"
    }
    finally {
        if ($mutexAcquired) {
            try {
                Release-ChildStreamSessionMutex -Mutex $sessionMutex
            }
            catch {
                Write-ChildStreamRuntimeLog -Root $Root -Message 'launch cleanup failed: sunshine-session-lock-release'
            }
        }
        if ($null -ne $sessionMutex) {
            try {
                Close-ChildStreamSessionMutex -Mutex $sessionMutex
            }
            catch {
                Write-ChildStreamRuntimeLog -Root $Root -Message 'launch cleanup failed: sunshine-session-lock-dispose'
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Read-ChildSessionAuthorization',
    'Test-ChildSessionAuthorization',
    'Invoke-ChildSessionSunshine'
)
