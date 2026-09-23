# Sharing a book with everyone at Vocate.
#
# The book stays on this computer. What is shared is a read-only copy of its
# finished files -- the Word book, the HTML book and the interactive study
# page -- listed under the designer's name in Everyone's books on the web
# site, where anyone signed in at Vocate can download them. Sharing again
# replaces the copy; stopping removes it.
#
# The upload uses the credential this computer was connected with, so it works
# the same whether the designer opened Book Studio here or through the web
# site. It runs in the background: a Word book with its photos is about 10 MB,
# and a request carried from the web site has 50 seconds.

$script:BookStudioShareBaseUrl = 'https://ebook-generator.gduarte-28e.workers.dev'

function Get-BookStudioShareToken {
    # The agent's saved credential, read the way the agent reads it.
    . (Join-Path $PSScriptRoot 'EbookCloudRunner.ps1')
    return (Resolve-BookRunnerToken).token
}

# The HTML book names its photos and diagrams as separate files. A copy on the
# web site has none of them beside it, so each is written into the page.
function ConvertTo-BookStudioSelfContainedHtml {
    param(
        [Parameter(Mandatory)][string]$HtmlPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $folder = [IO.Path]::GetFullPath((Split-Path -Parent $HtmlPath))
    $html = [IO.File]::ReadAllText($HtmlPath, [Text.Encoding]::UTF8)
    $types = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.svg' = 'image/svg+xml'; '.webp' = 'image/webp' }
    $inlined = [regex]::Replace($html, '(?i)(\bsrc\s*=\s*)(["''])([^"''<>]+?)\2', {
        param($match)
        $reference = [Uri]::UnescapeDataString($match.Groups[3].Value)
        if ($reference -match '^(?i)(data:|https?:|//)') { return $match.Value }
        $path = [IO.Path]::GetFullPath((Join-Path $folder $reference))
        # Only files inside the book's own folder, however the page names them.
        if (-not $path.StartsWith($folder + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $match.Value }
        $type = $types[[IO.Path]::GetExtension($path).ToLowerInvariant()]
        if (-not $type -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $match.Value }
        $data = 'data:' + $type + ';base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
        return $match.Groups[1].Value + $match.Groups[2].Value + $data + $match.Groups[2].Value
    })
    [IO.File]::WriteAllText($Destination, $inlined, [Text.UTF8Encoding]::new($false))
    return $Destination
}

# What is shared: the Word book (required), and the HTML book and interactive
# study page when the book has them, each made to stand on its own.
function Get-BookStudioShareFiles {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$WorkFolder
    )

    $word = Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.docx' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $word) { throw 'This book has no Word file yet. Finish the book, or use Rebuild Package, before sharing it.' }
    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    $files = @([pscustomobject]@{ fileName = $word.Name; path = $word.FullName; contentType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' })
    $html = Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.html' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($html) {
        $files += [pscustomobject]@{ fileName = $html.Name; path = (ConvertTo-BookStudioSelfContainedHtml -HtmlPath $html.FullName -Destination (Join-Path $WorkFolder $html.Name)); contentType = 'text/html; charset=utf-8' }
    }
    $study = Join-Path $OutputFolder 'interactive-study.html'
    if (Test-Path -LiteralPath $study -PathType Leaf) {
        $files += [pscustomobject]@{ fileName = 'interactive-study.html'; path = (ConvertTo-BookStudioSelfContainedHtml -HtmlPath $study -Destination (Join-Path $WorkFolder 'interactive-study.html')); contentType = 'text/html; charset=utf-8' }
    }
    return $files
}

function Invoke-BookStudioShareRequest {
    param([string]$Method, [string]$Path, [string]$Body, [string]$Token, [string]$BaseUrl = $script:BookStudioShareBaseUrl)
    $arguments = @{ Uri = $BaseUrl + $Path; Method = $Method; Headers = @{ 'x-book-runner-token' = $Token }; TimeoutSec = 600 }
    if ($Body) { $arguments.Body = [Text.Encoding]::UTF8.GetBytes($Body); $arguments.ContentType = 'application/json' }
    Invoke-RestMethod @arguments
}

function Set-BookStudioShareState {
    param([string]$DatabasePath, [string]$JobId, [object]$State)
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current | Add-Member -NotePropertyName shared -NotePropertyValue $State -Force
    }
}

# The upload itself, run in the background by Start-BookStudioShare.
function Invoke-BookStudioShare {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$ProjectRoot,
        # How requests reach the web site; a parameter so the sequence can be
        # tested without it.
        [scriptblock]$Send = { param($method, $path, $body, $token) Invoke-BookStudioShareRequest -Method $method -Path $path -Body $body -Token $token },
        [string]$Token = ''
    )

    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    $work = Join-Path ([IO.Path]::GetTempPath()) ('book-studio-share-' + [guid]::NewGuid().ToString('N'))
    try {
        if (-not $Token) { $Token = Get-BookStudioShareToken }
        if (-not $Token) { throw 'This computer is not connected to the Book Studio web site, so it cannot share. Connect it from ebookstudio.vocate.app, Your computer, then share again.' }
        $files = @(Get-BookStudioShareFiles -OutputFolder $job.outputFolder -WorkFolder $work)
        $book = [pscustomobject]@{ localId = $job.id; title = [string]$job.title; courseCode = [string]$job.courseCode; workflowStatus = [string](Get-BookStudioShareStage $job); runnerName = "$env:COMPUTERNAME / $env:USERNAME" }
        $shared = & $Send 'POST' '/api/runner/shares' ($book | ConvertTo-Json -Compress) $Token
        if (-not $shared.id) { throw 'The web site did not accept the book.' }
        foreach ($file in $files) {
            # Built by hand: ConvertTo-Json on a 13 MB string is slow in
            # Windows PowerShell and gains nothing.
            $body = '{"fileName":' + ($file.fileName | ConvertTo-Json) + ',"contentType":' + ($file.contentType | ConvertTo-Json) +
                    ',"contentBase64":"' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.path)) + '"}'
            $null = & $Send 'POST' ('/api/runner/jobs/' + $shared.id + '/artifacts') $body $Token
        }
        Set-BookStudioShareState -DatabasePath $DatabasePath -JobId $JobId -State ([pscustomobject]@{
            status = 'Shared'; sharedAt = (Get-Date).ToString('o'); files = @($files.fileName); error = ''
        })
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Shared with everyone at Vocate: $(@($files.fileName) -join ', ')."
    }
    catch {
        $reason = $_.Exception.Message
        Set-BookStudioShareState -DatabasePath $DatabasePath -JobId $JobId -State ([pscustomobject]@{ status = 'Failed'; failedAt = (Get-Date).ToString('o'); error = $reason })
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Sharing did not complete: $reason"
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-BookStudioShareStage {
    param([object]$Job)
    if ($Job.PSObject.Properties.Name -contains 'workflowStatus' -and $Job.workflowStatus) { return [string]$Job.workflowStatus }
    return [string]$Job.status
}

# Checked here, in the request, so a book that cannot be shared says so at
# once instead of failing quietly in the background.
function Start-BookStudioShare {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    if (-not $job) { throw 'Book not found.' }
    if (-not $job.outputFolder -or -not (Get-ChildItem -LiteralPath $job.outputFolder -Filter '* - E-Book.docx' -File -ErrorAction SilentlyContinue)) {
        throw 'This book has no Word file yet. Finish the book, or use Rebuild Package, before sharing it.'
    }
    if (-not (Get-BookStudioShareToken)) {
        throw 'This computer is not connected to the Book Studio web site, so it cannot share. Connect it from ebookstudio.vocate.app, Your computer, then share again.'
    }
    $current = if ($job.PSObject.Properties.Name -contains 'shared') { $job.shared } else { $null }
    if ($current -and $current.status -eq 'Sharing' -and $current.startedAt -and [datetime]$current.startedAt -gt (Get-Date).AddMinutes(-15)) {
        throw 'This book is already being shared. It will show as Shared when the upload finishes.'
    }
    Set-BookStudioShareState -DatabasePath $DatabasePath -JobId $JobId -State ([pscustomobject]@{ status = 'Sharing'; startedAt = (Get-Date).ToString('o'); error = '' })
    $module = Join-Path $PSScriptRoot 'BookStudio.psm1'
    $command = "Import-Module '" + $module.Replace("'", "''") + "' -Force -DisableNameChecking; Invoke-BookStudioShare -DatabasePath '" + $DatabasePath.Replace("'", "''") +
               "' -JobId '" + $JobId.Replace("'", "''") + "' -ProjectRoot '" + $ProjectRoot.Replace("'", "''") + "'"
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', $command) -WindowStyle Hidden | Out-Null
    return (Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId)
}

function Stop-BookStudioShare {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [scriptblock]$Send = { param($method, $path, $body, $token) Invoke-BookStudioShareRequest -Method $method -Path $path -Body $body -Token $token },
        [string]$Token = ''
    )

    if (-not $Token) { $Token = Get-BookStudioShareToken }
    if (-not $Token) { throw 'This computer is not connected to the Book Studio web site, so it cannot withdraw the shared copy.' }
    $null = & $Send 'DELETE' ('/api/runner/shares/' + [Uri]::EscapeDataString($JobId)) '' $Token
    Set-BookStudioShareState -DatabasePath $DatabasePath -JobId $JobId -State $null
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'Stopped sharing with Vocate. The shared copy was removed from the web site.'
    return (Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId)
}
