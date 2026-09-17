[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DocxPath,
    [Parameter(Mandatory)][string]$PdfPath
)
$ErrorActionPreference = 'Stop'
$docxFull = (Resolve-Path -LiteralPath $DocxPath).ProviderPath
$pdfFull = [IO.Path]::GetFullPath($PdfPath)
$beforeHash = (Get-FileHash -LiteralPath $docxFull -Algorithm SHA256).Hash
$word = $null; $document = $null
try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $word.Options.UpdateLinksAtOpen = $false
    $document = $word.Documents.Open($docxFull, $false, $true, $false)
    $document.Repaginate()
    $headings = New-Object System.Collections.ArrayList
    foreach ($paragraph in $document.Paragraphs) {
        $style = [string]$paragraph.Style.NameLocal
        if ($style -match '^Heading [123]' -or $paragraph.Range.Text -match '^Chapter \d+:') {
            [void]$headings.Add([pscustomobject]@{text=$paragraph.Range.Text.Trim();style=$style;page=$paragraph.Range.Information(3)})
        }
    }
    $document.ExportAsFixedFormat($pdfFull, 17)
    $result = [pscustomobject]@{
        docx = $docxFull; pdf = $pdfFull
        generatedAt = (Get-Date).ToString('s')
        docxSha256 = $beforeHash
        pdfSha256 = (Get-FileHash -LiteralPath $pdfFull -Algorithm SHA256).Hash
        pages = $document.ComputeStatistics(2)
        words = $document.ComputeStatistics(0)
        tables = $document.Tables.Count
        headings = @($headings)
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath ([IO.Path]::ChangeExtension($pdfFull, '.render.json')) -Encoding UTF8
    $result | Select-Object docx,pdf,pages,words,tables
}
finally {
    if ($document) { $document.Close([ref]0); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($document) }
    if ($word) { $word.Quit([ref]0); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($word) }
}
if ((Get-FileHash -LiteralPath $docxFull -Algorithm SHA256).Hash -ne $beforeHash) { throw 'Read-only rendering changed the DOCX.' }
