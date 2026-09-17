[CmdletBinding()]
param(
    [string]$PackageId = "en2150-interpersonal-professional-communication",
    [string]$AccessCode = "EN2150-SME",
    [string]$OutputPath = "",
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
        [Parameter(Mandatory)][ValidateSet("Get", "Post")][string]$Method,
        [Parameter(Mandatory)][string]$Path
    )

    $result = Invoke-RestMethod `
        -Uri "https://api.cloudflare.com/client/v4$Path" `
        -Method $Method `
        -Headers @{ Authorization = "Bearer $script:token" }

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

function Get-KvNamespaceId {
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

    throw "KV namespace not found: $Title"
}

Import-CloudflareEnv -Path $EnvPath
$script:token = if ($env:CLOUDFLARE_API_TOKEN) { $env:CLOUDFLARE_API_TOKEN } else { $env:CF_API_TOKEN }
if (-not $script:token) {
    throw "Cloudflare API token not found. Add CLOUDFLARE_API_TOKEN to $EnvPath or paste a curl Authorization: Bearer command there."
}

$script:accountId = Get-CloudflareAccountId
$namespaceId = Get-KvNamespaceId -Title $KvNamespaceTitle
$cleanAccessCode = ($AccessCode.ToUpperInvariant() -replace "[^A-Z0-9-]", "")
$key = [System.Uri]::EscapeDataString("feedback:${PackageId}:${cleanAccessCode}")
$uri = "https://api.cloudflare.com/client/v4/accounts/$script:accountId/storage/kv/namespaces/$namespaceId/values/$key"

try {
    $feedback = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $script:token" } -Method Get
}
catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
        $feedback = [pscustomobject]@{
            packageId = $PackageId
            accessCode = $cleanAccessCode
            reviewerName = ""
            savedAt = ""
            chapterFeedback = [pscustomobject]@{}
        }
    }
    else {
        throw
    }
}

if (-not $OutputPath) {
    $folder = Join-Path (Get-Location).Path ".bookstudio\feedback"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $OutputPath = Join-Path $folder "$PackageId-$cleanAccessCode-feedback.json"
}

$feedback | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Downloaded SME feedback: $OutputPath"
