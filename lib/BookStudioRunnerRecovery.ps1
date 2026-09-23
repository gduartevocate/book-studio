# What to do with a book when Codex runs out of quota part-way through.
#
# The runner used to restore the backup it took at the start of the run, and
# only then look at whether that backup was any good. For RB1000 the backup was
# the planning files, so twenty-one minutes of finished, validated chapters were
# deleted to put back an outline, because the limit was hit afterwards, while
# drawing chapter images. The manuscript had to be rebuilt from Codex's own
# session record.
#
# A backup is only ever worth restoring when it is itself a finished book that
# passes its checks. Anything less is never better than what the run produced,
# and the folder the run produced is left exactly as it is.

function Test-BookStudioBackupWorthRestoring {
    param(
        [AllowNull()][object]$Backup,
        # How a folder's QA is judged. A parameter so the rule can be exercised
        # without building a whole book; the runner passes its own check.
        [Parameter(Mandatory)][scriptblock]$QaStatus
    )

    if (-not $Backup -or [string]::IsNullOrWhiteSpace([string]$Backup.backupPath)) { return $false }
    if (-not (Test-Path -LiteralPath ([string]$Backup.backupPath) -PathType Container)) { return $false }
    try {
        return ((& $QaStatus ([string]$Backup.backupPath)) -eq 'PASS')
    }
    catch {
        # A backup whose checks cannot even be read is not a book to put back.
        return $false
    }
}

# Whether the run got as far as a written manuscript: the thing worth keeping
# above all else when something later in the run fails.
function Test-BookStudioRunWroteManuscript {
    param(
        [AllowNull()][string]$OutputFolder,
        [datetime]$StartedAt
    )

    if ([string]::IsNullOrWhiteSpace($OutputFolder) -or -not (Test-Path -LiteralPath $OutputFolder -PathType Container)) { return $false }
    $manuscript = Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $manuscript) { return $false }
    return ($manuscript.LastWriteTime -ge $StartedAt.AddSeconds(-5))
}

# Said in terms a designer can act on. The old text told them to "try again
# after the time shown in the log" when the log showed no time at all.
function Get-BookStudioUsageLimitNotice {
    param(
        [AllowEmptyString()][string]$CodexMessage,
        [bool]$ManuscriptKept
    )

    $when = if ($CodexMessage -match '(?i)try again at\s*([^\r\n.]+)') {
        "Codex says you can try again at $($Matches[1].Trim())."
    } else {
        'Codex did not say when the limit resets; it is usually within a few hours.'
    }
    if ($ManuscriptKept) {
        return "Codex reached its usage limit after the chapters were written. The manuscript is kept. Once the limit resets, choose Finish images: it draws the missing chapter images and nothing has to be written again. $when"
    }
    return "Codex reached its usage limit before the chapters were written. Nothing was lost; start generation again once the limit resets. $when"
}

# A book whose chapters survived a usage limit is waiting for its images, not
# for a rewrite. Retry used to start the whole book again unless the folder
# happened to hold an unfinished image run, and after RB1000's rollback it did
# not, so the obvious button would have written the chapters a second time.
# The runner records the wait on the job and leaves the marker that makes the
# next run finish images only; every way of starting the book then does that.
function Set-BookStudioImagesOnlyMarker {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [string]$Reason = 'Codex reached its usage limit before the chapter images were finished.'
    )

    $markerPath = Join-Path $OutputFolder 'image-production-run.json'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            if ((Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json).status -eq 'Incomplete') { return }
        }
        catch { }
    }
    [pscustomobject]@{ status = 'Incomplete'; failure = $Reason; updatedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
}

function Test-BookStudioJobAwaitingImages {
    param([AllowNull()][object]$Job)

    if (-not $Job -or -not ($Job.PSObject.Properties.Name -contains 'recovery') -or -not $Job.recovery) { return $false }
    if ([string]$Job.recovery.kind -ne 'usage-limit' -or -not $Job.recovery.manuscriptKept) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Job.outputFolder) -or -not (Test-Path -LiteralPath $Job.outputFolder -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $Job.outputFolder -Filter '* - E-Book.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}
