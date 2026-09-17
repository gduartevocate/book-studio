[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'content/GM1000/assigned-reading-list.json'),
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$urls = @(@($manifest.resources.url) + @($manifest.sections.url) + @($manifest.sections.fullTextUrl) | Where-Object { $_ } | Sort-Object -Unique)
$results = @(foreach ($url in $urls) {
    $response = $null; $errorText = ''
    for ($attempt=1; $attempt -le 2; $attempt++) {
        try { $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 20; break } catch { $errorText = $_.Exception.Message }
    }
    $contentType = if ($response) { [string]$response.Headers['Content-Type'] } else { '' }
    $body = if ($response -and $response.Content -is [string]) { [string]$response.Content } else { '' }
    $title = [Net.WebUtility]::HtmlDecode([regex]::Match($body, '(?is)<title[^>]*>(.*?)</title>').Groups[1].Value).Trim()
    $blocked = $title -match '(?i)just a moment|access denied|not found|captcha'
    $pdfValid = $true
    if ($contentType -match 'application/pdf') { $pdfValid = $response.Content -is [byte[]] -and [Text.Encoding]::ASCII.GetString($response.Content, 0, [Math]::Min(5,$response.Content.Length)) -eq '%PDF-' }
    $ok = $response -and $response.StatusCode -eq 200 -and -not $blocked -and $pdfValid
    [pscustomobject]@{url=$url;status=$(if($ok){'PASS'}else{'FAIL'});httpStatus=$(if($response){[int]$response.StatusCode}else{0});contentType=$contentType;title=$title;error=$(if($ok){''}else{$errorText});checkedAt=(Get-Date).ToString('s')}
})
$report = [pscustomobject]@{
    courseCode=$manifest.courseCode;generatedAt=(Get-Date).ToString('s');manifestSha256=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    status=$(if(@($results | Where-Object status -eq 'FAIL').Count){'FAIL'}else{'PASS'});results=$results
    limitation='HTTP retrieval and basic response checks only. Does not guarantee future availability, browser policy behavior, or suitability of content. Editorial content review is recorded separately.'
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$report | Select-Object status,@{n='links';e={$_.results.Count}},@{n='failures';e={@($_.results | Where-Object status -eq 'FAIL').Count}}
$results | Where-Object status -eq 'FAIL' | Format-List
if ($report.status -ne 'PASS') { throw 'One or more assigned source links could not be verified.' }
