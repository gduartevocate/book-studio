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
    [string]$SignInUrl = "https://ebook.vocate.app/connect",
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
        $connection = Test-BookStudioCodexConnection -ProjectRoot $ProjectRoot
        $result.status = if ($connection.connectionStatus -eq 'PASS') { 'Connected' } else { 'Unavailable' }
        $result.detail = [string]$connection.connectionMessage
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
    try {
        Invoke-RunnerApi -Method Post -Path '/api/runner/status' -Body @{
            codex = $Status
            runnerName = "$env:COMPUTERNAME / $env:USERNAME"
        } | Out-Null
    }
    catch {
        Write-Warning "Could not report Codex status to the cloud: $($_.Exception.Message)"
    }
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
Publish-CodexStatus -Status $script:codexStatus

do {
    try {
        if (((Get-Date) - $script:codexCheckedAt).TotalMinutes -ge 10) {
            $script:codexStatus = Test-LocalCodexConnection -ProjectRoot $ProjectRoot
            $script:codexCommandPath = $script:codexStatus.commandPath
            $script:codexCheckedAt = Get-Date
        }
        Publish-CodexStatus -Status $script:codexStatus
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
        Start-Sleep -Seconds $PollIntervalSeconds
    }
} while (-not $Once)
