[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputFolder,[Parameter(Mandatory)][string]$CourseCode)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/EbookGenerator.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$module=Get-Module EbookGenerator
function Read-Json([string]$Name){Get-Content -LiteralPath (Join-Path $OutputFolder $Name) -Raw -Encoding UTF8 | ConvertFrom-Json}
$contract=Read-Json 'source-format-contract.json';$plan=Read-Json 'ebook-plan.json';$manifest=Read-Json 'assigned-reading-list.json'
$course=Import-CourseSpec -Path $contract.curriculumAuthority.path
if($CourseCode -ne $course.courseCode -or $CourseCode -ne $plan.courseCode -or $CourseCode -ne $contract.targetCourseCode){throw 'Review target identity mismatch.'}
$mdFile=@(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.md' -File)
if($mdFile.Count -ne 1){throw 'Exactly one learner manuscript is required.'}
$md=Get-Content -LiteralPath $mdFile[0].FullName -Raw -Encoding UTF8
$docx=[IO.Path]::ChangeExtension($mdFile[0].FullName,'.docx');$htmlPath=[IO.Path]::ChangeExtension($mdFile[0].FullName,'.html')
$html=Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Ok,[object]$Detail){$checks.Add([pscustomobject]@{name=$Name;status=$(if($Ok){'PASS'}else{'FAIL'});detail=$Detail})}
function Part([string]$Path,[string]$Name){$zip=[IO.Compression.ZipFile]::OpenRead($Path);try{$reader=[IO.StreamReader]::new($zip.GetEntry($Name).Open());try{return $reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}}
function Normalize([string]$Text){return [regex]::Replace($Text,'\s+',' ').Trim()}
foreach($record in $contract.inputs){Check ('input_unchanged: '+[IO.Path]::GetFileName($record.path)) ((Get-FileHash -LiteralPath $record.path -Algorithm SHA256).Hash -eq $record.sha256) $record.path}
$trace=Test-EbookObjectiveTraceability -Course $course -Plan $plan -Markdown $md
Check 'curriculum_objective_trace' ($trace.status -eq 'PASS') $trace.detail
$assigned=Test-EbookAssignedSourcePackage -Course $course -Plan $plan -Markdown $md -OutputFolder $OutputFolder
Check 'assigned_source_trace' ($assigned.status -eq 'PASS') $assigned.detail
$release=Test-EbookReleaseArtifacts -Course $course -Plan $plan -Markdown $md -HtmlPath $htmlPath -DocxPath $docx -OutputFolder $OutputFolder
Check 'current_release_integrity' ($release.status -eq 'PASS') $release.checks
[xml]$document=Part $docx 'word/document.xml'
$ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
$docText=($document.SelectNodes('//w:p',$ns) | ForEach-Object {($_.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join ''}) -join ' '
$normalizedDoc=Normalize $docText
$missing=@()
foreach($line in ($md -split '\r?\n')){
    if($line -match '^\|' -or $line.Trim().Length -lt 30){continue}
    $plain=[regex]::Replace($line,'\[([^\]]+)\]\([^)]+\)','$1')
    $plain=& $module {param($v) ConvertFrom-MarkdownLineToPlainText $v} $plain
    $plain=$plain -replace '^#{1,4}\s+','' -replace '^\d+\.\s+','' -replace '^-\s+',''
    if(-not $normalizedDoc.Contains((Normalize $plain))){$missing+=$plain}
}
Check 'word_prose_round_trip' ($missing.Count -eq 0) $missing
$missingCells=@()
foreach($line in ($md -split '\r?\n' | Where-Object {$_ -match '^\|' -and $_ -notmatch '^\|\s*:?-+'})){
    foreach($cell in ($line.Trim('|') -split '\|')){
        $plain=[regex]::Replace($cell,'\[([^\]]+)\]\([^)]+\)','$1') -replace '\*\*',''
        if(-not $normalizedDoc.Contains((Normalize $plain))){$missingCells+=$plain}
    }
}
Check 'word_table_text_round_trip' ($missingCells.Count -eq 0) $missingCells
$prohibited='(?i)knowledge checks?|check your reasoning|reflection activit|workplace challenge|chapter summary|think about it|interactive.study|case and (?:a )?face|\[(?:cite|objectives):|</?span\b|\[H\(|\[AJ\d'
Check 'no_prohibited_learner_content' ($md -notmatch $prohibited -and $docText -notmatch $prohibited) 'Actual manuscript and Word text; modeled workplace questions are allowed.'
Check 'html_no_prohibited_visible_content' (([Net.WebUtility]::HtmlDecode(($html -replace '<[^>]+>',' '))) -notmatch $prohibited) 'HTML visible text.'
$chapter=0;$inObjectives=$false;$rendered=@{}
foreach($p in $document.SelectNodes('/w:document/w:body/w:p',$ns)){
    $text=($p.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join ''
    $style=$p.SelectSingleNode('w:pPr/w:pStyle',$ns)
    if($text -match '^Chapter (\d+):'){$chapter=[int]$Matches[1];$rendered[$chapter]=@()}
    if($style -and $style.val -match '^Heading'){$inObjectives=$text -eq 'Learning Objectives';continue}
    if($inObjectives -and $p.SelectSingleNode('w:pPr/w:numPr',$ns)){$rendered[$chapter]+=$text}
}
foreach($week in $course.weeks){
    $n=[int]$week.number
    Check "word_chapter_${n}_exact_objectives" (($rendered[$n] -join '|') -eq ($week.modules.objective -join '|')) $rendered[$n]
    $chapterText=[regex]::Match($md,"(?ms)^# Chapter ${n}:.*?(?=^# Chapter |\z)").Value
    $vocabulary=[regex]::Match($chapterText,'(?ms)^### Vocabulary Review\r?\n(?<body>.*?)(?=^### |^## |\z)').Groups['body'].Value
    Check "chapter_${n}_developed_vocabulary" ([regex]::Matches($vocabulary,'(?m)^- \*\*').Count -ge 6) 'At least six defined terms.'
    $integration=[regex]::Match($chapterText,"(?ms)^## Section $n\.4[^\r\n]*\r?\n(?<body>.*?)(?=^#{2,4} |\z)").Groups['body'].Value
    Check "chapter_${n}_substantive_integration" (((Normalize $integration) -split ' ').Count -ge 65) 'Developed prose before takeaways.'
}
if($contract.PSObject.Properties['curriculumWordSource']) {
    [xml]$original=Part $contract.curriculumWordSource.path 'word/document.xml'
    $sourceNs=[Xml.XmlNamespaceManager]::new($original.NameTable);$sourceNs.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $sourceText=($original.SelectNodes('//w:p',$sourceNs) | ForEach-Object {($_.SelectNodes('.//w:t',$sourceNs) | ForEach-Object InnerText) -join ''}) -join "`n"
    $sourceObjectives=@{}
    foreach($match in [regex]::Matches($sourceText,'(?m)^CO(?<id>\d+)[.:]\s*\r?\n(?<text>[^\r\n]+)')) { $sourceObjectives['CO'+$match.Groups['id'].Value]=$match.Groups['text'].Value.Trim() }
    Check 'original_word_objectives_extracted' ($sourceObjectives.Count -eq @($course.weeks.modules).Count) 'Independent check against the supplied source Word document, not only the derived text spec.'
    foreach($week in $course.weeks) {
        $expected=@($week.modules | ForEach-Object {$sourceObjectives[$_.objectiveId]})
        Check "original_word_chapter_$($week.number)_objectives" (($expected -join '|') -ceq ($rendered[[int]$week.number] -join '|')) $expected
    }
}
# Reconstruct visible Word text with heading boundaries for a separate style
# review. Table text and objective wording remain included; notes are excluded
# by the same documented prose policy as the authoring check.
$wordMarkdown=($document.SelectNodes('//w:p',$ns) | ForEach-Object {
    $text=($_.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join ''
    $style=$_.SelectSingleNode('w:pPr/w:pStyle/@w:val',$ns)
    if($style -and $style.Value -match '^Heading([1-6])$'){ ('#' * [int]$Matches[1])+' '+$text } else { $text }
}) -join "`n"
foreach($chapterMatch in [regex]::Matches($wordMarkdown,'(?ms)^# Chapter (\d+):.*?(?=^# Chapter |\z)')) {
    $number=[regex]::Match($chapterMatch.Value,'^# Chapter (\d+):').Groups[1].Value
    $style=& $module {param($text) $plain=Get-PlainTextForStyleGuideCheck $text; $r=Get-ReadabilityMetrics $plain; $rate=[Math]::Round(1000 * @(Get-PassiveVoiceMatches $plain).Count / [Math]::Max(1,$r.wordCount),1); Test-EbookEditorialThresholds -Grade $r.fleschKincaidGrade -PassiveRate $rate} $chapterMatch.Value
    Check "word_chapter_${number}_editorial_thresholds" ($style.status -eq 'PASS') $style.detail
}
$tables=@($document.SelectNodes('//w:tbl',$ns))
Check 'matching_word_html_tables' ($tables.Count -gt 0 -and $tables.Count -eq [regex]::Matches($html,'<table>').Count) "$($tables.Count) tables"
foreach($table in $tables){Check 'table_grid_and_wrapping_styles' ($null -ne $table.SelectSingleNode('w:tblGrid',$ns) -and @($table.SelectNodes('.//w:tc/w:p[not(w:pPr/w:pStyle/@w:val="TableText")]',$ns)).Count -eq 0) 'Fixed grid and TableText paragraph style.'}
[xml]$rels=Part $docx 'word/_rels/document.xml.rels'
$wordUrls=@($rels.Relationships.Relationship | Where-Object {$_.Type -match '/hyperlink$'} | ForEach-Object {[string]$_.Target} | Sort-Object -Unique)
$expectedUrls=@([regex]::Matches($md,'\]\((https?://[^)]+)\)') | ForEach-Object {$_.Groups[1].Value} | Sort-Object -Unique)
$htmlUrls=@([regex]::Matches($html,'href="(https?://[^"]+)"') | ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)} | Sort-Object -Unique)
Check 'word_source_destinations' (($wordUrls -join '|') -eq ($expectedUrls -join '|')) $wordUrls
Check 'html_source_destinations' (($htmlUrls -join '|') -eq ($expectedUrls -join '|')) $htmlUrls
$render=Read-Json "$CourseCode-review.render.json"
Check 'current_word_render_hash' ((Get-FileHash -LiteralPath $docx -Algorithm SHA256).Hash -eq $render.docxSha256) $render.docxSha256
Check 'current_pdf_render_hash' ((Get-FileHash -LiteralPath $render.pdf -Algorithm SHA256).Hash -eq $render.pdfSha256) $render.pdfSha256
$urlListing=(& pdfinfo -url $render.pdf) -join "`n";if($LASTEXITCODE){throw 'PDF URL inspection failed.'}
$pdfUrls=@([regex]::Matches($urlListing,'https?://[^\s]+') | ForEach-Object Value | Sort-Object -Unique)
Check 'pdf_source_destinations' (($pdfUrls -join '|') -eq ($expectedUrls -join '|')) $pdfUrls
$pdfText=(& pdftotext -layout $render.pdf -) -join "`n";if($LASTEXITCODE){throw 'PDF text extraction failed.'}
$pdfPlain=Normalize $pdfText
Check 'pdf_no_prohibited_content' ($pdfPlain -notmatch $prohibited) 'Actual Word-rendered PDF text.'
Check 'business_case_labels_in_word_and_pdf' ([regex]::Matches($docText,'Business Case:').Count -eq $course.weeks.Count -and [regex]::Matches($pdfPlain,'Business Case:').Count -eq $course.weeks.Count) 'One named Business Case per chapter.'
$notes=@([regex]::Matches($pdfText,'(?ms)^[ \t]*Scholarly Sources[ \t]*\r?\n(?<body>.*?)(?=^[ \t]*Chapter \d+:|\z)'))
Check 'pdf_has_all_chapter_bibliographies' ($notes.Count -eq $course.weeks.Count) $notes.Count
for($i=0;$i -lt $course.weeks.Count;$i++){
    $numbers=if($i -lt $notes.Count){@([regex]::Matches($notes[$i].Groups['body'].Value,'(?m)^[ \t]*(\d+)\.[ \t]+') | ForEach-Object {$_.Groups[1].Value})}else{@()}
    $expected=@(1..$manifest.weeks[$i].sectionIds.Count)
    Check "pdf_chapter_$($i+1)_note_numbering" (($numbers -join ',') -eq ($expected -join ',')) $numbers
    $pdfChapter=[regex]::Match($pdfText,"(?ms)^[ \t]*Chapter $($i+1):.*?(?=^[ \t]*Chapter \d+:|\z)").Value
    $obj=[regex]::Match($pdfChapter,'(?s)Learning Objectives\s*(?<body>.*?)Section \d+\.1').Groups['body'].Value
    $numbers=@([regex]::Matches($obj,'(?m)^[ \t]*(\d+)\.[ \t]+') | ForEach-Object {$_.Groups[1].Value})
    Check "pdf_chapter_$($i+1)_objective_numbering" (($numbers -join ',') -eq (@(1..$course.weeks[$i].modules.Count) -join ',')) $numbers
}
$policy=& $module { Get-EbookEditorialPolicy }
$report=[pscustomobject]@{courseCode=$CourseCode;generatedAt=(Get-Date).ToString('s');editorialPolicyVersion=$policy.version;status=$(if(@($checks | Where-Object status -eq 'FAIL').Count){'FAIL'}else{'PASS'});checks=@($checks);docxSha256=$render.docxSha256;pdfSha256=$render.pdfSha256;visualReviewRequired=$true;limitation='Mechanical artifact/traceability checks. Page images and academic/rights review remain separate.'}
$report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputFolder 'independent-publication-review.json') -Encoding UTF8
$report | Select-Object status,@{n='checks';e={$_.checks.Count}}
if($report.status -ne 'PASS'){$checks | Where-Object status -eq 'FAIL' | Format-List;throw 'Independent publication review failed.'}
