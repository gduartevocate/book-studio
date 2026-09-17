param([Parameter(Mandatory)][string]$PdfPath,[Parameter(Mandatory)][string]$OutputFolder)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$info=pdfinfo $PdfPath
if($LASTEXITCODE -ne 0){throw 'Could not read current PDF page count.'}
$pageMatch=[regex]::Match(($info -join "`n"),'(?m)^Pages:\s+(\d+)')
if(-not $pageMatch.Success){throw 'Current PDF page count is missing.'}
$pageCount=[int]$pageMatch.Groups[1].Value
# A fresh subfolder prevents leftover thumbnails from an older, longer PDF
# from appearing in the new contact sheets. Existing review images are kept.
$renderFolder=Join-Path $OutputFolder ('pages-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $renderFolder | Out-Null
pdftoppm -scale-to 320 -png $PdfPath (Join-Path $renderFolder 'thumb')
if ($LASTEXITCODE -ne 0) { throw 'PDF thumbnail rendering failed.' }
$files = @(Get-ChildItem -LiteralPath $renderFolder -Filter 'thumb-*.png' | Sort-Object Name)
if($files.Count -ne $pageCount){throw 'Rendered thumbnail count does not match the current PDF.'}
$font = New-Object Drawing.Font('Arial',11)
try {
    for ($start=0; $start -lt $files.Count; $start+=16) {
        $canvas=New-Object Drawing.Bitmap(1040,1400)
        $graphics=[Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.Clear([Drawing.Color]::White)
            for ($offset=0; $offset -lt 16 -and $start+$offset -lt $files.Count; $offset++) {
                $x=($offset%4)*260; $y=[int][Math]::Floor($offset/4)*350
                $img=[Drawing.Image]::FromFile($files[$start+$offset].FullName)
                try { $graphics.DrawImage($img,$x,$y+24,247,320) } finally { $img.Dispose() }
                $graphics.DrawString("Page $($start+$offset+1)",$font,[Drawing.Brushes]::Black,[single]($x+10),[single]$y)
            }
            $canvas.Save((Join-Path $OutputFolder "contact-$([int]($start/16)+1).png"),[Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $canvas.Dispose() }
    }
} finally { $font.Dispose() }
[pscustomobject]@{generatedAt=(Get-Date).ToString('s');pdfSha256=(Get-FileHash -LiteralPath $PdfPath -Algorithm SHA256).Hash;pages=$pageCount;thumbnailFolder=$renderFolder;contactSheets=@(1..[int][Math]::Ceiling($pageCount/16) | ForEach-Object {Join-Path $OutputFolder "contact-$_.png"})} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputFolder 'contact-sheet-index.json') -Encoding UTF8
Write-Output "Rendered $($files.Count) current page thumbnails; use contact-sheet-index.json for the current sheets."
