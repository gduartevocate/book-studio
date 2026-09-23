# Designers open Book Studio at https://ebook.vocate.app. The agent keeps the
# workers.dev address instead, because Cloudflare Access sits in front of the
# custom domain and would answer this unattended process with a login page. Once
# the Access policy bypasses /api/runner/*, both addresses work and this default
# can move.
[CmdletBinding()]
param(
    [string]$Token = "",
    [switch]$StartWithWindows,
    [switch]$StopStartingWithWindows,
    [string]$BaseUrl = "https://ebook-generator.gduarte-28e.workers.dev",
    [string]$SignInUrl = "https://ebookstudio.vocate.app/cloud/connect",
    [int]$StudioPort = 8790,
    # How often to look for a new release. It was used but never declared, so
    # it was empty and every cycle, about every 25 seconds, asked GitHub.
    # How often to ask GitHub for a new release. Fifteen minutes: a fix should
    # reach every computer the same morning, without anyone doing anything.
    [int]$UpdateCheckMinutes = 15,
    # Page helpers: copies of this agent that only carry requests between the
    # web site and Book Studio here. See Start-BridgeWorkers.
    [switch]$BridgeWorker,
    [int]$ParentProcessId = 0,
    [int]$BridgeWorkers = 3,
    [string]$EnvPath = "..\.env",
    [string]$ProjectRoot = "",
    [string]$WorkRoot = "",
    [int]$PollIntervalSeconds = 20,
    [switch]$Once,
    [string[]]$SkipCourseCode = @("TEST1000")
)

$ErrorActionPreference = "Stop"

function Import-DotEnvFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        $parts = $trimmed -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }
        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        if ($name) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Invoke-RunnerApi {
    param(
        [Parameter(Mandatory)][ValidateSet("Get", "Post")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )

    $params = @{
        Uri     = "$BaseUrl$Path"
        Method  = $Method
        Headers = @{ "x-book-runner-token" = $script:runnerToken }
    }

    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    return Invoke-RestMethod @params
}

# The whole point of running the agent on a designer's PC is that Codex is
# signed in there. The cloud cannot see that, so the agent reports it: which
# executable it found, whether a real request succeeds, and whether file
# editing is available. A designer should learn their connection is broken
# from the app, not from a book failing twenty minutes into drafting.
function Test-LocalCodexConnection {
    param([string]$ProjectRoot)

    $result = [pscustomobject]@{
        status = 'Unavailable'
        detail = ''
        commandPath = ''
        version = ''
        signedIn = $false
        checkedAt = (Get-Date).ToString('o')
    }
    try {
        . (Join-Path $ProjectRoot 'lib/EbookCodexSandbox.ps1')
        Import-Module (Join-Path $ProjectRoot 'lib/BookStudio.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $command = Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
        if (-not $command) {
            $result.detail = 'Codex CLI was not found on this computer. Install Codex and sign in, or set the executable path in Book Studio.'
            return $result
        }
        $result.commandPath = $command.Source
        $result.version = (& $command.Source --version 2>&1 | Select-Object -First 1) -as [string]
        # The connection test reports connectionStatus/connectionMessage, not
        # status/message; reading the wrong pair reported every healthy Codex
        # as unavailable with no explanation.
        # The longest the test allows: a slow first answer on a laptop is not a
        # broken Codex, and a timeout here used to be reported as one.
        $connection = Test-BookStudioCodexConnection -ProjectRoot $ProjectRoot -TimeoutSeconds 45
        # A check that timed out is not a Codex that is missing or signed out.
        # Reporting the two the same way told a designer their Codex was broken
        # when the only thing that had happened was a slow answer, and sent them
        # looking for a problem that was not there.
        $message = [string]$connection.connectionMessage
        $result.status = if ($connection.connectionStatus -eq 'PASS') { 'Connected' }
            elseif ($message -match 'timed out') { 'Unknown' }
            else { 'Unavailable' }
        $result.detail = if ($result.status -eq 'Unknown') {
            "Codex did not answer in time, so its state is unknown. Book Studio checks again every ten minutes. ($message)"
        } else { $message }
        $result.signedIn = [bool]$connection.signedIn
        if (-not $result.commandPath -and $connection.commandPath) { $result.commandPath = [string]$connection.commandPath }
        if ($connection.version) { $result.version = [string]$connection.version }
    }
    catch {
        $result.detail = "Could not check the Codex connection: $($_.Exception.Message)"
    }
    return $result
}

function Publish-CodexStatus {
    param([object]$Status)

    $machineName = "$env:COMPUTERNAME / $env:USERNAME"
    # A computer that cannot update itself must say so here rather than quietly
    # falling behind: the refusal is deliberate, but silence about it is not.
    $updatable = Test-BookStudioSelfUpdatable -ProjectRoot $ProjectRoot
    try {
        Invoke-RunnerApi -Method Post -Path '/api/runner/status' -Body @{
            codex = $Status
            runnerName = $machineName
            version = (Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot)
            updates = @{ automatic = [bool]$updatable.updatable; reason = [string]$updatable.reason }
        } | Out-Null
        # Said once, on the first success. Without it a designer has no way to
        # tell a machine that reported itself from one that quietly could not,
        # and the web page looks identical either way until they refresh it.
        if (-not $script:reportedOnce) {
            $script:reportedOnce = $true
            Write-Host "This computer is now visible in Book Studio as $machineName. Leave this window open." -ForegroundColor Green
        }
        return $true
    }
    catch {
        Write-Warning "This computer could not report itself to Book Studio, so it will show there as not running: $($_.Exception.Message)"
        return $false
    }
}

# The bridge: the designer's browser asks the cloud, the cloud asks this agent,
# and this agent asks the Book Studio running on this PC. That local server is
# the only place the outcome analysis, the production panel, the QA review and
# the Codex chat exist, and it is where they should stay: a second copy of those
# rules in the cloud would drift from this one.
function Test-LocalStudioServer {
    param([int]$Port)

    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/version.json" -TimeoutSec 4 -UseBasicParsing
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function Start-LocalStudioServer {
    param([string]$ProjectRoot, [int]$Port)

    if (Test-LocalStudioServer -Port $Port) { return $true }
    # Started without book-studio.ps1, which opens a browser window: nothing
    # should appear on a designer's screen because someone clicked in the cloud.
    $command = "Import-Module '" + (Join-Path $ProjectRoot 'lib\BookStudio.psm1') + "' -Force -DisableNameChecking; " +
               "Start-BookStudioServer -ProjectRoot '" + $ProjectRoot + "' -Port " + $Port
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-Command', $command) -WindowStyle Minimized | Out-Null
    foreach ($attempt in 1..20) {
        Start-Sleep -Milliseconds 500
        if (Test-LocalStudioServer -Port $Port) { return $true }
    }
    return $false
}

function Invoke-LocalStudioRequest {
    param([object]$BridgeRequest, [string]$ProjectRoot, [int]$Port)

    $reply = @{ id = $BridgeRequest.id; status = 502; headers = @{}; bodyBase64 = '' }
    if (-not (Start-LocalStudioServer -ProjectRoot $ProjectRoot -Port $Port)) {
        $reply.status = 503
        $reply.headers = @{ 'content-type' = 'application/json' }
        $reply.bodyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"error":"Book Studio could not be started on this computer."}'))
        return $reply
    }

    try {
        $uri = "http://localhost:$Port" + $BridgeRequest.path
        $parameters = @{
            Uri = $uri
            Method = $BridgeRequest.method
            TimeoutSec = 50
            UseBasicParsing = $true
            Headers = @{}
        }
        foreach ($name in $BridgeRequest.headers.PSObject.Properties.Name) {
            # Host and content-length describe the hop that has already ended.
            # Origin and Referer matter most here: the local Book Studio refuses
            # any change whose Origin is not its own address. That is the right
            # rule for a browser sitting on that PC, and the wrong one for a
            # request that arrived through the cloud already authenticated.
            # Forwarding the browser's Origin turned every action in Settings
            # into "Request failed: 403". The cloud's own cookie means nothing
            # on that machine either.
            if ($name -in @('Host', 'Content-Length', 'Content-Type', 'Origin', 'Referer', 'Cookie')) { continue }
            $parameters.Headers[$name] = [string]$BridgeRequest.headers.$name
        }
        if ($BridgeRequest.bodyBase64) {
            $parameters.Body = [Convert]::FromBase64String($BridgeRequest.bodyBase64)
            $contentType = $BridgeRequest.headers.'content-type'
            if (-not $contentType) { $contentType = $BridgeRequest.headers.'Content-Type' }
            if ($contentType) { $parameters.ContentType = [string]$contentType }
        }
        $response = Invoke-WebRequest @parameters
        $reply.status = [int]$response.StatusCode
        foreach ($name in $response.Headers.Keys) {
            if ($name -in @('Transfer-Encoding', 'Content-Encoding', 'Content-Length', 'Connection')) { continue }
            $reply.headers[$name] = [string]$response.Headers[$name]
        }
        $bytes = if ($response.RawContentStream) { $response.RawContentStream.ToArray() } else { [byte[]]@() }
        $reply.bodyBase64 = [Convert]::ToBase64String($bytes)
    }
    catch {
        # An error page from the local server is an answer, not a failure of the
        # bridge, and the designer has to see it rather than a blank tab.
        $webResponse = $_.Exception.Response
        if ($webResponse) {
            $reply.status = [int]$webResponse.StatusCode
            # PowerShell has already read the response body into ErrorDetails by
            # the time this runs, so the stream is at its end and reading it
            # again returns nothing. That is why a refusal such as "this book is
            # still generating" reached the designer as a bare "Request failed:
            # 400" with nothing to act on.
            $text = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $text = [string]$_.ErrorDetails.Message
            }
            else {
                try {
                    $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
                    $text = $reader.ReadToEnd()
                    $reader.Dispose()
                }
                catch { }
            }
            $reply.headers = @{ 'content-type' = [string]$webResponse.ContentType }
            $reply.bodyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        }
        else {
            $reply.headers = @{ 'content-type' = 'application/json' }
            $message = ($_.Exception.Message -replace '"', "'")
            $reply.bodyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                '{"error":"Book Studio on this computer could not answer: ' + $message + '"}'))
        }
    }
    return $reply
}

function Invoke-BridgeCycle {
    param([string]$ProjectRoot, [int]$Port)

    # The cloud holds this request open until a designer clicks something, so
    # this is both how work arrives and how the agent waits between polls.
    try {
        $waiting = Invoke-RunnerApi -Method Get -Path '/api/bridge/next'
    }
    catch {
        Start-Sleep -Seconds 5
        return $false
    }
    if (-not $waiting -or $waiting.idle) { return $false }

    $reply = Invoke-LocalStudioRequest -BridgeRequest $waiting -ProjectRoot $ProjectRoot -Port $Port
    try {
        Invoke-RunnerApi -Method Post -Path '/api/bridge/reply' -Body $reply | Out-Null
    }
    catch {
        Write-Warning "Could not return an answer to the cloud: $($_.Exception.Message)"
    }
    return $true
}

function Add-CloudJobLog {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        Invoke-RunnerApi -Method Post -Path "/api/runner/jobs/$JobId/log" -Body @{ message = $Message } | Out-Null
    }
    catch {
        Write-Warning "Could not write cloud log for ${JobId}: $($_.Exception.Message)"
    }
}

function Get-ContentType {
    param([Parameter(Mandatory)][string]$Path)

    switch -Regex ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        "\.html?$" { return "text/html; charset=utf-8" }
        "\.md$" { return "text/markdown; charset=utf-8" }
        "\.json$" { return "application/json; charset=utf-8" }
        "\.docx$" { return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }
        "\.svg$" { return "image/svg+xml; charset=utf-8" }
        "\.png$" { return "image/png" }
        default { return "application/octet-stream" }
    }
}

function Get-ArtifactSpecs {
    return @(
        @{ name = "E-book planning packet"; pattern = "* - E-Book Planning Packet.docx" },
        @{ name = "E-book outline"; pattern = "* - E-Book Outline.docx" },
        @{ name = "E-book planning packet Markdown"; fileName = "ebook-planning-packet.md" },
        @{ name = "E-book outline Markdown"; fileName = "ebook-outline.md" },
        @{ name = "Word document"; pattern = "* - E-Book.docx" },
        @{ name = "HTML ebook"; pattern = "* - E-Book.html" },
        @{ name = "Markdown ebook"; pattern = "* - E-Book.md" },
        @{ name = "Interactive study"; fileName = "interactive-study.html" },
        @{ name = "Quality report"; fileName = "quality-report.md" },
        @{ name = "Agent report"; fileName = "agent-report.md" },
        @{ name = "Publishing editor report"; fileName = "publishing-editor-report.md" },
        @{ name = "Export validation report"; fileName = "export-validation.md" },
        @{ name = "Output audit report"; fileName = "ebook-output-audit.md" },
        @{ name = "Academic source registry"; fileName = "sources.md" }
    )
}

function Save-CloudJobFiles {
    param(
        [Parameter(Mandatory)][object]$JobFiles,
        [Parameter(Mandatory)][string]$UploadFolder,
        [AllowNull()][string]$SpecialInstructions
    )

    New-Item -ItemType Directory -Path $UploadFolder -Force | Out-Null
    $saved = New-Object System.Collections.ArrayList
    foreach ($file in @($JobFiles.files)) {
        $safeName = ([string]$file.name) -replace '[<>:"/\\|?*]', "-"
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            $safeName = "uploaded-source.txt"
        }
        $targetPath = Join-Path $UploadFolder $safeName
        [System.IO.File]::WriteAllBytes($targetPath, [Convert]::FromBase64String([string]$file.contentBase64))
        [void]$saved.Add([pscustomobject]@{
            name = $safeName
            path = (Resolve-Path $targetPath).ProviderPath
            role = $file.role
        })
    }

    if ($SpecialInstructions) {
        $briefPath = Join-Path $UploadFolder "book-studio-brief.txt"
        Set-Content -LiteralPath $briefPath -Value $SpecialInstructions -Encoding UTF8
        [void]$saved.Add([pscustomobject]@{
            name = "book-studio-brief.txt"
            path = (Resolve-Path $briefPath).ProviderPath
            role = "brief"
        })
    }

    return @($saved)
}

function Upload-CloudArtifact {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )

    $file = Get-Item -LiteralPath $Path
    $payload = @{
        name = $Name
        fileName = $file.Name
        contentType = Get-ContentType -Path $file.FullName
        size = $file.Length
        contentBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    }

    Invoke-RunnerApi -Method Post -Path "/api/runner/jobs/$JobId/artifacts" -Body $payload | Out-Null
}

function Complete-CloudJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$OutputFolder
    )

    Invoke-RunnerApi -Method Post -Path "/api/runner/jobs/$JobId/complete" -Body @{ outputSummary = $OutputFolder } | Out-Null
}

function Fail-CloudJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Message
    )

    Invoke-RunnerApi -Method Post -Path "/api/runner/jobs/$JobId/fail" -Body @{ error = $Message } | Out-Null
}

function Cancel-CloudJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Reason
    )

    Invoke-RunnerApi -Method Post -Path "/api/runner/jobs/$JobId/cancel" -Body @{ reason = $Reason } | Out-Null
}

function Invoke-CloudBookJob {
    param([Parameter(Mandatory)][object]$Job)

    if ($SkipCourseCode -contains $Job.courseCode) {
        Write-Host "Canceling skipped test job $($Job.id) ($($Job.courseCode))."
        Cancel-CloudJob -JobId $Job.id -Reason "Canceled local smoke-test job; not a production book request."
        return
    }

    Write-Host "Claiming job $($Job.id): $($Job.courseCode) $($Job.title)"
    $runnerName = "$env:COMPUTERNAME / $env:USERNAME"
    Invoke-RunnerApi -Method Post -Path "/api/runner/jobs/$($Job.id)/claim" -Body @{ runnerName = $runnerName } | Out-Null

    $jobRoot = Join-Path $script:workRootPath $Job.id
    $uploadFolder = Join-Path $jobRoot "uploads"
    $outputRoot = Join-Path $jobRoot "outputs"
    $logPath = Join-Path $jobRoot "runner-output.log"
    New-Item -ItemType Directory -Path $jobRoot, $outputRoot -Force | Out-Null

    try {
        Add-CloudJobLog -JobId $Job.id -Message "Downloading source files to local runner."
        $jobFiles = Invoke-RunnerApi -Method Get -Path "/api/runner/jobs/$($Job.id)/files"
        $savedFiles = Save-CloudJobFiles -JobFiles $jobFiles -UploadFolder $uploadFolder -SpecialInstructions $Job.specialInstructions
        $specFile = @($savedFiles | Where-Object { $_.role -eq "spec" } | Select-Object -First 1)[0]
        if (-not $specFile) {
            throw "No spec/source file was available for this job."
        }

        $generatorPath = Join-Path $ProjectRoot "ebook-generator.ps1"
        if (-not (Test-Path -LiteralPath $generatorPath)) {
            throw "Generator script not found: $generatorPath"
        }

        # The cloud holds the book's settings; the generator is the same one the
        # local app runs, so every setting a designer chose has to be carried
        # across or the cloud quietly produces a differently configured book.
        $generatorParams = @{
            SpecPath = $specFile.path
            SourceContextPath = (Resolve-Path $uploadFolder).ProviderPath
            OutputDir = (Resolve-Path $outputRoot).ProviderPath
            MaxResearchPerChapter = $(if ($Job.options.maxResearchPerChapter) { [int]$Job.options.maxResearchPerChapter } else { 3 })
            MaxSourceContextFiles = 52
            SourceMode = $(if ($Job.options.sourceMode) { [string]$Job.options.sourceMode } else { 'UploadedOnly' })
        }
        if ([bool]$Job.options.skipResearch) { $generatorParams.SkipResearch = $true }
        if ([bool]$Job.options.skipOpenStaxFetch) { $generatorParams.SkipOpenStaxFetch = $true }
        $generatorParams.UseCodexDrafting = $(if ($null -eq $Job.options.useCodexDrafting -or [bool]$Job.options.useCodexDrafting) { 1 } else { 0 })
        $generatorParams.UseCodexImages = $(if ($null -eq $Job.options.useCodexImages -or [bool]$Job.options.useCodexImages) { 1 } else { 0 })
        if ($script:codexCommandPath) { $generatorParams.CodexCommandPath = $script:codexCommandPath }

        # Reading level, required readings and the image setting travel in the
        # production file the generator already reads, so they reach it the same
        # way they do locally rather than through a second mechanism.
        $production = [pscustomobject]@{
            sourceMode = $generatorParams.SourceMode
            readingLevel = $(if ($Job.options.readingLevel) { [int]$Job.options.readingLevel } else { 8 })
            allowAdditionalResearch = [bool]$Job.options.allowAdditionalResearch
            requiredReadings = @($Job.options.requiredReadings | Where-Object { $_ })
            imageSettings = $(if ($Job.options.imageSettings) { $Job.options.imageSettings } else { [pscustomobject]@{ context = 'Generic'; instructions = '' } })
        }
        $production | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $uploadFolder 'book-studio-production.json') -Encoding UTF8
        Add-CloudJobLog -JobId $Job.id -Message "Reading level grade $($production.readingLevel); sources: $($production.sourceMode); $(@($production.requiredReadings).Count) required reading(s)."


        Add-CloudJobLog -JobId $Job.id -Message "Running ebook generator on local workstation."
        $global:LASTEXITCODE = 0
        $output = & $generatorPath @generatorParams *>&1
        $output | Set-Content -LiteralPath $logPath -Encoding UTF8
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Generator exited with code $LASTEXITCODE. See local log: $logPath"
        }

        $outputFolder = @(
            Get-ChildItem -LiteralPath $outputRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        )[0]
        if (-not $outputFolder) {
            throw "Generator completed, but no output folder was found."
        }

        Add-CloudJobLog -JobId $Job.id -Message "Uploading finished artifacts to Cloudflare."
        foreach ($artifactSpec in Get-ArtifactSpecs) {
            $artifactPath = $null
            if ($artifactSpec.pattern) {
                $matchedFile = @(
                    Get-ChildItem -LiteralPath $outputFolder.FullName -File -Filter $artifactSpec.pattern -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 1
                )[0]
                if ($matchedFile) {
                    $artifactPath = $matchedFile.FullName
                }
            }
            else {
                $artifactPath = Join-Path $outputFolder.FullName $artifactSpec.fileName
            }
            if ($artifactPath -and (Test-Path -LiteralPath $artifactPath)) {
                Upload-CloudArtifact -JobId $Job.id -Name $artifactSpec.name -Path $artifactPath
            }
        }

        Complete-CloudJob -JobId $Job.id -OutputFolder $outputFolder.FullName
        Write-Host "Completed job $($Job.id)."
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning "Job $($Job.id) failed: $message"
        Fail-CloudJob -JobId $Job.id -Message $message
    }
}

Import-DotEnvFile -Path $EnvPath

# Resolved before anything else uses it. $PSScriptRoot is empty both while
# parameter defaults are evaluated and when this script is run as a command
# rather than as a file -- which is how a computer whose execution policy
# forbids running .ps1 files has to run it, and designers cannot change that
# policy. The folder is worked out once, here, and everything else uses it.
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
        else { (Get-Location).Path }
}
$ProjectRoot = (Resolve-Path $ProjectRoot).ProviderPath
. (Join-Path $ProjectRoot 'lib/EbookCloudRunner.ps1')

if ($StopStartingWithWindows) {
    $removed = Uninstall-BookRunnerStartup
    Write-Host "This computer will no longer connect to Book Studio on its own. Removed: $removed"
    return
}

# Pasted once, remembered afterwards. A designer types the command from the
# connect page a single time; every start after that finds the token here.
$resolved = Resolve-BookRunnerToken -Token $Token -EnvironmentToken $env:BOOK_RUNNER_TOKEN
$script:runnerToken = $resolved.token
if (-not $script:runnerToken) {
    # The address a designer signs in at, not the one this agent dials. They
    # are different on purpose, and pointing someone at the machine-facing one
    # sends them to a page they have no account on.
    throw "No runner token. Sign in at $SignInUrl, create a token for this computer, and run the one command it shows you."
}
if ($Token) {
    $savedTo = Save-BookRunnerToken -Token $Token
    Write-Host "Token saved for this computer. You will not have to paste it again ($savedTo)."
}

# A page helper carries requests between the web site and Book Studio on this
# computer and does nothing else. The agent used to do it between its other
# work -- polling for jobs, reporting, checking for updates, and every ten
# minutes a Codex test of up to 45 seconds -- so every page waited behind all
# of that, one request at a time, and a designer's page hung and then said
# "Book Studio on your computer did not answer in time". Several helpers wait
# side by side, and each stops when the agent that started it does.
if ($BridgeWorker) {
    while (-not $ParentProcessId -or (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
        $null = Invoke-BridgeCycle -ProjectRoot $ProjectRoot -Port $StudioPort
    }
    return
}

# One agent per computer. A second one polls the same queue and reports the
# same machine over the first, and the designer who started it twice cannot
# tell. -Once is exempt: it is a check, not a second agent.
if (-not $Once) {
    # Given a token, this is the setup command being run on purpose: replace
    # whatever agent is running. Started at sign-in, defer to it.
    $instance = Enter-BookRunnerSingleInstance -TakeOver:([bool]$Token)
    if ($instance.replaced.Count) {
        Write-Host "Replaced the Book Studio agent that was already running here (process $($instance.replaced -join ', '))." -ForegroundColor Green
    }
    if (-not $instance.acquired) {
        if ($Token) {
            Write-Warning "Another Book Studio window on this computer would not close. Close every PowerShell window titled Book Studio, then run the setup command again."
            # Kept open: setup tells the designer to look in this window.
            try { Read-Host 'Press Enter to close this window' | Out-Null } catch { }
        }
        else {
            Write-Host "Book Studio is already running on this computer, so this window has nothing to do."
            Write-Host "Its connection is unaffected. Close this window."
        }
        return
    }
}

if ($StartWithWindows) {
    $link = Install-BookRunnerStartup -ScriptPath (Join-Path $ProjectRoot 'cloud-book-runner.ps1')
    Write-Host "This computer will connect to Book Studio whenever you sign in to Windows ($link)."
    Write-Host "To stop that later: .\cloud-book-runner.ps1 -StopStartingWithWindows"
}
if (-not [System.IO.Path]::IsPathRooted($WorkRoot)) {
    if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
        $WorkRoot = Join-Path $env:LOCALAPPDATA "EbookGenerator\BookRunner"
    }
    else {
        $WorkRoot = Join-Path $ProjectRoot $WorkRoot
    }
}
$script:workRootPath = $WorkRoot
New-Item -ItemType Directory -Path $script:workRootPath -Force | Out-Null

Write-Host "Cloud Book Runner connected to $BaseUrl"
Write-Host "Local work root: $script:workRootPath"
Write-Host "Press Ctrl+C to stop."
if (-not (Test-BookRunnerStartupInstalled)) {
    # Said once, where the person who has to act on it is looking. A machine
    # whose agent is not running reads as disconnected in the browser, with
    # nothing on that screen to explain why.
    Write-Host "Tip: run  .\cloud-book-runner.ps1 -StartWithWindows  once, and this computer connects on its own from then on."
}

# Checked once at startup so the executable is known before the first book,
# and re-checked while idle so a sign-in that lapses is noticed before a
# designer waits twenty minutes to find out.
$script:codexStatus = Test-LocalCodexConnection -ProjectRoot $ProjectRoot
$script:codexCommandPath = $script:codexStatus.commandPath
$script:codexCheckedAt = Get-Date
Write-Host "Codex: $($script:codexStatus.status). $($script:codexStatus.detail)"
Publish-CodexStatus -Status $script:codexStatus | Out-Null

# A designer should never have to paste a command again to get a fix. The check
# happens at start and then hourly; when there is something new, the agent
# restarts into it.
function Invoke-BookRunnerSelfUpdate {
    param([string]$ProjectRoot, [object]$Instance)

    $result = Update-BookStudioInstall -ProjectRoot $ProjectRoot
    $script:lastUpdateCheck = Get-Date
    if (-not $result.updated) { return $false }
    Write-Host "Book Studio updated itself from $($result.from) to $($result.to). Restarting." -ForegroundColor Green
    Restart-BookRunner -ProjectRoot $ProjectRoot -Instance $Instance
    return $true
}

function Sync-LocalStudioServer {
    $server = Update-StaleLocalStudioServer -ProjectRoot $ProjectRoot -Port $StudioPort
    switch ($server.status) {
        'restarted' {
            Write-Host "The Book Studio server here was running $($server.served); restarting it on $($server.installed)." -ForegroundColor Green
            Start-LocalStudioServer -ProjectRoot $ProjectRoot -Port $StudioPort | Out-Null
        }
        'busy' { Write-Host "The Book Studio server here runs $($server.served), not $($server.installed). It restarts once nothing is being written: $($server.detail)" }
        'not-found' { Write-Warning "The Book Studio server here runs $($server.served), not $($server.installed). $($server.detail)" }
    }
}

function Start-BridgeWorkers {
    param([object[]]$Running = @())

    $alive = @($Running | Where-Object { $_ -and -not $_.HasExited })
    $agent = Join-Path $ProjectRoot 'cloud-book-runner.ps1'
    while ($alive.Count -lt $BridgeWorkers) {
        # Read and run as a command, like every start of the agent, because a
        # managed PC refuses to run a .ps1 file.
        $inner = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '" + $agent.Replace("'", "''") + "'))) -BridgeWorker -ParentProcessId $PID" +
                 " -ProjectRoot '" + $ProjectRoot.Replace("'", "''") + "' -BaseUrl '" + $BaseUrl.Replace("'", "''") + "' -StudioPort $StudioPort"
        $alive += Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', $inner) -WindowStyle Hidden -PassThru
    }
    return $alive
}

$script:lastUpdateCheck = [datetime]::MinValue
# The release this agent's code is. Compared with the files on disk every
# cycle, so any update -- downloaded here or installed from Book Studio's
# Settings -- is running within one cycle.
$script:agentVersion = Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot
if (-not $Once) {
    if (Invoke-BookRunnerSelfUpdate -ProjectRoot $ProjectRoot -Instance $instance) { return }
    Sync-LocalStudioServer
    $script:bridgeWorkerProcesses = @(Start-BridgeWorkers)
}

do {
    try {
        # Every eight minutes: a passing test counts for ten, so Book Studio
        # always finds a recent one and never has to stop a designer's
        # request to test Codex itself.
        if (((Get-Date) - $script:codexCheckedAt).TotalMinutes -ge 8) {
            $script:codexStatus = Test-LocalCodexConnection -ProjectRoot $ProjectRoot
            $script:codexCommandPath = $script:codexStatus.commandPath
            $script:codexCheckedAt = Get-Date
        }
        Publish-CodexStatus -Status $script:codexStatus | Out-Null
        $queue = Invoke-RunnerApi -Method Get -Path "/api/runner/jobs"
        $jobs = @($queue.jobs)
        if ($jobs.Count -eq 0) {
            Write-Host "No queued jobs."
        }
        foreach ($job in $jobs) {
            Invoke-CloudBookJob -Job $job
        }
    }
    catch {
        Write-Warning "Runner poll failed: $($_.Exception.Message)"
    }

    if (-not $Once) {
        # Waiting on the bridge is the sleep: it returns the moment a
        # designer clicks something in the browser, and otherwise after
        # about twenty-five seconds, which is the poll interval by another
        # name.
        if (Test-BookRunnerBehindInstall -ProjectRoot $ProjectRoot -RunningVersion $script:agentVersion) {
            Write-Host "Book Studio $(Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot) is installed; this agent runs $($script:agentVersion). Restarting into it." -ForegroundColor Green
            Restart-BookRunner -ProjectRoot $ProjectRoot -Instance $instance
            return
        }
        if (((Get-Date) - $script:lastUpdateCheck).TotalMinutes -ge $UpdateCheckMinutes) {
            if (Invoke-BookRunnerSelfUpdate -ProjectRoot $ProjectRoot -Instance $instance) { return }
            Sync-LocalStudioServer
        }
        # Pages are carried by the helpers; this loop only keeps them running,
        # and replaces any that stopped.
        $script:bridgeWorkerProcesses = @(Start-BridgeWorkers -Running $script:bridgeWorkerProcesses)
        Start-Sleep -Seconds $PollIntervalSeconds
    }
} while (-not $Once)
