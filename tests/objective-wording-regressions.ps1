$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# Codex rewording a learning objective. MI1010 stopped at "Chapter 2: Rendered
# objective 2 does not exactly match the source text", and the automatic Codex
# repair did not put it back. The list is the course's objectives, word for
# word, so a reworded one is restored from the plan and the change recorded; a
# chapter with a different number of objectives is left for the designer.

. (Join-Path $root 'lib/EbookPublicationTemplate.ps1')

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('objective-wording-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $plan = [pscustomobject]@{ chapters = @(
        [pscustomobject]@{ number = 1; learningTargetRecords = @([pscustomobject]@{ objectiveId = 'CO1'; objective = 'Explain the stages of the revenue cycle.' }) },
        [pscustomobject]@{ number = 2; learningTargetRecords = @(
            [pscustomobject]@{ objectiveId = 'CO2'; objective = 'Describe how services are documented.' },
            [pscustomobject]@{ objectiveId = 'CO3'; objective = 'Identify risks to accurate claims in payer administrative operations.' }) },
        [pscustomobject]@{ number = 3; learningTargetRecords = @(
            [pscustomobject]@{ objectiveId = 'CO4'; objective = 'Evaluate account follow-up.' },
            [pscustomobject]@{ objectiveId = 'CO5'; objective = 'Recommend one improvement.' }) }
    ) }
    $drafted = @(
        '# Chapter 1: Foundations', '', '### Learning Objectives', '', 'By the end of this chapter, you should be able to:', '',
        '1. Explain the stages of the revenue cycle.', '', '## Section 1.1 - Start', '', 'Body text 1. Identify risks, as the text says.', '',
        '# Chapter 2: Documentation', '', '### Learning Objectives', '',
        '1. Describe how services are documented.',
        '2. Identify the main risks to claim accuracy across payer operations.', '',
        '## Section 2.1 - Start', '', '1. A numbered step in the body that must never be touched.', '',
        '# Chapter 3: Improvement', '', '### Learning Objectives', '',
        '1. Evaluate account follow-up.', '',
        '## Section 3.1 - Start', '', 'Body.'
    ) -join "`r`n"
    $md = Join-Path $fixture 'book - E-Book.md'
    Set-Content -LiteralPath $md -Value $drafted -Encoding UTF8

    $changes = @(Update-EbookObjectiveListWording -MarkdownPath $md -Plan $plan)
    $after = Get-Content -LiteralPath $md -Raw -Encoding UTF8
    Check ($changes.Count -eq 1 -and $changes[0].chapter -eq 2 -and $changes[0].objective -eq 2) "Only the reworded objective is restored, got $($changes.Count) change(s)."
    Check ($after -match '(?m)^2\. Identify risks to accurate claims in payer administrative operations\.\r?$') 'The reworded objective must read exactly as the course document has it.'
    Check ($changes[0].drafted -match 'main risks to claim accuracy' -and $changes[0].restored -match '^Identify risks to accurate claims') 'The change is recorded: what Codex wrote and what it was restored to.'
    Check ($after -match '(?m)^1\. A numbered step in the body that must never be touched\.') 'Numbered lists outside Learning Objectives are never touched.'
    Check ($after -match '(?m)^1\. Evaluate account follow-up\.\r?$' -and $after -notmatch 'Recommend one improvement') 'A chapter with a different number of objectives is left for the designer, not filled in.'
    Check ($after -match 'Body text 1\. Identify risks, as the text says\.') 'Body text is never touched.'
    Check (@(Update-EbookObjectiveListWording -MarkdownPath $md -Plan $plan).Count -eq 0) 'Running it again changes nothing.'

    # Punctuation and case alone are not a rewording: the gate compares the
    # same way, and a book is not rewritten for a full stop.
    Set-Content -LiteralPath $md -Value ('# Chapter 1: F' + "`r`n`r`n### Learning Objectives`r`n`r`n1. explain the stages of the revenue cycle`r`n") -Encoding UTF8
    Check (@(Update-EbookObjectiveListWording -MarkdownPath $md -Plan $plan).Count -eq 0) 'A difference of case or punctuation only is left alone, as the gate leaves it.'

    # Plans from before objective IDs: the plain list of targets is used.
    $oldPlan = [pscustomobject]@{ chapters = @([pscustomobject]@{ number = 1; learningTargets = @('Explain the stages of the revenue cycle.') }) }
    Set-Content -LiteralPath $md -Value ('# Chapter 1: F' + "`r`n`r`n### Learning Objectives`r`n`r`n1. Explain revenue cycle stages.`r`n") -Encoding UTF8
    Check (@(Update-EbookObjectiveListWording -MarkdownPath $md -Plan $oldPlan).Count -eq 1) 'A plan with only learning targets is used the same way.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# The package rebuild -- which generation ends with, and which Rebuild Package
# is -- restores wording before the manuscript preflight and the release gate.
$generator = Get-Content -LiteralPath (Join-Path $root 'lib/EbookGenerator.psm1') -Raw
$restoreAt = $generator.IndexOf('Update-EbookObjectiveListWording -MarkdownPath $ebookMarkdownFile.FullName')
$preflightAt = $generator.IndexOf('$preflight = Update-EbookManuscriptPreflight -MarkdownPath $ebookMarkdownFile.FullName')
Check ($restoreAt -gt 0 -and $preflightAt -gt $restoreAt) 'The rebuild must restore objective wording before its checks run.'
Check ($generator -match "objective-wording-restored\.json") 'Every restoration must be written down in the package.'

"PASS: $checks objective wording assertions (a reworded objective restored and recorded, a different count left to the designer, nothing else touched)."
