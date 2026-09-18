$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('book-bare-weeks-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++}

# Synthetic wording, with the real failure's assignment pattern: objective 6
# has one different supporting objective in weeks 3 and 5. Do not collapse it.
$groups=@(@(1),@(2),@(3,6),@(4,5),@(6,7))
foreach($variant in @('bare','compact','colon','titled','next-line-title','markdown')) {
    $lines=for($week=1;$week -le 5;$week++) {
        switch($variant) {
            bare { "Week $week" }
            compact { "Week$week" }
            colon { "Week ${week}:" }
            titled { "Week $week - Topic $week" }
            next-line-title { "Week $week"; "Topic $week" }
            markdown { "## Week $week" }
        }
        foreach($id in $groups[$week-1]) {
            "$id. Describe fixture objective $id."
            $lessonNumbers=if($id -eq 6){if($week -eq 3){@(1)}else{@(2)}}else{@(1,2,3)}
            foreach($lesson in $lessonNumbers){ "$id.$lesson Explain fixture lesson $id.$lesson." }
        }
    }
    $path=Join-Path $fixture "QA1015 $variant.txt"
    $text=$lines -join "`n"
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
    $course=Import-CourseSpec $path
    Check ($course.weeks.Count -eq 5) "$variant did not produce five weeks."
    Check ($course.description -notmatch 'argumentation|critical thinking') 'Missing description invented an unrelated course domain.'
    $modules=@($course.weeks | ForEach-Object { $_.modules })
    Check ($modules.Count -eq 8 -and @($modules | ForEach-Object { $_.subObjectives }).Count -eq 20) "$variant lost objective assignments."
    Check (($course.weeks[2].modules.objectiveId -join ',') -eq '3,6' -and ($course.weeks[4].modules.objectiveId -join ',') -eq '6,7') "$variant moved objective 6."
    Check ($course.weeks[2].modules[1].subObjectives[0] -eq 'Explain fixture lesson 6.1.' -and $course.weeks[4].modules[0].subObjectives[0] -eq 'Explain fixture lesson 6.2.') "$variant merged lesson assignments across weeks."
    Check (@(ConvertFrom-EbookReadingList $text -Origin Blueprint).Count -eq 0) "$variant objectives were treated as readings."
    $plan=New-EbookPlan $course
    Check ($plan.chapters.Count -eq 5) "$variant changed chapter count while planning."
}

# Exercise the labeled spec-sheet parser as well as the filename fallback.
$spec="Course Number`nQA1015`nCourse Name`nFixture Course`nCourse Description`nFixture weekly learning.`n" + $text
$specPath=Join-Path $fixture 'spec.txt'
Set-Content -LiteralPath $specPath -Value $spec -Encoding UTF8
$course=Import-CourseSpec $specPath
Check ($course.courseName -eq 'Fixture Course' -and $course.weeks.Count -eq 5) 'Spec-sheet bare headings failed.'

# Full generation must reject absent/misparsed readings before launching AI.
$job=[pscustomobject]@{status='Failed';workflowStage='generation';options=[pscustomobject]@{sourceMode='Assigned';requiredReadings=@();useCodexDrafting=$false;useCodexImages=$false}}
$studio=Get-Module BookStudio
foreach($case in @('missing','legacy-objective')) {
    if($case -eq 'legacy-objective'){$job.options.requiredReadings=@([pscustomobject]@{title='1. Describe a fixture.';url='';origin='Blueprint/designer'})}
    $caught=$false
    try { & $studio {param($j,$r) Assert-BookStudioGenerationReady $j $r} $job $root }
    catch { if($_.Exception.Message -notmatch 'Sources and image setting'){throw};$caught=$true }
    Check $caught "Generation did not reject $case readings early."
}
$job.options.requiredReadings=@([pscustomobject]@{title='Actual reading';url='https://example.org/article'})
& $studio {param($j,$r) Assert-BookStudioGenerationReady $j $r} $job $root
Check $true 'Valid reading assignments pass this configuration gate (retrieval remains a separate check).'
Write-Output "PASS: $script:checks standalone-week, objective assignment, and source-preflight assertions. Fixtures: $fixture"
