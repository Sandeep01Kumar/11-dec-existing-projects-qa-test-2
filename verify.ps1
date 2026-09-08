<#
.SYNOPSIS
    Assertive, fail-fast verification harness for server.js.

.DESCRIPTION
    This script is the executable form of the verification protocol in Agent Action Plan
    section 0.7. Every check compares an exact expected value - raw response bytes, byte
    counts, normalised header values, stdout/stderr text, log occurrence counts, process
    exit codes, git blob ids and changed-file sets - and any mismatch fails the owning case
    and forces a non-zero exit from the whole script. Nothing here merely prints a value for
    a human to eyeball.

    Zero dependencies, by design and by mandate. The harness uses only Windows PowerShell
    5.1, the .NET base class library that ships with it, the `git` and `npm` executables
    already required by the repository, and the Node.js core runtime. It installs nothing,
    imports no module, adds no package, and is not a test framework: it defines no test DSL,
    no discovery convention and no runner contract, and `package.json` (including its
    placeholder `test` script) is neither read for configuration nor modified. AAP section
    0.6.1 lists no created files and section 0.6.2 excludes "an automated test framework";
    this plain script is neither a framework nor a dependency, and it is the resolution the
    code review explicitly required for findings F01-F06 of the test-and-verification
    review. It is the only file that review adds to the repository.

.PARAMETER Port
    Base TCP port for the cases that bind a listener. Omit it (or pass 0) to have the
    harness reserve free ports dynamically, which is the safe default on a host shared by
    many clones. Port 3000 is never bound by this harness even when the module under test
    defaults to it - the default-configuration case captures what server.js passes to
    listen() without binding, so a busy 3000 can neither fail nor falsely pass a case.

.PARAMETER WorkDir
    Directory for the harness's own artifacts: the generated Node driver and every child
    process log. The default is a per-process directory under $env:TEMP, which the harness
    creates and then removes on exit; a directory passed here is used as given and is never
    removed. Nothing is ever written inside the repository.

.PARAMETER BaselineRef
    The pre-fix commit this checkpoint is measured against. Case A07 requires that the
    committed diff between it and HEAD is exactly the sanctioned change set, and proves the
    reference really is the pre-fix commit by checking server.js's blob id there. Override
    it only if history is rewritten so the default commit is no longer reachable.

.PARAMETER Only
    Wildcard filter over case ids (for example 'E0*' or 'F1?'). Default runs every case.

.PARAMETER ListCases
    Print the case inventory - id, owner and description - and exit 0 without executing
    anything, starting no process and binding no port.

.PARAMETER KeepWorkDir
    Leave the work directory in place after the run so child logs can be inspected.

.NOTES
    Exit code: 0 when every executed case passes, 1 when any case fails or the harness
    itself cannot complete. The summary lists each failure with its case id, the owning
    review finding and the exact expected-versus-actual mismatch.

    Windows signal limitation: Windows has no SIGTERM/SIGINT delivery equivalent to
    kill(2), and Stop-Process terminates a Node process without running any handler. The
    lifecycle cases therefore drive shutdown with process.emit('SIGTERM'|'SIGINT') inside
    the child, which exercises exactly the handlers server.js registers - the shutdown
    function, its duplicate-signal guard, connection cleanup, the forced-exit timer and the
    resulting exit code - but not the operating system's signal delivery itself. Every case
    that relies on this is marked "(handler-level)" in its description.

    Ownership tags. Cases tagged AAP assert the contract AAP sections 0.5.1-0.5.3 and 0.7
    pin, and must pass. Cases tagged with another finding id assert post-fix behaviour that
    a concurrently reviewed concern owns - API-F01/F02 (response-state-safe error writes),
    API-F03 (CONNECT rejection), API-F04 (clientError mapping), CFG-F01/F02 (PORT/HOST
    validation), BE-F01/F02/F03/F04 (fatal exit semantics, escalation, listen ordering,
    error routing) and PERF-F01 (finite socket inactivity timeout). They fail until that
    fix is present, which is the point: each one is the detector for a named gap.

    Reading the result. The summary reports two counts: contract (AAP-owned) failures, and
    failures owned by another finding. A non-zero contract count is a regression against
    the frozen contract and must be fixed here. A non-zero delegated count means the named
    concern's fix is not in this tree yet; against server.js as it stood when this harness
    was written, 46 of the 65 cases pass and the 19 delegated ones fail, which is the
    harness reporting those gaps rather than a defect in the harness. The exit code is 1
    whenever any case fails, deliberately: a verification run that mismatches must never
    report success.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Only 'E0*' -KeepWorkDir
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [string]$WorkDir = '',

    [string]$BaselineRef = '7c90ae2d73a1e0a19a8b5aa471181578d1f0d477',

    [string]$Only = '*',

    [switch]$ListCases,

    [switch]$KeepWorkDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# An empty filter would silently select nothing and report success, so it means "all".
if ([string]::IsNullOrWhiteSpace($Only)) { $Only = '*' }

# --------------------------------------------------------------------------------------
# Expected values. Every literal the AAP pins lives here so a contract change is a
# one-line edit and never a silently weakened assertion.
# --------------------------------------------------------------------------------------
$LF = [char]10
$script:Expected = @{
    GreetingText      = 'Hello, World!' + $LF          # AAP 0.5.1 happy-path body
    GreetingBytes     = [System.Text.Encoding]::ASCII.GetBytes('Hello, World!' + $LF)
    GreetingLength    = 14                             # AAP 0.7.2 response size
    MethodNotAllowed  = 'Method Not Allowed' + $LF
    BadRequest        = 'Bad Request' + $LF
    ServerError       = 'Internal Server Error' + $LF
    AllowHeader       = 'GET, HEAD'
    ContentType       = 'text/plain'
    DefaultHost       = '127.0.0.1'
    DefaultPort       = 3000
    RequestTimeoutMs  = 30000
    HeadersTimeoutMs  = 20000
    KeepAliveTimeout  = 5000
    ShutdownTimeoutMs = 10000
    ClosedLog         = 'Server closed. Exiting.'
    ForcedLog         = 'Forced shutdown after timeout.'
    CloseErrorLog     = 'Error during server close:'
    ReqErrorLog       = 'Request stream error:'
    ResErrorLog       = 'Response stream error:'
    HandlerErrorLog   = 'Unhandled request error:'
    UncaughtLog       = 'Uncaught exception:'
    RejectionLog      = 'Unhandled promise rejection:'
    GenericErrorLog   = 'Server error:'
    TestScript        = 'echo "Error: no test specified" && exit 1'
    PackageJsonBlob   = '5a6d9ed8c5fa1cc2e79999983a95c54deb96aa00'
    PackageLockBlob   = '3c71221650a386bd03dbb411ecdfd8e07112ca4b'
    # server.js as it stood at the baseline commit: the original 14-line scaffold. Case
    # A07 uses it to prove the baseline reference really is the pre-fix commit.
    BaselineServerBlob = '320a75a7649db30756f011001f299d20df1c44b3'
    # The complete set of committed changes this checkpoint may introduce, as
    # `git diff --name-status <baseline> HEAD` reports it (case A07).
    CommittedChangeSet = @('M server.js', 'A verify.ps1')
}

# Files the fix must leave untouched (AAP 0.6.2). Anything modified here fails case A07.
$script:ProtectedPaths = @(
    'package.json', 'package-lock.json', 'README.md', '100Pages.pdf', 'LoginTest.java',
    'demo.jpg', 'industry.csv', 'sample.doc', 'test.py.txt', 'test.txt.txt'
)

# Paths this checkpoint is allowed to add or change in the working tree (case A05).
# 'blitzy/' holds QA screenshot/recording artifacts and is never committed.
$script:AllowedWorkingTreePaths = @('server.js', 'verify.ps1', 'blitzy/')

# Text that must never appear where a clean, application-level diagnostic is required.
$script:RawCrashMarkers = @(
    "Unhandled 'error' event",
    'ERR_SOCKET_BAD_PORT',
    'node:internal/errors',
    'throw er;',
    'throw error;'
)

# --------------------------------------------------------------------------------------
# Harness state
# --------------------------------------------------------------------------------------
$script:RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ServerPath = Join-Path $script:RepoRoot 'server.js'
$script:ServerRequirePath = $script:ServerPath -replace '\\', '/'
$script:ListMode = [bool]$ListCases
$script:Results = New-Object System.Collections.ArrayList
$script:Children = New-Object System.Collections.ArrayList
$script:DriverPath = ''
$script:WorkPath = ''

function Write-Line { param([string]$Text = '') Write-Host $Text }

# --------------------------------------------------------------------------------------
# Assertion primitives. Each throws on mismatch; Invoke-Case turns the throw into a
# recorded FAIL and the run into exit 1. There is no "warn" level and no soft assertion.
# --------------------------------------------------------------------------------------
function Assert-Failed { param([string]$Message) throw $Message }

function Assert-Equal {
    param($Actual, $Expected, [string]$What)
    if ($Actual -is [string] -or $Expected -is [string]) {
        if ([string]$Actual -cne [string]$Expected) {
            Assert-Failed ("{0}: expected [{1}] but got [{2}]" -f $What, (Show-Text ([string]$Expected)), (Show-Text ([string]$Actual)))
        }
        return
    }
    if ($Actual -ne $Expected) {
        Assert-Failed ("{0}: expected [{1}] but got [{2}]" -f $What, $Expected, $Actual)
    }
}

function Assert-True {
    param([bool]$Condition, [string]$What)
    if (-not $Condition) { Assert-Failed ("{0}: condition was false" -f $What) }
}

function Assert-InSet {
    param($Actual, $Allowed, [string]$What)
    foreach ($a in $Allowed) { if ($Actual -eq $a) { return } }
    Assert-Failed ("{0}: [{1}] is not one of [{2}]" -f $What, $Actual, ($Allowed -join ' | '))
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$What)
    if ($null -eq $Text) { $Text = '' }
    if (-not $Text.Contains($Needle)) {
        Assert-Failed ("{0}: [{1}] does not contain [{2}]" -f $What, (Show-Text $Text), (Show-Text $Needle))
    }
}

function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$What)
    if ($null -eq $Text) { return }
    if ($Text.Contains($Needle)) {
        Assert-Failed ("{0}: [{1}] must not contain [{2}]" -f $What, (Show-Text $Text), (Show-Text $Needle))
    }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$What)
    if ($null -eq $Text) { $Text = '' }
    if ($Text -notmatch $Pattern) {
        Assert-Failed ("{0}: [{1}] does not match /{2}/" -f $What, (Show-Text $Text), $Pattern)
    }
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$What)
    if ($null -eq $Text) { return }
    if ($Text -match $Pattern) {
        Assert-Failed ("{0}: [{1}] must not match /{2}/" -f $What, (Show-Text $Text), $Pattern)
    }
}

function Assert-BytesEqual {
    param([byte[]]$Actual, [byte[]]$Expected, [string]$What)
    if ($null -eq $Actual) { $Actual = New-Object byte[] 0 }
    if ($Actual.Length -ne $Expected.Length) {
        Assert-Failed ("{0}: expected {1} bytes but got {2} bytes; expected [{3}] actual [{4}]" -f `
            $What, $Expected.Length, $Actual.Length, `
            (Show-Text ([System.Text.Encoding]::ASCII.GetString($Expected))), `
            (Show-Text ([System.Text.Encoding]::ASCII.GetString($Actual))))
    }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Actual[$i] -ne $Expected[$i]) {
            Assert-Failed ("{0}: byte {1} expected 0x{2:X2} but got 0x{3:X2}" -f $What, $i, $Expected[$i], $Actual[$i])
        }
    }
}

function Assert-Between {
    param([long]$Actual, [long]$Min, [long]$Max, [string]$What)
    if ($Actual -lt $Min -or $Actual -gt $Max) {
        Assert-Failed ("{0}: {1} is outside the required range {2}..{3}" -f $What, $Actual, $Min, $Max)
    }
}

function Assert-OccurrenceCount {
    param([string]$Text, [string]$Needle, [int]$Expected, [string]$What)
    if ($null -eq $Text) { $Text = '' }
    $count = 0
    $index = $Text.IndexOf($Needle)
    while ($index -ge 0) {
        $count++
        $index = $Text.IndexOf($Needle, $index + $Needle.Length)
    }
    if ($count -ne $Expected) {
        Assert-Failed ("{0}: [{1}] occurred {2} time(s), expected exactly {3}" -f $What, (Show-Text $Needle), $count, $Expected)
    }
}

# A clean application diagnostic: no node crash banner, no raw stack frames.
function Assert-NoRawCrash {
    param([string]$Text, [string]$What)
    if ($null -eq $Text) { return }
    foreach ($marker in $script:RawCrashMarkers) {
        Assert-NotContains -Text $Text -Needle $marker -What $What
    }
    Assert-NotMatch -Text $Text -Pattern '(?m)^\s+at\s' -What ($What + ' (raw stack frame)')
}

function Show-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '<null>' }
    $s = $Text.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    if ($s.Length -gt 220) { $s = $s.Substring(0, 220) + '...<truncated>' }
    return $s
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# --------------------------------------------------------------------------------------
# Case runner
# --------------------------------------------------------------------------------------
function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    if ($Id -notlike $Only) { return }

    if ($script:ListMode) {
        Write-Line ("{0,-5} {1,-10} {2}" -f $Id, $Owner, $Name)
        [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Owner = $Owner; Name = $Name; Status = 'LISTED'; Message = ''; Ms = 0 })
        return
    }

    $childMark = $script:Children.Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'PASS'
    $message = ''
    try {
        & $Body
    } catch {
        $status = 'FAIL'
        $message = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$_ }
    } finally {
        Stop-ChildrenAfter -Mark $childMark
    }
    $sw.Stop()

    [void]$script:Results.Add([pscustomobject]@{
        Id = $Id; Owner = $Owner; Name = $Name; Status = $status; Message = $message; Ms = $sw.ElapsedMilliseconds
    })
    $tag = if ($status -eq 'PASS') { '[PASS]' } else { '[FAIL]' }
    Write-Line ("{0} {1,-5} {2,-10} {3,6}ms  {4}" -f $tag, $Id, $Owner, $sw.ElapsedMilliseconds, $Name)
    if ($status -eq 'FAIL') { Write-Line ("        -> " + $message) }
}

# --------------------------------------------------------------------------------------
# Process orchestration. Every child is started with Start-Process -PassThru, its handle
# is cached immediately (without which PowerShell 5.1 reports a null ExitCode after
# WaitForExit), it is tracked so only captured PIDs are ever terminated, its streams are
# redirected to files in the private work directory, readiness is polled against a
# deadline, and exit is awaited with a bounded WaitForExit that yields the real code.
# --------------------------------------------------------------------------------------
function Get-FreePort {
    param([int]$Preferred = 0)
    if ($Preferred -gt 0 -and (Test-PortFree -Candidate $Preferred)) { return $Preferred }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $candidate = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        } finally {
            $listener.Stop()
        }
        if ($candidate -ne $script:Expected.DefaultPort -and (Test-PortFree -Candidate $candidate)) { return $candidate }
    }
    Assert-Failed 'unable to reserve a free loopback port after 40 attempts'
}

function Test-PortFree {
    param([int]$Candidate)
    if ($Candidate -eq $script:Expected.DefaultPort) { return $false }
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Candidate)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Set-ChildEnvironment {
    param([hashtable]$Values)
    $saved = @{}
    foreach ($key in @('PORT', 'HOST')) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    foreach ($key in $Values.Keys) {
        if (-not $saved.ContainsKey($key)) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
    }
    foreach ($key in @($saved.Keys)) {
        if ($Values.ContainsKey($key)) {
            [Environment]::SetEnvironmentVariable($key, [string]$Values[$key])
        } else {
            [Environment]::SetEnvironmentVariable($key, $null)
        }
    }
    return $saved
}

function Restore-ChildEnvironment {
    param([hashtable]$Saved)
    foreach ($key in $Saved.Keys) { [Environment]::SetEnvironmentVariable($key, $Saved[$key]) }
}

function Start-NodeChild {
    param(
        [string[]]$NodeArgs,
        [hashtable]$EnvVars = @{},
        [string]$Label = 'child'
    )
    $stamp = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $script:WorkPath ("{0}-{1}.out" -f $Label, $stamp)
    $errFile = Join-Path $script:WorkPath ("{0}-{1}.err" -f $Label, $stamp)
    New-Item -ItemType File -Path $outFile -Force | Out-Null
    New-Item -ItemType File -Path $errFile -Force | Out-Null

    $saved = Set-ChildEnvironment -Values $EnvVars
    try {
        $proc = Start-Process -FilePath 'node' -ArgumentList $NodeArgs -WorkingDirectory $script:RepoRoot `
            -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Cache the process handle: without this PowerShell 5.1 loses the exit code.
        $null = $proc.Handle
    } finally {
        Restore-ChildEnvironment -Saved $saved
    }

    $child = [pscustomobject]@{
        Process = $proc
        Pid     = $proc.Id
        OutFile = $outFile
        ErrFile = $errFile
        Label   = $Label
        Started = [System.Diagnostics.Stopwatch]::StartNew()
    }
    [void]$script:Children.Add($child)
    return $child
}

function Get-ChildOut {
    param($Child)
    return Read-TextFile -Path $Child.OutFile
}

function Get-ChildErr {
    param($Child)
    return Read-TextFile -Path $Child.ErrFile
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch {
        return ''
    }
}

function Wait-ForChildOutput {
    param($Child, [string]$Pattern, [int]$TimeoutMs = 15000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $text = Get-ChildOut -Child $Child
        if ($text -and ($text -match $Pattern)) { return $text }
        if ($Child.Process.HasExited) {
            $text = Get-ChildOut -Child $Child
            if ($text -and ($text -match $Pattern)) { return $text }
            Assert-Failed ("child '{0}' (pid {1}) exited with code {2} before matching /{3}/; stdout=[{4}] stderr=[{5}]" -f `
                $Child.Label, $Child.Pid, $Child.Process.ExitCode, $Pattern, (Show-Text $text), (Show-Text (Get-ChildErr -Child $Child)))
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-Failed ("child '{0}' (pid {1}) did not produce /{2}/ within {3}ms; stdout=[{4}] stderr=[{5}]" -f `
        $Child.Label, $Child.Pid, $Pattern, $TimeoutMs, (Show-Text (Get-ChildOut -Child $Child)), (Show-Text (Get-ChildErr -Child $Child)))
}

function Wait-ChildExit {
    param($Child, [int]$TimeoutMs = 20000)
    $exited = $Child.Process.WaitForExit($TimeoutMs)
    if (-not $exited) {
        Assert-Failed ("child '{0}' (pid {1}) was still running after {2}ms; stdout=[{3}] stderr=[{4}]" -f `
            $Child.Label, $Child.Pid, $TimeoutMs, (Show-Text (Get-ChildOut -Child $Child)), (Show-Text (Get-ChildErr -Child $Child)))
    }
    # The parameterless overload settles ExitCode and flushes redirected streams.
    $Child.Process.WaitForExit()
    $elapsed = $Child.Started.ElapsedMilliseconds
    return [pscustomobject]@{
        ExitCode = $Child.Process.ExitCode
        Out      = Get-ChildOut -Child $Child
        Err      = Get-ChildErr -Child $Child
        Ms       = $elapsed
    }
}

function Stop-TrackedChild {
    param($Child)
    if ($null -eq $Child) { return }
    try {
        if (-not $Child.Process.HasExited) {
            # Only a PID captured from Start-Process -PassThru is ever terminated.
            Stop-Process -Id $Child.Pid -Force -ErrorAction SilentlyContinue
            $null = $Child.Process.WaitForExit(5000)
        }
    } catch {
        # A child that has already gone is not an error.
    }
}

function Stop-ChildrenAfter {
    param([int]$Mark)
    while ($script:Children.Count -gt $Mark) {
        $index = $script:Children.Count - 1
        $child = $script:Children[$index]
        Stop-TrackedChild -Child $child
        $script:Children.RemoveAt($index)
    }
}

# --------------------------------------------------------------------------------------
# Byte-exact HTTP client over System.Net.Sockets.TcpClient. Node's own client is
# deliberately not used: these cases must observe the exact bytes on the wire, including
# the response status line, header casing, the body's trailing LF and its byte count, and
# whether the server closed the connection. Requests carry "Connection: close" unless a
# keep-alive case needs otherwise, so reading to close yields a provably complete body.
# --------------------------------------------------------------------------------------
function Invoke-HttpExchange {
    param(
        [string]$Address = '127.0.0.1',
        [Parameter(Mandatory = $true)][int]$TargetPort,
        [Parameter(Mandatory = $true)][string]$RequestText,
        [int]$IdleMs = 1500,
        [int]$TotalMs = 20000,
        [switch]$ExpectServerClose
    )
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $buffer = New-Object System.IO.MemoryStream
    $closed = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connect = $client.BeginConnect($Address, $TargetPort, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(5000)) {
            Assert-Failed ("connect to {0}:{1} timed out after 5000ms" -f $Address, $TargetPort)
        }
        $client.EndConnect($connect)
        $stream = $client.GetStream()
        $payload = [System.Text.Encoding]::ASCII.GetBytes($RequestText)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()

        $chunk = New-Object byte[] 16384
        $idle = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TotalMs) {
            if ($stream.DataAvailable) {
                $read = $stream.Read($chunk, 0, $chunk.Length)
                if ($read -le 0) { $closed = $true; break }
                $buffer.Write($chunk, 0, $read)
                $idle.Restart()
                continue
            }
            # Poll reports readable both for pending data and for a peer that has closed.
            if ($client.Client.Poll(50000, [System.Net.Sockets.SelectMode]::SelectRead) -and -not $stream.DataAvailable) {
                $closed = $true
                break
            }
            if (-not $ExpectServerClose -and $idle.ElapsedMilliseconds -ge $IdleMs) { break }
        }
    } finally {
        $client.Close()
        $sw.Stop()
    }

    $raw = $buffer.ToArray()
    $split = Find-HeaderTerminator -Bytes $raw
    $headerText = ''
    $bodyBytes = New-Object byte[] 0
    if ($split -ge 0) {
        $headerText = [System.Text.Encoding]::ASCII.GetString($raw, 0, $split)
        $bodyStart = $split + 4
        if ($raw.Length -gt $bodyStart) {
            $bodyBytes = New-Object byte[] ($raw.Length - $bodyStart)
            [Array]::Copy($raw, $bodyStart, $bodyBytes, 0, $bodyBytes.Length)
        }
    } else {
        $headerText = [System.Text.Encoding]::ASCII.GetString($raw)
    }

    $lines = @()
    if ($headerText.Length -gt 0) { $lines = $headerText -split "`r`n" }
    $statusLine = ''
    if ($lines.Count -gt 0) { $statusLine = $lines[0] }
    $statusCode = 0
    if ($statusLine -match '^HTTP/1\.[01]\s+(\d{3})') { $statusCode = [int]$Matches[1] }
    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrEmpty($line)) { continue }
        $colon = $line.IndexOf(':')
        if ($colon -lt 1) { continue }
        $name = $line.Substring(0, $colon).Trim().ToLowerInvariant()
        $value = $line.Substring($colon + 1).Trim()
        if ($headers.ContainsKey($name)) { $headers[$name] = $headers[$name] + ', ' + $value } else { $headers[$name] = $value }
    }

    return [pscustomobject]@{
        RawBytes   = $raw
        RawText    = [System.Text.Encoding]::ASCII.GetString($raw)
        StatusLine = $statusLine
        StatusCode = $statusCode
        Headers    = $headers
        HeaderText = $headerText
        BodyBytes  = $bodyBytes
        BodyText   = [System.Text.Encoding]::ASCII.GetString($bodyBytes)
        BodyLength = $bodyBytes.Length
        Closed     = $closed
        Ms         = $sw.ElapsedMilliseconds
    }
}

function Find-HeaderTerminator {
    param([byte[]]$Bytes)
    for ($i = 0; $i -le $Bytes.Length - 4; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $i }
    }
    return -1
}

function Get-HeaderValue {
    param($Response, [string]$Name)
    $key = $Name.ToLowerInvariant()
    if ($Response.Headers.ContainsKey($key)) { return $Response.Headers[$key] }
    return $null
}

function Assert-HeaderEqual {
    param($Response, [string]$Name, [string]$Value, [string]$What)
    $actual = Get-HeaderValue -Response $Response -Name $Name
    if ($null -eq $actual) {
        Assert-Failed ("{0}: header '{1}' is absent; headers=[{2}]" -f $What, $Name, (Show-Text $Response.HeaderText))
    }
    Assert-Equal -Actual $actual -Expected $Value -What ("{0}: header '{1}'" -f $What, $Name)
}

function New-Request {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        [int]$TargetPort,
        [switch]$KeepAlive,
        [string[]]$ExtraHeaders = @(),
        [switch]$NoTerminator
    )
    $connection = if ($KeepAlive) { 'keep-alive' } else { 'close' }
    $text = "{0} {1} HTTP/1.1`r`nHost: 127.0.0.1:{2}`r`nConnection: {3}" -f $Method, $Path, $TargetPort, $connection
    foreach ($h in $ExtraHeaders) { $text += "`r`n" + $h }
    if ($NoTerminator) { return $text + "`r`n" }
    return $text + "`r`n`r`n"
}

# Every case that talks to a live listener asserts afterwards that the server survived:
# it still answers a fresh request with the exact greeting and its process is still up.
function Assert-ServerStillHealthy {
    param($Child, [int]$TargetPort, [string]$What)
    Assert-True -Condition (-not $Child.Process.HasExited) -What ("{0}: server process must still be running" -f $What)
    $probe = Invoke-HttpExchange -TargetPort $TargetPort -RequestText (New-Request -TargetPort $TargetPort) -ExpectServerClose
    Assert-Equal -Actual $probe.StatusCode -Expected 200 -What ("{0}: follow-up GET / status" -f $What)
    Assert-BytesEqual -Actual $probe.BodyBytes -Expected $script:Expected.GreetingBytes -What ("{0}: follow-up GET / body" -f $What)
}

# --------------------------------------------------------------------------------------
# The Node driver. It is generated into the work directory at run time (never into the
# repository) and is the only way these cases can reach behaviour that no HTTP request can
# trigger: the request/response 'error' listeners, the handler's catch block, the server
# 'error' listener, the process fatal handlers, the shutdown sequence, and the
# configuration server.js resolves before it binds.
#
# It never re-implements the module's behaviour. It captures the real request handler and
# the real server object created by server.js, drives them, and reports what they did.
# --------------------------------------------------------------------------------------
$script:DriverSource = @'
'use strict';
/*
 * Verification driver for server.js. Generated by verify.ps1; not part of the application.
 *   usage: node driver.js <absolute-path-to-server.js> <mode> [argument]
 * Machine-readable output lines:
 *   ###READY###{...}   the captured server is listening
 *   ###UNIT###{...}    result of a handler-level injection
 *   ###RESULT###{...}  final report, emitted from process.on('exit')
 *   ###NOTE###text     progress marker
 */
const http = require('http');
const net = require('net');
const EventEmitter = require('events');

const target = process.argv[2];
const mode = process.argv[3];
const arg = process.argv[4];

let handler = null;      // the real request callback server.js passed to createServer
let server = null;       // the real http.Server instance server.js created
let listenArgs = null;   // what server.js passed to listen()
let idleCalls = 0;
let allCalls = 0;
let moduleIdleCalls = 0; // closeIdleConnections calls made by server.js itself
let moduleAllCalls = 0;  // closeAllConnections calls made by server.js itself

const SELF = __filename;

function isUnitMode() { return mode.indexOf('unit:') === 0; }
function noBind() { return mode === 'config-capture' || isUnitMode(); }

function emitJson(tag, payload) {
  process.stdout.write('###' + tag + '###' + JSON.stringify(payload) + '\n');
}

// Attribute an optional-API call to the module under test. Node core also calls
// closeIdleConnections() itself from httpServerPreClose() during server.close(), so the
// first stack frame outside this driver decides who the caller is.
function callerIsTarget() {
  const frames = String(new Error().stack || '').split('\n').slice(1);
  for (const frame of frames) {
    if (frame.indexOf(SELF) >= 0) { continue; }
    return frame.indexOf(target) >= 0 || frame.indexOf('server.js') >= 0;
  }
  return false;
}

const origCreateServer = http.createServer;
http.createServer = function () {
  for (const a of arguments) { if (typeof a === 'function') { handler = a; } }
  const created = origCreateServer.apply(this, arguments);
  if (!server) { server = created; }
  return created;
};

if (typeof http.Server.prototype.closeIdleConnections === 'function') {
  const original = http.Server.prototype.closeIdleConnections;
  http.Server.prototype.closeIdleConnections = function () {
    idleCalls++;
    if (callerIsTarget()) { moduleIdleCalls++; }
    return original.apply(this, arguments);
  };
}
if (typeof http.Server.prototype.closeAllConnections === 'function') {
  const original = http.Server.prototype.closeAllConnections;
  http.Server.prototype.closeAllConnections = function () {
    allCalls++;
    if (callerIsTarget()) { moduleAllCalls++; }
    return original.apply(this, arguments);
  };
}

if (noBind()) {
  // Resolve configuration without binding: capture the arguments and run the callback so
  // the startup log is still produced, but never occupy a port on a shared host.
  http.Server.prototype.listen = function () {
    listenArgs = Array.prototype.slice.call(arguments);
    const last = listenArgs[listenArgs.length - 1];
    if (typeof last === 'function') { last.call(this); }
    return this;
  };
}

// Older-runtime simulation (Node < 18.2 had neither optional cleanup API). The methods
// cannot be deleted, because node core's own server.close() calls closeIdleConnections();
// removing it breaks core and hangs the process. Instead the instance property is hidden
// from the module under test around the core call, so only its typeof guard sees it gone.
if (mode === 'absent-idle-api' || mode === 'absent-all-api') {
  const realClose = http.Server.prototype.close;
  const hideIdle = (mode === 'absent-idle-api');
  http.Server.prototype.close = function (cb) {
    if (hideIdle) { delete this.closeIdleConnections; }
    const result = realClose.call(this, cb);
    if (hideIdle) {
      Object.defineProperty(this, 'closeIdleConnections', { value: undefined, configurable: true, writable: true });
    }
    Object.defineProperty(this, 'closeAllConnections', { value: undefined, configurable: true, writable: true });
    return result;
  };
}

// Inject a failure into the close callback without preventing the real close.
if (mode === 'close-error') {
  const realClose = http.Server.prototype.close;
  http.Server.prototype.close = function (cb) {
    const self = this;
    return realClose.call(self, function () {
      if (typeof cb === 'function') { cb(new Error('synthetic close failure')); }
    });
  };
}

// Report listen() arguments as [port, host] for both the positional form the AAP pins and
// the options-object form, so a case asserts the bind target rather than a call shape.
// Non-finite numbers are stringified because JSON cannot carry them.
function normalizeListenArgs(args) {
  if (!args) { return null; }
  const values = args.filter(function (a) { return typeof a !== 'function'; });
  if (values.length === 1 && values[0] !== null && typeof values[0] === 'object') {
    const options = values[0];
    const host = Object.prototype.hasOwnProperty.call(options, 'host') ? options.host : options.address;
    return [jsonSafe(options.port), jsonSafe(host)];
  }
  return values.map(jsonSafe);
}

function jsonSafe(value) {
  return (typeof value === 'number' && !isFinite(value)) ? String(value) : value;
}

process.on('exit', function (code) {
  emitJson('RESULT', {
    mode: mode,
    exitCode: code,
    idleCalls: idleCalls,
    allCalls: allCalls,
    moduleIdleCalls: moduleIdleCalls,
    moduleAllCalls: moduleAllCalls,
    listenCalled: listenArgs !== null,
    listenArgs: normalizeListenArgs(listenArgs),
    requestTimeout: server ? server.requestTimeout : null,
    headersTimeout: server ? server.headersTimeout : null,
    keepAliveTimeout: server ? server.keepAliveTimeout : null,
    socketTimeout: server ? server.timeout : null,
    errorListeners: server ? server.listenerCount('error') : 0,
    connectListeners: server ? server.listenerCount('connect') : 0,
    clientErrorListeners: server ? server.listenerCount('clientError') : 0,
    sigtermListeners: process.listenerCount('SIGTERM'),
    sigintListeners: process.listenerCount('SIGINT'),
    uncaughtListeners: process.listenerCount('uncaughtException'),
    rejectionListeners: process.listenerCount('unhandledRejection')
  });
});

// A response double that records every call and whose committed/ended/destroyed state the
// driver controls, so each branch of the module's error handling can be reached exactly.
class RecordingResponse extends EventEmitter {
  constructor(state) {
    super();
    this.statusCode = 200;
    this.calls = [];
    this.state = state || { headersSent: false, writableEnded: false, destroyed: false };
    this.throwOnceOnSetHeader = false;
  }
  get headersSent() { return this.state.headersSent; }
  get writableEnded() { return this.state.writableEnded; }
  get writableFinished() { return this.state.writableEnded; }
  get finished() { return this.state.writableEnded; }
  get destroyed() { return this.state.destroyed; }
  get writable() { return !this.state.writableEnded && !this.state.destroyed; }
  setHeader(name, value) {
    this.calls.push({ call: 'setHeader', name: String(name), value: String(value) });
    if (this.throwOnceOnSetHeader) {
      this.throwOnceOnSetHeader = false;
      throw new Error('synthetic setHeader failure');
    }
    return this;
  }
  getHeader() { return undefined; }
  hasHeader() { return false; }
  removeHeader(name) { this.calls.push({ call: 'removeHeader', name: String(name) }); }
  writeHead(code) {
    this.calls.push({ call: 'writeHead', value: String(code) });
    this.statusCode = code;
    this.state.headersSent = true;
    return this;
  }
  write(chunk) {
    this.calls.push({ call: 'write', value: chunk === undefined ? null : String(chunk) });
    this.state.headersSent = true;
    return true;
  }
  end(chunk) {
    this.calls.push({ call: 'end', value: chunk === undefined ? null : String(chunk) });
    this.state.headersSent = true;
    this.state.writableEnded = true;
    return this;
  }
  destroy(err) {
    this.calls.push({ call: 'destroy', value: err ? String(err.message) : null });
    this.state.destroyed = true;
    return this;
  }
  cork() { }
  uncork() { }
  flushHeaders() { this.state.headersSent = true; }
}

function makeRequest(method) {
  const req = new EventEmitter();
  req.method = method || 'GET';
  req.url = '/';
  req.httpVersion = '1.1';
  req.headers = { host: '127.0.0.1' };
  req.socket = { remoteAddress: '127.0.0.1', destroy: function () { }, destroyed: false };
  req.destroy = function () { req.socket.destroyed = true; };
  req.resume = function () { };
  return req;
}

// Stages a fault at the moment the handler first reads req.method - inside the handler's
// own try block, before any response has been written. A fault has to arrive through the
// request object to reach the handler's failure paths while the response is genuinely
// uncommitted: the module answers every status through one one-shot responder, so a fault
// staged after the handler has already answered is correctly ignored rather than able to
// rewrite a response that is already complete. Injecting through the response object
// instead would exercise the responder's own write-failure containment, which is a
// different path with a different contract.
function armRequestFault(req, fault) {
  let fired = false;
  Object.defineProperty(req, 'method', {
    configurable: true,
    enumerable: true,
    get: function () {
      if (!fired) {
        fired = true;
        fault();
      }
      return 'GET';
    }
  });
}

function runUnitCase(sub) {
  const req = makeRequest('GET');
  const throwing = (sub === 'throw-before-headers' || sub === 'throw-after-headers');
  const preCommitted = (sub === 'throw-after-headers');
  const res = new RecordingResponse(preCommitted
    ? { headersSent: true, writableEnded: false, destroyed: false }
    : { headersSent: false, writableEnded: false, destroyed: false });
  if (throwing) {
    armRequestFault(req, function () { throw new Error('synthetic handler failure'); });
  } else if (sub === 'request-error-before-headers') {
    armRequestFault(req, function () {
      req.emit('error', new Error('synthetic request stream error'));
    });
  }

  let threwOutOfHandler = false;
  try {
    handler(req, res);
  } catch (err) {
    threwOutOfHandler = true;
  }
  const boundary = res.calls.length;
  let threwOnInjection = false;

  // Only the post-commit states are staged after the handler has returned. The
  // pre-commit case is injected during dispatch (see armRequestFault above), because a
  // response cannot un-send its headers: rolling the recorded state backwards would
  // describe a state the real runtime never reaches.
  const states = {
    'request-error-after-headers': { headersSent: true, writableEnded: false, destroyed: false },
    'request-error-after-end': { headersSent: true, writableEnded: true, destroyed: false },
    'request-error-after-destroy': { headersSent: true, writableEnded: true, destroyed: true }
  };

  if (Object.prototype.hasOwnProperty.call(states, sub)) {
    res.state = states[sub];
    try {
      req.emit('error', new Error('synthetic request stream error'));
    } catch (err) {
      threwOnInjection = true;
    }
  } else if (sub === 'response-error') {
    try {
      res.emit('error', new Error('synthetic response stream error'));
    } catch (err) {
      threwOnInjection = true;
    }
  }

  emitJson('UNIT', {
    sub: sub,
    statusCode: res.statusCode,
    requestErrorListeners: req.listenerCount('error'),
    responseErrorListeners: res.listenerCount('error'),
    threwOutOfHandler: threwOutOfHandler,
    threwOnInjection: threwOnInjection,
    callsDuringHandler: res.calls.slice(0, boundary),
    callsAfterInjection: res.calls.slice(boundary)
  });
}

// ---- load the module under test -------------------------------------------------------
require(target);

// Loading the module must have produced the two things every mode drives. Saying so
// plainly beats letting a null dereference surface as an unrelated stack trace.
if (!server) {
  emitJson('NOTE', 'the module under test created no http.Server');
  process.exit(90);
}
if (isUnitMode() && !handler) {
  emitJson('NOTE', 'the module under test passed no request handler to createServer');
  process.exit(91);
}

if (isUnitMode()) {
  runUnitCase(mode.slice(5));
  process.exit(0);
} else if (mode === 'config-capture') {
  // The exit reporter above carries the captured configuration.
} else if (mode === 'server-error-before-listen') {
  const err = new Error(arg === 'EACCES' ? 'permission denied' : 'synthetic pre-listen failure');
  if (arg && arg !== 'generic') { err.code = arg; }
  server.emit('error', err);
  // A genuine bind failure never yields a listening handle, and that is what lets the
  // module record a failure status and let the drained loop end the process. Emitting the
  // event synthetically does not stop the real listen() the module already started, so
  // release the handle it produces - otherwise this case measures a listener the failure
  // it simulates could never have created.
  const releaseHandle = function () { try { server.close(); } catch (closeErr) { } };
  if (server.listening) { releaseHandle(); } else { server.once('listening', releaseHandle); }
} else {
  server.once('listening', function () {
    const address = server.address();
    emitJson('READY', { port: address.port, address: address.address });

    if (mode === 'signal') {
      setTimeout(function () { process.emit(arg || 'SIGTERM'); }, 60);
    } else if (mode === 'signal-twice') {
      const signal = arg || 'SIGTERM';
      setTimeout(function () { process.emit(signal); process.emit(signal); }, 60);
    } else if (mode === 'close-error' || mode === 'absent-idle-api') {
      setTimeout(function () { process.emit('SIGTERM'); }, 60);
    } else if (mode === 'idle-socket-shutdown') {
      const client = net.connect(address.port, address.address, function () {
        client.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n');
      });
      let received = '';
      client.on('data', function (data) {
        received += data.toString('latin1');
        if (received.indexOf('Hello, World!') >= 0) {
          emitJson('NOTE', 'idle keep-alive socket established');
          setTimeout(function () { process.emit('SIGTERM'); }, 120);
        }
      });
      client.on('close', function () { emitJson('NOTE', 'idle client socket closed'); });
      client.on('error', function () { });
    } else if (mode === 'hung-socket-shutdown' || mode === 'absent-all-api') {
      const client = net.connect(address.port, address.address, function () {
        // Deliberately incomplete headers: the connection stays ACTIVE, so it is not
        // released by closeIdleConnections() and server.close() cannot complete.
        client.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n');
        setTimeout(function () { process.emit('SIGTERM'); }, 200);
      });
      client.on('data', function () { });
      client.on('close', function () { emitJson('NOTE', 'hung client socket closed'); });
      client.on('error', function () { });
    } else if (mode === 'fatal-uncaught') {
      setTimeout(function () { throw new Error('synthetic uncaught exception'); }, 60);
    } else if (mode === 'fatal-rejection') {
      setTimeout(function () { Promise.reject(new Error('synthetic unhandled rejection')); }, 60);
    } else if (mode === 'fatal-during-shutdown') {
      // Same tick: shutdown has certainly started and cannot have completed.
      setTimeout(function () {
        process.emit('SIGTERM');
        throw new Error('synthetic fatal during shutdown');
      }, 60);
    } else if (mode === 'server-error-while-listening') {
      setTimeout(function () {
        const err = new Error('synthetic accept failure');
        if (arg && arg !== 'generic') { err.code = arg; }
        server.emit('error', err);
      }, 60);
    }
  });
}
'@

function Initialize-WorkDir {
    if ($script:ListMode) { return }
    if ([string]::IsNullOrWhiteSpace($WorkDir)) {
        $name = 'blitzy-verify-{0}-{1}' -f $PID, ([System.Guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:WorkPath = Join-Path $env:TEMP $name
    } else {
        $script:WorkPath = $WorkDir
    }
    New-Item -ItemType Directory -Path $script:WorkPath -Force | Out-Null
    $script:DriverPath = Join-Path $script:WorkPath 'driver.js'
    [System.IO.File]::WriteAllText($script:DriverPath, $script:DriverSource, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Driver {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Argument = '',
        [hashtable]$EnvVars = @{},
        [int]$TimeoutMs = 25000,
        [string]$Label = ''
    )
    $nodeArgs = @($script:DriverPath, $script:ServerRequirePath, $Mode)
    if ($Argument -ne '') { $nodeArgs += $Argument }
    if ($Label -eq '') { $Label = ($Mode -replace '[^A-Za-z0-9]', '-') }
    $child = Start-NodeChild -NodeArgs $nodeArgs -EnvVars $EnvVars -Label $Label
    $exit = Wait-ChildExit -Child $child -TimeoutMs $TimeoutMs
    return New-DriverResult -Exit $exit -Child $child
}

function New-DriverResult {
    param($Exit, $Child)
    $result = Get-TaggedJson -Text $Exit.Out -Tag 'RESULT'
    $unit = Get-TaggedJson -Text $Exit.Out -Tag 'UNIT'
    $ready = Get-TaggedJson -Text $Exit.Out -Tag 'READY'
    return [pscustomobject]@{
        ExitCode = $Exit.ExitCode
        Out      = $Exit.Out
        Err      = $Exit.Err
        Ms       = $Exit.Ms
        Result   = $result
        Unit     = $unit
        Ready    = $ready
        Logs     = Get-PlainLogLines -Text $Exit.Out
        Child    = $Child
    }
}

function Get-TaggedJson {
    param([string]$Text, [string]$Tag)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $marker = '###' + $Tag + '###'
    foreach ($line in ($Text -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith($marker)) {
            $json = $trimmed.Substring($marker.Length)
            try { return $json | ConvertFrom-Json } catch { Assert-Failed ("driver emitted unparsable {0} payload: [{1}]" -f $Tag, (Show-Text $json)) }
        }
    }
    return $null
}

# The child's stdout minus the driver's own machine-readable markers: exactly the lines
# server.js itself logged, in order.
function Get-PlainLogLines {
    param([string]$Text)
    $lines = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($line in ($Text -split "`n")) {
        $trimmed = $line.TrimEnd("`r")
        if ($trimmed.Trim() -eq '') { continue }
        if ($trimmed.Trim().StartsWith('###')) { continue }
        [void]$lines.Add($trimmed)
    }
    return $lines.ToArray()
}

function Get-StartupLog {
    param([string]$BindHost, [int]$BindPort)
    return "Server running at http://{0}:{1}/" -f $BindHost, $BindPort
}


function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 120000,
        [hashtable]$EnvVars = @{},
        [string]$Label = 'tool'
    )
    $stamp = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $script:WorkPath ("{0}-{1}.out" -f $Label, $stamp)
    $errFile = Join-Path $script:WorkPath ("{0}-{1}.err" -f $Label, $stamp)
    New-Item -ItemType File -Path $outFile -Force | Out-Null
    New-Item -ItemType File -Path $errFile -Force | Out-Null

    $saved = Set-ChildEnvironment -Values $EnvVars
    try {
        if ($Arguments.Count -gt 0) {
            $proc = Start-Process -FilePath $File -ArgumentList $Arguments -WorkingDirectory $script:RepoRoot `
                -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        } else {
            $proc = Start-Process -FilePath $File -WorkingDirectory $script:RepoRoot `
                -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        }
        $null = $proc.Handle
    } finally {
        Restore-ChildEnvironment -Saved $saved
    }

    if (-not $proc.WaitForExit($TimeoutMs)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Assert-Failed ("{0} {1} did not finish within {2}ms" -f $File, ($Arguments -join ' '), $TimeoutMs)
    }
    $proc.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Out      = (Read-TextFile -Path $outFile)
        Err      = (Read-TextFile -Path $errFile)
    }
}

function Invoke-Git {
    param([string[]]$Arguments, [int]$TimeoutMs = 60000)
    $run = Invoke-Tool -File 'git' -Arguments $Arguments -TimeoutMs $TimeoutMs -Label 'git'
    Assert-Equal -Actual $run.ExitCode -Expected 0 -What ("git {0} exit code" -f ($Arguments -join ' '))
    return $run.Out
}

function Test-AnyCaseSelected {
    param([string[]]$Ids)
    foreach ($id in $Ids) { if ($id -like $Only) { return $true } }
    return $false
}

function Add-SyntheticFailure {
    param([string]$Id, [string]$Owner, [string]$Name, [string]$Message)
    [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Owner = $Owner; Name = $Name; Status = 'FAIL'; Message = $Message; Ms = 0 })
    Write-Line ("[FAIL] {0,-5} {1,-10} {2,6}ms  {3}" -f $Id, $Owner, 0, $Name)
    Write-Line ("        -> " + $Message)
}

# Splits `git status --porcelain` into the set of paths it reports.
function Get-WorkingTreePaths {
    param([string]$PorcelainText)
    $paths = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($PorcelainText)) { return @() }
    foreach ($line in ($PorcelainText -split "`n")) {
        $entry = $line.TrimEnd("`r")
        if ($entry.Trim() -eq '') { continue }
        if ($entry.Length -le 3) { continue }
        $path = $entry.Substring(3).Trim('"')
        if ($path.Contains(' -> ')) { $path = $path.Substring($path.IndexOf(' -> ') + 4) }
        [void]$paths.Add($path)
    }
    return $paths.ToArray()
}

function Test-PathAllowed {
    param([string]$CandidatePath)
    foreach ($allowed in $script:AllowedWorkingTreePaths) {
        if ($allowed.EndsWith('/')) {
            if ($CandidatePath -eq $allowed -or $CandidatePath.StartsWith($allowed)) { return $true }
        } elseif ($CandidatePath -eq $allowed) {
            return $true
        }
    }
    return $false
}

# A malformed-request response must be an intentional, standardised plain-text error: no
# echoed request bytes, no stack, an accurate Content-Length and a closed connection.
function Assert-StandardisedClientError {
    param($Response, [int[]]$AllowedStatus, [string[]]$MustNotEcho, [string]$What)
    Assert-InSet -Actual $Response.StatusCode -Allowed $AllowedStatus -What ("{0}: status code" -f $What)
    Assert-HeaderEqual -Response $Response -Name 'Content-Type' -Value $script:Expected.ContentType -What $What
    Assert-HeaderEqual -Response $Response -Name 'Connection' -Value 'close' -What $What
    Assert-True -Condition ($Response.BodyLength -gt 0) -What ("{0}: response must carry a plain-text body" -f $What)
    $length = Get-HeaderValue -Response $Response -Name 'Content-Length'
    if ($null -eq $length) {
        Assert-Failed ("{0}: Content-Length header is absent; headers=[{1}]" -f $What, (Show-Text $Response.HeaderText))
    }
    Assert-Equal -Actual ([int]$length) -Expected $Response.BodyLength -What ("{0}: Content-Length must match the body byte count" -f $What)
    Assert-Match -Text $Response.BodyText -Pattern '^[\x20-\x7E\r\n]+$' -What ("{0}: body must be printable plain text" -f $What)
    Assert-NoRawCrash -Text $Response.RawText -What ("{0}: response must not leak internals" -f $What)
    foreach ($fragment in $MustNotEcho) {
        Assert-NotContains -Text $Response.BodyText -Needle $fragment -What ("{0}: body must not echo the request" -f $What)
    }
    Assert-True -Condition $Response.Closed -What ("{0}: server must close the connection" -f $What)
}

function Get-EstablishedConnectionCount {
    param([int]$TargetPort)
    try {
        $connections = Get-NetTCPConnection -LocalPort $TargetPort -State Established -ErrorAction SilentlyContinue
    } catch {
        return -1   # cmdlet unavailable: the caller treats -1 as "not measurable"
    }
    if ($null -eq $connections) { return 0 }
    return @($connections).Count
}

# A node child's stderr interleaves the application's own diagnostic lines with what node
# renders after each of them: indented stack frames, and the indented property dump of an
# error object with its closing brace. The unindented head lines are the diagnostics.
function Get-DiagnosticLines {
    param([string]$Text)
    $result = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($raw in ($Text -split "`n")) {
        $line = $raw.TrimEnd("`r")
        if ($line.Trim() -eq '') { continue }
        if ($line -match '^\s') { continue }
        if ($line -match '^[\}\]\{]') { continue }
        [void]$result.Add($line)
    }
    return $result.ToArray()
}

# Asserts the child emitted exactly these diagnostics, in this order, and nothing else.
# Only the error rendering that follows each prefix is treated as variable data: which
# object shape a diagnostic prints is owned by the observability concern, whereas the
# number of diagnostics, their order and their wording are asserted here.
function Assert-DiagnosticSequence {
    param([string]$Text, [string[]]$ExpectedPrefixes, [string]$What)
    $lines = @(Get-DiagnosticLines -Text $Text)
    Assert-Equal -Actual $lines.Count -Expected $ExpectedPrefixes.Count `
        -What ("{0}: diagnostic line count (actual: {1})" -f $What, (Show-Text ($lines -join ' | ')))
    for ($i = 0; $i -lt $ExpectedPrefixes.Count; $i++) {
        if (-not $lines[$i].StartsWith($ExpectedPrefixes[$i])) {
            Assert-Failed ("{0}: diagnostic {1} must begin with [{2}] but was [{3}]" -f `
                $What, $i, $ExpectedPrefixes[$i], (Show-Text $lines[$i]))
        }
    }
}

# Asserts the application's stdout is exactly these lines, in order, with nothing else.
# The driver's own machine-readable markers are excluded before comparison.
function Assert-LogSequence {
    param($Logs, [string[]]$Expected, [string]$What)
    $lines = @($Logs)
    Assert-Equal -Actual $lines.Count -Expected $Expected.Count `
        -What ("{0}: stdout line count (actual: {1})" -f $What, (Show-Text ($lines -join ' | ')))
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        Assert-Equal -Actual $lines[$i] -Expected $Expected[$i] -What ("{0}: stdout line {1}" -f $What, $i)
    }
}

function Assert-EndsWith {
    param([string]$Text, [string]$Suffix, [string]$What)
    if ($null -eq $Text) { $Text = '' }
    if (-not $Text.EndsWith($Suffix)) {
        Assert-Failed ("{0}: [{1}] must end with [{2}]" -f $What, (Show-Text $Text), (Show-Text $Suffix))
    }
}

# The shutdown announcement for a fatal trigger: the reason label in front of it is the
# lifecycle concern's to choose, the announcement itself is fixed.
function Assert-FatalShutdownLogs {
    param($Driver, [int]$BindPort, [string]$What)
    $logs = @($Driver.Logs)
    Assert-Equal -Actual $logs.Count -Expected 3 `
        -What ("{0}: stdout line count (actual: {1})" -f $What, (Show-Text ($logs -join ' | ')))
    Assert-Equal -Actual $logs[0] -Expected (Get-StartupLog -BindHost $script:Expected.DefaultHost -BindPort $BindPort) `
        -What ("{0}: startup log" -f $What)
    Assert-EndsWith -Text $logs[1] -Suffix 'received: closing server gracefully...' -What ("{0}: shutdown announcement" -f $What)
    Assert-Equal -Actual $logs[2] -Expected $script:Expected.ClosedLog -What ("{0}: close-completion log" -f $What)
}

function Format-CallList {
    param($Calls)
    $items = @()
    foreach ($call in @($Calls)) {
        $name = Get-Prop -Object $call -Name 'name'
        $value = Get-Prop -Object $call -Name 'value'
        $text = [string](Get-Prop -Object $call -Name 'call')
        if ($null -ne $name) { $text += "('" + $name + "')" }
        if ($null -ne $value) { $text += '=' + (Show-Text ([string]$value)) }
        $items += $text
    }
    if ($items.Count -eq 0) { return '<no calls>' }
    return ($items -join '; ')
}

# Asserts the exact ordered sequence of response calls the handler made.
function Assert-CallSequence {
    param($Calls, [array]$Expected, [string]$What)
    # An empty JSON array arrives as $null through a function return, and @($null) would
    # otherwise count as one element.
    $actual = @($Calls | Where-Object { $null -ne $_ })
    Assert-Equal -Actual $actual.Count -Expected $Expected.Count `
        -What ("{0}: response call count (actual sequence: {1})" -f $What, (Format-CallList $actual))
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        $expectedCall = $Expected[$i]
        $actualCall = $actual[$i]
        Assert-Equal -Actual (Get-Prop -Object $actualCall -Name 'call') -Expected $expectedCall['call'] `
            -What ("{0}: call {1} kind" -f $What, $i)
        if ($expectedCall.ContainsKey('name')) {
            Assert-Equal -Actual (Get-Prop -Object $actualCall -Name 'name') -Expected $expectedCall['name'] `
                -What ("{0}: call {1} header name" -f $What, $i)
        }
        if ($expectedCall.ContainsKey('value')) {
            Assert-Equal -Actual (Get-Prop -Object $actualCall -Name 'value') -Expected $expectedCall['value'] `
                -What ("{0}: call {1} value" -f $What, $i)
        }
    }
}

# Once a response is committed, ended or destroyed, no further body may be produced.
# Header mutation and a deliberate destroy() are permitted; a write is not.
function Assert-NoResponseBodyWrite {
    param($Calls, [string]$What)
    foreach ($call in @($Calls | Where-Object { $null -ne $_ })) {
        $kind = [string](Get-Prop -Object $call -Name 'call')
        if ($kind -eq 'end' -or $kind -eq 'write' -or $kind -eq 'writeHead') {
            Assert-Failed ("{0}: response was written again after it was already committed/ended/destroyed (calls: {1})" -f `
                $What, (Format-CallList $Calls))
        }
    }
}

# Configuration outcome. A present value must either be accepted with a value in the
# allowed set, or be rejected before listen() with a clean non-zero startup failure.
# Silently binding something else - the default, or the raw malformed value - fails.
function Assert-ConfigOutcome {
    param(
        $Driver,
        [object[]]$AllowedPorts,
        [string[]]$AllowedHosts,
        [string]$What
    )
    $result = $Driver.Result
    Assert-True -Condition ($null -ne $result) -What ("{0}: driver produced no result payload; stdout=[{1}] stderr=[{2}]" -f $What, (Show-Text $Driver.Out), (Show-Text $Driver.Err))
    if (-not (Get-Prop -Object $result -Name 'listenCalled')) {
        # Rejected: startup must fail loudly, cleanly, and before any bind attempt.
        Assert-True -Condition ($Driver.ExitCode -ne 0) -What ("{0}: a rejected configuration must exit non-zero" -f $What)
        Assert-True -Condition ($Driver.Err.Trim().Length -gt 0) -What ("{0}: a rejected configuration must explain itself on stderr" -f $What)
        Assert-NoRawCrash -Text $Driver.Err -What ("{0}: rejection diagnostic" -f $What)
        Assert-NotContains -Text $Driver.Out -Needle 'Server running at' -What ("{0}: a rejected configuration must not report a running server" -f $What)
        return 'rejected'
    }
    $listenArgs = @(Get-Prop -Object $result -Name 'listenArgs')
    Assert-True -Condition ($listenArgs.Count -ge 2) -What ("{0}: listen() must receive a port and a host (got [{1}])" -f $What, ($listenArgs -join ', '))
    Assert-InSet -Actual $listenArgs[0] -Allowed $AllowedPorts -What ("{0}: port passed to listen()" -f $What)
    Assert-InSet -Actual $listenArgs[1] -Allowed $AllowedHosts -What ("{0}: host passed to listen()" -f $What)
    Assert-Equal -Actual $Driver.ExitCode -Expected 0 -What ("{0}: an accepted configuration must not fail" -f $What)
    $logs = @($Driver.Logs)
    Assert-Equal -Actual $logs.Count -Expected 1 -What ("{0}: startup log line count" -f $What)
    Assert-Equal -Actual $logs[0] -Expected (Get-StartupLog -BindHost ([string]$listenArgs[1]) -BindPort ([int]$listenArgs[0])) `
        -What ("{0}: startup log must report exactly what was bound" -f $What)
    return 'accepted'
}

# --------------------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------------------
$script:HarnessError = ''
$httpFixture = $null
$httpPort = 0

try {
    Initialize-WorkDir

    # The handler-level cases run with PORT and HOST cleared and listen() stubbed, so the
    # one line they may print is the startup log for the documented defaults.
    $script:UnitStartupLog = Get-StartupLog -BindHost $script:Expected.DefaultHost -BindPort $script:Expected.DefaultPort

    if (-not $script:ListMode) {
        Write-Line ''
        Write-Line 'server.js verification harness'
        Write-Line ('  repository : ' + $script:RepoRoot)
        Write-Line ('  work dir   : ' + $script:WorkPath)
        Write-Line ('  node       : ' + (Invoke-Tool -File 'node' -Arguments @('--version') -Label 'node-version').Out.Trim())
        Write-Line ('  filter     : ' + $Only)
        Write-Line ''
    }

    # ==================================================================================
    # Group A - static contract and repository continuity (AAP 0.5.3, 0.7.2)
    # ==================================================================================
    Invoke-Case -Id 'A01' -Owner 'AAP' -Name 'node --check server.js exits 0 with no diagnostics' -Body {
        $run = Invoke-Tool -File 'node' -Arguments @('--check', 'server.js') -Label 'node-check'
        Assert-Equal -Actual $run.ExitCode -Expected 0 -What 'node --check exit code'
        Assert-Equal -Actual $run.Out.Trim() -Expected '' -What 'node --check stdout'
        Assert-Equal -Actual $run.Err.Trim() -Expected '' -What 'node --check stderr'
    }

    Invoke-Case -Id 'A02' -Owner 'AAP' -Name 'npm test remains the sanctioned placeholder that exits 1' -Body {
        $manifest = (Read-TextFile -Path (Join-Path $script:RepoRoot 'package.json')) | ConvertFrom-Json
        $scripts = Get-Prop -Object $manifest -Name 'scripts'
        Assert-True -Condition ($null -ne $scripts) -What 'package.json must declare a scripts section'
        Assert-Equal -Actual (Get-Prop -Object $scripts -Name 'test') -Expected $script:Expected.TestScript -What 'package.json scripts.test'
        $run = Invoke-Tool -File 'cmd' -Arguments @('/c', 'npm', 'test') -EnvVars @{ CI = 'true' } -Label 'npm-test'
        Assert-Equal -Actual $run.ExitCode -Expected 1 -What 'npm test exit code (the placeholder must keep failing)'
        Assert-Contains -Text ($run.Out + $run.Err) -Needle 'Error: no test specified' -What 'npm test output'
    }

    Invoke-Case -Id 'A03' -Owner 'AAP' -Name 'zero-dependency footprint: no packages, only the http built-in' -Body {
        $manifest = (Read-TextFile -Path (Join-Path $script:RepoRoot 'package.json')) | ConvertFrom-Json
        Assert-True -Condition ($null -eq (Get-Prop -Object $manifest -Name 'dependencies')) -What 'package.json must declare no dependencies'
        Assert-True -Condition ($null -eq (Get-Prop -Object $manifest -Name 'devDependencies')) -What 'package.json must declare no devDependencies'
        # The lockfile is read as text on purpose: its root package key is the empty
        # string, which ConvertFrom-Json in PowerShell 5.1 cannot represent as a property.
        $lockText = Read-TextFile -Path (Join-Path $script:RepoRoot 'package-lock.json')
        Assert-Match -Text $lockText -Pattern '"lockfileVersion"\s*:\s*3' -What 'package-lock.json lockfileVersion'
        Assert-Match -Text $lockText -Pattern '"packages"\s*:\s*\{\s*""\s*:' -What 'package-lock.json must open its packages map with the root package'
        Assert-NotContains -Text $lockText -Needle 'node_modules/' -What 'package-lock.json must contain no installed package entry'
        Assert-True -Condition (-not (Test-Path (Join-Path $script:RepoRoot 'node_modules'))) -What 'no node_modules directory may exist'
        $source = Read-TextFile -Path $script:ServerPath
        $requires = [regex]::Matches($source, "require\(\s*'([^']+)'\s*\)")
        Assert-True -Condition ($requires.Count -ge 1) -What 'server.js must require the http module'
        foreach ($match in $requires) {
            Assert-Equal -Actual $match.Groups[1].Value -Expected 'http' -What 'server.js may only require the http built-in'
        }
    }

    Invoke-Case -Id 'A04' -Owner 'AAP' -Name 'manifest blobs are byte-identical to the baseline' -Body {
        Assert-Equal -Actual (Invoke-Git -Arguments @('rev-parse', 'HEAD:package.json')).Trim() `
            -Expected $script:Expected.PackageJsonBlob -What 'package.json blob id at HEAD'
        Assert-Equal -Actual (Invoke-Git -Arguments @('rev-parse', 'HEAD:package-lock.json')).Trim() `
            -Expected $script:Expected.PackageLockBlob -What 'package-lock.json blob id at HEAD'
        $status = Invoke-Git -Arguments @('status', '--porcelain', '--', 'package.json', 'package-lock.json')
        Assert-Equal -Actual $status.Trim() -Expected '' -What 'both manifests must be unmodified in the working tree'
    }

    Invoke-Case -Id 'A05' -Owner 'AAP' -Name 'working tree changes are confined to the sanctioned paths' -Body {
        $status = Invoke-Git -Arguments @('status', '--porcelain')
        $paths = Get-WorkingTreePaths -PorcelainText $status
        foreach ($path in $paths) {
            if (-not (Test-PathAllowed -CandidatePath $path)) {
                Assert-Failed ("unexpected working-tree change [{0}]; only [{1}] are sanctioned by AAP 0.6.1" -f $path, ($script:AllowedWorkingTreePaths -join ', '))
            }
        }
    }

    Invoke-Case -Id 'A06' -Owner 'AAP' -Name 'the committed change set since the baseline is exactly the sanctioned one' -Body {
        # A05 and A07 compare the working tree with HEAD, so on their own they cannot see a
        # change that was committed. This case compares the pre-fix baseline commit with
        # HEAD and requires the exact sanctioned set, which is what AAP 0.7.2 means by
        # "git diff --stat shows only server.js changed" (plus this harness itself).
        $baseline = $BaselineRef
        $resolved = Invoke-Tool -File 'git' -Arguments @('rev-parse', '--verify', "$baseline^{commit}") -Label 'git-baseline'
        if ($resolved.ExitCode -ne 0) {
            Assert-Failed ("the baseline commit [{0}] is not present in this repository; pass -BaselineRef with the pre-fix commit. git said: {1}" -f `
                $baseline, (Show-Text ($resolved.Out + $resolved.Err)))
        }
        # Anchor the baseline by content, not only by name: at that commit server.js must
        # still be the original scaffold.
        $baselineBlob = (Invoke-Git -Arguments @('rev-parse', ("{0}:server.js" -f $baseline))).Trim()
        Assert-Equal -Actual $baselineBlob -Expected $script:Expected.BaselineServerBlob `
            -What 'the baseline commit must carry the original, pre-fix server.js'
        $nameStatus = Invoke-Git -Arguments @('diff', '--name-status', $baseline, 'HEAD')
        $entries = New-Object System.Collections.ArrayList
        foreach ($line in ($nameStatus -split "`n")) {
            $entry = $line.TrimEnd("`r")
            if ($entry.Trim() -eq '') { continue }
            [void]$entries.Add(($entry -replace "`t", ' '))
        }
        $actual = @($entries.ToArray() | Sort-Object)
        $expected = @($script:Expected.CommittedChangeSet | Sort-Object)
        Assert-Equal -Actual ($actual -join '; ') -Expected ($expected -join '; ') `
            -What 'committed change set between the baseline and HEAD'
    }

    Invoke-Case -Id 'A07' -Owner 'AAP' -Name 'every file AAP 0.6.2 excludes is untouched' -Body {
        $arguments = @('diff', '--name-only', 'HEAD', '--') + $script:ProtectedPaths
        $diff = Invoke-Git -Arguments $arguments
        Assert-Equal -Actual $diff.Trim() -Expected '' -What 'excluded files must show no diff against HEAD'
        $statusArgs = @('status', '--porcelain', '--') + $script:ProtectedPaths
        $status = Invoke-Git -Arguments $statusArgs
        Assert-Equal -Actual $status.Trim() -Expected '' -What 'excluded files must be clean in the working tree'
    }

    # ==================================================================================
    # Group B - the HTTP contract, asserted byte for byte against a live listener
    # ==================================================================================
    # The live listener is started only when a case that needs it is actually selected, so
    # a filtered run neither binds a port nor leaves a process behind.
    $liveHttpCases = @(
        'B01', 'B02', 'B03', 'B04', 'B05', 'B06', 'B07', 'B08', 'B09', 'B10', 'B11', 'B12', 'B13',
        'C01', 'C02', 'C03', 'C04', 'C05', 'C06'
    )
    if (-not $script:ListMode -and (Test-AnyCaseSelected -Ids $liveHttpCases)) {
        try {
            $httpPort = Get-FreePort -Preferred $Port
            $httpFixture = Start-NodeChild -NodeArgs @('server.js') -Label 'http' `
                -EnvVars @{ PORT = "$httpPort"; HOST = $script:Expected.DefaultHost }
            [void](Wait-ForChildOutput -Child $httpFixture -Pattern 'Server running at' -TimeoutMs 15000)
        } catch {
            Add-SyntheticFailure -Id 'B00' -Owner 'AAP' -Name 'HTTP fixture reaches a ready listener' -Message $_.Exception.Message
            $httpFixture = $null
        }
    }

    function Assert-Fixture {
        Assert-True -Condition ($null -ne $httpFixture) -What 'the HTTP fixture must be running (see case B00)'
    }

    Invoke-Case -Id 'B01' -Owner 'AAP' -Name 'startup log is the exact single line, stderr stays empty' -Body {
        Assert-Fixture
        $stdout = Get-ChildOut -Child $httpFixture
        $lines = @(Get-PlainLogLines -Text $stdout)
        Assert-Equal -Actual $lines.Count -Expected 1 -What 'startup stdout line count'
        Assert-Equal -Actual $lines[0] -Expected (Get-StartupLog -BindHost $script:Expected.DefaultHost -BindPort $httpPort) -What 'startup log line'
        Assert-Equal -Actual (Get-ChildErr -Child $httpFixture).Trim() -Expected '' -What 'startup stderr'
    }

    Invoke-Case -Id 'B02' -Owner 'AAP' -Name 'GET / returns 200 text/plain and the exact 14-byte greeting' -Body {
        Assert-Fixture
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText (New-Request -TargetPort $httpPort) -ExpectServerClose
        Assert-Equal -Actual $response.StatusLine -Expected 'HTTP/1.1 200 OK' -What 'GET / status line'
        Assert-HeaderEqual -Response $response -Name 'Content-Type' -Value $script:Expected.ContentType -What 'GET /'
        Assert-HeaderEqual -Response $response -Name 'Content-Length' -Value ([string]$script:Expected.GreetingLength) -What 'GET /'
        Assert-BytesEqual -Actual $response.BodyBytes -Expected $script:Expected.GreetingBytes -What 'GET / body bytes'
        Assert-Equal -Actual $response.BodyLength -Expected $script:Expected.GreetingLength -What 'GET / body byte count'
        Assert-Equal -Actual $response.BodyBytes[$response.BodyLength - 1] -Expected 10 -What 'GET / body must end with a single LF'
    }

    Invoke-Case -Id 'B03' -Owner 'AAP' -Name 'HEAD / returns 200 text/plain with a zero-byte body' -Body {
        Assert-Fixture
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText (New-Request -Method 'HEAD' -TargetPort $httpPort) -ExpectServerClose
        Assert-Equal -Actual $response.StatusLine -Expected 'HTTP/1.1 200 OK' -What 'HEAD / status line'
        Assert-HeaderEqual -Response $response -Name 'Content-Type' -Value $script:Expected.ContentType -What 'HEAD /'
        Assert-Equal -Actual $response.BodyLength -Expected 0 -What 'HEAD / body byte count'
    }

    Invoke-Case -Id 'B04' -Owner 'AAP' -Name 'keep-alive response advertises the configured 5s keep-alive ceiling' -Body {
        Assert-Fixture
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText (New-Request -TargetPort $httpPort -KeepAlive) -IdleMs 1200
        Assert-Equal -Actual $response.StatusCode -Expected 200 -What 'keep-alive GET / status'
        Assert-HeaderEqual -Response $response -Name 'Connection' -Value 'keep-alive' -What 'keep-alive GET /'
        $expectedSeconds = [int]($script:Expected.KeepAliveTimeout / 1000)
        Assert-HeaderEqual -Response $response -Name 'Keep-Alive' -Value ("timeout={0}" -f $expectedSeconds) -What 'keep-alive GET /'
        Assert-BytesEqual -Actual $response.BodyBytes -Expected $script:Expected.GreetingBytes -What 'keep-alive GET / body'
    }

    $disallowedMethods = @(
        @{ Id = 'B05'; Method = 'POST' },
        @{ Id = 'B06'; Method = 'PUT' },
        @{ Id = 'B07'; Method = 'DELETE' },
        @{ Id = 'B08'; Method = 'PATCH' },
        @{ Id = 'B09'; Method = 'OPTIONS' },
        @{ Id = 'B10'; Method = 'TRACE' }
    )
    foreach ($entry in $disallowedMethods) {
        $method = [string]$entry.Method
        Invoke-Case -Id ([string]$entry.Id) -Owner 'AAP' -Name ("{0} / is rejected with 405, exact Allow header and exact body" -f $method) -Body {
            Assert-Fixture
            $request = New-Request -Method $method -TargetPort $httpPort -ExtraHeaders @('Content-Length: 0')
            $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText $request -ExpectServerClose
            Assert-Equal -Actual $response.StatusLine -Expected 'HTTP/1.1 405 Method Not Allowed' -What ("{0} / status line" -f $method)
            Assert-HeaderEqual -Response $response -Name 'Allow' -Value $script:Expected.AllowHeader -What ("{0} /" -f $method)
            Assert-HeaderEqual -Response $response -Name 'Content-Type' -Value $script:Expected.ContentType -What ("{0} /" -f $method)
            Assert-Equal -Actual $response.BodyText -Expected $script:Expected.MethodNotAllowed -What ("{0} / body" -f $method)
            Assert-HeaderEqual -Response $response -Name 'Content-Length' -Value ([string]$script:Expected.MethodNotAllowed.Length) -What ("{0} /" -f $method)
        }
    }

    Invoke-Case -Id 'B11' -Owner 'AAP' -Name 'GET on an unknown path keeps the method-only contract (no 404)' -Body {
        Assert-Fixture
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText (New-Request -Path '/no/such/route?x=1&y=2' -TargetPort $httpPort) -ExpectServerClose
        Assert-Equal -Actual $response.StatusLine -Expected 'HTTP/1.1 200 OK' -What 'GET /no/such/route status line'
        Assert-HeaderEqual -Response $response -Name 'Content-Type' -Value $script:Expected.ContentType -What 'GET /no/such/route'
        Assert-BytesEqual -Actual $response.BodyBytes -Expected $script:Expected.GreetingBytes -What 'GET /no/such/route body bytes'
    }

    Invoke-Case -Id 'B12' -Owner 'AAP' -Name 'HEAD on an unknown path returns 200 with no body' -Body {
        Assert-Fixture
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText (New-Request -Method 'HEAD' -Path '/no/such/route' -TargetPort $httpPort) -ExpectServerClose
        Assert-Equal -Actual $response.StatusCode -Expected 200 -What 'HEAD /no/such/route status'
        Assert-Equal -Actual $response.BodyLength -Expected 0 -What 'HEAD /no/such/route body byte count'
    }

    Invoke-Case -Id 'B13' -Owner 'AAP' -Name 'two pipelined requests on one connection both answer exactly' -Body {
        Assert-Fixture
        $first = New-Request -TargetPort $httpPort -KeepAlive
        $second = New-Request -TargetPort $httpPort
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText ($first + $second) -ExpectServerClose
        Assert-OccurrenceCount -Text $response.RawText -Needle 'HTTP/1.1 200 OK' -Expected 2 -What 'pipelined 200 responses'
        Assert-OccurrenceCount -Text $response.RawText -Needle $script:Expected.GreetingText -Expected 2 -What 'pipelined greeting bodies'
    }

    # ==================================================================================
    # Group C - parser and special-method edges (review finding F06)
    # ==================================================================================
    Invoke-Case -Id 'C01' -Owner 'API-F03' -Name 'CONNECT is rejected with the standard 405 response, not a silent socket drop' -Body {
        Assert-Fixture
        $request = "CONNECT 127.0.0.1:9999 HTTP/1.1`r`nHost: 127.0.0.1:9999`r`n`r`n"
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText $request -ExpectServerClose -TotalMs 8000
        Assert-True -Condition ($response.RawBytes.Length -gt 0) -What 'CONNECT must receive a response rather than a closed socket'
        Assert-Equal -Actual $response.StatusCode -Expected 405 -What 'CONNECT status code'
        Assert-HeaderEqual -Response $response -Name 'Allow' -Value $script:Expected.AllowHeader -What 'CONNECT'
        Assert-HeaderEqual -Response $response -Name 'Content-Type' -Value $script:Expected.ContentType -What 'CONNECT'
        Assert-Equal -Actual $response.BodyText -Expected $script:Expected.MethodNotAllowed -What 'CONNECT body'
        Assert-True -Condition $response.Closed -What 'CONNECT: server must close the socket'
        Assert-ServerStillHealthy -Child $httpFixture -TargetPort $httpPort -What 'after CONNECT'
    }

    Invoke-Case -Id 'C02' -Owner 'API-F04' -Name 'unknown method token gets a standardised plain-text 400' -Body {
        Assert-Fixture
        $request = "BOGUS / HTTP/1.1`r`nHost: 127.0.0.1`r`n`r`n"
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText $request -ExpectServerClose -TotalMs 8000
        Assert-StandardisedClientError -Response $response -AllowedStatus @(400) -MustNotEcho @('BOGUS') -What 'unknown method token'
        Assert-ServerStillHealthy -Child $httpFixture -TargetPort $httpPort -What 'after an unknown method token'
    }

    Invoke-Case -Id 'C03' -Owner 'API-F04' -Name 'malformed header line gets a standardised plain-text 400' -Body {
        Assert-Fixture
        $request = "GET / HTTP/1.1`r`nHost: 127.0.0.1`r`nBad Header Line`r`n`r`n"
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText $request -ExpectServerClose -TotalMs 8000
        Assert-StandardisedClientError -Response $response -AllowedStatus @(400) -MustNotEcho @('Bad Header Line') -What 'malformed header line'
        Assert-ServerStillHealthy -Child $httpFixture -TargetPort $httpPort -What 'after a malformed header line'
    }

    Invoke-Case -Id 'C04' -Owner 'API-F04' -Name 'oversized header block gets a standardised plain-text 431 or 400' -Body {
        Assert-Fixture
        $filler = 'a' * 20000
        $request = "GET / HTTP/1.1`r`nHost: 127.0.0.1`r`nX-Oversized: $filler`r`n`r`n"
        $response = Invoke-HttpExchange -TargetPort $httpPort -RequestText $request -ExpectServerClose -TotalMs 12000
        Assert-StandardisedClientError -Response $response -AllowedStatus @(431, 400) -MustNotEcho @('aaaaaaaaaa') -What 'oversized header block'
        Assert-ServerStillHealthy -Child $httpFixture -TargetPort $httpPort -What 'after an oversized header block'
    }

    Invoke-Case -Id 'C05' -Owner 'AAP' -Name 'no socket or process leak survives the parser edge cases' -Body {
        Assert-Fixture
        Assert-True -Condition (-not $httpFixture.Process.HasExited) -What 'the server process must still be alive'
        $established = -1
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $established = Get-EstablishedConnectionCount -TargetPort $httpPort
            if ($established -le 0) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($established -ge 0) {
            Assert-Equal -Actual $established -Expected 0 -What 'established connections to the listener after every client closed'
        }
        Assert-ServerStillHealthy -Child $httpFixture -TargetPort $httpPort -What 'after the parser edge cases'
    }

    Invoke-Case -Id 'C06' -Owner 'AAP' -Name 'the whole HTTP group produced no unexpected server diagnostics' -Body {
        Assert-Fixture
        $stderr = Get-ChildErr -Child $httpFixture
        Assert-NoRawCrash -Text $stderr -What 'server stderr across the HTTP group'
        Assert-NotContains -Text $stderr -Needle $script:Expected.HandlerErrorLog -What 'server stderr across the HTTP group'
        $lines = @(Get-PlainLogLines -Text (Get-ChildOut -Child $httpFixture))
        Assert-Equal -Actual $lines.Count -Expected 1 -What 'the server must log nothing beyond its startup line while serving'
    }

    if (-not $script:ListMode -and $null -ne $httpFixture) {
        Stop-TrackedChild -Child $httpFixture
        [void]$script:Children.Remove($httpFixture)
        $httpFixture = $null
    }


    # ==================================================================================
    # Group D - error paths, each executed in its own child process (review finding F03)
    # ==================================================================================
    Invoke-Case -Id 'D01' -Owner 'AAP' -Name 'request-stream error before commit answers 400 Bad Request' -Body {
        $driver = Invoke-Driver -Mode 'unit:request-error-before-headers'
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'D01 child exit code'
        $unit = $driver.Unit
        Assert-True -Condition ($null -ne $unit) -What 'D01: driver must report a unit payload'
        Assert-Equal -Actual (Get-Prop -Object $unit -Name 'requestErrorListeners') -Expected 1 -What 'request-stream error listeners registered'
        Assert-Equal -Actual (Get-Prop -Object $unit -Name 'responseErrorListeners') -Expected 1 -What 'response-stream error listeners registered'
        Assert-True -Condition (-not (Get-Prop -Object $unit -Name 'threwOutOfHandler')) -What 'the handler must not throw'
        Assert-True -Condition (-not (Get-Prop -Object $unit -Name 'threwOnInjection')) -What 'the error listener must not throw'
        Assert-Equal -Actual (Get-Prop -Object $unit -Name 'statusCode') -Expected 400 -What 'status after a pre-commit request error'
        # The error arrives while the response is still uncommitted, so the 400 is the one
        # terminal response and the greeting is suppressed: the exact call sequence proves
        # both, since a written greeting would appear here.
        Assert-CallSequence -Calls (Get-Prop -Object $unit -Name 'callsDuringHandler') -What 'pre-commit request-error response' -Expected @(
            @{ call = 'setHeader'; name = 'Content-Type'; value = $script:Expected.ContentType },
            @{ call = 'end'; value = $script:Expected.BadRequest }
        )
        Assert-CallSequence -Calls (Get-Prop -Object $unit -Name 'callsAfterInjection') -What 'nothing further after the 400' -Expected @()
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.ReqErrorLog) -What 'D01 stderr'
        Assert-LogSequence -Logs $driver.Logs -What 'D01 stdout' -Expected @($script:UnitStartupLog)
    }

    $postCommitStates = @(
        @{ Id = 'D02'; Mode = 'unit:request-error-after-headers'; Label = 'after headers were sent' },
        @{ Id = 'D03'; Mode = 'unit:request-error-after-end'; Label = 'after the response ended' },
        @{ Id = 'D04'; Mode = 'unit:request-error-after-destroy'; Label = 'after the response was destroyed' }
    )
    foreach ($entry in $postCommitStates) {
        $mode = [string]$entry.Mode
        $label = [string]$entry.Label
        Invoke-Case -Id ([string]$entry.Id) -Owner 'API-F01' -Name ("request-stream error {0} writes no second response" -f $label) -Body {
            $driver = Invoke-Driver -Mode $mode
            Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'child exit code'
            $unit = $driver.Unit
            Assert-True -Condition ($null -ne $unit) -What 'driver must report a unit payload'
            Assert-True -Condition (-not (Get-Prop -Object $unit -Name 'threwOnInjection')) -What 'the error listener must not throw'
            Assert-Equal -Actual (Get-Prop -Object $unit -Name 'statusCode') -Expected 200 -What 'committed status must not be rewritten'
            Assert-NoResponseBodyWrite -Calls (Get-Prop -Object $unit -Name 'callsAfterInjection') -What ("request-stream error {0}" -f $label)
            Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.ReqErrorLog) -What ("stderr for a request error {0}" -f $label)
            Assert-LogSequence -Logs $driver.Logs -What ("stdout for a request error {0}" -f $label) -Expected @($script:UnitStartupLog)
        }
    }

    Invoke-Case -Id 'D05' -Owner 'AAP' -Name 'response-stream error is logged and writes nothing further' -Body {
        $driver = Invoke-Driver -Mode 'unit:response-error'
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'D05 child exit code'
        $unit = $driver.Unit
        Assert-True -Condition ($null -ne $unit) -What 'D05: driver must report a unit payload'
        Assert-True -Condition (-not (Get-Prop -Object $unit -Name 'threwOnInjection')) -What 'the response error listener must not throw'
        Assert-CallSequence -Calls (Get-Prop -Object $unit -Name 'callsAfterInjection') -What 'response-error handling' -Expected @()
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.ResErrorLog) -What 'D05 stderr'
        Assert-LogSequence -Logs $driver.Logs -What 'D05 stdout' -Expected @($script:UnitStartupLog)
    }

    Invoke-Case -Id 'D06' -Owner 'AAP' -Name 'synchronous handler throw before commit answers 500' -Body {
        $driver = Invoke-Driver -Mode 'unit:throw-before-headers'
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'D06 child exit code'
        $unit = $driver.Unit
        Assert-True -Condition ($null -ne $unit) -What 'D06: driver must report a unit payload'
        Assert-True -Condition (-not (Get-Prop -Object $unit -Name 'threwOutOfHandler')) -What 'the handler must swallow the throw and answer instead'
        Assert-Equal -Actual (Get-Prop -Object $unit -Name 'statusCode') -Expected 500 -What 'status after a pre-commit handler throw'
        $calls = @(Get-Prop -Object $unit -Name 'callsDuringHandler')
        $last = $calls[$calls.Count - 1]
        Assert-Equal -Actual (Get-Prop -Object $last -Name 'call') -Expected 'end' -What 'the 500 response must be ended'
        Assert-Equal -Actual (Get-Prop -Object $last -Name 'value') -Expected $script:Expected.ServerError -What '500 response body'
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.HandlerErrorLog) -What 'D06 stderr'
        Assert-LogSequence -Logs $driver.Logs -What 'D06 stdout' -Expected @($script:UnitStartupLog)
    }

    Invoke-Case -Id 'D07' -Owner 'API-F02' -Name 'handler throw after commit appends no body under the wrong status' -Body {
        $driver = Invoke-Driver -Mode 'unit:throw-after-headers'
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'D07 child exit code'
        $unit = $driver.Unit
        Assert-True -Condition ($null -ne $unit) -What 'D07: driver must report a unit payload'
        Assert-True -Condition (-not (Get-Prop -Object $unit -Name 'threwOutOfHandler')) -What 'the catch block must not itself throw'
        Assert-NoResponseBodyWrite -Calls (Get-Prop -Object $unit -Name 'callsDuringHandler') -What 'post-commit handler throw'
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.HandlerErrorLog) -What 'D07 stderr'
        Assert-LogSequence -Logs $driver.Logs -What 'D07 stdout' -Expected @($script:UnitStartupLog)
    }

    Invoke-Case -Id 'D08' -Owner 'AAP' -Name 'a port already in use fails with one clean line, exit 1 and no crash dump' -Body {
        $conflictPort = Get-FreePort
        $envVars = @{ PORT = "$conflictPort"; HOST = $script:Expected.DefaultHost }
        $first = Start-NodeChild -NodeArgs @('server.js') -EnvVars $envVars -Label 'eaddrinuse-first'
        [void](Wait-ForChildOutput -Child $first -Pattern 'Server running at' -TimeoutMs 15000)
        $second = Start-NodeChild -NodeArgs @('server.js') -EnvVars $envVars -Label 'eaddrinuse-second'
        $exit = Wait-ChildExit -Child $second -TimeoutMs 15000
        Assert-Equal -Actual $exit.ExitCode -Expected 1 -What 'the second instance must exit 1'
        Assert-Equal -Actual $exit.Err.Trim() -Expected ("Port {0} is already in use on {1}." -f $conflictPort, $script:Expected.DefaultHost) -What 'EADDRINUSE diagnostic'
        Assert-Equal -Actual (@(Get-PlainLogLines -Text $exit.Out)).Count -Expected 0 -What 'the failed instance must not claim to be running'
        Assert-NoRawCrash -Text $exit.Err -What 'EADDRINUSE diagnostic'
        Assert-NotContains -Text $exit.Err -Needle 'EADDRINUSE' -What 'EADDRINUSE diagnostic must be the application message, not the raw code'
        Assert-ServerStillHealthy -Child $first -TargetPort $conflictPort -What 'the first instance after the conflict'
    }

    Invoke-Case -Id 'D09' -Owner 'AAP' -Name 'a bind privilege failure reports the exact diagnostic and exits 1' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'server-error-before-listen' -Argument 'EACCES' -TimeoutMs 15000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'EACCES exit code'
        Assert-Equal -Actual $driver.Err.Trim() -Expected ("Insufficient privileges to bind {0}:{1}." -f $script:Expected.DefaultHost, $bindPort) -What 'EACCES diagnostic'
        Assert-NoRawCrash -Text $driver.Err -What 'EACCES diagnostic'
    }

    Invoke-Case -Id 'D10' -Owner 'BE-F04' -Name 'a generic server error while listening terminates with exit 1 and a diagnostic' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'server-error-while-listening' -Argument 'generic' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'generic server error exit code'
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.GenericErrorLog) -What 'D10 stderr'
        Assert-Contains -Text $driver.Err -Needle 'synthetic accept failure' -What 'generic server error diagnostic'
        Assert-NotContains -Text $driver.Err -Needle "Unhandled 'error' event" -What 'generic server error must stay handled'
        # BE-F04 requires an error on a listening server to stop acceptance and drain
        # through the guarded shutdown path instead of exiting on the spot, so the drain
        # announcement and the close-completion log are part of this case's contract.
        Assert-LogSequence -Logs $driver.Logs -What 'D10 stdout' -Expected @(
            (Get-StartupLog -BindHost $script:Expected.DefaultHost -BindPort $bindPort),
            'server error received: closing server gracefully...',
            $script:Expected.ClosedLog
        )
        Assert-Between -Actual $driver.Ms -Min 0 -Max 15000 -What 'generic server error must terminate promptly'
    }

    Invoke-Case -Id 'D11' -Owner 'BE-F01' -Name 'an uncaught exception drains the server and exits non-zero' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'fatal-uncaught' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.UncaughtLog) -What 'D11 stderr'
        Assert-Contains -Text $driver.Err -Needle 'synthetic uncaught exception' -What 'uncaught exception diagnostic'
        Assert-FatalShutdownLogs -Driver $driver -BindPort $bindPort -What 'D11 stdout'
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'a crash must not be reported to the supervisor as a clean stop'
    }

    Invoke-Case -Id 'D12' -Owner 'BE-F01' -Name 'an unhandled rejection drains the server and exits non-zero' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'fatal-rejection' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.RejectionLog) -What 'D12 stderr'
        Assert-Contains -Text $driver.Err -Needle 'synthetic unhandled rejection' -What 'unhandled rejection diagnostic'
        Assert-FatalShutdownLogs -Driver $driver -BindPort $bindPort -What 'D12 stdout'
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'a rejection crash must not be reported as a clean stop'
    }

    Invoke-Case -Id 'D13' -Owner 'BE-F02' -Name 'a fatal event during signal shutdown keeps one sequence and escalates the exit code' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'fatal-during-shutdown' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-OccurrenceCount -Text $driver.Out -Needle 'closing server gracefully' -Expected 1 -What 'the duplicate-shutdown guard must keep a single sequence'
        Assert-FatalShutdownLogs -Driver $driver -BindPort $bindPort -What 'D13 stdout'
        Assert-DiagnosticSequence -Text $driver.Err -ExpectedPrefixes @($script:Expected.UncaughtLog) -What 'D13 stderr'
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'a fatal event during shutdown must escalate the pending exit status'
    }

    # ==================================================================================
    # Group E - shutdown, resource cleanup, timer and reentrancy (review finding F04)
    # ==================================================================================
    Invoke-Case -Id 'E01' -Owner 'AAP' -Name 'SIGTERM closes gracefully with the exact log pair and exit 0 (handler-level)' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'signal' -Argument 'SIGTERM' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'SIGTERM exit code'
        $logs = @($driver.Logs)
        Assert-Equal -Actual $logs.Count -Expected 3 -What ("SIGTERM stdout line count (actual: {0})" -f (Show-Text ($logs -join ' | ')))
        Assert-Equal -Actual $logs[0] -Expected (Get-StartupLog -BindHost $script:Expected.DefaultHost -BindPort $bindPort) -What 'startup log'
        Assert-Equal -Actual $logs[1] -Expected 'SIGTERM received: closing server gracefully...' -What 'shutdown log'
        Assert-Equal -Actual $logs[2] -Expected $script:Expected.ClosedLog -What 'close-completion log'
        Assert-Equal -Actual $driver.Err.Trim() -Expected '' -What 'a graceful shutdown must produce no stderr'
        Assert-Between -Actual $driver.Ms -Min 0 -Max 6000 -What 'the unref-ed forced-exit timer must not delay a clean drain'
    }

    Invoke-Case -Id 'E02' -Owner 'AAP' -Name 'SIGINT closes gracefully with the exact log pair and exit 0 (handler-level)' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'signal' -Argument 'SIGINT' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'SIGINT exit code'
        $logs = @($driver.Logs)
        Assert-Equal -Actual $logs.Count -Expected 3 -What ("SIGINT stdout line count (actual: {0})" -f (Show-Text ($logs -join ' | ')))
        Assert-Equal -Actual $logs[1] -Expected 'SIGINT received: closing server gracefully...' -What 'shutdown log'
        Assert-Equal -Actual $logs[2] -Expected $script:Expected.ClosedLog -What 'close-completion log'
        Assert-Between -Actual $driver.Ms -Min 0 -Max 6000 -What 'SIGINT drain duration'
    }

    Invoke-Case -Id 'E03' -Owner 'AAP' -Name 'a repeated signal runs the shutdown sequence exactly once (handler-level)' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'signal-twice' -Argument 'SIGTERM' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'duplicate SIGTERM exit code'
        Assert-OccurrenceCount -Text $driver.Out -Needle 'SIGTERM received: closing server gracefully...' -Expected 1 -What 'shutdown announcements'
        Assert-OccurrenceCount -Text $driver.Out -Needle $script:Expected.ClosedLog -Expected 1 -What 'close-completion announcements'
        Assert-Equal -Actual (@($driver.Logs)).Count -Expected 3 -What 'duplicate SIGTERM stdout line count'
    }

    Invoke-Case -Id 'E04' -Owner 'AAP' -Name 'a failing server.close reports the error and exits 1' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'close-error' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'close-error exit code'
        Assert-Contains -Text $driver.Err -Needle $script:Expected.CloseErrorLog -What 'close-error diagnostic'
        Assert-OccurrenceCount -Text $driver.Out -Needle $script:Expected.ClosedLog -Expected 0 -What 'a failed close must not report a successful one'
    }

    Invoke-Case -Id 'E05' -Owner 'AAP' -Name 'idle keep-alive sockets are released by the module so the drain completes at once' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'idle-socket-shutdown' -TimeoutMs 20000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'idle-socket shutdown exit code'
        Assert-Contains -Text $driver.Out -Needle 'idle keep-alive socket established' -What 'the case must actually have held an idle socket'
        Assert-Equal -Actual (Get-Prop -Object $driver.Result -Name 'moduleIdleCalls') -Expected 1 -What 'server.js must release idle connections itself exactly once'
        Assert-Equal -Actual (@($driver.Logs))[2] -Expected $script:Expected.ClosedLog -What 'close-completion log'
        Assert-Between -Actual $driver.Ms -Min 0 -Max 6000 -What 'an idle keep-alive socket must not delay the drain'
    }

    Invoke-Case -Id 'E06' -Owner 'AAP' -Name 'a hung active connection reaches the forced-exit timer, is destroyed, and exits 1' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'hung-socket-shutdown' -TimeoutMs 40000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'forced shutdown exit code'
        Assert-Contains -Text $driver.Err -Needle $script:Expected.ForcedLog -What 'forced shutdown diagnostic'
        Assert-Equal -Actual (Get-Prop -Object $driver.Result -Name 'moduleAllCalls') -Expected 1 -What 'server.js must destroy the remaining connections itself'
        Assert-OccurrenceCount -Text $driver.Out -Needle $script:Expected.ClosedLog -Expected 0 -What 'a forced shutdown must not report a graceful close'
        Assert-Between -Actual $driver.Ms -Min ($script:Expected.ShutdownTimeoutMs - 2000) -Max ($script:Expected.ShutdownTimeoutMs + 10000) `
            -What 'the forced exit must happen at the configured shutdown timeout'
    }

    Invoke-Case -Id 'E07' -Owner 'AAP' -Name 'shutdown still completes cleanly when closeIdleConnections is unavailable' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'absent-idle-api' -TimeoutMs 25000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 0 -What 'exit code without closeIdleConnections'
        Assert-NotContains -Text $driver.Err -Needle 'TypeError' -What 'the optional-API guard must prevent a TypeError'
        Assert-Equal -Actual (Get-Prop -Object $driver.Result -Name 'moduleIdleCalls') -Expected 0 -What 'the module must skip the unavailable API'
        Assert-Equal -Actual (@($driver.Logs))[2] -Expected $script:Expected.ClosedLog -What 'close-completion log'
        Assert-Between -Actual $driver.Ms -Min 0 -Max 6000 -What 'drain duration without closeIdleConnections'
    }

    Invoke-Case -Id 'E08' -Owner 'AAP' -Name 'the forced-exit path survives closeAllConnections being unavailable' -Body {
        $bindPort = Get-FreePort
        $driver = Invoke-Driver -Mode 'absent-all-api' -TimeoutMs 40000 `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        Assert-Equal -Actual $driver.ExitCode -Expected 1 -What 'forced exit code without closeAllConnections'
        Assert-Contains -Text $driver.Err -Needle $script:Expected.ForcedLog -What 'forced shutdown diagnostic'
        Assert-NotContains -Text $driver.Err -Needle 'TypeError' -What 'the optional-API guard must prevent a TypeError'
        Assert-Equal -Actual (Get-Prop -Object $driver.Result -Name 'moduleAllCalls') -Expected 0 -What 'the module must skip the unavailable API'
        Assert-Between -Actual $driver.Ms -Min ($script:Expected.ShutdownTimeoutMs - 2000) -Max ($script:Expected.ShutdownTimeoutMs + 10000) -What 'forced exit timing'
    }

    # ==================================================================================
    # Group F - configuration and timeout policy (review finding F05)
    # ==================================================================================
    Invoke-Case -Id 'F01' -Owner 'AAP' -Name 'the server object server.js creates carries the three explicit HTTP timeouts' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000
        $result = $driver.Result
        Assert-True -Condition ($null -ne $result) -What 'F01: driver must report a result payload'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'requestTimeout') -Expected $script:Expected.RequestTimeoutMs -What 'server.requestTimeout'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'headersTimeout') -Expected $script:Expected.HeadersTimeoutMs -What 'server.headersTimeout'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'keepAliveTimeout') -Expected $script:Expected.KeepAliveTimeout -What 'server.keepAliveTimeout'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'errorListeners') -Expected 1 -What 'server error listeners'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'sigtermListeners') -Expected 1 -What 'SIGTERM listeners'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'sigintListeners') -Expected 1 -What 'SIGINT listeners'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'uncaughtListeners') -Expected 1 -What 'uncaughtException listeners'
        Assert-Equal -Actual (Get-Prop -Object $result -Name 'rejectionListeners') -Expected 1 -What 'unhandledRejection listeners'
    }

    Invoke-Case -Id 'F02' -Owner 'PERF-F01' -Name 'a finite general socket inactivity timeout is configured' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000
        $socketTimeout = Get-Prop -Object $driver.Result -Name 'socketTimeout'
        Assert-True -Condition ($null -ne $socketTimeout) -What 'server.timeout must be readable'
        Assert-Between -Actual ([long]$socketTimeout) -Min 1 -Max 600000 `
            -What 'server.timeout must be a finite, positive per-socket inactivity ceiling (0 disables it entirely)'
    }

    Invoke-Case -Id 'F03' -Owner 'AAP' -Name 'with no environment override the bind defaults to 127.0.0.1:3000' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000
        $outcome = Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort) `
            -AllowedHosts @($script:Expected.DefaultHost) -What 'default configuration'
        Assert-Equal -Actual $outcome -Expected 'accepted' -What 'the documented defaults must be accepted'
    }

    Invoke-Case -Id 'F04' -Owner 'AAP' -Name 'HOST and PORT overrides are honoured end to end' -Body {
        $bindPort = Get-FreePort
        $child = Start-NodeChild -NodeArgs @('server.js') -Label 'override' `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        [void](Wait-ForChildOutput -Child $child -Pattern 'Server running at' -TimeoutMs 15000)
        $logs = @(Get-PlainLogLines -Text (Get-ChildOut -Child $child))
        Assert-Equal -Actual $logs.Count -Expected 1 -What 'override startup line count'
        Assert-Equal -Actual $logs[0] -Expected (Get-StartupLog -BindHost $script:Expected.DefaultHost -BindPort $bindPort) -What 'override startup log'
        $response = Invoke-HttpExchange -TargetPort $bindPort -RequestText (New-Request -TargetPort $bindPort) -ExpectServerClose
        Assert-Equal -Actual $response.StatusCode -Expected 200 -What 'overridden bind must serve GET /'
        Assert-BytesEqual -Actual $response.BodyBytes -Expected $script:Expected.GreetingBytes -What 'overridden bind body bytes'
    }

    Invoke-Case -Id 'F05' -Owner 'CFG-F01' -Name 'a padded but valid PORT is trimmed, never silently replaced by the default' -Body {
        $candidate = Get-FreePort
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ PORT = "  $candidate  "; HOST = $script:Expected.DefaultHost }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($candidate) -AllowedHosts @($script:Expected.DefaultHost) -What 'padded PORT')
    }

    Invoke-Case -Id 'F06' -Owner 'CFG-F01' -Name 'a blank PORT is rejected or falls back to the documented default, never to something else' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ PORT = '   '; HOST = $script:Expected.DefaultHost }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort) -AllowedHosts @($script:Expected.DefaultHost) -What 'blank PORT')
    }

    Invoke-Case -Id 'F07' -Owner 'CFG-F01' -Name 'a non-numeric PORT is rejected or falls back to the documented default' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ PORT = 'not-a-port'; HOST = $script:Expected.DefaultHost }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort) -AllowedHosts @($script:Expected.DefaultHost) -What 'non-numeric PORT')
    }

    Invoke-Case -Id 'F08' -Owner 'CFG-F01' -Name 'PORT=0 follows a decided policy: rejected, defaulted, or an explicit ephemeral bind' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ PORT = '0'; HOST = $script:Expected.DefaultHost }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort, 0) -AllowedHosts @($script:Expected.DefaultHost) -What 'PORT=0')
    }

    $invalidPorts = @(
        @{ Id = 'F09'; Value = '70000'; Label = 'an out-of-range' },
        @{ Id = 'F10'; Value = '-1'; Label = 'a negative' },
        @{ Id = 'F11'; Value = '1.5'; Label = 'a fractional' }
    )
    foreach ($entry in $invalidPorts) {
        $value = [string]$entry.Value
        $label = [string]$entry.Label
        Invoke-Case -Id ([string]$entry.Id) -Owner 'CFG-F01' -Name ("{0} PORT fails startup cleanly instead of crashing inside listen()" -f $label) -Body {
            $child = Start-NodeChild -NodeArgs @('server.js') -Label ('bad-port-' + $label) `
                -EnvVars @{ PORT = $value; HOST = $script:Expected.DefaultHost }
            $exit = Wait-ChildExit -Child $child -TimeoutMs 20000
            Assert-True -Condition ($exit.ExitCode -ne 0) -What ("a {0} PORT must fail startup" -f $label)
            Assert-Equal -Actual (@(Get-PlainLogLines -Text $exit.Out)).Count -Expected 0 -What 'a rejected configuration must not report a running server'
            Assert-True -Condition ($exit.Err.Trim().Length -gt 0) -What 'the failure must be explained on stderr'
            Assert-NoRawCrash -Text $exit.Err -What ("{0} PORT diagnostic" -f $label)
        }
    }

    Invoke-Case -Id 'F12' -Owner 'CFG-F02' -Name 'a blank HOST is rejected or normalised, never forwarded raw to listen()' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ HOST = '   ' }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort) -AllowedHosts @($script:Expected.DefaultHost) -What 'blank HOST')
    }

    Invoke-Case -Id 'F13' -Owner 'CFG-F02' -Name 'a padded HOST is trimmed before it reaches listen() and the log' -Body {
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ HOST = '  127.0.0.1  ' }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort) -AllowedHosts @($script:Expected.DefaultHost) -What 'padded HOST')
    }

    Invoke-Case -Id 'F14' -Owner 'CFG-F02' -Name 'a HOST carrying a control character never reaches listen() or a log line' -Body {
        $controlHost = '127.0.0.1' + [char]1 + 'x'
        $driver = Invoke-Driver -Mode 'config-capture' -TimeoutMs 15000 -EnvVars @{ HOST = $controlHost }
        [void](Assert-ConfigOutcome -Driver $driver -AllowedPorts @($script:Expected.DefaultPort) -AllowedHosts @($script:Expected.DefaultHost) -What 'HOST with a control character')
        Assert-NotMatch -Text ($driver.Out + $driver.Err) -Pattern '[\x00-\x08\x0B\x0C\x0E-\x1F]' -What 'diagnostics must not carry raw control characters'
    }

    Invoke-Case -Id 'F15' -Owner 'CFG-F02' -Name 'a syntactically invalid HOST fails startup cleanly, without a resolver stack' -Body {
        $bindPort = Get-FreePort
        $child = Start-NodeChild -NodeArgs @('server.js') -Label 'bad-host' `
            -EnvVars @{ PORT = "$bindPort"; HOST = 'not a host' }
        $exit = Wait-ChildExit -Child $child -TimeoutMs 25000
        Assert-True -Condition ($exit.ExitCode -ne 0) -What 'an invalid HOST must fail startup'
        Assert-Equal -Actual (@(Get-PlainLogLines -Text $exit.Out)).Count -Expected 0 -What 'a rejected configuration must not report a running server'
        Assert-True -Condition ($exit.Err.Trim().Length -gt 0) -What 'the failure must be explained on stderr'
        Assert-NoRawCrash -Text $exit.Err -What 'invalid HOST diagnostic'
    }

    Invoke-Case -Id 'F16' -Owner 'AAP' -Name 'an idle keep-alive socket is closed by the server within the keep-alive ceiling' -Body {
        $bindPort = Get-FreePort
        $child = Start-NodeChild -NodeArgs @('server.js') -Label 'keepalive' `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        [void](Wait-ForChildOutput -Child $child -Pattern 'Server running at' -TimeoutMs 15000)
        $cap = $script:Expected.KeepAliveTimeout + 7000
        $response = Invoke-HttpExchange -TargetPort $bindPort -RequestText (New-Request -TargetPort $bindPort -KeepAlive) -ExpectServerClose -TotalMs $cap
        Assert-Equal -Actual $response.StatusCode -Expected 200 -What 'keep-alive request status'
        Assert-True -Condition $response.Closed -What ("the server must close an idle keep-alive socket within {0}ms" -f $cap)
        Assert-Between -Actual $response.Ms -Min 2000 -Max $cap -What 'idle keep-alive socket lifetime'
        Assert-ServerStillHealthy -Child $child -TargetPort $bindPort -What 'after a keep-alive idle close'
    }

    Invoke-Case -Id 'F17' -Owner 'AAP' -Name 'a slow-header client is bounded by the headers timeout and cannot hold a socket' -Body {
        $bindPort = Get-FreePort
        $child = Start-NodeChild -NodeArgs @('server.js') -Label 'slowloris' `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        [void](Wait-ForChildOutput -Child $child -Pattern 'Server running at' -TimeoutMs 15000)
        # Node enforces the header deadline on a coarse timer, so the observed drop lands
        # somewhere after headersTimeout rather than exactly on it. The bound is generous
        # on purpose: what must hold is that the socket cannot be held indefinitely.
        $cap = ($script:Expected.HeadersTimeoutMs * 2) + 5000
        $partial = New-Request -TargetPort $bindPort -NoTerminator
        $response = Invoke-HttpExchange -TargetPort $bindPort -RequestText $partial -ExpectServerClose -TotalMs $cap
        Assert-True -Condition $response.Closed -What ("the server must drop a slow-header client within {0}ms" -f $cap)
        Assert-Between -Actual $response.Ms -Min 3000 -Max $cap -What 'slow-header client lifetime'
        if ($response.StatusCode -ne 0) {
            Assert-InSet -Actual $response.StatusCode -Allowed @(408) -What 'slow-header response status'
        }
        Assert-ServerStillHealthy -Child $child -TargetPort $bindPort -What 'after a slow-header client was dropped'
    }

    Invoke-Case -Id 'F18' -Owner 'AAP' -Name 'a slow-request-body client cannot hold a socket past the configured ceilings' -Body {
        $bindPort = Get-FreePort
        $child = Start-NodeChild -NodeArgs @('server.js') -Label 'slowbody' `
            -EnvVars @{ PORT = "$bindPort"; HOST = $script:Expected.DefaultHost }
        [void](Wait-ForChildOutput -Child $child -Pattern 'Server running at' -TimeoutMs 15000)
        # A complete header block declaring a body, then only part of that body, on a
        # keep-alive connection the client never closes. The outer bound is the configured
        # request ceiling plus slack for node's coarse timer.
        #
        # Which ceiling actually fires depends on the handler: this one answers on method
        # alone without reading the body, so the response completes first and the socket is
        # then governed by the keep-alive ceiling, which is the tighter of the two. The
        # invariant asserted here is the one that matters either way - an incomplete request
        # body cannot hold a socket open indefinitely - while F01 asserts requestTimeout's
        # configured value on the server object server.js itself created.
        $cap = $script:Expected.RequestTimeoutMs + 15000
        $request = "GET / HTTP/1.1`r`nHost: 127.0.0.1:$bindPort`r`nContent-Length: 100`r`nConnection: keep-alive`r`n`r`nabc"
        $response = Invoke-HttpExchange -TargetPort $bindPort -RequestText $request -ExpectServerClose -TotalMs $cap
        Assert-True -Condition $response.Closed -What ("the server must release a stalled request-body socket within {0}ms" -f $cap)
        Assert-Between -Actual $response.Ms -Min 2000 -Max $cap -What 'stalled request-body socket lifetime'
        if ($response.StatusCode -ne 0) {
            Assert-InSet -Actual $response.StatusCode -Allowed @(200, 408) -What 'stalled request-body response status'
            if ($response.StatusCode -eq 200) {
                Assert-BytesEqual -Actual $response.BodyBytes -Expected $script:Expected.GreetingBytes -What 'stalled request-body response body'
            }
        }
        Assert-NoRawCrash -Text (Get-ChildErr -Child $child) -What 'server stderr during a stalled request body'
        Assert-ServerStillHealthy -Child $child -TargetPort $bindPort -What 'after a stalled request body'
        $established = Get-EstablishedConnectionCount -TargetPort $bindPort
        if ($established -ge 0) {
            Assert-Equal -Actual $established -Expected 0 -What 'no established connection may survive the stalled request body'
        }
    }

} catch {
    $script:HarnessError = $_.Exception.Message
    if ($_.ScriptStackTrace) { $script:HarnessError += "`n" + $_.ScriptStackTrace }
} finally {
    # Terminate only the children this run captured, then remove the harness work
    # directory this run created. Nothing outside it is ever touched.
    Stop-ChildrenAfter -Mark 0
    if (-not $script:ListMode -and -not $KeepWorkDir -and $script:WorkPath -ne '' -and (Test-Path $script:WorkPath)) {
        $leaf = Split-Path $script:WorkPath -Leaf
        if ([string]::IsNullOrWhiteSpace($WorkDir) -and $leaf.StartsWith('blitzy-verify-')) {
            Remove-Item -LiteralPath $script:WorkPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --------------------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------------------
if ($script:ListMode) {
    Write-Line ''
    Write-Line ("{0} case(s) listed." -f $script:Results.Count)
    exit 0
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' })

Write-Line ''
Write-Line '--------------------------------------------------------------------------'

# A filter that matches nothing must not be mistaken for a clean run.
if ($script:Results.Count -eq 0) {
    Write-Line ("no case matched the filter '{0}'; nothing was verified" -f $Only)
    Write-Line '--------------------------------------------------------------------------'
    exit 1
}
Write-Line ("cases run : {0}    passed: {1}    failed: {2}" -f $script:Results.Count, $passed.Count, $failed.Count)

if ($failed.Count -gt 0) {
    Write-Line ''
    Write-Line 'failures:'
    foreach ($failure in $failed) {
        Write-Line ("  {0}  [{1}]  {2}" -f $failure.Id, $failure.Owner, $failure.Name)
        foreach ($line in ($failure.Message -split "`n")) {
            if ($line.Trim() -ne '') { Write-Line ('      ' + $line.TrimEnd()) }
        }
    }
    $byOwner = @($failed | Group-Object -Property Owner | Sort-Object -Property Name)
    Write-Line ''
    Write-Line 'failures by owning finding:'
    foreach ($group in $byOwner) {
        Write-Line ("  {0,-10} {1,3}  {2}" -f $group.Name, $group.Count, (($group.Group | ForEach-Object { $_.Id }) -join ', '))
    }

    # An AAP-owned failure is a regression against the frozen contract. A failure owned by
    # another finding id is this harness detecting that finding's gap, and clears when the
    # concern that owns it is fixed.
    $contractFailures = @($failed | Where-Object { $_.Owner -eq 'AAP' })
    $delegatedFailures = @($failed | Where-Object { $_.Owner -ne 'AAP' })
    Write-Line ''
    Write-Line ("contract (AAP-owned) failures        : {0}" -f $contractFailures.Count)
    Write-Line ("failures owned by another finding    : {0}{1}" -f $delegatedFailures.Count,
        $(if ($delegatedFailures.Count -gt 0) { ' (each clears when that finding is fixed)' } else { '' }))
}

if ($script:HarnessError -ne '') {
    Write-Line ''
    Write-Line 'the harness itself could not complete:'
    foreach ($line in ($script:HarnessError -split "`n")) {
        if ($line.Trim() -ne '') { Write-Line ('  ' + $line.TrimEnd()) }
    }
    Write-Line '--------------------------------------------------------------------------'
    exit 1
}

Write-Line '--------------------------------------------------------------------------'
if ($failed.Count -gt 0) { exit 1 }
exit 0

