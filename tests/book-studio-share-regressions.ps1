$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }
function Reject([scriptblock]$Action, [string]$Pattern) { $rejected = $false; try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw "FAIL: unexpected refusal: $($_.Exception.Message)" }; $rejected = $true }; Check $rejected "Expected a refusal matching: $Pattern" }

# Sharing a book with everyone at Vocate: a read-only copy of its Word book,
# HTML book and interactive study page on the web site. Nothing here reaches
# the web site -- requests go to a stand-in -- and this computer's own
# connection credential is never read: the profile folder is a fixture.

Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('studio-share-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$realLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $fixture 'profile'
try {
    # A finished book: Word, HTML with a photo and a diagram, interactive study.
    $book = Join-Path $fixture 'outputs\QA1000-Book'
    New-Item -ItemType Directory -Path (Join-Path $book 'images'), (Join-Path $book 'visuals') -Force | Out-Null
    $photo = [byte[]](137, 80, 78, 71, 1, 2, 3, 4)
    [IO.File]::WriteAllBytes((Join-Path $book 'images\chapter-1-opener.png'), $photo)
    Set-Content -LiteralPath (Join-Path $book 'visuals\chapter-1-aid.svg') -Value '<svg xmlns="http://www.w3.org/2000/svg"/>'
    Set-Content -LiteralPath (Join-Path $fixture 'outputs\outside.png') -Value 'not part of the book'
    $html = '<html><body><img src="images/chapter-1-opener.png" alt="a"><img src=''visuals/chapter-1-aid.svg''><img src="https://example.com/x.png"><img src="../outside.png"><img src="images/missing.png"></body></html>'
    Set-Content -LiteralPath (Join-Path $book 'QA1000 Book - E-Book.html') -Value $html
    Set-Content -LiteralPath (Join-Path $book 'interactive-study.html') -Value '<html><img src="visuals/chapter-1-aid.svg"></html>'
    $word = [byte[]](80, 75, 3, 4, 9, 9, 9)
    [IO.File]::WriteAllBytes((Join-Path $book 'QA1000 Book - E-Book.docx'), $word)

    # 1. The shared HTML stands on its own: the book's own photos and diagrams
    #    are written into it; nothing outside the book's folder is.
    $work = Join-Path $fixture 'work'
    $files = @(& $studio { param($o, $w) Get-BookStudioShareFiles -OutputFolder $o -WorkFolder $w } $book $work)
    Check (($files.fileName -join '|') -eq 'QA1000 Book - E-Book.docx|QA1000 Book - E-Book.html|interactive-study.html') "The Word book, HTML book and study page are shared, in that order: $($files.fileName -join ', ')"
    $sharedHtml = [IO.File]::ReadAllText(($files | Where-Object fileName -like '* - E-Book.html').path)
    Check ($sharedHtml -match 'src="data:image/png;base64,' + [regex]::Escape([Convert]::ToBase64String($photo)) + '"') 'The chapter photo must be written into the shared HTML.'
    Check ($sharedHtml -match "src='data:image/svg\+xml;base64,") 'A diagram must be written in too, whichever quotes the page uses.'
    Check ($sharedHtml -match 'src="https://example.com/x.png"') 'A web address is left as it is.'
    Check ($sharedHtml -match 'src="\.\./outside\.png"') 'A file outside the book''s folder must never be written into a shared page.'
    Check ($sharedHtml -match 'src="images/missing.png"') 'A missing file is left as a reference, not guessed at.'
    Check ([IO.File]::ReadAllText((Join-Path $book 'QA1000 Book - E-Book.html')) -eq ($html + [Environment]::NewLine)) 'The book''s own HTML must not be changed by sharing.'
    Check ([IO.File]::ReadAllText(($files | Where-Object fileName -eq 'interactive-study.html').path) -match 'data:image/svg\+xml') 'The study page is made to stand on its own too.'
    Reject { & $studio { param($o, $w) Get-BookStudioShareFiles -OutputFolder $o -WorkFolder $w } (Join-Path $fixture 'empty') $work } 'no Word file'

    # 2. The upload, in order: the book, then each file, then it is marked Shared.
    $db = Initialize-BookStudioDatabase -ProjectRoot $fixture
    $job = [pscustomobject]@{ id = 'share-fixture'; title = 'QA Book'; courseCode = 'QA1000'; status = 'Completed'; workflowStage = 'id-review'; workflowStatus = 'Ready for ID review';
        updatedAt = (Get-Date).ToString('s'); outputFolder = $book; options = [pscustomobject]@{}; artifacts = @(); log = @() }
    $data = Read-BookStudioDatabase $db; $data.jobs = @($job); Write-BookStudioDatabase $db $data
    $script:sent = New-Object System.Collections.ArrayList
    $fakeSite = { param($method, $path, $body, $token) [void]$script:sent.Add([pscustomobject]@{ method = $method; path = $path; body = $body; token = $token }); if ($path -eq '/api/runner/shares') { [pscustomobject]@{ id = 'share-0123456789abcdef0123' } } else { [pscustomobject]@{ ok = $true } } }
    Invoke-BookStudioShare -DatabasePath $db -JobId 'share-fixture' -ProjectRoot $fixture -Send $fakeSite -Token 'fixture-token'
    Check ($script:sent.Count -eq 4) "One request for the book and one per file, got $($script:sent.Count)."
    $first = $script:sent[0]; $book0 = $first.body | ConvertFrom-Json
    Check ($first.method -eq 'POST' -and $first.path -eq '/api/runner/shares' -and $first.token -eq 'fixture-token') 'The book is announced first, with this computer''s credential.'
    Check ($book0.localId -eq 'share-fixture' -and $book0.title -eq 'QA Book' -and $book0.courseCode -eq 'QA1000' -and $book0.workflowStatus -eq 'Ready for ID review') 'The shared entry names the book, its course and its stage.'
    Check (@($script:sent | Select-Object -Skip 1 | Where-Object { $_.path -ne '/api/runner/jobs/share-0123456789abcdef0123/artifacts' }).Count -eq 0) 'Every file goes to the entry the site created.'
    $wordUpload = ($script:sent[1].body | ConvertFrom-Json)
    Check ($wordUpload.fileName -eq 'QA1000 Book - E-Book.docx' -and [Convert]::ToBase64String($word) -eq $wordUpload.contentBase64) 'The Word book must arrive byte for byte.'
    Check ($wordUpload.contentType -match 'wordprocessingml') 'The Word book must be sent as a Word document.'
    $after = Get-BookStudioJob -DatabasePath $db -JobId 'share-fixture'
    Check ($after.shared.status -eq 'Shared' -and @($after.shared.files).Count -eq 3 -and $after.shared.sharedAt) 'The book must then show as shared, with what was shared and when.'
    Check (@($after.log | Where-Object { $_.message -match 'Shared with everyone at Vocate' }).Count -eq 1) 'The book''s log must record the share.'

    # 3. A failed upload says why, on the book, and leaves it shareable again.
    $failingSite = { param($method, $path, $body, $token) if ($path -like '*/artifacts') { throw 'The remote server returned an error: (413) Payload Too Large.' } else { [pscustomobject]@{ id = 'share-0123456789abcdef0123' } } }
    Invoke-BookStudioShare -DatabasePath $db -JobId 'share-fixture' -ProjectRoot $fixture -Send $failingSite -Token 'fixture-token'
    $failed = Get-BookStudioJob -DatabasePath $db -JobId 'share-fixture'
    Check ($failed.shared.status -eq 'Failed' -and $failed.shared.error -match '413') 'A failed share must say so on the book, with the reason.'

    # 4. A computer that was never connected cannot share, and says how to fix it.
    Invoke-BookStudioShare -DatabasePath $db -JobId 'share-fixture' -ProjectRoot $fixture -Send $fakeSite
    Check ((Get-BookStudioJob -DatabasePath $db -JobId 'share-fixture').shared.error -match 'not connected to the Book Studio web site') 'Without this computer''s credential, sharing must say to connect it.'
    Reject { Start-BookStudioShare -DatabasePath $db -JobId 'share-fixture' -ProjectRoot $fixture } 'not connected'
    Remove-Item -LiteralPath (Join-Path $book 'QA1000 Book - E-Book.docx')
    Reject { Start-BookStudioShare -DatabasePath $db -JobId 'share-fixture' -ProjectRoot $fixture } 'no Word file'

    # 5. Stopping removes the web copy and clears the book's sharing state.
    $script:sent.Clear()
    $null = Stop-BookStudioShare -DatabasePath $db -JobId 'share-fixture' -Send $fakeSite -Token 'fixture-token'
    Check ($script:sent.Count -eq 1 -and $script:sent[0].method -eq 'DELETE' -and $script:sent[0].path -eq '/api/runner/shares/share-fixture') 'Stopping must ask the site to remove this book''s copy.'
    Check (-not (Get-BookStudioJob -DatabasePath $db -JobId 'share-fixture').shared) 'After stopping, the book is no longer marked as shared.'
}
finally {
    $env:LOCALAPPDATA = $realLocalAppData
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# The server and the page use these.
$module = Get-Content -LiteralPath (Join-Path $root 'lib/BookStudio.psm1') -Raw
Check ($module -match "/share\$' -and \`$request.HttpMethod -eq 'POST'" -and $module -match "/unshare\$' -and \`$request.HttpMethod -eq 'POST'") 'The server must offer share and unshare for a book.'
$app = Get-Content -LiteralPath (Join-Path $root 'book-studio/app.js') -Raw
Check ($app -match 'if \(!isJobProcessing\(job\)\) appendShareAction\(actions, job\);') 'Every book not being worked on must offer sharing.'
Check ($app -match '"Share again" : "Share with Vocate"' -and $app -match '"Stop sharing"') 'The page must offer Share with Vocate, Share again and Stop sharing.'
Check ($app -match 'job\.shared\?\.status === "Sharing"\) \|\| bookChatHasRunningRequests') 'The page must keep refreshing while a share uploads.'
Check ($app -match '\$\{describeSharing\(job\)\}') 'Each book''s summary line must say whether and when it was shared.'
$appVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw), 'app\.js\?v=(\d{8})-(\d+)')
Check ($appVersion.Success -and ([long]$appVersion.Groups[1].Value * 100 + [int]$appVersion.Groups[2].Value) -ge 2026092306) 'The page must be cache-busted to at least the release that added sharing.'

"PASS: $checks sharing assertions (self-contained copies, upload order, failures on the book, never-connected computers, stop sharing)."
