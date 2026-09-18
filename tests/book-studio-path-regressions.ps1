$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
$ebook = Get-Module EbookGenerator
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# Windows PowerShell fails past 259 characters with "Could not find a part of
# the path". Package parts built from course titles are capped, long installs
# are called out, and deep writes fail early with the fix.
$long = & $ebook { param($t) ConvertTo-SafePathPart $t -MaxLength 48 } 'RB1010-Healthcare Revenue Cycle Fundamentals & Medical Coding Systems'
Check ($long -eq 'RB1010-Healthcare-Revenue-Cycle-Fundamentals' -and $long.Length -le 48) "Course folder names are capped at a word boundary (got '$long')."
Check ((& $ebook { param($t) ConvertTo-SafePathPart $t } 'RB1010-Healthcare Revenue Cycle Fundamentals & Medical Coding Systems') -eq 'RB1010-Healthcare-Revenue-Cycle-Fundamentals-Medical-Coding-Systems') 'Without a cap the full safe name is kept.'
Check ((& $ebook { param($t) ConvertTo-SafePathPart $t -MaxLength 10 } 'Abcdefghijklmnopqrstuvwxyz') -eq 'Abcdefghij') 'A name with no boundary is cut at the cap.'

$short = & $studio { param($r) Get-BookStudioInstallPathStatus -ProjectRoot $r } 'C:\Users\designer\book-studio'
Check ($short.warning -eq '' -and $short.installPathLength -eq 29) 'A short local install has no warning.'
$oneDrive = & $studio { param($r) Get-BookStudioInstallPathStatus -ProjectRoot $r } 'C:\Users\designer\OneDrive - Example\Documents\book-studio'
Check ($oneDrive.warning -match 'OneDrive') 'An install inside OneDrive is called out.'
$deepRoot = 'C:\Users\GiovanniDuarte\Documents\Instructional Design\Course Production\Book Studio Pilot\Working Copies\2026\book-studio'
$deep = & $studio { param($r) Get-BookStudioInstallPathStatus -ProjectRoot $r } $deepRoot
Check ($deepRoot.Length -gt 120 -and $deep.warning -match "long path \($($deepRoot.Length) characters\)" -and $deep.warning -match 'Move Book Studio') 'A long install path is measured and the move is recommended.'
$boundary = & $studio { param($r) Get-BookStudioInstallPathStatus -ProjectRoot $r } ('C:\Users\GiovanniDuarte\OneDrive - Vocate Education Solutions, Inc\Documents\ITS Development\book-studio')
Check ($boundary.installPathLength -eq 104 -and $boundary.warning -match 'OneDrive' -and $boundary.warning -notmatch 'long path') 'A 104-character install fits once package names are capped; only the OneDrive advisory remains.'

$fine = 'C:\short\.bookstudio\outputs\abc\course\codex-requests\ai-1\exit-code.txt'
& $studio { param($p) Assert-BookStudioPathLength -Path $p -What 'a test file' } $fine
Check $true 'Paths within the limit pass.'
$tooLong = 'C:\' + ('x' * 240) + '\codex-requests\ai-1\exit-code.txt'
try { & $studio { param($p, $r) Assert-BookStudioPathLength -Path $p -What 'this Codex request' -ProjectRoot $r } $tooLong 'C:\short'; throw 'FAIL: A path beyond 259 characters must be rejected.' }
catch { Check ($_.Exception.Message -match 'would be \d+ characters; Windows allows 259' -and $_.Exception.Message -match 'book-studio') 'Over-long paths fail with the character count and the suggested folder.' }

Check ((Get-Content -LiteralPath (Join-Path $root 'lib/BookStudio.psm1') -Raw) -match 'Join-Path \$requestFolder "run\.ps1"') 'Codex request scripts use the short run.ps1 name.'
$index = Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
foreach ($id in @('installStatus', 'installBadge', 'installHeading')) { Check ($index -match ('id="' + $id + '"')) "index.html defines $id." }


# Moving the Book Studio folder (out of OneDrive, onto a shorter path) must not
# strand its books: every stored path is absolute and has to follow the move.
$oldRoot = Join-Path $env:LOCALAPPDATA ('BookStudioTests\moved-old-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$newRoot = Join-Path $env:LOCALAPPDATA ('BookStudioTests\moved-new-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$oldDb = Initialize-BookStudioDatabase -ProjectRoot $oldRoot
$oldStorage = Split-Path $oldDb -Parent
$job = [pscustomobject]@{
    id = 'moved01'
    status = 'Failed'
    outputRoot = (Join-Path $oldStorage 'outputs\moved01')
    outputFolder = (Join-Path $oldStorage 'outputs\moved01\GM1015-Book')
    sourceContextPath = (Join-Path $oldStorage 'uploads\moved01')
    specPath = (Join-Path $oldStorage 'uploads\moved01\spec.docx')
    logPath = (Join-Path $oldStorage 'logs\moved01.log')
    title = 'Moved book'
    uploadedFiles = @([pscustomobject]@{ name = 'spec.docx'; path = (Join-Path $oldStorage 'uploads\moved01\spec.docx') })
    artifacts = @([pscustomobject]@{ name = 'Word document'; path = (Join-Path $oldStorage 'outputs\moved01\GM1015-Book\Book.docx') })
    aiRequests = @([pscustomobject]@{ id = 'r1'; status = 'Completed'; errorPath = (Join-Path $oldStorage 'outputs\moved01\GM1015-Book\codex-requests\r1\error.log') })
    externalReference = 'C:\Users\someone\Documents\original-spec.docx'
}
$db = Read-BookStudioDatabase -DatabasePath $oldDb
$db.jobs = @($job)
Write-BookStudioDatabase -DatabasePath $oldDb -Database $db
Move-Item -LiteralPath $oldRoot -Destination $newRoot
$newDb = Initialize-BookStudioDatabase -ProjectRoot $newRoot
$newStorage = Split-Path $newDb -Parent
$moved = (Read-BookStudioDatabase -DatabasePath $newDb).jobs[0]
foreach ($field in @('outputRoot', 'outputFolder', 'sourceContextPath', 'specPath', 'logPath')) {
    Check ($moved.$field -like "$newStorage*") "$field still points at the old folder after the move: $($moved.$field)"
}
Check ($moved.outputFolder -eq (Join-Path $newStorage 'outputs\moved01\GM1015-Book')) "The moved output folder is wrong: $($moved.outputFolder)"
Check ($moved.uploadedFiles[0].path -like "$newStorage*" -and $moved.artifacts[0].path -like "$newStorage*") 'Nested upload or artifact paths did not follow the move.'
Check ($moved.aiRequests[0].errorPath -like "$newStorage*") 'Codex request paths did not follow the move.'
Check ($moved.externalReference -eq 'C:\Users\someone\Documents\original-spec.docx') 'A path outside Book Studio storage was rewritten.'
Check ($moved.title -eq 'Moved book' -and $moved.status -eq 'Failed') 'The move changed book data other than its paths.'
Check (-not (Repair-BookStudioMovedPaths -DatabasePath $newDb)) 'A second startup reported another move.'
Remove-Item -LiteralPath $newRoot -Recurse -Force -ErrorAction SilentlyContinue
$index = Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
$app = Get-Content -LiteralPath (Join-Path $root 'book-studio/app.js') -Raw -Encoding UTF8
Check ($app -match 'function reportJobActionError') 'Job action failures have nowhere visible to report.'
Check ($app -notmatch 'runJob\(job\.id, getWorkflowRunMode\(job\)\)\);') 'A run action still drops its error instead of showing it.'
Check ($app -match 'Recreate format preview') 'A failed book cannot rebuild its format preview.'

Write-Output "PASS: $checks path-length and relocation assertions."
