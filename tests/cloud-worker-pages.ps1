$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Parses the pages the worker sends to a browser, by asking the worker for them
# rather than by reading its source. A template literal eats one level of
# escaping, so source that looks right can deliver a script that does not parse,
# and a page whose script is dead still serves, still contains every expected
# word, and does nothing at all.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'node is required to run the worker page tests.' }

$harness = Join-Path $PSScriptRoot 'cloud-worker-pages.mjs'
$worker = Join-Path $root 'cloudflare/ebook-generator-worker.js'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('worker-pages-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$stdout = Join-Path $scratch 'out.txt'
$stderr = Join-Path $scratch 'err.txt'
$process = Start-Process -FilePath $node.Source -ArgumentList @("`"$harness`"", "`"$worker`"") -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $process.WaitForExit(120000)) { $process.Kill(); throw "The worker page tests did not finish within two minutes. Output: $scratch" }
$out = (Get-Content -LiteralPath $stdout -Raw -Encoding UTF8) + ''
$err = (Get-Content -LiteralPath $stderr -Raw -Encoding UTF8) + ''
if ($out -notmatch '(?m)^PASS: \d+ page checks') {
    $reason = ([regex]::Match($err, '(?m)^Error: (.+)$')).Groups[1].Value
    if (-not $reason) { $reason = ($err.Trim() -split "`n" | Select-Object -First 6) -join "`n" }
    throw "FAIL: $reason"
}
Remove-Item -LiteralPath $scratch -Recurse -Force
$out.Trim()
