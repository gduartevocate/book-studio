$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
# The real page, every client script it loads, and an in-memory HTTP boundary
# (tests/fixtures/book-studio-library-error-ui.js). A book list that cannot be
# loaded must say so on the books page with a way to try again; on the web site
# it used to be simply blank. Never contacts a server, Codex, or a real book.
$browser=@('C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Microsoft/Edge/Application/msedge.exe') | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(-not $browser){throw 'Chrome or Edge is required for the book list UI test.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('bookstudio-library-ui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$index=Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
# Every script the page loads, in the order it loads them. A harness that
# leaves one out tests a page no designer ever sees.
$appScripts=@([regex]::Matches($index,'<script src="/([A-Za-z0-9\-\.]+\.js)[^"]*"></script>') | ForEach-Object { 'book-studio/' + $_.Groups[1].Value })
if($appScripts.Count -lt 2 -or $appScripts[-1] -ne 'book-studio/app.js'){throw "The page's scripts were not found as expected: $($appScripts -join ', ')"}
$harness=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/book-studio-library-error-ui.js') -Raw -Encoding UTF8
$css=Get-Content -LiteralPath (Join-Path $root 'book-studio/styles.css') -Raw -Encoding UTF8
$injected=($appScripts | ForEach-Object {
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath (Join-Path $root $_) -Raw -Encoding UTF8)))
    '<script>{ const s = document.createElement("script"); s.textContent = new TextDecoder().decode(Uint8Array.from(atob("' + $encoded + '"), c => c.charCodeAt(0))); document.body.append(s); }</script>'
}) -join ''
$scripts='<output id="test-result">RUNNING</output><script>'+$harness+'</script>'+$injected
$html=[regex]::Replace($index,'(?:\s*<script src="/[^"]+"></script>)+',[Text.RegularExpressions.MatchEvaluator]{param($m) $scripts})
$html=[regex]::Replace($html,'<link rel="stylesheet"[^>]*>',[Text.RegularExpressions.MatchEvaluator]{param($m) '<style>'+$css+'</style>'})
$page=Join-Path $fixture 'test.html'
$html | Set-Content -LiteralPath $page -Encoding UTF8
$stdout=Join-Path $fixture 'stdout.txt';$stderr=Join-Path $fixture 'stderr.txt'
$args=@('--headless','--disable-gpu','--disable-extensions','--no-first-run','--no-default-browser-check','--dump-dom','--virtual-time-budget=10000',('--user-data-dir="'+(Join-Path $fixture 'profile')+'"'),('"'+([uri]$page).AbsoluteUri+'"'))
$process=Start-Process -FilePath $browser -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
# A browser left running slows the machine until the next run times out too, so
# a timeout stops the whole test-only browser tree before it is reported.
function Stop-TestBrowserTree([int]$ProcessId){
    foreach($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)){
        Stop-TestBrowserTree -ProcessId ([int]$child.ProcessId)
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}
if(-not $process.WaitForExit(45000)){
    Stop-TestBrowserTree -ProcessId ([int]$process.Id)
    foreach($stray in @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$fixture*" })){
        Stop-Process -Id ([int]$stray.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    throw "Book list browser test exceeded 45 seconds; its browser was stopped. Inspect $fixture."
}
$result=Get-Content -LiteralPath $stdout -Raw -Encoding UTF8
$match=[regex]::Match($result,'<output id="test-result">(PASS:[^<]+)</output>')
if(-not $match.Success){throw "Book list browser test failed; inspect $fixture. $([regex]::Match($result,'<output id="test-result">([^<]+)</output>').Groups[1].Value)"}
Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ($match.Groups[1].Value + '.')
