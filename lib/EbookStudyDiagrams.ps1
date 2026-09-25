# Study diagrams: each chapter's model figure and its quick visual check.
#
# Word prints every figure 6.5 in wide (Get-WordImageExtent), so on the
# 1200-unit canvas one unit prints at 0.39 pt. The first diagrams used 14-18
# unit text, which printed at 5.5-7 pt, and they printed the designer's purpose
# note ("Help students choose ...") under the title as if it were part of the
# figure. A designer asked for larger text and for that sentence to go. Every
# size below is chosen for the printed page: nothing under 26 units (10 pt),
# labels 32 (12.5 pt), titles 40 (15.6 pt). Test-EbookStudyDiagramSvg measures
# any SVG against the same rule.
#
# A diagram is a model (what it says) drawn by a layout (how it looks). The
# model also writes the figure's description, so the alt text and <desc> say
# what the figure shows rather than what the designer meant it to do.
#
# Connectors are separate paths with fill="none". One path holding several
# segments gets a single arrowhead at its very end, and an unfilled L-shaped
# path is filled black by default; both happened in the first version.

$script:StudyDiagramWidth = 1200
$script:StudyDiagramPrintWidthPoints = 468.0
$script:StudyDiagramMinimumPrintPoints = 10.0
$script:StudyDiagramSize = @{ title = 40; label = 32; center = 36; note = 26; minimum = 26; labelMinimum = 28 }
$script:StudyDiagramInk = '#172026'
$script:StudyDiagramMuted = '#52606d'
$script:StudyDiagramFont = 'Arial, Helvetica, sans-serif'
$script:StudyDiagramSealName = 'book-studio-study-diagram v2'
$script:StudyDiagramIssues = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- text

function Get-StudyDiagramTextWidth {
    # Estimated rendered width of one line of Arial. Deliberately a little wide,
    # so text judged to fit does fit.
    param([AllowNull()][string]$Text, [double]$Size, [switch]$Bold)
    $em = 0.0
    foreach ($ch in ([string]$Text).ToCharArray()) {
        $c = [string]$ch
        if ($c -cmatch "[ijl'.,:;!|]") { $em += 0.28 }
        elseif ($c -cmatch '[ ftrI()/-]') { $em += 0.34 }
        elseif ($c -cmatch '[mw]') { $em += 0.86 }
        elseif ($c -cmatch '[MW]') { $em += 0.94 }
        elseif ($c -cmatch '[A-Z]') { $em += 0.72 }
        else { $em += 0.56 }
    }
    if ($Bold) { $em *= 1.1 }
    return $em * $Size
}

function Split-StudyDiagramText {
    # Greedy word wrap by estimated width. A single word wider than the line
    # stays whole on its own line; Get-StudyDiagramTextFit shrinks it first.
    param([AllowNull()][string]$Text, [double]$Size, [double]$MaxWidth, [switch]$Bold)
    $lines = New-Object System.Collections.ArrayList
    $current = ''
    foreach ($word in @(([string]$Text) -split '\s+' | Where-Object { $_ })) {
        $candidate = if ($current) { "$current $word" } else { $word }
        if (-not $current -or (Get-StudyDiagramTextWidth -Text $candidate -Size $Size -Bold:$Bold) -le $MaxWidth) {
            $current = $candidate
            continue
        }
        [void]$lines.Add($current)
        $current = $word
    }
    if ($current) { [void]$lines.Add($current) }
    return ,([string[]]$lines.ToArray())
}

function Get-StudyDiagramTextFit {
    # The largest size from Size down to MinimumSize at which the text wraps
    # into at most MaxLines lines, each narrower than MaxWidth. When nothing
    # fits, the minimum size is used and the overflow is recorded; the
    # regression suite treats that as a defect in the diagram's wording.
    param(
        [AllowNull()][string]$Text,
        [double]$Size,
        [double]$MaxWidth,
        [int]$MaxLines = 2,
        [double]$MinimumSize = 0,
        [switch]$Bold
    )
    if ($MinimumSize -le 0) { $MinimumSize = $script:StudyDiagramSize.minimum }
    if ($MinimumSize -gt $Size) { $MinimumSize = $Size }
    $s = $Size
    while ($true) {
        $lines = Split-StudyDiagramText -Text $Text -Size $s -MaxWidth $MaxWidth -Bold:$Bold
        $widest = 0.0
        foreach ($line in $lines) {
            $w = Get-StudyDiagramTextWidth -Text $line -Size $s -Bold:$Bold
            if ($w -gt $widest) { $widest = $w }
        }
        $fits = ($lines.Count -le $MaxLines) -and ($widest -le $MaxWidth)
        if ($fits -or $s -le $MinimumSize) {
            if (-not $fits) { [void]$script:StudyDiagramIssues.Add("'$Text' does not fit in $([int]$MaxWidth) units on $MaxLines line(s) at $s units.") }
            return [pscustomobject]@{ size = $s; lines = $lines; lineHeight = [Math]::Round($s * 1.22); overflow = -not $fits }
        }
        $s = [Math]::Max($MinimumSize, $s - 2)
    }
}

function New-StudyDiagramTextSvg {
    # One <text> element per line. Plain lines rather than <tspan> keep the
    # figure inside what Word's SVG renderer draws reliably. Y is the first
    # baseline.
    param(
        [string[]]$Lines,
        [double]$X,
        [double]$Y,
        [double]$Size,
        [double]$LineHeight = 0,
        [string]$Fill = '',
        [string]$Anchor = 'middle',
        [switch]$Bold
    )
    if (-not $Fill) { $Fill = $script:StudyDiagramInk }
    if ($LineHeight -le 0) { $LineHeight = [Math]::Round($Size * 1.22) }
    $weight = if ($Bold) { ' font-weight="700"' } else { '' }
    $out = New-Object System.Collections.ArrayList
    # PowerShell names ignore case: a loop variable called $y would overwrite
    # the $Y parameter and push every later line further down.
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $baseline = [Math]::Round($Y + $i * $LineHeight)
        [void]$out.Add("<text x=""$([Math]::Round($X))"" y=""$baseline"" text-anchor=""$Anchor"" font-size=""$Size""$weight fill=""$Fill"">$(ConvertTo-SvgText $Lines[$i])</text>")
    }
    return ($out -join "`r`n")
}

function Get-StudyDiagramBlockHeight {
    param([object]$Heading, [object]$Note, [double]$Gap = 10)
    $height = $Heading.lines.Count * $Heading.lineHeight
    if ($Note -and $Note.lines.Count) { $height += $Gap + $Note.lines.Count * $Note.lineHeight }
    return $height
}

function New-StudyDiagramBlockSvg {
    # A heading and an optional note, centred on CenterX and vertically centred
    # in the band from Top to Top + Height.
    param([object]$Heading, [object]$Note, [double]$CenterX, [double]$Top, [double]$Height, [string]$HeadingFill = '', [string]$NoteFill = '', [double]$Gap = 10)
    if (-not $HeadingFill) { $HeadingFill = $script:StudyDiagramInk }
    if (-not $NoteFill) { $NoteFill = $script:StudyDiagramMuted }
    $block = Get-StudyDiagramBlockHeight -Heading $Heading -Note $Note -Gap $Gap
    $lineTop = $Top + ($Height - $block) / 2
    # A line's baseline sits below its top by half the line height plus half the cap height.
    $baseline = $lineTop + ($Heading.lineHeight + 0.72 * $Heading.size) / 2
    $parts = @(New-StudyDiagramTextSvg -Lines $Heading.lines -X $CenterX -Y $baseline -Size $Heading.size -LineHeight $Heading.lineHeight -Fill $HeadingFill -Bold)
    if ($Note -and $Note.lines.Count) {
        $noteTop = $lineTop + $Heading.lines.Count * $Heading.lineHeight + $Gap
        $noteBaseline = $noteTop + ($Note.lineHeight + 0.72 * $Note.size) / 2
        $parts += New-StudyDiagramTextSvg -Lines $Note.lines -X $CenterX -Y $noteBaseline -Size $Note.size -LineHeight $Note.lineHeight -Fill $NoteFill
    }
    return ($parts -join "`r`n")
}

function Get-StudyDiagramBoxText {
    # Fits a box's heading and note to its inner width.
    param([string]$Heading, [string]$Note = '', [double]$InnerWidth, [double]$HeadingSize = 0, [int]$HeadingLines = 2, [int]$NoteLines = 3)
    if ($HeadingSize -le 0) { $HeadingSize = $script:StudyDiagramSize.label }
    $headingFit = Get-StudyDiagramTextFit -Text $Heading -Size $HeadingSize -MaxWidth $InnerWidth -MaxLines $HeadingLines -MinimumSize ([Math]::Min($HeadingSize, $script:StudyDiagramSize.labelMinimum)) -Bold
    $noteFit = $null
    if ($Note) { $noteFit = Get-StudyDiagramTextFit -Text $Note -Size $script:StudyDiagramSize.note -MaxWidth $InnerWidth -MaxLines $NoteLines }
    return [pscustomobject]@{ heading = $headingFit; note = $noteFit; height = (Get-StudyDiagramBlockHeight -Heading $headingFit -Note $noteFit) }
}

function New-StudyDiagramRectSvg {
    param([double]$X, [double]$Y, [double]$Width, [double]$Height, [string]$Fill = '#ffffff', [string]$Stroke = '#71828a', [double]$StrokeWidth = 3, [double]$Radius = 14)
    return "<rect x=""$([Math]::Round($X))"" y=""$([Math]::Round($Y))"" width=""$([Math]::Round($Width))"" height=""$([Math]::Round($Height))"" rx=""$Radius"" fill=""$Fill"" stroke=""$Stroke"" stroke-width=""$StrokeWidth""/>"
}

function New-StudyDiagramLineSvg {
    # A connector. Always its own path, always unfilled; -Arrow adds one
    # arrowhead at the end.
    param([string]$Data, [switch]$Arrow, [double]$StrokeWidth = 4, [string]$Stroke = '')
    if (-not $Stroke) { $Stroke = $script:StudyDiagramInk }
    $marker = if ($Arrow) { ' marker-end="url(#arrow)"' } else { '' }
    return "<path d=""$Data"" fill=""none"" stroke=""$Stroke"" stroke-width=""$StrokeWidth"" stroke-linejoin=""round""$marker/>"
}

# ---------------------------------------------------------------- document

function Get-StudyDiagramSealHash {
    param([string]$Svg)
    $body = (($Svg -replace "\r\n", "`n") -split "`n" | Where-Object { $_ -notmatch '^<!-- book-studio-study-diagram ' }) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($body)) } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Add-StudyDiagramSeal {
    # Marks a file as the generator's own drawing. Rebuild Package redraws a
    # sealed file only while the seal still matches, so an edited diagram is
    # never overwritten.
    param([string]$Svg)
    $hash = Get-StudyDiagramSealHash -Svg $Svg
    $lines = @($Svg -split "\r\n")
    return (@($lines[0], "<!-- $($script:StudyDiagramSealName) sha256:$hash -->") + $lines[1..($lines.Count - 1)]) -join "`r`n"
}

function Test-StudyDiagramSeal {
    # $true when the file carries a seal and has not changed since it was drawn.
    param([AllowNull()][string]$Svg)
    $match = [regex]::Match([string]$Svg, '<!-- book-studio-study-diagram v\d+ sha256:([0-9a-f]{64}) -->')
    if (-not $match.Success) { return $false }
    return $match.Groups[1].Value -eq (Get-StudyDiagramSealHash -Svg $Svg)
}

function New-StudyDiagramDocument {
    # The frame shared by every study diagram: the figure title (no subtitle),
    # a description for screen readers, the arrowhead, and the body shifted
    # below the title.
    param([string]$Title, [string]$Description, [double]$BodyHeight, [string]$Body)
    $width = $script:StudyDiagramWidth
    $titleFit = Get-StudyDiagramTextFit -Text $Title -Size $script:StudyDiagramSize.title -MaxWidth ($width - 120) -MaxLines 2 -MinimumSize 34 -Bold
    $titleTop = 44
    $titleBaseline = $titleTop + $titleFit.size * 0.8
    $bodyTop = [Math]::Round($titleTop + $titleFit.lines.Count * $titleFit.lineHeight + 40)
    $height = [Math]::Round($bodyTop + $BodyHeight + 40)
    $svg = @(
        "<svg xmlns=""http://www.w3.org/2000/svg"" width=""$width"" height=""$height"" viewBox=""0 0 $width $height"" role=""img"" aria-labelledby=""title desc"">",
        "<title id=""title"">$(ConvertTo-SvgText $Title)</title>",
        "<desc id=""desc"">$(ConvertTo-SvgText $Description)</desc>",
        "<defs><marker id=""arrow"" markerWidth=""6"" markerHeight=""6"" refX=""6"" refY=""3"" orient=""auto""><path d=""M0,0 L6,3 L0,6 z"" fill=""$($script:StudyDiagramInk)""/></marker></defs>",
        "<rect width=""$width"" height=""$height"" fill=""#ffffff""/>",
        "<g font-family=""$($script:StudyDiagramFont)"">",
        (New-StudyDiagramTextSvg -Lines $titleFit.lines -X 60 -Y $titleBaseline -Size $titleFit.size -LineHeight $titleFit.lineHeight -Anchor 'start' -Bold),
        "<g transform=""translate(0,$bodyTop)"">",
        $Body,
        "</g>",
        "</g>",
        "</svg>"
    ) -join "`r`n"
    return Add-StudyDiagramSeal -Svg $svg
}

# ---------------------------------------------------------------- models

function New-StudyDiagramStep {
    param([string]$Label, [string]$Note = '')
    return [pscustomobject]@{ label = $Label; note = $Note }
}

function Get-StudyDiagramModel {
    # What each catalog diagram says. The title decides the model, exactly as
    # it decided the drawing before; Get-EngagementVisualSpec holds the titles.
    param([string]$Title)

    if ($Title -match "Windows Workspace|File Organization|Word Document|APA Source|Secure Digital") {
        $labels = @('Open', 'Navigate', 'Adjust', 'Verify'); $center = 'Windows Task'
        if ($Title -match "File Organization") { $labels = @('Name', 'Folder', 'Sync', 'Share'); $center = 'Findable Files' }
        elseif ($Title -match "Word Document") { $labels = @('Layout', 'Styles', 'Structure', 'Review'); $center = 'Readable Document' }
        elseif ($Title -match "APA Source") { $labels = @('Evaluate', 'Use', 'Cite', 'Check'); $center = 'Academic Support' }
        elseif ($Title -match "Secure Digital") { $labels = @('Protect', 'Think', 'Type', 'Finish'); $center = 'Secure Work' }
        $notes = @('choose the tool', 'follow the standard', 'check the result', 'finish cleanly')
        $steps = for ($i = 0; $i -lt 4; $i++) { New-StudyDiagramStep -Label $labels[$i] -Note $notes[$i] }
        return [pscustomobject]@{ layout = 'steps'; steps = @($steps); outcome = (New-StudyDiagramStep -Label $center -Note 'complete, review, save, and explain'); outcomeStyle = 'result' }
    }

    if ($Title -match "Critical Thinking|Intellectual Standards|Problem-Solving|Decision Review|Argument Test|Ethical Argument") {
        $labels = @('Question', 'Evidence', 'Assumptions', 'Conclusion'); $center = 'Reasoned Judgment'
        if ($Title -match "Intellectual Standards") { $labels = @('Clarity', 'Accuracy', 'Relevance', 'Sufficiency'); $center = 'Trustworthy Support' }
        elseif ($Title -match "Problem-Solving") { $labels = @('Issue', 'Constraints', 'Alternatives', 'Justification'); $center = 'Defensible Solution' }
        elseif ($Title -match "Decision Review") { $labels = @('Evidence', 'Bias', 'Pressure', 'Fallacy Check'); $center = 'Decision Quality' }
        elseif ($Title -match "Argument Test") { $labels = @('Premises', 'Support', 'Inference', 'Conclusion'); $center = 'Argument Strength' }
        elseif ($Title -match "Ethical Argument") { $labels = @('Issue', 'Values', 'Stakeholders', 'Response'); $center = 'Ethical Position' }
        $steps = foreach ($label in $labels) { New-StudyDiagramStep -Label $label }
        return [pscustomobject]@{ layout = 'steps'; steps = @($steps); outcome = (New-StudyDiagramStep -Label $center -Note 'pause, test, revise, and explain'); outcomeStyle = 'result' }
    }

    if ($Title -match "Audience|Message|Difficult|Meeting|Presentation") {
        $labels = @('Audience', 'Purpose', 'Channel', 'Tone', 'Structure', 'Revise'); $center = 'Clear Message'
        if ($Title -match "Listening") { $labels = @('Audience', 'Words', 'Tone', 'Signals', 'Question', 'Response'); $center = 'Shared Meaning' }
        elseif ($Title -match "Difficult|Bad") { $labels = @('Issue', 'Reason', 'Respect', 'Options', 'Next Step', 'Review'); $center = 'Trust' }
        elseif ($Title -match "Meeting") { $labels = @('Purpose', 'Roles', 'Agenda', 'Voices', 'Decisions', 'Follow-up'); $center = 'Team Clarity' }
        elseif ($Title -match "Presentation") { $labels = @('Audience', 'Opening', 'Evidence', 'Visuals', 'Delivery', 'Closing'); $center = 'Memorable Point' }
        $steps = foreach ($label in $labels) { New-StudyDiagramStep -Label $label }
        return [pscustomobject]@{ layout = 'steps'; steps = @($steps); outcome = (New-StudyDiagramStep -Label $center -Note 'easy to understand, trust, and act on'); outcomeStyle = 'result' }
    }

    if ($Title -match "Risk Triangle") {
        return [pscustomobject]@{
            layout = 'triangle'
            corners = @(
                (New-StudyDiagramStep -Label 'People' -Note 'judgment and handoffs'),
                (New-StudyDiagramStep -Label 'Technology' -Note 'records and tools'),
                (New-StudyDiagramStep -Label 'Procedures' -Note 'standards and controls'))
            center = (New-StudyDiagramStep -Label 'Operational Risk' -Note 'appears where one side is weak')
            lookFor = (New-StudyDiagramStep -Label 'Look for' -Note 'missing owners, hidden records, outdated steps')
            improveBy = (New-StudyDiagramStep -Label 'Improve by' -Note 'aligning roles, tools, and repeatable routines')
        }
    }

    if ($Title -match "Cross-Functional") {
        return [pscustomobject]@{
            layout = 'lanes'
            lanes = @(
                [pscustomobject]@{ label = 'Finance'; note = 'budget approval'; risk = 'missing cost details' },
                [pscustomobject]@{ label = 'HR'; note = 'staffing coverage'; risk = 'no owner' },
                [pscustomobject]@{ label = 'Marketing'; note = 'customer message'; risk = 'promise exceeds capacity' },
                [pscustomobject]@{ label = 'Operations'; note = 'service delivery'; risk = 'delayed follow-up' })
        }
    }

    if ($Title -match "Office Process") {
        return [pscustomobject]@{
            layout = 'steps'
            steps = @(
                (New-StudyDiagramStep -Label 'Intake' -Note 'trigger and request'),
                (New-StudyDiagramStep -Label 'Review' -Note 'complete inputs'),
                (New-StudyDiagramStep -Label 'Correct' -Note 'resolve gaps'),
                (New-StudyDiagramStep -Label 'Approve' -Note 'decision point'),
                (New-StudyDiagramStep -Label 'Follow Up' -Note 'close the loop'))
            outcome = (New-StudyDiagramStep -Label 'Risk points' -Note 'unclear owner, missing input, waiting time, rework, no status update')
            outcomeStyle = 'risk'
        }
    }

    if ($Title -match "Decision Tree") {
        return [pscustomobject]@{
            layout = 'tree'
            root = (New-StudyDiagramStep -Label 'Customer request' -Note 'listen, verify, document')
            branches = @(
                (New-StudyDiagramStep -Label 'Urgent?' -Note 'set expectation'),
                (New-StudyDiagramStep -Label 'Enough information?' -Note 'ask, confirm, record'),
                (New-StudyDiagramStep -Label 'Needs escalation?' -Note 'route with context'))
            close = (New-StudyDiagramStep -Label 'Professional close' -Note 'document, explain next step, follow through')
        }
    }

    $cycle = foreach ($label in @('Define', 'Gather', 'Identify', 'Recommend', 'Test', 'Adjust')) { New-StudyDiagramStep -Label $label }
    return [pscustomobject]@{ layout = 'cycle'; steps = @($cycle); center = (New-StudyDiagramStep -Label 'Improvement' -Note 'evidence to action') }
}

function Join-StudyDiagramList {
    param([string[]]$Items)
    if ($Items.Count -le 1) { return ($Items -join '') }
    if ($Items.Count -eq 2) { return "$($Items[0]) and $($Items[1])" }
    return (($Items[0..($Items.Count - 2)]) -join ', ') + ", and $($Items[-1])"
}

function Format-StudyDiagramStep {
    param([object]$Step)
    if ($Step.note) { return "$($Step.label) ($($Step.note))" }
    return [string]$Step.label
}

function Get-StudyDiagramDescription {
    # What the figure shows, in words, for alt text and the SVG <desc>.
    param([object]$Model)
    switch ($Model.layout) {
        'steps' {
            $list = Join-StudyDiagramList -Items @($Model.steps | ForEach-Object { Format-StudyDiagramStep $_ })
            $text = "$($Model.steps.Count) steps in order: $list."
            if ($Model.outcomeStyle -eq 'risk') { return "$text $($Model.outcome.label) to watch: $($Model.outcome.note)." }
            return "$text Together they lead to $($Model.outcome.label): $($Model.outcome.note)."
        }
        'triangle' {
            $corners = Join-StudyDiagramList -Items @($Model.corners | ForEach-Object { Format-StudyDiagramStep $_ })
            return "A triangle with $corners at its corners. $($Model.center.label) sits in the middle and $($Model.center.note). $($Model.lookFor.label): $($Model.lookFor.note). $($Model.improveBy.label): $($Model.improveBy.note)."
        }
        'lanes' {
            $lanes = Join-StudyDiagramList -Items @($Model.lanes | ForEach-Object { "$($_.label) ($($_.note))" })
            $risks = (@($Model.lanes | ForEach-Object { "$($_.label), $($_.risk)" }) -join '; ')
            return "Work is handed across $($Model.lanes.Count) lanes: $lanes. The risk in each lane: $risks."
        }
        'tree' {
            $branches = Join-StudyDiagramList -Items @($Model.branches | ForEach-Object { Format-StudyDiagramStep $_ })
            return "A $(Format-StudyDiagramStep $Model.root) branches into $($Model.branches.Count) questions: $branches. Every branch ends in a $($Model.close.label.ToLowerInvariant()): $($Model.close.note)."
        }
        default {
            $labels = @($Model.steps | ForEach-Object { $_.label })
            return "A cycle of $($labels.Count) steps around $($Model.center.label) ($($Model.center.note)): $(Join-StudyDiagramList -Items $labels), then back to $($labels[0])."
        }
    }
}

# ---------------------------------------------------------------- layouts

function Get-StudyDiagramPalette {
    param([object]$BrandProfile)
    return [pscustomobject]@{
        accent = (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553")
        accent2 = (Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6")
        accent3 = (Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8")
        cta = (Get-BrandColor -BrandProfile $BrandProfile -Name "Journey Green" -Fallback "#15EAC4")
        soft = (Get-BrandColor -BrandProfile $BrandProfile -Name "Gracious Gray" -Fallback "#F9F9F9")
        line = (Get-BrandColor -BrandProfile $BrandProfile -Name "Integrity Gray" -Fallback "#444444")
    }
}

function New-StudyDiagramStepsBody {
    # Steps left to right, wrapping to a second row when there are more than
    # five, then the outcome they lead to (or, for a risk box, what to watch).
    param([object]$Model, [object]$Palette)
    $steps = @($Model.steps)
    $count = $steps.Count
    $perRow = if ($count -le 5) { $count } else { [int][Math]::Ceiling($count / 2) }
    $gap = 48
    $boxWidth = [Math]::Floor((1080 - ($perRow - 1) * $gap) / $perRow)
    $pad = 18
    $texts = @($steps | ForEach-Object { Get-StudyDiagramBoxText -Heading $_.label -Note $_.note -InnerWidth ($boxWidth - 2 * $pad) })
    $boxHeight = [Math]::Max([double]110, (($texts | Measure-Object -Property height -Maximum).Maximum) + 2 * $pad + 8)
    $rowGap = 90
    $rows = [int][Math]::Ceiling($count / $perRow)
    $strokes = @($Palette.accent, $Palette.accent2, $Palette.accent3)
    $parts = New-Object System.Collections.ArrayList
    $centers = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $count; $i++) {
        $row = [Math]::Floor($i / $perRow)
        $col = $i % $perRow
        $x = 60 + $col * ($boxWidth + $gap)
        $y = $row * ($boxHeight + $rowGap)
        $fill = if ($i -eq 0) { $Palette.soft } elseif ($i -eq $count - 1) { '#eef7fb' } else { '#ffffff' }
        [void]$parts.Add((New-StudyDiagramRectSvg -X $x -Y $y -Width $boxWidth -Height $boxHeight -Fill $fill -Stroke $strokes[$i % 3]))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $texts[$i].heading -Note $texts[$i].note -CenterX ($x + $boxWidth / 2) -Top $y -Height $boxHeight))
        [void]$centers.Add([pscustomobject]@{ x = $x; y = $y; cx = $x + $boxWidth / 2; bottom = $y + $boxHeight })
        if ($col -gt 0) {
            $midY = $y + $boxHeight / 2
            [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($x - $gap + 2) $midY H$($x - 2)" -Arrow))
        }
        elseif ($row -gt 0) {
            # Carry the flow from the end of the row above to the start of this one.
            $previous = $centers[$i - 1]
            $midY = $previous.bottom + $rowGap / 2
            [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($previous.cx) $($previous.bottom + 2) V$midY H$($x + $boxWidth / 2) V$($y - 2)" -Arrow))
        }
    }
    $stepsBottom = $rows * $boxHeight + ($rows - 1) * $rowGap

    $isRisk = $Model.outcomeStyle -eq 'risk'
    $outcomeWidth = if ($isRisk) { 760 } else { 600 }
    $outcomeText = Get-StudyDiagramBoxText -Heading $Model.outcome.label -Note $Model.outcome.note -InnerWidth ($outcomeWidth - 2 * 24) -HeadingSize $script:StudyDiagramSize.center -NoteLines 3
    $outcomeHeight = $outcomeText.height + 2 * 24 + 8
    $outcomeX = (1200 - $outcomeWidth) / 2
    $outcomeY = $stepsBottom + 100
    if ($isRisk) {
        [void]$parts.Add((New-StudyDiagramRectSvg -X $outcomeX -Y $outcomeY -Width $outcomeWidth -Height $outcomeHeight -Fill '#f7f0ec' -Stroke $Palette.accent2))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $outcomeText.heading -Note $outcomeText.note -CenterX 600 -Top $outcomeY -Height $outcomeHeight))
    }
    else {
        # Every step feeds the result: a bracket under the last row, then one arrow down.
        $lastRow = @($centers | Select-Object -Last ($count - ($rows - 1) * $perRow))
        $bracketY = $stepsBottom + 44
        foreach ($c in $lastRow) { [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($c.cx) $($c.bottom + 2) V$bracketY")) }
        if ($lastRow.Count -gt 1) { [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($lastRow[0].cx) $bracketY H$($lastRow[-1].cx)")) }
        $joinX = if ($lastRow.Count -gt 1) { 600 } else { $lastRow[0].cx }
        if ($lastRow.Count -gt 1 -and ($lastRow[0].cx -gt 600 -or $lastRow[-1].cx -lt 600)) { $joinX = ($lastRow[0].cx + $lastRow[-1].cx) / 2 }
        [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$joinX $bracketY V$($outcomeY - 2)" -Arrow))
        [void]$parts.Add((New-StudyDiagramRectSvg -X $outcomeX -Y $outcomeY -Width $outcomeWidth -Height $outcomeHeight -Fill $Palette.accent -Stroke $Palette.accent -Radius 16))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $outcomeText.heading -Note $outcomeText.note -CenterX 600 -Top $outcomeY -Height $outcomeHeight -HeadingFill '#ffffff' -NoteFill '#ffffff'))
    }
    return [pscustomobject]@{ svg = ($parts -join "`r`n"); height = $outcomeY + $outcomeHeight }
}

function New-StudyDiagramLanesBody {
    # Functions side by side, the handoff between them, and the risk in each.
    param([object]$Model, [object]$Palette)
    $lanes = @($Model.lanes)
    $gap = 48
    $width = [Math]::Floor((1080 - ($lanes.Count - 1) * $gap) / $lanes.Count)
    $inner = $width - 2 * 18
    $fills = @($Palette.soft, '#f7f0ec', '#eef1f7', '#f4f4ef')
    $strokes = @($Palette.accent, $Palette.accent2, $Palette.accent3, $Palette.cta)
    $top = foreach ($lane in $lanes) { Get-StudyDiagramBoxText -Heading $lane.label -Note $lane.note -InnerWidth $inner -NoteLines 2 }
    $risk = foreach ($lane in $lanes) { Get-StudyDiagramBoxText -Heading 'Risk' -Note $lane.risk -InnerWidth $inner -HeadingSize $script:StudyDiagramSize.note -HeadingLines 1 -NoteLines 3 }
    $topHeight = (($top | Measure-Object -Property height -Maximum).Maximum) + 48
    $riskHeight = (($risk | Measure-Object -Property height -Maximum).Maximum) + 48
    $laneHeight = $topHeight + $riskHeight
    $parts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lanes.Count; $i++) {
        $x = 60 + $i * ($width + $gap)
        $cx = $x + $width / 2
        [void]$parts.Add((New-StudyDiagramRectSvg -X $x -Y 0 -Width $width -Height $laneHeight -Fill $fills[$i % 4] -Stroke $strokes[$i % 4] -Radius 10))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $top[$i].heading -Note $top[$i].note -CenterX $cx -Top 0 -Height $topHeight))
        [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($x + 20) $topHeight H$($x + $width - 20)" -StrokeWidth 2 -Stroke '#b8c2cc'))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $risk[$i].heading -Note $risk[$i].note -CenterX $cx -Top $topHeight -Height $riskHeight -HeadingFill $Palette.accent2 -NoteFill $script:StudyDiagramInk))
        if ($i -gt 0) {
            $y = $topHeight / 2
            [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($x - $gap + 2) $y H$($x - 2)" -Arrow))
        }
    }
    return [pscustomobject]@{ svg = ($parts -join "`r`n"); height = $laneHeight }
}

function New-StudyDiagramTreeBody {
    # One request, three questions, one close.
    param([object]$Model, [object]$Palette)
    $parts = New-Object System.Collections.ArrayList
    $rootWidth = 440; $rootX = 380
    $rootText = Get-StudyDiagramBoxText -Heading $Model.root.label -Note $Model.root.note -InnerWidth ($rootWidth - 48)
    $rootHeight = $rootText.height + 56
    [void]$parts.Add((New-StudyDiagramRectSvg -X $rootX -Y 0 -Width $rootWidth -Height $rootHeight -Fill $Palette.soft -Stroke $Palette.accent))
    [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $rootText.heading -Note $rootText.note -CenterX 600 -Top 0 -Height $rootHeight))

    $branches = @($Model.branches)
    $gap = 60
    $width = [Math]::Floor((1080 - ($branches.Count - 1) * $gap) / $branches.Count)
    $texts = @($branches | ForEach-Object { Get-StudyDiagramBoxText -Heading $_.label -Note $_.note -InnerWidth ($width - 40) })
    $branchHeight = (($texts | Measure-Object -Property height -Maximum).Maximum) + 56
    $busY = $rootHeight + 50
    $branchY = $rootHeight + 100
    $centers = for ($i = 0; $i -lt $branches.Count; $i++) { 60 + $i * ($width + $gap) + $width / 2 }
    [void]$parts.Add((New-StudyDiagramLineSvg -Data "M600 $($rootHeight + 2) V$busY"))
    [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($centers[0]) $busY H$($centers[-1])"))
    for ($i = 0; $i -lt $branches.Count; $i++) {
        $x = 60 + $i * ($width + $gap)
        [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$($centers[$i]) $busY V$($branchY - 2)" -Arrow))
        [void]$parts.Add((New-StudyDiagramRectSvg -X $x -Y $branchY -Width $width -Height $branchHeight))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $texts[$i].heading -Note $texts[$i].note -CenterX $centers[$i] -Top $branchY -Height $branchHeight))
    }

    $closeWidth = 600; $closeX = 300
    $closeText = Get-StudyDiagramBoxText -Heading $Model.close.label -Note $Model.close.note -InnerWidth ($closeWidth - 48) -HeadingSize $script:StudyDiagramSize.center
    $closeHeight = $closeText.height + 56
    $branchBottom = $branchY + $branchHeight
    $closeY = $branchBottom + 90
    $closeMid = $closeY + $closeHeight / 2
    foreach ($cx in $centers) {
        if ($cx -lt $closeX) { [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$cx $($branchBottom + 2) V$closeMid H$($closeX - 2)" -Arrow)) }
        elseif ($cx -gt $closeX + $closeWidth) { [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$cx $($branchBottom + 2) V$closeMid H$($closeX + $closeWidth + 2)" -Arrow)) }
        else { [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$cx $($branchBottom + 2) V$($closeY - 2)" -Arrow)) }
    }
    [void]$parts.Add((New-StudyDiagramRectSvg -X $closeX -Y $closeY -Width $closeWidth -Height $closeHeight -Fill '#eef1f7' -Stroke $Palette.accent3))
    [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $closeText.heading -Note $closeText.note -CenterX 600 -Top $closeY -Height $closeHeight))
    return [pscustomobject]@{ svg = ($parts -join "`r`n"); height = $closeY + $closeHeight }
}

function New-StudyDiagramTriangleBody {
    # Three corners around the risk they share, with what to look for on one
    # side and how to improve on the other.
    param([object]$Model, [object]$Palette)
    $parts = New-Object System.Collections.ArrayList
    $r = 122
    $points = @(@(600, 132), @(300, 600), @(900, 600))
    [void]$parts.Add("<polygon points=""600,132 300,600 900,600"" fill=""$($Palette.soft)"" stroke=""$($Palette.accent)"" stroke-width=""6""/>")
    $strokes = @($Palette.accent, $Palette.accent2, $Palette.accent3)
    for ($i = 0; $i -lt 3; $i++) {
        $cx = $points[$i][0]; $cy = $points[$i][1]
        $corner = $Model.corners[$i]
        $text = Get-StudyDiagramBoxText -Heading $corner.label -Note $corner.note -InnerWidth 200 -HeadingLines 1 -NoteLines 2
        [void]$parts.Add("<circle cx=""$cx"" cy=""$cy"" r=""$r"" fill=""#ffffff"" stroke=""$($strokes[$i])"" stroke-width=""4""/>")
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $text.heading -Note $text.note -CenterX $cx -Top ($cy - $r) -Height (2 * $r)))
    }
    # The triangle is 360 units wide 430 units down, so the centre box starts there.
    $centerText = Get-StudyDiagramBoxText -Heading $Model.center.label -Note $Model.center.note -InnerWidth 300 -HeadingLines 1
    $centerHeight = $centerText.height + 44
    [void]$parts.Add((New-StudyDiagramRectSvg -X 430 -Y 418 -Width 340 -Height $centerHeight -Stroke $Palette.line -StrokeWidth 2 -Radius 10))
    [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $centerText.heading -Note $centerText.note -CenterX 600 -Top 418 -Height $centerHeight))
    foreach ($side in @(@{ x = 60; item = $Model.lookFor }, @{ x = 880; item = $Model.improveBy })) {
        $heading = Get-StudyDiagramTextFit -Text "$($side.item.label):" -Size $script:StudyDiagramSize.label -MaxWidth 260 -MaxLines 1 -Bold
        $note = Get-StudyDiagramTextFit -Text $side.item.note -Size $script:StudyDiagramSize.note -MaxWidth 260 -MaxLines 4
        [void]$parts.Add((New-StudyDiagramTextSvg -Lines $heading.lines -X $side.x -Y 250 -Size $heading.size -Anchor 'start' -Bold))
        [void]$parts.Add((New-StudyDiagramTextSvg -Lines $note.lines -X $side.x -Y 292 -Size $note.size -LineHeight $note.lineHeight -Anchor 'start' -Fill $script:StudyDiagramMuted))
    }
    return [pscustomobject]@{ svg = ($parts -join "`r`n"); height = 600 + $r }
}

function New-StudyDiagramCycleBody {
    # Steps around a centre, each arrow leading to the next and the last back
    # to the first.
    param([object]$Model, [object]$Palette)
    $parts = New-Object System.Collections.ArrayList
    $steps = @($Model.steps)
    $cx = 600; $cy = 330; $rx = 350; $ry = 280
    $pillWidth = 230; $pillHeight = 84
    [void]$parts.Add("<circle cx=""$cx"" cy=""$cy"" r=""150"" fill=""$($Palette.soft)"" stroke=""$($Palette.accent)"" stroke-width=""5""/>")
    $centerText = Get-StudyDiagramBoxText -Heading $Model.center.label -Note $Model.center.note -InnerWidth 250 -HeadingSize $script:StudyDiagramSize.center -NoteLines 2
    [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $centerText.heading -Note $centerText.note -CenterX $cx -Top ($cy - 150) -Height 300))
    $positions = for ($i = 0; $i -lt $steps.Count; $i++) {
        $angle = (-90 + $i * 360 / $steps.Count) * [Math]::PI / 180
        [pscustomobject]@{ x = [Math]::Round($cx + $rx * [Math]::Cos($angle)); y = [Math]::Round($cy + $ry * [Math]::Sin($angle)) }
    }
    # Arrows run between pill edges: leave one pill along the line to the next and stop short of it.
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $from = $positions[$i]; $to = $positions[($i + 1) % $steps.Count]
        $dx = $to.x - $from.x; $dy = $to.y - $from.y
        # Both arguments are doubles on purpose: given an int first, PowerShell
        # picks Math.Min(int, int) and turns 0.2 into 0.
        $exitX = [double]1.0; $exitY = [double]1.0
        if ($dx -ne 0) { $exitX = [double](($pillWidth / 2 + 8) / [Math]::Abs($dx)) }
        if ($dy -ne 0) { $exitY = [double](($pillHeight / 2 + 8) / [Math]::Abs($dy)) }
        $exit = [Math]::Min($exitX, $exitY)
        $x1 = [Math]::Round($from.x + $dx * $exit); $y1 = [Math]::Round($from.y + $dy * $exit)
        $x2 = [Math]::Round($to.x - $dx * $exit); $y2 = [Math]::Round($to.y - $dy * $exit)
        [void]$parts.Add((New-StudyDiagramLineSvg -Data "M$x1 $y1 L$x2 $y2" -Arrow))
    }
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $p = $positions[$i]
        $text = Get-StudyDiagramBoxText -Heading $steps[$i].label -InnerWidth ($pillWidth - 32) -HeadingLines 1
        [void]$parts.Add((New-StudyDiagramRectSvg -X ($p.x - $pillWidth / 2) -Y ($p.y - $pillHeight / 2) -Width $pillWidth -Height $pillHeight -Radius 42))
        [void]$parts.Add((New-StudyDiagramBlockSvg -Heading $text.heading -CenterX $p.x -Top ($p.y - $pillHeight / 2) -Height $pillHeight))
    }
    $bottom = (($positions | Measure-Object -Property y -Maximum).Maximum) + $pillHeight / 2
    return [pscustomobject]@{ svg = ($parts -join "`r`n"); height = $bottom }
}

function ConvertTo-StudyDiagram {
    # Draws one catalog diagram. Returns the SVG, its description, and any text
    # that could not be fitted (which should never happen for catalog wording).
    param([object]$Item, [object]$BrandProfile)
    $script:StudyDiagramIssues = New-Object System.Collections.ArrayList
    $model = Get-StudyDiagramModel -Title ([string]$Item.title)
    $palette = Get-StudyDiagramPalette -BrandProfile $BrandProfile
    $body = switch ($model.layout) {
        'steps' { New-StudyDiagramStepsBody -Model $model -Palette $palette }
        'lanes' { New-StudyDiagramLanesBody -Model $model -Palette $palette }
        'tree' { New-StudyDiagramTreeBody -Model $model -Palette $palette }
        'triangle' { New-StudyDiagramTriangleBody -Model $model -Palette $palette }
        default { New-StudyDiagramCycleBody -Model $model -Palette $palette }
    }
    $description = Get-StudyDiagramDescription -Model $model
    $svg = New-StudyDiagramDocument -Title "Chapter $($Item.chapterNumber): $($Item.title)" -Description $description -BodyHeight $body.height -Body $body.svg
    return [pscustomobject]@{ svg = $svg; description = $description; layout = $model.layout; issues = @($script:StudyDiagramIssues) }
}

function New-VisualAssetSvg {
    param(
        [object]$Item,
        [object]$BrandProfile
    )
    return (ConvertTo-StudyDiagram -Item $Item -BrandProfile $BrandProfile).svg
}

function ConvertTo-QuickVisualCheck {
    # The chapter's quick check: a coloured band with the chapter number, the
    # check's title, and its question. The question is the whole point, so it
    # gets the space the old footer notes used.
    param([object]$Item, [object]$BrandProfile)
    $script:StudyDiagramIssues = New-Object System.Collections.ArrayList
    $accentPalette = @(
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6")
    )
    $accent = $accentPalette[([Math]::Max(1, [int]$Item.chapterNumber) - 1) % $accentPalette.Count]
    $textX = 280
    $textWidth = 1200 - $textX - 90
    $title = Get-StudyDiagramTextFit -Text ([string]$Item.quickCheckTitle) -Size $script:StudyDiagramSize.title -MaxWidth $textWidth -MaxLines 2 -MinimumSize 34 -Bold
    $question = Get-StudyDiagramTextFit -Text ([string]$Item.quickCheckText) -Size 30 -MaxWidth $textWidth -MaxLines 7
    $titleBaseline = 54 + 70
    $questionBaseline = $titleBaseline + ($title.lines.Count - 1) * $title.lineHeight + 64
    $panelBottom = [Math]::Max([double]400, $questionBaseline + ($question.lines.Count - 1) * $question.lineHeight + 64)
    $panelHeight = $panelBottom - 54
    $height = $panelBottom + 54
    $bandMid = 54 + $panelHeight / 2
    $chapterLabel = Get-StudyDiagramTextFit -Text "Chapter $($Item.chapterNumber)" -Size 30 -MaxWidth 160 -MaxLines 1 -Bold
    $svg = @(
        "<svg xmlns=""http://www.w3.org/2000/svg"" width=""1200"" height=""$height"" viewBox=""0 0 1200 $height"" role=""img"" aria-labelledby=""title desc"">",
        "<title id=""title"">$(ConvertTo-SvgText $Item.quickCheckTitle)</title>",
        "<desc id=""desc"">$(ConvertTo-SvgText $Item.quickCheckText)</desc>",
        "<rect width=""1200"" height=""$height"" fill=""#ffffff""/>",
        "<g font-family=""$($script:StudyDiagramFont)"">",
        "<rect x=""54"" y=""54"" width=""1092"" height=""$panelHeight"" rx=""16"" fill=""#f7f8fa"" stroke=""#d7dde3"" stroke-width=""2""/>",
        "<rect x=""54"" y=""54"" width=""180"" height=""$panelHeight"" rx=""16"" fill=""$accent""/>",
        "<rect x=""194"" y=""54"" width=""40"" height=""$panelHeight"" fill=""$accent""/>",
        (New-StudyDiagramTextSvg -Lines $chapterLabel.lines -X 144 -Y ($bandMid - 12) -Size $chapterLabel.size -Fill '#ffffff' -Bold),
        (New-StudyDiagramTextSvg -Lines @('CHECK') -X 144 -Y ($bandMid + 34) -Size 34 -Fill '#ffffff' -Bold),
        (New-StudyDiagramTextSvg -Lines $title.lines -X $textX -Y $titleBaseline -Size $title.size -LineHeight $title.lineHeight -Anchor 'start' -Bold),
        (New-StudyDiagramTextSvg -Lines $question.lines -X $textX -Y $questionBaseline -Size $question.size -LineHeight $question.lineHeight -Anchor 'start'),
        "</g>",
        "</svg>"
    ) -join "`r`n"
    return [pscustomobject]@{ svg = (Add-StudyDiagramSeal -Svg $svg); issues = @($script:StudyDiagramIssues) }
}

function New-QuickVisualCheckSvg {
    param(
        [object]$Item,
        [object]$BrandProfile
    )
    return (ConvertTo-QuickVisualCheck -Item $Item -BrandProfile $BrandProfile).svg
}

# ---------------------------------------------------------------- checks

function Test-EbookStudyDiagramSvg {
    # Legibility findings for any SVG figure, whoever drew it: text that prints
    # under 10 pt at the 6.5 in Word width, and connector paths that are not
    # explicitly unfilled (an unfilled L-shaped path is painted black).
    # Returns one message per problem, quoting the text it is about.
    param([AllowNull()][string]$Svg)
    $issues = New-Object System.Collections.ArrayList
    try { $xml = [xml]$Svg } catch { return "The SVG could not be read: $($_.Exception.Message)" }
    $root = $xml.DocumentElement
    $viewWidth = 0.0
    $viewBox = [string]$root.GetAttribute('viewBox')
    if ($viewBox) { $viewWidth = [double](($viewBox -split '[\s,]+')[2]) }
    if ($viewWidth -le 0) { [double]::TryParse(([string]$root.GetAttribute('width') -replace 'px$', ''), [ref]$viewWidth) | Out-Null }
    if ($viewWidth -le 0) { $viewWidth = [double]$script:StudyDiagramWidth }
    $pointsPerUnit = $script:StudyDiagramPrintWidthPoints / $viewWidth
    foreach ($node in @($root.SelectNodes('//*[local-name()="text"]'))) {
        $size = 16.0
        $cursor = $node
        while ($cursor -and $cursor.NodeType -eq 'Element') {
            $value = [string]$cursor.GetAttribute('font-size')
            if ($value) { $size = [double]($value -replace 'px$', ''); break }
            $cursor = $cursor.ParentNode
        }
        $printed = [Math]::Round($size * $pointsPerUnit, 1)
        if ($printed -lt $script:StudyDiagramMinimumPrintPoints) {
            [void]$issues.Add("Text prints at $printed pt, under $($script:StudyDiagramMinimumPrintPoints) pt: '$($node.InnerText.Trim())'.")
        }
    }
    foreach ($node in @($root.SelectNodes('//*[local-name()="path"][not(ancestor::*[local-name()="defs" or local-name()="marker"])]'))) {
        if ([string]$node.GetAttribute('fill') -ne 'none' -and [string]$node.GetAttribute('stroke')) {
            [void]$issues.Add("A connector path is not marked fill=""none"" and may be painted black: '$($node.GetAttribute('d'))'.")
        }
    }
    # Callers collect the messages with @(...); an empty result is no findings.
    return $issues.ToArray()
}

# ---------------------------------------------------------------- rebuild

function Test-StudyDiagramFirstVersion {
    # A diagram drawn by the first version of these templates and never
    # edited: it still prints the plan's purpose note (study aid) or the two
    # stock footer notes (quick check) exactly where that version put them.
    param([AllowNull()][string]$Svg, [object]$Item, [ValidateSet('study', 'quick')][string]$Kind)
    $text = [string]$Svg
    if ($Kind -eq 'study') {
        $purpose = ConvertTo-SvgText ([string]$Item.learnerPurpose)
        if (-not $purpose) { return $false }
        return $text.Contains("<desc id=""desc"">$purpose</desc>") -and $text.Contains("font-size=""18"" fill=""#52606d"">$purpose</text>")
    }
    return $text.Contains('>Pause before moving from concept to action</text>') -and $text.Contains('>Use the question to test the workplace case</text>')
}

function Update-EbookStudyDiagrams {
    # Rebuild Package redraws the study diagrams and quick checks from the
    # engagement plan, so a book made before a drawing fix gets the fix without
    # regenerating. Only the generator's own untouched drawings are redrawn: a
    # sealed file whose seal still matches, or a first-version file that still
    # carries its purpose note. A file changed after generation is kept as it
    # is and reported with its legibility findings. Every replaced file is
    # copied to manuscript-backups first.
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [object]$EngagementPlan,
        [object]$BrandProfile
    )
    $refreshed = New-Object System.Collections.ArrayList
    $kept = New-Object System.Collections.ArrayList
    $backupFolder = $null
    foreach ($item in @($EngagementPlan.items)) {
        if (-not $item) { continue }
        $targets = @()
        if ($item.assetFile) { $targets += [pscustomobject]@{ kind = 'study'; file = [string]$item.assetFile } }
        if ($item.quickCheckFile) { $targets += [pscustomobject]@{ kind = 'quick'; file = [string]$item.quickCheckFile } }
        foreach ($target in $targets) {
            $path = Join-Path $OutputFolder $target.file
            if (-not [System.IO.File]::Exists((ConvertTo-EbookLongPath -Path $path))) { continue }
            $current = [System.IO.File]::ReadAllText((ConvertTo-EbookLongPath -Path $path), [System.Text.Encoding]::UTF8)
            $ours = (Test-StudyDiagramSeal -Svg $current) -or (Test-StudyDiagramFirstVersion -Svg $current -Item $item -Kind $target.kind)
            if (-not $ours) {
                [void]$kept.Add([pscustomobject]@{ file = $target.file; issues = @(Test-EbookStudyDiagramSvg -Svg $current) })
                continue
            }
            $next = if ($target.kind -eq 'study') { New-VisualAssetSvg -Item $item -BrandProfile $BrandProfile } else { New-QuickVisualCheckSvg -Item $item -BrandProfile $BrandProfile }
            if (($current -replace "\r\n", "`n").Trim() -ceq ($next -replace "\r\n", "`n").Trim()) { continue }
            if (-not $backupFolder) {
                $backupFolder = Join-Path $OutputFolder ('manuscript-backups\visuals-before-redraw-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Force -Path $backupFolder | Out-Null
            }
            Copy-Item -LiteralPath $path -Destination (Join-Path $backupFolder ([System.IO.Path]::GetFileName($path))) -Force
            [System.IO.File]::WriteAllText((ConvertTo-EbookLongPath -Path $path), $next, [System.Text.Encoding]::UTF8)
            [void]$refreshed.Add($target.file)
        }
    }
    return [pscustomobject]@{ refreshed = @($refreshed); kept = @($kept); backupFolder = $backupFolder }
}
