[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputFolder,[Parameter(Mandatory)][string]$CourseCode,[Parameter(Mandatory)][string]$DestinationPath,[switch]$ReviewDraft,[switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/EbookReadiness.ps1')
$output=[IO.Path]::GetFullPath($OutputFolder)
$destination=[IO.Path]::GetFullPath($DestinationPath)
$releaseRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'releases'))
if ([IO.Path]::GetDirectoryName($destination) -ne $releaseRoot -or [IO.Path]::GetFileName($destination) -notmatch ('^'+[regex]::Escape($CourseCode)+' .+\.docx$')) { throw 'Delivery must be a course-named Word file directly inside this workspace releases folder.' }
if ($ReviewDraft -and [IO.Path]::GetFileName($destination) -notmatch ' - Review Draft v\d+\.docx$') { throw 'A review-only delivery must explicitly use the filename suffix - Review Draft vN.docx.' }
$plan=Get-Content -LiteralPath (Join-Path $output 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.courseCode -ne $CourseCode) { throw 'Delivery course does not match the package.' }
$requirements=@{OutputFolder=$output;CourseCode=$CourseCode;RequireDraftReady=$true}
if(-not $ReviewDraft){$requirements.RequirePublicationReady=$true}
& (Join-Path $PSScriptRoot 'audit-ebook-output.ps1') @requirements
if((Get-EbookPackageQaStatus -OutputFolder $output) -ne 'PASS'){throw 'Current package QA is not PASS.'}
function Read([string]$Name){Get-Content -LiteralPath (Join-Path $output $Name) -Raw -Encoding UTF8 | ConvertFrom-Json}
$docx=@(Get-ChildItem -LiteralPath $output -Filter '* - E-Book.docx' -File)
if($docx.Count -ne 1){throw 'Exactly one learner Word document is required.'}
$pdf=Join-Path $output "$CourseCode-review.pdf"
$docxHash=(Get-FileHash -LiteralPath $docx[0].FullName -Algorithm SHA256).Hash
$pdfHash=(Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
$manifestPath=Join-Path $output 'assigned-reading-list.json'
$manifest=Read 'assigned-reading-list.json'
$urls=@($manifest.sections.url)+@($manifest.resources.url)
# Re-run the full independent suite; a truncated cached PASS is not evidence.
& (Join-Path $PSScriptRoot 'review-assigned-book.ps1') -OutputFolder $output -CourseCode $CourseCode
$evidence=Test-EbookReviewEvidence -Render (Read "$CourseCode-review.render.json") -Independent (Read 'independent-publication-review.json') -Visual (Read 'visual-review.json') -Links (Read 'source-link-review.json') -DocxSha256 $docxHash -PdfSha256 $pdfHash -ManifestSha256 (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ExpectedUrls $urls -CourseCode $CourseCode -ChapterNumbers @($plan.chapters.number)
if($evidence.status -ne 'PASS'){throw $evidence.detail}
if($CheckOnly){Write-Output 'PASS: Delivery requirements satisfied; no file copied.';return}
if(Test-Path -LiteralPath $destination){
    if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $docxHash){throw 'A different file already uses this release name. Use a new version; existing delivery preserved.'}
}else{Copy-Item -LiteralPath $docx[0].FullName -Destination $destination}
if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $docxHash){throw 'Delivery hash does not match the reviewed Word file.'}
[pscustomobject]@{deliveredAt=(Get-Date).ToString('s');courseCode=$CourseCode;destination=$destination;docxSha256=$docxHash;reviewDraft=[bool]$ReviewDraft;publicationApproved=(-not [bool]$ReviewDraft);evidenceStatus=$evidence.status} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'delivery-receipt.json') -Encoding UTF8
Write-Output "Delivered $destination. Review draft: $ReviewDraft."
