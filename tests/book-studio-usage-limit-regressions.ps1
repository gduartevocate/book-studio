$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# When Codex runs out of quota part-way through a book.
#
# RB1000 wrote five validated chapters, then hit the Codex usage limit while
# drawing chapter images. The runner put back the copy it had taken at the start
# of the run -- only the planning files -- deleting the manuscript on the way,
# and only afterwards checked whether that copy was a finished book. It was not.
# The chapters had to be rebuilt from Codex's own session record. The message
# then told the designer to "try again after the time shown in the log", which
# showed no time.

. (Join-Path $root 'lib/BookStudioRunnerRecovery.ps1')

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('studio-usage-limit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $planningOnly = Join-Path $fixture 'bk-planning'
    $finishedBook = Join-Path $fixture 'bk-finished'
    New-Item -ItemType Directory -Path $planningOnly, $finishedBook | Out-Null
    Set-Content -LiteralPath (Join-Path $planningOnly 'ebook-outline.md') -Value 'outline'
    Set-Content -LiteralPath (Join-Path $finishedBook 'RB1000 - E-Book.md') -Value 'book'
    $qa = { param($folder) if (Test-Path -LiteralPath (Join-Path $folder 'RB1000 - E-Book.md')) { 'PASS' } else { 'FAIL' } }

    Check (-not (Test-BookStudioBackupWorthRestoring -Backup ([pscustomobject]@{ backupPath = $planningOnly; sourcePath = 'x' }) -QaStatus $qa)) 'A planning-only copy must never be put back over a run: it is not a finished book.'
    Check (Test-BookStudioBackupWorthRestoring -Backup ([pscustomobject]@{ backupPath = $finishedBook; sourcePath = 'x' }) -QaStatus $qa) 'A copy that is a finished book passing its checks may be put back.'
    Check (-not (Test-BookStudioBackupWorthRestoring -Backup $null -QaStatus $qa)) 'No copy, nothing to put back.'
    Check (-not (Test-BookStudioBackupWorthRestoring -Backup ([pscustomobject]@{ backupPath = (Join-Path $fixture 'gone') }) -QaStatus $qa)) 'A copy that has disappeared is not put back.'
    Check (-not (Test-BookStudioBackupWorthRestoring -Backup ([pscustomobject]@{ backupPath = $finishedBook }) -QaStatus { throw 'unreadable' })) 'A copy whose checks cannot be read is not put back.'

    # Did this run write the chapters?
    $output = Join-Path $fixture 'output'
    New-Item -ItemType Directory -Path $output | Out-Null
    $started = Get-Date
    Check (-not (Test-BookStudioRunWroteManuscript -OutputFolder $output -StartedAt $started)) 'A folder with no manuscript has no chapters to keep.'
    Set-Content -LiteralPath (Join-Path $output 'RB1000 001 - E-Book.md') -Value 'chapters'
    Check (Test-BookStudioRunWroteManuscript -OutputFolder $output -StartedAt $started) 'A manuscript written during this run is recognised as work to keep.'
    (Get-Item -LiteralPath (Join-Path $output 'RB1000 001 - E-Book.md')).LastWriteTime = $started.AddHours(-3)
    Check (-not (Test-BookStudioRunWroteManuscript -OutputFolder $output -StartedAt $started)) 'A manuscript left by an earlier run is not mistaken for this run''s work.'
    Check (-not (Test-BookStudioRunWroteManuscript -OutputFolder '' -StartedAt $started)) 'No output folder, no manuscript.'

    # What the designer is told.
    $kept = Get-BookStudioUsageLimitNotice -CodexMessage 'Codex reported a usage limit.' -ManuscriptKept $true
    Check ($kept -match 'manuscript is kept' -and $kept -match 'Generate images for saved setting') 'With chapters written, the notice must say they are kept and how to finish the images.'
    Check ($kept -notmatch 'time shown in the log') 'The notice must not point at a time the log does not show.'
    Check ($kept -match 'did not say when') 'Without a reset time from Codex, the notice must say so plainly.'
    $timed = Get-BookStudioUsageLimitNotice -CodexMessage "You've hit your usage limit. Try again at 2:15 PM." -ManuscriptKept $false
    Check ($timed -match 'try again at 2:15 PM') 'A reset time Codex gave must be passed on.'
    Check ($timed -match 'before the chapters were written' -and $timed -notmatch 'Generate images') 'Without chapters, the notice must not offer image generation.'
    Check ((Get-Command Get-BookStudioUsageLimitNotice) -and $kept.Length -lt 400) 'The notice stays short enough to read in the job panel.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# The runner itself: it must use these rules, and decide before it deletes.
$runnerPath = Join-Path $root 'book-studio-runner.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
Check ($errors.Count -eq 0) ('The runner must parse: ' + (($errors | ForEach-Object Message) -join '; '))
$runner = Get-Content -LiteralPath $runnerPath -Raw
Check ($runner -match "lib/BookStudioRunnerRecovery\.ps1") 'The runner must load the recovery rules.'
$branchStart = $runner.IndexOf('if (Test-RunnerCodexUsageLimitText -Text $failureText)')
Check ($branchStart -gt 0) 'The runner must still recognise a Codex usage limit.'
$branch = $runner.Substring($branchStart, $runner.IndexOf('Get-BookStudioUsageLimitNotice', $branchStart) - $branchStart)
$restoreAt = $branch.IndexOf('Restore-RunnerExistingOutputBackup')
Check ($restoreAt -gt 0) 'The runner can still put back a finished book when that is the right thing to do.'
$guard = $branch.Substring(0, $restoreAt)
Check ($guard -match 'Test-BookStudioBackupWorthRestoring' -and $guard -match 'if \(-not \$manuscriptKept -and') 'The copy must be judged, and this run''s chapters checked, before anything is deleted to put it back.'
Check (([regex]::Matches($branch, 'Restore-RunnerExistingOutputBackup')).Count -eq 1) 'There must be only one place that puts a copy back, and it is the guarded one.'
Check ($runner -notmatch 'time shown in the log') 'No message may point at a time the log does not show.'

"PASS: $checks usage-limit assertions (never put back a copy over chapters this run wrote, only put back a finished book, say what to do next)."
