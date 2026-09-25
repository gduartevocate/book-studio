$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# Study diagrams nobody could read. Word prints every figure 6.5 in wide, and
# the first templates drew 14-18 unit text on a 1200-unit canvas, which printed
# at 5.5-7 pt. Each figure also printed the designer's purpose note ("Help
# students choose ...") under its title, and the same note became its alt text.
# The decision tree's L-shaped connectors had no fill="none" and were painted
# as black wedges, and a connector path holding several segments got only one
# arrowhead. A designer (Ann Jackson, 2026-09-25) asked for larger text and for
# the sentence to go. Every diagram the catalog can produce is drawn here and
# measured against the printed page, and Rebuild Package must redraw a book's
# untouched diagrams without overwriting one somebody edited.

$module = Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -PassThru -DisableNameChecking

# One focus per branch of Get-EngagementVisualSpec, plus one that matches none.
$focuses = @('critical thinking', 'information evaluation', 'problem solving', 'decision influences and bias', 'inductive and deductive reasoning',
    'ethical reasoning', 'operating system basics', 'file management', 'document creation in microsoft word', 'source evaluation and apa citation',
    'cybersecurity and keyboarding', 'interpersonal listening', 'message planning and tone', 'difficult-message delivery', 'team collaboration and meetings',
    'presentation skills', 'core business functions', 'workflow and process', 'customer service', 'operational improvement', 'healthcare billing terminology')

$drawn = & $module {
    param($Focuses)
    $n = 0
    foreach ($focus in $Focuses) {
        $n++
        $chapter = [pscustomobject]@{ number = (($n - 1) % 5) + 1; title = "Chapter $n"; focus = $focus; learningTargets = @() }
        $visual = Get-EngagementVisualSpec -Chapter $chapter
        $quick = Get-QuickVisualCheckSpec -Chapter $chapter
        $item = [pscustomobject]@{ chapterNumber = $chapter.number; title = $visual.title; learnerPurpose = $visual.learnerPurpose; quickCheckTitle = $quick.title; quickCheckText = $quick.prompt }
        $study = ConvertTo-StudyDiagram -Item $item -BrandProfile $null
        $check = ConvertTo-QuickVisualCheck -Item $item -BrandProfile $null
        $outside = New-Object System.Collections.ArrayList
        foreach ($svg in @($study.svg, $check.svg)) {
            $xml = [xml]$svg
            foreach ($node in @($xml.SelectNodes('//*[local-name()="text"]'))) {
                $size = [double]$node.GetAttribute('font-size')
                $width = Get-StudyDiagramTextWidth -Text $node.InnerText -Size $size -Bold:($node.GetAttribute('font-weight') -eq '700')
                $x = [double]$node.GetAttribute('x')
                $left = switch ($node.GetAttribute('text-anchor')) { 'middle' { $x - $width / 2 } 'end' { $x - $width } default { $x } }
                if ($left -lt 20 -or $left + $width -gt 1180) { [void]$outside.Add($node.InnerText) }
            }
        }
        [pscustomobject]@{
            focus = $focus; title = $visual.title; purpose = $visual.learnerPurpose; layout = $study.layout; description = $study.description
            svg = $study.svg; issues = @($study.issues); legibility = @(Test-EbookStudyDiagramSvg -Svg $study.svg); sealed = (Test-StudyDiagramSeal -Svg $study.svg)
            quickSvg = $check.svg; quickIssues = @($check.issues); quickLegibility = @(Test-EbookStudyDiagramSvg -Svg $check.svg); quickSealed = (Test-StudyDiagramSeal -Svg $check.svg)
            outside = @($outside)
            generated = (New-VisualAssetSvg -Item $item -BrandProfile $null)
        }
    }
} $focuses

Check ($drawn.Count -eq $focuses.Count) "Expected $($focuses.Count) diagrams, drew $($drawn.Count)."
foreach ($d in $drawn) {
    $name = "The '$($d.title)' diagram (focus '$($d.focus)')"
    Check ($d.issues.Count -eq 0) "$name has text that does not fit: $($d.issues -join ' ')"
    Check ($d.legibility.Count -eq 0) "$name is not legible at the printed width: $($d.legibility -join ' ')"
    Check ($d.quickIssues.Count -eq 0) "$name's quick check has text that does not fit: $($d.quickIssues -join ' ')"
    Check ($d.quickLegibility.Count -eq 0) "$name's quick check is not legible at the printed width: $($d.quickLegibility -join ' ')"
    $purpose = [Security.SecurityElement]::Escape($d.purpose)
    Check (-not $d.svg.Contains($purpose)) "$name still prints the designer's purpose note: '$($d.purpose)'."
    Check (-not $d.description.Contains($d.purpose)) "$name's description is the purpose note, not what the figure shows."
    Check ($d.svg.Contains("<desc id=""desc"">$([Security.SecurityElement]::Escape($d.description))</desc>")) "$name's <desc> must be the figure's description."
    Check ($d.description.Length -ge 40) "$name's description is too short to describe anything: '$($d.description)'."
    Check (-not $d.quickSvg.Contains('Pause before moving from concept to action')) "$name's quick check still prints the stock footer notes."
    Check ($d.outside.Count -eq 0) "$name has text running off the canvas: $($d.outside -join ' | ')"
    Check ($d.sealed -and $d.quickSealed) "$name must carry an intact seal so Rebuild Package can tell it from an edited file."
    Check ($d.generated -ceq $d.svg) "${name}: New-VisualAssetSvg must draw exactly what ConvertTo-StudyDiagram draws."
    $xml = [xml]$d.svg
    foreach ($path in @($xml.SelectNodes('//*[local-name()="path"][@marker-end]'))) {
        Check (([regex]::Matches($path.GetAttribute('d'), '[Mm]')).Count -eq 1) "$name has a connector with several segments and one arrowhead: '$($path.GetAttribute('d'))'."
    }
}
# Assert the difference: a single description repeated for every title is the
# same failure as one diagram for every chapter.
$titles = @($drawn | Select-Object -ExpandProperty title -Unique)
$descriptions = @($drawn | Select-Object -ExpandProperty description -Unique)
Check ($descriptions.Count -eq $titles.Count) "Each diagram title must get its own description: $($titles.Count) titles, $($descriptions.Count) descriptions."
$layouts = @($drawn | Select-Object -ExpandProperty layout -Unique)
foreach ($layout in @('steps', 'lanes', 'tree', 'triangle', 'cycle')) { Check ($layouts -contains $layout) "No catalog diagram exercised the '$layout' layout." }

# The measuring rule must catch what the first templates did.
$legacy = @'
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">Customer Service Response Decision Tree</title>
  <desc id="desc">PURPOSE</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">Chapter 4: Customer Service Response Decision Tree</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">PURPOSE</text>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
  <g font-family="Arial, Helvetica, sans-serif" font-size="14">
    <text x="600" y="226" text-anchor="middle" fill="#52606d">listen, verify, document</text>
    <path d="M600 247 V315 M600 315 H275 V355 M600 315 V355 M600 315 H925 V355" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
  </g>
</svg>
'@
$legacyFindings = & $module { param($Svg) @(Test-EbookStudyDiagramSvg -Svg $Svg) } $legacy.Replace('PURPOSE', 'Help students choose a timely response.')
Check (@($legacyFindings | Where-Object { $_ -match "5\.5 pt.*listen, verify, document" }).Count -eq 1) "The legibility check must quote 14-unit text inherited from its group as 5.5 pt: $($legacyFindings -join ' ')"
Check (@($legacyFindings | Where-Object { $_ -match "7 pt.*Help students" }).Count -eq 1) "The legibility check must flag the 18-unit purpose line: $($legacyFindings -join ' ')"
Check (@($legacyFindings | Where-Object { $_ -match 'fill="none".*M600 247' }).Count -eq 1) "The legibility check must flag an unfilled connector path: $($legacyFindings -join ' ')"
Check (@($legacyFindings | Where-Object { $_ -match 'M0,0' }).Count -eq 0) "The arrowhead inside <marker> is a shape, not a connector."

# The engagement plan's alt text says what the figure shows.
$plan = & $module {
    $course = [pscustomobject]@{ courseCode = 'GM1000'; courseName = 'Business Office' }
    $chapters = @(
        [pscustomobject]@{ number = 1; title = 'Customers'; focus = 'customer service'; learningTargets = @('Respond to a customer request.') },
        [pscustomobject]@{ number = 2; title = 'Workflow'; focus = 'workflow and process'; learningTargets = @('Map an office process.') })
    New-EngagementPlan -Course $course -Plan ([pscustomobject]@{ chapters = $chapters }) -BrandProfile $null
}
foreach ($item in @($plan.items)) {
    $expected = & $module { param($Title) Get-StudyDiagramDescription -Model (Get-StudyDiagramModel -Title $Title) } $item.title
    Check ($item.altText -ceq "$($item.title): $expected") "Chapter $($item.chapterNumber) alt text must describe the figure: '$($item.altText)'."
    Check (-not $item.altText.Contains($item.learnerPurpose)) "Chapter $($item.chapterNumber) alt text still reads the purpose note to screen-reader users."
}

# Rebuild Package: redraw the generator's untouched diagrams, keep edited ones.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('study-diagrams-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'visuals') -Force | Out-Null
try {
    $items = @(
        [pscustomobject]@{ chapterNumber = 4; title = 'Customer Service Response Decision Tree'; learnerPurpose = 'Help students choose a timely, accurate, professional response based on urgency, documentation, and escalation needs.'; assetFile = 'visuals/chapter-4-tree.svg'; quickCheckTitle = 'Choose the Next Step'; quickCheckText = 'Decide whether the request is urgent, complete, or needs escalation.'; quickCheckFile = 'visuals/chapter-4-quick.svg' },
        [pscustomobject]@{ chapterNumber = 3; title = 'Office Process Flow From Intake to Follow-Up'; learnerPurpose = 'Make inputs, outputs, roles, and handoffs visible before students build their own process map.'; assetFile = 'visuals/chapter-3-flow.svg'; quickCheckTitle = ''; quickCheckText = ''; quickCheckFile = '' },
        [pscustomobject]@{ chapterNumber = 1; title = 'People, Technology, and Procedures Risk Triangle'; learnerPurpose = 'Show how people, tools, and procedures interact to influence productivity and risk.'; assetFile = 'visuals/chapter-1-triangle.svg'; quickCheckTitle = ''; quickCheckText = ''; quickCheckFile = '' },
        [pscustomobject]@{ chapterNumber = 5; title = 'Evidence-Based Improvement Cycle'; learnerPurpose = 'Guide students from problem evidence to recommendation and measurement.'; assetFile = 'visuals/chapter-5-cycle.svg'; quickCheckTitle = ''; quickCheckText = ''; quickCheckFile = 'visuals/chapter-5-missing.svg' }
    )
    $write = { param($Name, $Text) [IO.File]::WriteAllText((Join-Path $fixture $Name), $Text, [Text.Encoding]::UTF8) }
    # 1. A first-version drawing, never edited: purpose note and stock footer still in place.
    & $write 'visuals/chapter-4-tree.svg' $legacy.Replace('PURPOSE', [Security.SecurityElement]::Escape($items[0].learnerPurpose))
    & $write 'visuals/chapter-4-quick.svg' '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 560"><text x="310" y="448">Pause before moving from concept to action</text><text x="694" y="448">Use the question to test the workplace case</text></svg>'
    # 2. A diagram someone redrew by hand: no seal, no first-version signature.
    $custom = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 760"><text x="60" y="80" font-size="16">Our own process map</text></svg>'
    & $write 'visuals/chapter-3-flow.svg' $custom
    # 3. A sealed drawing that was edited afterwards.
    $sealed = & $module { param($Item) New-VisualAssetSvg -Item $Item -BrandProfile $null } $items[2]
    $edited = $sealed.Replace('>Procedures<', '>Policies<')
    & $write 'visuals/chapter-1-triangle.svg' $edited
    # 4. A sealed drawing that is already current.
    $current = & $module { param($Item) New-VisualAssetSvg -Item $Item -BrandProfile $null } $items[3]
    & $write 'visuals/chapter-5-cycle.svg' $current

    $result = & $module { param($Folder, $Items) Update-EbookStudyDiagrams -OutputFolder $Folder -EngagementPlan ([pscustomobject]@{ items = $Items }) -BrandProfile $null } $fixture $items
    $read = { param($Name) [IO.File]::ReadAllText((Join-Path $fixture $Name), [Text.Encoding]::UTF8) }

    Check (@($result.refreshed) -contains 'visuals/chapter-4-tree.svg') "An untouched first-version study diagram must be redrawn: refreshed $($result.refreshed -join ', ')."
    Check (@($result.refreshed) -contains 'visuals/chapter-4-quick.svg') "An untouched first-version quick check must be redrawn."
    $tree = & $read 'visuals/chapter-4-tree.svg'
    Check (-not $tree.Contains('Help students choose')) 'The redrawn decision tree must not print the purpose note.'
    Check ((& $module { param($Svg) Test-StudyDiagramSeal -Svg $Svg } $tree)) 'The redrawn decision tree must be sealed.'
    Check ((& $module { param($Svg) @(Test-EbookStudyDiagramSvg -Svg $Svg).Count } $tree) -eq 0) 'The redrawn decision tree must be legible.'
    Check ([IO.File]::Exists((Join-Path $result.backupFolder 'chapter-4-tree.svg'))) 'The replaced decision tree must be backed up first.'
    Check ((Get-Content -LiteralPath (Join-Path $result.backupFolder 'chapter-4-tree.svg') -Raw -Encoding UTF8).Contains('Help students choose')) 'The backup must be the file as it was.'

    Check ((& $read 'visuals/chapter-3-flow.svg') -ceq $custom) 'A hand-edited diagram must never be overwritten.'
    Check (@($result.kept | Where-Object { $_.file -eq 'visuals/chapter-3-flow.svg' -and @($_.issues | Where-Object { $_ -match 'Our own process map' }).Count -eq 1 }).Count -eq 1) 'A kept diagram must be reported with its legibility findings, quoting the text.'
    Check ((& $read 'visuals/chapter-1-triangle.svg') -ceq $edited) 'A sealed diagram edited after generation must be kept.'
    Check (@($result.kept | Where-Object { $_.file -eq 'visuals/chapter-1-triangle.svg' }).Count -eq 1) 'The edited sealed diagram must be reported as kept.'
    Check (-not (@($result.refreshed) -contains 'visuals/chapter-5-cycle.svg')) 'A current diagram must not be rewritten.'
    Check (-not [IO.File]::Exists((Join-Path $result.backupFolder 'chapter-5-cycle.svg'))) 'A current diagram must not be backed up.'
    Check (@($result.refreshed).Count -eq 2 -and @($result.kept).Count -eq 2) "Expected 2 redrawn and 2 kept, got $(@($result.refreshed).Count) and $(@($result.kept).Count)."

    $again = & $module { param($Folder, $Items) Update-EbookStudyDiagrams -OutputFolder $Folder -EngagementPlan ([pscustomobject]@{ items = $Items }) -BrandProfile $null } $fixture $items
    Check (@($again.refreshed).Count -eq 0) 'A second rebuild must find nothing left to redraw.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# Both paths draw with the same code: generation through New-VisualAssets, and
# Rebuild Package (which generation also ends in) before Word and HTML.
$generator = Get-Content -LiteralPath (Join-Path $root 'lib/EbookGenerator.psm1') -Raw -Encoding UTF8
$definitions = @(Get-ChildItem -LiteralPath (Join-Path $root 'lib') -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } | ForEach-Object { [regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw), '(?m)^function New-VisualAssetSvg \{').Count } | Measure-Object -Sum).Sum
Check ($definitions -eq 1) "New-VisualAssetSvg must be defined once; found $definitions definitions."
$repairAt = $generator.IndexOf('function Repair-EbookPackageOutputs')
$redrawAt = $generator.IndexOf('Update-EbookStudyDiagrams -OutputFolder $resolvedOutputFolder')
$htmlAt = $generator.IndexOf('$ebookHtml = ConvertTo-SimpleHtmlFromMarkdown -Markdown $markdown -Title "$titlePrefix$CourseName"')
Check ($repairAt -gt 0 -and $redrawAt -gt $repairAt -and $htmlAt -gt $redrawAt) 'Rebuild Package must redraw study diagrams before it exports HTML and Word.'
Check ($generator -match 'svg = New-VisualAssetSvg -Item \$item' -and $generator -match 'svg = New-QuickVisualCheckSvg -Item \$item') 'Generation must draw with the same functions.'

"PASS: $checks study diagram assertions ($($drawn.Count) catalog diagrams and quick checks legible at 6.5 in, no purpose note, described alt text, untouched diagrams redrawn and edited ones kept)."
