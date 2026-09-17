[CmdletBinding()]
param(
    [string]$WorkerName = "ebook-sme-review",
    [string]$WorkerScriptPath = ".\cloudflare\sme-review-worker.js",
    [string]$EnvPath = "..\.env",
    [string]$AccountId = "",
    [string]$KvNamespaceTitle = "ebook-sme-review"
)

$ErrorActionPreference = "Stop"

function Import-CloudflareEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lines = Get-Content -LiteralPath $Path
    foreach ($line in $lines) {
        if ($line -match '^\s*([^#][^=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim().Trim('"').Trim("'")
            if ($name) {
                [Environment]::SetEnvironmentVariable($name, $value, "Process")
            }
        }
    }

    if (-not $env:CLOUDFLARE_API_TOKEN) {
        $joined = $lines -join "`n"
        if ($joined -match 'Authorization:\s*Bearer\s+([A-Za-z0-9_\-\.]+)') {
            [Environment]::SetEnvironmentVariable("CLOUDFLARE_API_TOKEN", $matches[1], "Process")
        }
    }
}

function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory)][ValidateSet("Get", "Post", "Put")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [string]$ContentType = "application/json"
    )

    $invokeParams = @{
        Uri     = "https://api.cloudflare.com/client/v4$Path"
        Method  = $Method
        Headers = @{ Authorization = "Bearer $script:token" }
    }

    if ($null -ne $Body) {
        if ($ContentType -eq "application/json") {
            $invokeParams.ContentType = $ContentType
            $invokeParams.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        }
        else {
            $invokeParams.ContentType = $ContentType
            $invokeParams.Body = $Body
        }
    }

    $result = Invoke-RestMethod @invokeParams
    if (-not $result.success) {
        throw "Cloudflare API call failed ($Method $Path): $($result.errors | ConvertTo-Json -Compress)"
    }
    return $result
}

function Get-CloudflareAccountId {
    if ($AccountId) {
        return $AccountId
    }
    if ($env:CLOUDFLARE_ACCOUNT_ID) {
        return $env:CLOUDFLARE_ACCOUNT_ID
    }
    $accounts = Invoke-CloudflareApi -Method Get -Path "/accounts"
    $account = @($accounts.result | Select-Object -First 1)[0]
    if (-not $account) {
        throw "No Cloudflare account is visible to this token."
    }
    return [string]$account.id
}

function Get-OrCreateKvNamespace {
    param([Parameter(Mandatory)][string]$Title)

    $page = 1
    do {
        $list = Invoke-CloudflareApi -Method Get -Path "/accounts/$script:accountId/storage/kv/namespaces?per_page=50&page=$page"
        $match = $list.result | Where-Object { $_.title -eq $Title } | Select-Object -First 1
        if ($match) {
            return $match.id
        }

        $totalPages = 1
        if ($list.result_info -and $list.result_info.total_pages) {
            $totalPages = [int]$list.result_info.total_pages
        }
        $page++
    } while ($page -le $totalPages)

    $created = Invoke-CloudflareApi -Method Post -Path "/accounts/$script:accountId/storage/kv/namespaces" -Body @{ title = $Title }
    return $created.result.id
}

if (-not (Test-Path -LiteralPath $WorkerScriptPath)) {
    throw "Worker script not found: $WorkerScriptPath"
}

Import-CloudflareEnv -Path $EnvPath
$script:token = if ($env:CLOUDFLARE_API_TOKEN) { $env:CLOUDFLARE_API_TOKEN } else { $env:CF_API_TOKEN }
if (-not $script:token) {
    throw "Cloudflare API token not found. Add CLOUDFLARE_API_TOKEN to $EnvPath or paste a curl Authorization: Bearer command there."
}

$script:accountId = Get-CloudflareAccountId
$namespaceId = Get-OrCreateKvNamespace -Title $KvNamespaceTitle

$scriptPath = (Resolve-Path $WorkerScriptPath).ProviderPath
$script = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
$metadata = @{
    main_module = "sme-review-worker.js"
    bindings = @(
        @{
            type = "kv_namespace"
            name = "REVIEW_KV"
            namespace_id = $namespaceId
        }
    )
} | ConvertTo-Json -Depth 20 -Compress

$boundary = "----sme-review-$([Guid]::NewGuid().ToString('N'))"
$newline = "`r`n"
$bodyText = @(
    "--$boundary",
    'Content-Disposition: form-data; name="metadata"',
    "Content-Type: application/json",
    "",
    $metadata,
    "--$boundary",
    'Content-Disposition: form-data; name="sme-review-worker.js"; filename="sme-review-worker.js"',
    "Content-Type: application/javascript+module",
    "",
    $script,
    "--$boundary--",
    ""
) -join $newline

$uri = "https://api.cloudflare.com/client/v4/accounts/$script:accountId/workers/scripts/$WorkerName"
$headers = @{ Authorization = "Bearer $script:token" }
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)

$response = Invoke-RestMethod `
    -Uri $uri `
    -Method Put `
    -Headers $headers `
    -ContentType "multipart/form-data; boundary=$boundary" `
    -Body $bodyBytes

if (-not $response.success) {
    throw "Cloudflare deploy failed: $($response.errors | ConvertTo-Json -Compress)"
}

$subdomainEnabled = "unknown"
try {
    $subdomain = Invoke-CloudflareApi `
        -Method Post `
        -Path "/accounts/$script:accountId/workers/scripts/$WorkerName/subdomain" `
        -Body @{ enabled = $true; previews_enabled = $true }
    $subdomainEnabled = $subdomain.result.enabled
}
catch {
    try {
        $subdomain = Invoke-CloudflareApi `
            -Method Put `
            -Path "/accounts/$script:accountId/workers/scripts/$WorkerName/subdomain" `
            -Body @{ enabled = $true; previews_enabled = $true }
        $subdomainEnabled = $subdomain.result.enabled
    }
    catch {
        Write-Warning "Could not explicitly enable the workers.dev route. The Worker may still be reachable if workers.dev is enabled by default."
    }
}

Write-Host "SME Review Worker deployed: $WorkerName"
Write-Host "Account ID: $script:accountId"
Write-Host "KV namespace: $KvNamespaceTitle ($namespaceId)"
Write-Host "workers.dev enabled: $subdomainEnabled"
