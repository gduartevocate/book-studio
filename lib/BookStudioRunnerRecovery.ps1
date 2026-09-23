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
        return "Codex reached its usage limit after the chapters were written. The manuscript is kept. Once the limit resets, use Generate images for saved setting to finish the chapter images; nothing has to be written again. $when"
    }
    return "Codex reached its usage limit before the chapters were written. Nothing was lost; start generation again once the limit resets. $when"
}
