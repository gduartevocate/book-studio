$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# Static checks for the mechanical failures that behaviour tests cannot see,
# because each one produces code that loads and runs and is simply wrong.

# 1. A generator function called from the Book Studio side must be exported.
#    Export-MarkdownToDocx was not, so approving course outcomes recorded a
#    Word-export failure instead of writing the document. Nothing failed
#    loudly; the fallback made it look like a graceful note.
$generator = Get-Content -LiteralPath (Join-Path $root 'lib/EbookGenerator.psm1') -Raw -Encoding UTF8
$defined = @([regex]::Matches($generator, '(?m)^function\s+([A-Za-z]+-[A-Za-z0-9]+)\s*\{') | ForEach-Object { $_.Groups[1].Value })
Check ($defined.Count -gt 100) "The generator function scan found only $($defined.Count) definitions; the pattern is wrong."
$exported = @()
foreach ($line in [regex]::Matches($generator, '(?m)^Export-ModuleMember\s+-Function\s+(.+)$')) {
    $exported += @($line.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
Check ($exported.Count -gt 20) "The export scan found only $($exported.Count) exported names."
$internal = @($defined | Where-Object { $exported -notcontains $_ } | Select-Object -Unique)

# Only the files dot-sourced into BookStudio.psm1 reach the generator through
# the module boundary. Files dot-sourced into the generator itself do not.
$studio = Get-Content -LiteralPath (Join-Path $root 'lib/BookStudio.psm1') -Raw -Encoding UTF8
$studioSide = @([regex]::Matches($studio, "(?m)^\.\s+\(Join-Path \`$PSScriptRoot '([A-Za-z0-9]+\.ps1)'\)") | ForEach-Object { $_.Groups[1].Value })
Check ($studioSide.Count -gt 5) "Only $($studioSide.Count) dot-sourced Book Studio files were found."
$offenders = New-Object System.Collections.ArrayList
foreach ($file in @($studioSide + 'BookStudio.psm1')) {
    $path = Join-Path $root "lib/$file"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    # Reaching an internal function through the module's own scope is the
    # documented way to do it, so those regions are removed before scanning.
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $kept = New-Object System.Text.StringBuilder
    $depth = 0
    foreach ($line in ($text -split "`n")) {
        if ($depth -eq 0 -and $line -match '&\s*\((Get-Module\s+EbookGenerator|\$\w+)\)?\s*\{|&\s*\$(module|ebook|studio)\s*\{') {
            $depth = 1
            $depth += (@([regex]::Matches($line, '\{')).Count - 1) - @([regex]::Matches($line, '\}')).Count
            if ($depth -lt 1) { $depth = 0 }
            continue
        }
        if ($depth -gt 0) {
            $depth += @([regex]::Matches($line, '\{')).Count - @([regex]::Matches($line, '\}')).Count
            if ($depth -lt 0) { $depth = 0 }
            continue
        }
        [void]$kept.AppendLine($line)
    }
    $text = $kept.ToString()
    foreach ($name in $internal) {
        # A call, not a definition or a mention inside a string of prose.
        if ($text -match ("(?m)(^|[\s\(\|\{=])" + [regex]::Escape($name) + "(\s+-[A-Za-z]|\s*\()")) {
            [void]$offenders.Add("$file calls $name, which lib/EbookGenerator.psm1 defines but does not export")
        }
    }
}
Check ($offenders.Count -eq 0) ("A Book Studio file calls an unexported generator function. Add it to Export-ModuleMember. " + ($offenders -join '; '))

# 2. Source files are CRLF, and the generator module carries a UTF-8 BOM.
#    Rewriting either through a tool that normalizes them corrupts the file:
#    dropping the BOM turned its em dashes into mojibake and broke the parse.
$sourceFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'lib') -File -Filter '*.ps*1'
    Get-ChildItem -LiteralPath (Join-Path $root 'tests') -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath (Join-Path $root 'book-studio') -File | Where-Object { $_.Extension -in @('.js', '.html', '.css') }
)
Check ($sourceFiles.Count -gt 30) "Only $($sourceFiles.Count) source files were scanned."
# These four were committed with LF before this check existed. They are left
# alone rather than converted: they build fixture XML and expected text in
# here-strings, so changing their line endings changes what they assert.
$knownLf = @('EbookCodexSandbox.ps1', 'book-studio-path-regressions.ps1', 'codex-sandbox-regressions.ps1', 'course-blueprint-regressions.ps1')
$strayLf = New-Object System.Collections.ArrayList
foreach ($file in $sourceFiles) {
    if ($knownLf -contains $file.Name) { continue }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ne 10) { continue }
        if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } else { $lf++ }
    }
    if ($lf -gt 0) { [void]$strayLf.Add("$($file.Name) has $lf bare LF line ending(s)") }
}
Check ($strayLf.Count -eq 0) ("Source files must keep their CRLF line endings. " + ($strayLf -join '; '))
$generatorBytes = [IO.File]::ReadAllBytes((Join-Path $root 'lib/EbookGenerator.psm1'))
Check ($generatorBytes[0] -eq 0xEF -and $generatorBytes[1] -eq 0xBB -and $generatorBytes[2] -eq 0xBF) 'lib/EbookGenerator.psm1 must keep its UTF-8 BOM; without it the file is re-read in the system codepage and its dashes become mojibake.'

# 3. Every client script the page loads must be served and cache-busted.
#    outcome-analysis.js was published but missing from the server allowlist,
#    so it 404'd and took down the whole book list with it.
$index = Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
$assets = @([regex]::Matches($index, '(?:src|href)="/([A-Za-z0-9\-\.]+\.(?:js|css))(\?v=([^"]*))?"'))
Check ($assets.Count -ge 4) "Only $($assets.Count) client assets were found in index.html."
foreach ($asset in $assets) {
    $name = $asset.Groups[1].Value
    Check (Test-Path -LiteralPath (Join-Path $root "book-studio/$name")) "index.html loads /$name, which does not exist in book-studio/."
    Check ($asset.Groups[2].Success -and $asset.Groups[3].Value) "index.html loads /$name with no ?v= cache-buster, so designers keep the cached copy after an update."
    Check ($studio -match ("\`$path -eq ['`"]/" + [regex]::Escape($name) + "['`"]")) "The server does not serve /$name. Add it to the static file route in lib/BookStudio.psm1, or the page 404s and the client dies at startup."
}

Write-Output "PASS: $checks repository hygiene assertions (module exports across the Book Studio boundary, CRLF and BOM preservation, client assets served and cache-busted)."
