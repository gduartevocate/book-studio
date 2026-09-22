$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# The sign-in rules live in the worker, which is JavaScript, so they are driven
# in Node against a fake KV rather than described in PowerShell. Nothing here
# reaches the real cloud: the point is that a password, a session and a lockout
# behave correctly before anything is deployed.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'node is required to run the worker sign-in tests.' }

$harness = Join-Path $PSScriptRoot 'cloud-worker-auth.mjs'
$worker = Join-Path $root 'cloudflare/ebook-generator-worker.js'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('worker-auth-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$stdout = Join-Path $scratch 'out.txt'
$stderr = Join-Path $scratch 'err.txt'
# Redirected to files rather than piped: PowerShell 5.1 wraps a native
# program's stderr in error records, which buries the one line that says what
# actually failed.
$process = Start-Process -FilePath $node.Source -ArgumentList @("`"$harness`"", "`"$worker`"") -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (-not $process.WaitForExit(120000)) { $process.Kill(); throw "The worker sign-in tests did not finish within two minutes. Output: $scratch" }
$out = (Get-Content -LiteralPath $stdout -Raw -Encoding UTF8) + ''
$err = (Get-Content -LiteralPath $stderr -Raw -Encoding UTF8) + ''
if ($out -notmatch '(?m)^PASS: \d+ sign-in checks') {
    $reason = ([regex]::Match($err, '(?m)^Error: (.+)$')).Groups[1].Value
    if (-not $reason) { $reason = ($err.Trim() -split "`n" | Select-Object -First 6) -join "`n" }
    throw "FAIL: $reason"
}
Remove-Item -LiteralPath $scratch -Recurse -Force
$out.Trim()
