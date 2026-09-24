$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# The cloud worker, the connect screen it serves, and the agent on the
# designer's PC are three separate programs that only meet over HTTP. Nothing
# compiles them together, so a path or a field name that only one of them
# knows about fails in production and nowhere else. Every check here stands for
# a failure that already happened once.

$workerPath = Join-Path $root 'cloudflare/ebook-generator-worker.js'
$worker = Get-Content -LiteralPath $workerPath -Raw -Encoding UTF8
$runner = Get-Content -LiteralPath (Join-Path $root 'cloud-book-runner.ps1') -Raw -Encoding UTF8
$wrangler = Get-Content -LiteralPath (Join-Path $root 'cloudflare/wrangler.toml') -Raw -Encoding UTF8

# 1. The worker must parse. A deployed worker that throws on load answers every
#    request with an error, including the connect screen.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $syntax = & $node --check $workerPath 2>&1
    Check ($LASTEXITCODE -eq 0) "The worker does not parse: $syntax"
} else {
    Write-Warning 'node was not found; the worker syntax check was skipped.'
}

# 2. Every route the agent calls must be one the worker serves. The agent runs
#    unattended, so an unknown path shows up as a job that never starts.
$exact = @([regex]::Matches($worker, 'pathname === "([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$suffixes = @([regex]::Matches($worker, 'getRunnerRouteId\(pathname, "([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Check ($exact.Count -ge 6) "Only $($exact.Count) exact worker routes were found; the scan pattern is wrong."
Check ($suffixes.Count -ge 5) "Only $($suffixes.Count) runner job routes were found; the scan pattern is wrong."
$called = @([regex]::Matches($runner, "['`"](/api/[^'`"]*)['`"]") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Check ($called.Count -ge 8) "Only $($called.Count) API calls were found in the agent; the scan pattern is wrong."
foreach ($path in $called) {
    $known = $exact -contains $path
    if (-not $known) {
        # "/api/runner/jobs/$JobId/claim" is a job route; only its tail is fixed.
        foreach ($suffix in $suffixes) {
            if ($path -like "/api/runner/jobs/*$suffix") { $known = $true; break }
        }
    }
    Check $known "The agent calls $path, which the worker does not serve."
}

# 3. The connect screen is served by the worker itself, so a typo in a path it
#    fetches is invisible to the browser suites too.
$connectStart = $worker.IndexOf('const CONNECT_HTML')
Check ($connectStart -ge 0) 'The worker no longer defines a connect page.'
$connectEnd = $worker.IndexOf('const APP_HTML')
Check ($connectEnd -gt $connectStart) 'The connect page and the app page could not be told apart.'
$connect = $worker.Substring($connectStart, $connectEnd - $connectStart)
# The cloud pages are served under /cloud on the one site, so they write the
# prefix marker in front of their own calls; the route they reach is what
# follows it.
$fetched = @([regex]::Matches($connect, 'api\("(?:__CLOUD__)?(/api/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Check ($fetched.Count -ge 3) "The connect page appears to call only $($fetched.Count) endpoints."
foreach ($path in $fetched) {
    Check ($exact -contains $path) "The connect page calls $path, which the worker does not serve."
}
Check ($worker -match 'pathname === "/connect"') 'The connect page is not routed.'

# 4. The page shows what the agent reports, through the record the worker
#    stores. Reading status/message instead of connectionStatus/connectionMessage
#    once reported a healthy Codex as unavailable, so the three field sets are
#    checked against each other rather than assumed to match.
foreach ($field in @('status', 'detail', 'version')) {
    Check ($runner -match "(?m)^\s+$field\s+=") "The agent does not report codex.$field, which the connect page displays."
    Check ($connect -match "codex\.$field") "The connect page no longer displays codex.$field."
}
Check ($runner -match 'connection\.connectionStatus' -and $runner -match 'connection\.connectionMessage') 'The agent must read connectionStatus/connectionMessage from Test-BookStudioCodexConnection; status/message are always empty.'
foreach ($field in @('runnerName', 'label', 'seenAt', 'connected')) {
    Check ($worker -match "$field[:,]") "The status record no longer carries $field, which the connect page displays."
}
Check ($connect -match 'status\.detail') 'A machine that has never checked in must say why, not show a blank panel.'

# 4b. Which Book Studio folder a computer is showing the web site, and how many
#     books are in it, travels from the agent through the stored record to both
#     pages that list computers. A PC with two copies of Book Studio showed the
#     empty one on the web site, and nothing on either page said so.
$agentLibrary = Get-Content -LiteralPath (Join-Path $root 'lib/EbookCloudRunner.ps1') -Raw -Encoding UTF8
$client = Get-Content -LiteralPath (Join-Path $root 'book-studio/app.js') -Raw -Encoding UTF8
Check ($runner -match '\$body\.studio = \$script:studioReport') 'The agent does not send what it knows about the folder it serves.'
Check ($worker -match 'studio: studioReport\(payload\.studio\)') 'The status record drops what the agent reports about the folder it serves.'
foreach ($field in @('installPath', 'bookCount', 'agentPath', 'agentBookCount')) {
    Check ($agentLibrary -match "(?m)^\s+$field\s+=") "The agent does not report studio.$field."
    Check ($worker -match "value\.$field") "The worker does not keep studio.$field."
    Check ($connect -match "studio\.$field") "The connect page does not show studio.$field."
    Check ($client -match "studio\.$field") "Book Studio's Settings does not show studio.$field."
}

# 5. Every route that reads or changes a book must authenticate. Four routes are
#    deliberately open: a probe, the one that tells the page whether anyone is
#    signed in, and the two that sign a person in and out, which cannot require
#    the session they are there to create and destroy.
# Asking for an account is open too: a person with no account has nothing to
# sign in with. It creates nothing -- an administrator approves every request.
$openRoutes = @('/api/health', '/api/identity', '/api/login', '/api/logout', '/api/signup')
$blocks = [regex]::Matches($worker, '(?s)if \(request\.method === "(GET|POST)" && pathname === "(/api/[^"]+)"\) \{(.*?)\r?\n      \}')
Check ($blocks.Count -ge 5) "Only $($blocks.Count) route bodies were matched; the scan pattern is wrong."
foreach ($block in $blocks) {
    $path = $block.Groups[2].Value
    if ($openRoutes -contains $path) { continue }
    $guarded = $block.Groups[3].Value -match 'requireUser|requireRunner'
    Check $guarded "$($block.Groups[1].Value) $path runs without requireUser or requireRunner."
}

# 6. Access adds cf-access-authenticated-user-email, but the workers.dev
#    hostname stays reachable and anyone can send that header, so the header
#    alone must never be an identity once sign-in is required.
Check ($worker -match 'verifyAccessAssertion') 'The worker no longer verifies the signed Access assertion.'
Check ($worker -match 'crypto\.subtle\.verify') 'The Access assertion is not checked against a signature.'
Check ($worker -match 'audiences\.includes\(audience\)') 'A token minted for a different Access application would be accepted.'
Check ($worker -match 'payload\.exp && now >= payload\.exp') 'An expired Access token would be accepted.'
$identityStart = $worker.IndexOf('async function accessIdentity')
Check ($identityStart -ge 0) 'The worker no longer resolves an identity in one place.'
$identityBody = $worker.Substring($identityStart, 700)
$headerUse = $identityBody.IndexOf('cf-access-authenticated-user-email')
$guard = $identityBody.IndexOf('REQUIRE_ACCESS === "true"')
Check ($headerUse -ge 0 -and $guard -ge 0 -and $guard -lt $headerUse) 'accessIdentity must refuse the unverified header when sign-in is required; it is forgeable.'

# 7. The agent and the connect screen must agree on where a machine's status
#    lives, or a connected machine reads as missing. A token with no owner
#    writes under "shared", which the reader has to know about.
Check ($worker -match 'runner:status:" \+ \(auth\.runner\.owner \|\| "shared"\)') 'The status key for an unowned runner token changed.'
Check ($worker -match 'runner:status:shared') 'The connect screen cannot find a machine running on a shared token.'
Check ($worker -match 'expirationTtl: 900') 'Without an expiry a machine that is switched off still reads as connected.'

# 7b. The Workers runtime refuses PBKDF2 above 100,000 iterations and only says
#     so when a password is checked, so a stronger-looking number ships fine and
#     then refuses every sign-in.
$iterations = [int]([regex]::Match($worker, 'const PASSWORD_ITERATIONS = (\d+)')).Groups[1].Value
Check ($iterations -gt 0 -and $iterations -le 100000) "PBKDF2 is set to $iterations iterations; the Workers runtime allows at most 100000 and fails the login outright."
Check ($worker -match 'PBKDF2') 'Passwords are no longer derived with PBKDF2.'
Check ($worker -notmatch 'SHA-1') 'Password hashing must not fall back to SHA-1.'

# 8. A finished book with images passes a few hundred kilobytes, where spreading
#    the whole array into fromCharCode overflows the call stack.
$base64Start = $worker.IndexOf('function bytesToBase64')
Check ($base64Start -ge 0) 'The worker no longer encodes file bodies.'
$base64 = $worker.Substring($base64Start, 400)
Check ($base64 -match 'i \+= chunk') 'bytesToBase64 must encode in chunks; a whole book overflows the call stack.'
Check ($base64 -notmatch 'fromCharCode\.apply\(null, bytes\)') 'bytesToBase64 spreads the whole array again.'

# 9. Every binding and variable the worker reads must be declared, or it is
#    undefined at runtime in a deployed worker and nowhere else.
$used = @([regex]::Matches($worker, 'env\.([A-Z][A-Z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Check ($used.Count -ge 3) "Only $($used.Count) environment names were found; the scan pattern is wrong."
foreach ($name in $used) {
    # A KV or R2 binding is declared with binding =, a Durable Object with
    # name =, and a plain variable as itself.
    Check ($wrangler -match "(?m)^\s*((binding|name)\s*=\s*`"$name`"|$name\s*=)") "The worker reads env.$name, which wrangler.toml does not declare."
}
Check ($wrangler -match '(?m)^\s*id\s*=\s*"[0-9a-f]{32}"') 'The KV namespace id is not a real namespace.'
Check ($wrangler -match '(?m)^\s*bucket_name\s*=\s*"[a-z0-9-]+"') 'The R2 bucket is not named.'

# 10. Sign-in is off while the Access application is still being created. That
#     is a deliberate, temporary state, and the connect page has to say so
#     rather than let a designer put a real course through an open worker.
Check ($connect -match 'Not signed in') 'The connect page no longer warns when sign-in is off.'
Check ($connect -match 'not shown again') 'A runner token is shown once; the page must say so before it is lost.'

"PASS: $checks cloud worker checks (route contract, status fields, authentication, Access verification, bindings)."
