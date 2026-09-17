[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib/EbookCodexImages.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ebook-images-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture,(Join-Path $fixture 'generated_images') -Force | Out-Null
$script:checks=0
function Check([bool]$Ok,[string]$Message){ if(-not $Ok){throw $Message};$script:checks++ }
function Reject([scriptblock]$Action,[string]$Pattern){$rejected=$false;try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$rejected=$true};Check $rejected "Expected rejection: $Pattern"}
function SaveJson($Value,$Name){$Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $fixture $Name) -Encoding UTF8}
$items=@(1..2 | ForEach-Object {[pscustomobject]@{chapterNumber=$_;chapterTitle="Chapter $_";openerImageFile="images/chapter-$_-test-opener.png";openerAltText="Test asset $_"}})
SaveJson ([pscustomobject]@{items=$items}) 'engagement-plan.json'
SaveJson ([pscustomobject]@{chapters=@(1..2 | ForEach-Object {[pscustomobject]@{number=$_}})}) 'ebook-plan.json'
Check ((Get-EbookImageProductionReview $fixture).status -eq 'FAIL') 'Absent imagery passed.'
Reject { Resolve-EbookImagePath $fixture 'images/../../outside.png' } 'Invalid'
# These tiny synthetic raster fixtures exercise validation only. They are never
# learner assets or purported production image-service results.
Add-Type -AssemblyName System.Drawing
foreach($n in 1..2){
    $bitmap=New-Object Drawing.Bitmap(1200,450)
    $bitmap.SetPixel($n,$n,[Drawing.Color]::Blue)
    $file=Join-Path $fixture "generated_images/test-$n.png"
    try{$bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
$first=Join-Path $fixture 'generated_images/test-1.png'
$second=Join-Path $fixture 'generated_images/test-2.png'
$null=Register-EbookGeneratedImage $fixture 1 $first 'Synthetic fixture only' 'TEST TOOL RECEIPT test-1.png' -EvidenceKind observed-builtin-tool-result
$review=Get-EbookImageProductionReview $fixture
Check ($review.status -eq 'FAIL' -and $review.generatedCount -eq 1 -and $review.expectedCount -eq 2) 'A partial batch passed.'
Reject { Add-EbookGeneratedOpeners $fixture (Join-Path $fixture 'QA - E-Book.md') } 'incomplete'
$null=Register-EbookGeneratedImage $fixture 2 $second 'Synthetic fixture only' 'TEST TOOL RECEIPT test-2.png' -EvidenceKind observed-builtin-tool-result
Check ((Get-EbookImageProductionReview $fixture).status -eq 'PASS') 'Complete, internally consistent test receipts did not pass.'
Check ((Get-EbookImageExportReview $fixture).status -eq 'FAIL') 'Missing actual deliverables passed.'
$manifestPath=Join-Path $fixture 'image-production.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$originalManifest=$manifest | ConvertTo-Json -Depth 20
$manifest.images[1].provider='local-clean-illustration'; SaveJson $manifest 'image-production.json'
Check ((Get-EbookImageProductionReview $fixture).status -eq 'FAIL') 'Local fallback provider passed.'
$originalManifest | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$target=Resolve-EbookImagePath $fixture $items[1].openerImageFile
Copy-Item -LiteralPath $first -Destination $target -Force
Check ((Get-EbookImageProductionReview $fixture).status -eq 'FAIL') 'Changed image passed an old receipt.'
Copy-Item -LiteralPath $second -Destination $target -Force
$receipt=Join-Path $fixture $manifest.images[0].receiptFile
'tampered' | Set-Content -LiteralPath $receipt
Check ((Get-EbookImageProductionReview $fixture).status -eq 'FAIL') 'Tampered receipt passed.'
$null=Register-EbookGeneratedImage $fixture 1 $first 'Synthetic fixture only' 'TEST TOOL RECEIPT test-1.png' -EvidenceKind observed-builtin-tool-result
$null=Register-EbookGeneratedImage $fixture 2 $first 'Synthetic fixture only' 'TEST TOOL RECEIPT test-1.png' -EvidenceKind observed-builtin-tool-result
Check ((Get-EbookImageProductionReview $fixture).status -eq 'FAIL') 'Duplicate artwork passed.'
$null=Register-EbookGeneratedImage $fixture 2 $second 'Synthetic fixture only' 'TEST TOOL RECEIPT test-2.png' -EvidenceKind observed-builtin-tool-result
$events=Join-Path $fixture 'events.jsonl'
'{"type":"item.completed","item":{"type":"agent_message","text":"Generated test-1.png"}}' | Set-Content -LiteralPath $events
Check (-not (Find-EbookImageToolEvidence $events $first)) 'An assistant claim counted as tool evidence.'
'{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"Generated test-1.png","status":"completed"}}' | Set-Content -LiteralPath $events
Check (-not (Find-EbookImageToolEvidence $events $first)) 'A shell result counted as image-tool evidence.'
'{"type":"item.completed","item":{"type":"mcp_tool_call","tool":"image_gen__imagegen","result":"test-1.png","status":"completed"}}' | Set-Content -LiteralPath $events
Check ([bool](Find-EbookImageToolEvidence $events $first)) 'A completed image-tool event was rejected.'
'{"type":"item.completed","item":{"type":"mcp_tool_call","tool":"image_gen__imagegen","result":"test-1.png","status":"failed"}}' | Set-Content -LiteralPath $events
Check (-not (Find-EbookImageToolEvidence $events $first)) 'A failed image-tool event passed.'
$rollout=Join-Path $fixture 'rollout.jsonl'
$records=@(
    @{type='response_item';payload=@{type='custom_tool_call';name='exec';call_id='image';input='const r = await tools.image_gen__imagegen({prompt:"test"}); generatedImage(r);'}},
    @{type='response_item';payload=@{type='custom_tool_call_output';call_id='image';output='Script running with cell ID 7'}},
    @{type='response_item';payload=@{type='function_call';name='wait';call_id='wait7';arguments='{"cell_id":"7"}'}},
    @{type='response_item';payload=@{type='function_call_output';call_id='wait7';output=@(@{type='input_text';text='Generated images are saved to test-1.png'})}}
)
$records | ForEach-Object {$_ | ConvertTo-Json -Depth 10 -Compress} | Set-Content -LiteralPath $rollout
Check ([bool](Find-EbookRolloutImageEvidence $rollout $first 'test-session')) 'Code-mode wait receipt was not linked to image generation.'
Check (-not (Find-EbookRolloutImageEvidence $rollout $second 'test-session')) 'Receipt for another image passed.'
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$generator=Get-Module EbookGenerator
Reject { & $generator {param($f) Assert-EbookChapterOpenerFiles -Markdown '![Missing](images/chapter-1-other-opener.png)' -OutputFolder $f} $fixture } 'Missing planned chapter image'
Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'images/chapter-1-other-opener.png'))) 'A similarly named image was silently substituted.'
$md="# Chapter 1: Chapter 1`n`n## Introduction`n`n# Chapter 2: Chapter 2`n`n## Introduction"
$mdPath=Join-Path $fixture 'QA - E-Book.md';$md | Set-Content -LiteralPath $mdPath -Encoding UTF8
Add-EbookGeneratedOpeners $fixture $mdPath
Add-EbookGeneratedOpeners $fixture $mdPath
$md=Get-Content -LiteralPath $mdPath -Raw
Check (([regex]::Matches($md,'!\[')).Count -eq 2) 'Resume duplicated or omitted image references.'
$html=& $generator {param($m) ConvertTo-SimpleHtmlFromMarkdown -Markdown $m -Title Test} $md
Check ($html.Contains('src="images/chapter-1-test-opener.png"') -and $html.Contains('src="images/chapter-2-test-opener.png"') -and -not $html.Contains('src=""')) 'HTML renderer lost opener URLs through $Matches mutation.'
$html | Set-Content -LiteralPath (Join-Path $fixture 'QA - E-Book.html') -Encoding UTF8
$null=& $generator {param($m,$p,$f) Export-MarkdownToDocx -Markdown $m -Path $p -Title Test -AssetRoot $f} $md (Join-Path $fixture 'QA - E-Book.docx') $fixture
Check ((Get-EbookImageExportReview $fixture).status -eq 'PASS') 'Matching Word/HTML image exports did not pass.'
$html.Replace('images/chapter-1-test-opener.png','') | Set-Content -LiteralPath (Join-Path $fixture 'QA - E-Book.html') -Encoding UTF8
Check ((Get-EbookImageExportReview $fixture).status -eq 'FAIL') 'Broken HTML image URLs passed delivery.'
$html | Set-Content -LiteralPath (Join-Path $fixture 'QA - E-Book.html') -Encoding UTF8
$null=& $generator {param($m,$p,$f) Export-MarkdownToDocx -Markdown $m -Path $p -Title Test -AssetRoot $f} '# Chapter 1: No images' (Join-Path $fixture 'QA - E-Book.docx') $fixture
Check ((Get-EbookImageExportReview $fixture).status -eq 'FAIL') 'Word output without generated images passed delivery.'
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
SaveJson ([pscustomobject]@{status='PASS';readiness=[pscustomobject]@{technicalStatus='PASS'}}) 'ebook-output-audit.json'
$summary=& (Get-Module BookStudio) {param($f) Get-BookStudioQualitySummary -OutputFolder $f} $fixture
Check (-not $summary.draftReadyForReview -and $summary.status -eq 'FAIL') 'App trusted cached PASS despite missing images in Word.'
$source=Get-Content (Join-Path $root 'lib/EbookGenerator.psm1') -Raw
Check ($source -notmatch 'function New-OpenerVisualAssetPngBytes|using clean local fallback|generated-raster-opener|local-clean-illustration') 'Procedural fallback or false generated status remains.'
$index=Get-Content (Join-Path $root 'book-studio/index.html') -Raw
Check ($index -match 'name="useCodexImages" type="checkbox" checked') 'New-book UI default is not real image generation.'
$app=Get-Content (Join-Path $root 'book-studio/app.js') -Raw
Check ($app -match 'useCodexImages.checked = true' -and $app -notmatch 'useCodexImages.checked = false') 'Reset turns images off.'
Write-Output "PASS: $script:checks image production, receipt, partial batch, retry, HTML, and Word checks. Fixtures: $fixture"
