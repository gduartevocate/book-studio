[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [string]$AccessCode = "",
    [string]$ReviewerLabel = "SME Reviewer",
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
            $invokeParams.Body = ($Body | ConvertTo-Json -Depth 30 -Compress)
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

    $created = Invoke-CloudflareApi -Method Post -Path "/accounts/$script:accountId/storage/kv/namespaces" -Body @{ title = $Title }
    return $created.result.id
}

function Get-EscapedKvKey {
    param([Parameter(Mandatory)][string]$Key)
    return (($Key -split "/") | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join "/"
}

function Set-KvTextValue {
    param(
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $escapedKey = Get-EscapedKvKey -Key $Key
    $uri = "https://api.cloudflare.com/client/v4/accounts/$script:accountId/storage/kv/namespaces/$NamespaceId/values/$escapedKey"
    $headers = @{ Authorization = "Bearer $script:token" }
    $result = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $Value -ContentType "text/plain; charset=utf-8"
    if (-not $result.success) {
        throw "Cloudflare KV write failed ($Key): $($result.errors | ConvertTo-Json -Compress)"
    }
}

function ConvertTo-Slug {
    param([AllowNull()][string]$Value)
    $slug = ([string]$Value).ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $slug.Trim("-")
}

function Convert-MarkdownAssetLinksToDataUris {
    param(
        [AllowNull()][string]$Markdown,
        [Parameter(Mandatory)][string]$RootFolder
    )

    if ([string]::IsNullOrWhiteSpace($Markdown)) {
        return ""
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$Match)

        $altText = $Match.Groups[1].Value
        $target = $Match.Groups[2].Value.Trim()
        if ($target -match "^(https?:|data:|#)") {
            return $Match.Value
        }

        $targetPath = ($target -split "\s+`"", 2)[0].Trim("`"")
        if ($targetPath -notmatch "^(images|visuals)/") {
            return $Match.Value
        }

        $localPath = Join-Path $RootFolder ($targetPath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            if ($targetPath -match "^images/chapter-(\d+)-.+-opener\.png$") {
                $visualsFolder = Join-Path $RootFolder "visuals"
                $opener = @(Get-ChildItem -LiteralPath $visualsFolder -File -Filter "chapter-$($Matches[1])-*-opener.svg" -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($opener.Count -gt 0) {
                    $localPath = $opener[0].FullName
                }
            }
            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                return $Match.Value
            }
        }

        $extension = [System.IO.Path]::GetExtension($localPath).ToLowerInvariant()
        $mediaType = switch ($extension) {
            ".svg" { "image/svg+xml" }
            ".png" { "image/png" }
            ".jpg" { "image/jpeg" }
            ".jpeg" { "image/jpeg" }
            ".gif" { "image/gif" }
            default { "" }
        }
        if ([string]::IsNullOrWhiteSpace($mediaType)) {
            return $Match.Value
        }

        try {
            $base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($localPath))
            return "![${altText}](data:${mediaType};base64,${base64})"
        }
        catch {
            return $Match.Value
        }
    }

    return [System.Text.RegularExpressions.Regex]::Replace($Markdown, "!\[([^\]]*)\]\(([^)]+)\)", $evaluator)
}

$resolvedPackagePath = (Resolve-Path -LiteralPath $PackagePath).ProviderPath
$manifestPath = Join-Path $resolvedPackagePath "chapters\manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Chapter manifest not found: $manifestPath"
}

Import-CloudflareEnv -Path $EnvPath
$script:token = if ($env:CLOUDFLARE_API_TOKEN) { $env:CLOUDFLARE_API_TOKEN } else { $env:CF_API_TOKEN }
if (-not $script:token) {
    throw "Cloudflare API token not found. Add CLOUDFLARE_API_TOKEN to $EnvPath or paste a curl Authorization: Bearer command there."
}

$script:accountId = Get-CloudflareAccountId
$namespaceId = Get-KvNamespaceId -Title $KvNamespaceTitle

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$courseCode = [string]$manifest.courseCode
$title = [string]$manifest.title
if ([string]::IsNullOrWhiteSpace($courseCode)) {
    $courseCode = Split-Path -Leaf $resolvedPackagePath
}
if ([string]::IsNullOrWhiteSpace($title)) {
    $title = $courseCode
}

$packageId = (ConvertTo-Slug "$courseCode-$title")
if ([string]::IsNullOrWhiteSpace($AccessCode)) {
    $AccessCode = ("{0}-{1}" -f $courseCode, ([guid]::NewGuid().ToString("N").Substring(0, 6))).ToUpperInvariant()
}
$AccessCode = ($AccessCode.ToUpperInvariant() -replace "[^A-Z0-9-]", "")

$chapters = New-Object System.Collections.ArrayList
foreach ($chapter in @($manifest.chapters | Sort-Object chapterNumber)) {
    $markdownPath = Join-Path $resolvedPackagePath ([string]$chapter.markdownFile -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    $markdown = if (Test-Path -LiteralPath $markdownPath -PathType Leaf) {
        Get-Content -LiteralPath $markdownPath -Raw -Encoding UTF8
    }
    elseif ($chapter.markdown) {
        [string]$chapter.markdown
    }
    else {
        ""
    }

    [void]$chapters.Add([pscustomobject]@{
        id = [string]$chapter.id
        chapterNumber = [int]$chapter.chapterNumber
        title = [string]$chapter.title
        wordCount = if ($chapter.wordCount) { [int]$chapter.wordCount } else { 0 }
        markdown = Convert-MarkdownAssetLinksToDataUris -Markdown $markdown -RootFolder $resolvedPackagePath
    })
}

$package = [pscustomobject]@{
    schemaVersion = 1
    id = $packageId
    courseCode = $courseCode
    title = $title
    sourcePackagePath = $resolvedPackagePath
    publishedAt = (Get-Date).ToUniversalTime().ToString("o")
    chapters = @($chapters)
}

$assignment = [pscustomobject]@{
    accessCode = $AccessCode
    reviewerLabel = $ReviewerLabel
    packageIds = @($packageId)
    updatedAt = (Get-Date).ToUniversalTime().ToString("o")
}

Set-KvTextValue -NamespaceId $namespaceId -Key "package:$packageId" -Value ($package | ConvertTo-Json -Depth 30 -Compress)
Set-KvTextValue -NamespaceId $namespaceId -Key "access:$AccessCode" -Value ($assignment | ConvertTo-Json -Depth 10 -Compress)

Write-Host "Published SME review package: $courseCode - $title"
Write-Host "Package ID: $packageId"
Write-Host "Access code: $AccessCode"
Write-Host "KV namespace: $KvNamespaceTitle ($namespaceId)"
