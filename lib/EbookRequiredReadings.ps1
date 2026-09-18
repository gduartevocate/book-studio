# A blueprint assigns readings; it is not itself evidence for subject claims.
function Get-EbookReadingId {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return 'reading-' + ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','').Substring(0,16).ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function Get-EbookBlueprintReadingText {
    param([string]$Path)
    if ([IO.Path]::GetExtension($Path) -ne '.docx') { return Get-SourceTextFromFile $Path }
    $zip = Open-DocxArchive $Path
    try {
        [xml]$document = Read-DocxZipEntryText $zip 'word/document.xml'
        [xml]$relationships = Read-DocxZipEntryText $zip 'word/_rels/document.xml.rels'
        $targets = @{}
        foreach ($rel in $relationships.Relationships.Relationship) {
            if ($rel.Type -match '/hyperlink$') { $targets[[string]$rel.Id] = [string]$rel.Target }
        }
        $ns = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $ns.AddNamespace('r','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $lines = foreach ($p in $document.SelectNodes('//w:body//w:p', $ns)) {
            foreach ($link in $p.SelectNodes('.//w:hyperlink', $ns)) {
                $label = ($link.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join ''
                $target = $targets[$link.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships')]
                if ($target -and $label) {
                    $texts=@($link.SelectNodes('.//w:t',$ns))
                    $texts[0].InnerText="[$label]($target)"
                    foreach ($extra in @($texts | Select-Object -Skip 1)) { $extra.InnerText='' }
                }
            }
            $text = ($p.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join ''
            # Word field hyperlinks are not always represented by w:hyperlink.
            $fields = @(($p.SelectNodes('.//w:instrText',$ns) | ForEach-Object InnerText) -join '')
            $fields += @($p.SelectNodes('.//w:fldSimple',$ns) | ForEach-Object { $_.GetAttribute('instr','http://schemas.openxmlformats.org/wordprocessingml/2006/main') })
            foreach ($field in $fields) {
                if ($field -match '(?i)HYPERLINK\s+"(https?://[^\"]+)"' -and -not $text.Contains($Matches[1])) { $text += ' ' + $Matches[1] }
            }
            $text
        }
        return $lines -join "`n"
    } finally { $zip.Dispose() }
}

function ConvertFrom-EbookReadingList {
    param([AllowEmptyString()][string]$Text, [string]$Origin = 'Designer')
    $isBlueprint = $Origin -like 'Blueprint*'
    $records = [Collections.Generic.List[object]]::new(); $byUrl = @{}; $week = 0; $inReadings = -not $isBlueprint
    foreach ($raw in ($Text -split '\r?\n')) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -match '(?i)^#{0,6}\s*(?:Week|Chapter)\s*(\d+)(?=\s|:|$)(.*)$') {
            $week = [int]$Matches[1]
            $line = $Matches[2].Trim().TrimStart(':','-').Trim()
            # A blueprint's week title/objectives are not assigned readings.
            if ($isBlueprint -and $line -notmatch 'https?://') {
                if ($line -match '(?i)^(?:(?:Required|Assigned|Scholarly)\s+)?(?:Readings?|Sources|References|Resources)\s*:?$') { $inReadings = $true }
                continue
            }
            if (-not $line) { continue }
        }
        if ($line -match '(?i)^(?:All chapters|General readings)\s*:?$') { $week=0; $inReadings=$true; continue }
        if ($line -match '(?i)^#{0,6}\s*(?:(?:Required|Assigned|Scholarly)\s+)?(?:Readings?|Sources|References|Resources)\s*:?$') { $inReadings=$true; continue }
        if ($isBlueprint -and ($line -match '(?i)^(?:(?:Course|Lesson|Learning|Weekly|Sub)[ -]?)?Objectives?\b|^(?:Course Description|Activities|Assignments|Assessments|Instructor Notes|Production Notes)\b' -or
            $line -match '(?i)^(?:CO|LO)\s*\d|^\d+\.\d+\b|^\d+[.)]\s+(?:Describe|Identify|Compare|Explain|Analyze|Evaluate|Develop|Apply|Examine|Assess|Differentiate|Demonstrate|Define|Discuss|Use)\b')) {
            $inReadings=$false
            continue
        }
        $linkPattern='\[(?<title>[^\]]+)\]\((?<url>https?://(?:[^()\s]|\([^()\s]*\))+)\)'
        $links = @([regex]::Matches($line, $linkPattern))
        $remaining = [regex]::Replace($line, $linkPattern, '')
        $links += @([regex]::Matches($remaining, '(?<url>https?://[^\s<>"\x27]+)'))
        foreach ($link in $links) {
            $url = [Net.WebUtility]::HtmlDecode($link.Groups['url'].Value).TrimEnd('.',',',';')
            $uri = $null
            if (-not [uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('https','http') -or $uri.UserInfo) { throw "Invalid reading URL: $url" }
            $url = $uri.AbsoluteUri
            $title = $link.Groups['title'].Value.Trim()
            if (-not $title) { $title = $url }
            if ($links.Count -eq 1 -and $link.Groups['title'].Success -and $remaining -match '[\p{L}\p{N}]') { $title += ' - ' + $remaining.Trim(' ','-',':',';','.') }
            if ($byUrl.ContainsKey($url)) {
                $record = $byUrl[$url]
                if ($week -notin $record.chapters) { $record.chapters = @($record.chapters) + $week }
            } else {
                $record = [pscustomobject]@{id=(Get-EbookReadingId $url);url=$url;title=$title;chapters=@($week);origin=$Origin}
                $records.Add($record); $byUrl[$url]=$record
            }
        }
        if (-not $links.Count -and $inReadings -and $line -notmatch '^(?i)(Required readings|Assigned readings|Sources|References)\s*:?$') {
            # A title is not evidence that its article was found or read.
            $records.Add([pscustomobject]@{id=(Get-EbookReadingId "$week|$line");url='';title=$line;chapters=@($week);origin=$Origin})
        }
    }
    if ($records.Count -gt 60) { throw 'Use at most 60 required readings per book.' }
    return $records.ToArray()
}

function Merge-EbookReadingLists {
    param([object[]]$BlueprintReadings, [object[]]$DesignerReadings)
    $records = [Collections.Generic.List[object]]::new(); $byId = @{}
    foreach ($reading in (@($BlueprintReadings) + @($DesignerReadings))) {
        if ($null -eq $reading) { continue }
        if ($byId.ContainsKey($reading.id)) {
            $record = $byId[$reading.id]
            $record.chapters = @((@($record.chapters) + @($reading.chapters)) | Select-Object -Unique)
        } else {
            $record = [pscustomobject]@{id=$reading.id;url=$reading.url;title=$reading.title;chapters=@($reading.chapters);origin=$reading.origin}
            $records.Add($record); $byId[$record.id]=$record
        }
    }
    if ($records.Count -gt 60) { throw 'Use at most 60 required readings per book.' }
    return $records.ToArray()
}

function ConvertTo-EbookReadingListText {
    param([object[]]$Readings)
    $lines = foreach ($reading in $Readings) {
        foreach ($number in $reading.chapters) {
            if ([int]$number -gt 0) { "Week ${number}:" } else { 'All chapters:' }
            if ($reading.url) { "[$($reading.title)]($($reading.url))" } else { $reading.title }
        }
    }
    return $lines -join "`n"
}

function Assert-EbookPublicReadingUrl {
    param([string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('https','http') -or $uri.UserInfo -or $uri.Port -notin @(80,443)) { throw 'Readings must use public HTTP(S) URLs without credentials or custom ports.' }
    $addresses = [Net.Dns]::GetHostAddresses($uri.DnsSafeHost)
    if (-not $addresses.Count) { throw 'Reading host could not be resolved.' }
    foreach ($address in $addresses) {
        if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
        $b=$address.GetAddressBytes()
        if ([Net.IPAddress]::IsLoopback($address) -or $address.IsIPv6LinkLocal -or $address.IsIPv6SiteLocal -or
            ($b.Length -eq 16 -and (($b[0] -band 254) -eq 252 -or $b[0] -eq 255 -or $address.Equals([Net.IPAddress]::IPv6Any))) -or
            ($b.Length -eq 4 -and ($b[0] -in @(0,10,127,169) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or $b[0] -ge 224))) { throw 'Local/private-network reading URLs are not allowed.' }
    }
}

function Read-EbookRequiredSourceUrl {
    param([string]$Url, [string]$WorkFolder)
    Initialize-EbookGeneratorRuntime
    if ($Url -match '(?i)openstax\.org/(?:details/books|books/[^/]+/?$)') { throw 'This is a book landing page. Assign the exact chapter/section URL so its teaching text can be retrieved.' }
    $current=$Url
    for ($redirect=0; $redirect -le 5; $redirect++) {
        Assert-EbookPublicReadingUrl $current
        $request=[Net.HttpWebRequest]::Create($current)
        $request.AllowAutoRedirect=$false; $request.Timeout=20000; $request.ReadWriteTimeout=20000
        $request.UserAgent='BookStudio/1.0 (assigned-reading retrieval)'
        $request.AutomaticDecompression=[Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $response=$request.GetResponse()
        try {
            if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) { $current=[uri]::new([uri]$current,$response.Headers['Location']).AbsoluteUri; continue }
            if ($response.ContentLength -gt 20000000) { throw 'Reading exceeds the 20 MB download limit.' }
            $stream=$response.GetResponseStream(); $memory=[IO.MemoryStream]::new(); $buffer=New-Object byte[] 8192
            try {
                while (($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if ($memory.Length+$count -gt 20000000) { throw 'Reading exceeds the 20 MB download limit.' }
                    $memory.Write($buffer,0,$count)
                }
                $bytes=$memory.ToArray()
            } finally { $memory.Dispose(); $stream.Dispose() }
            $contentType=[string]$response.ContentType
            if ($contentType -match 'pdf' -or ($bytes.Length -ge 5 -and [Text.Encoding]::ASCII.GetString($bytes,0,5) -eq '%PDF-')) {
                $converter=Get-Command pdftotext.exe,pdftotext -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $converter) { throw 'This reading is a PDF. Install the Poppler pdftotext utility, then check sources again. No PDF content has been read.' }
                $pdf=Join-Path $WorkFolder ((Get-EbookReadingId $Url)+'.pdf')
                [IO.File]::WriteAllBytes($pdf,$bytes)
                $extracted=$pdf+'.txt'; $diagnostic=$pdf+'.log'
                $process=Start-Process -FilePath $converter.Source -ArgumentList @('-enc','UTF-8','-layout',('"'+$pdf+'"'),('"'+$extracted+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError $diagnostic
                $null=$process.Handle
                if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'PDF text extraction timed out. Supply a readable chapter/text version.' }
                if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $extracted)) { throw 'PDF text extraction failed. Supply an accessible text version of this reading.' }
                $text=[IO.File]::ReadAllText($extracted,[Text.Encoding]::UTF8)
            } elseif ($contentType -match 'html|text/plain|xml') {
                $encoding=[Text.Encoding]::UTF8
                if ($response.CharacterSet) { try { $encoding=[Text.Encoding]::GetEncoding($response.CharacterSet) } catch {} }
                $raw=$encoding.GetString($bytes)
                $raw=[regex]::Replace($raw,'(?is)<(script|style|nav|footer|header)\b[^>]*>.*?</\1>',' ')
                $text=ConvertFrom-HtmlToPlainText $raw
            } else { throw "Unsupported reading content type: $contentType" }
            if ($text.Length -lt 500 -or $text -match '(?i)^\s*(access denied|just a moment|sign in to continue|enable javascript)') { throw 'The source did not provide readable article content (it may be blocked, scanned, or sign-in-only).' }
            if ($text.Length -gt 600000) { throw 'Reading text exceeds 600,000 characters. Assign a specific chapter or section instead of a whole book.' }
            return [pscustomobject]@{text=$text;resolvedUrl=$current;contentType=$contentType}
        } finally { $response.Close() }
    }
    throw 'Reading exceeded five redirects.'
}

function Update-EbookRequiredSourceEvidence {
    param([object]$Plan, [string]$OutputFolder, [scriptblock]$ReadSource)
    $readings=@($Plan.requiredReadings); $folder=Join-Path $OutputFolder 'source-readings'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $results=[Collections.Generic.List[object]]::new()
    foreach ($reading in $readings) {
        $result=[pscustomobject]@{id=$reading.id;url=$reading.url;title=$reading.title;chapters=@($reading.chapters);status='Blocked';detail='';contentFile='';contentSha256='';resolvedUrl='';checkedAt=(Get-Date).ToString('o')}
        try {
            if ($reading.id -notmatch '^reading-[a-f0-9]{16}$') { throw 'Invalid required-reading identifier. Save the reading list again.' }
            if (-not $reading.url) { throw 'Add the exact URL for this assigned title; a title alone is not a retrieved source.' }
            if (@($reading.chapters | Where-Object { $_ -ne 0 -and $_ -notin @($Plan.chapters.number) }).Count) { throw 'Reading is assigned to a chapter that is not in the approved outline.' }
            Write-EbookGeneratorProgress -Phase 'Reading required sources' -Detail $reading.url
            $retrieved=if($ReadSource){ & $ReadSource $reading.url $folder }else{ Read-EbookRequiredSourceUrl -Url $reading.url -WorkFolder $folder }
            $result.contentFile="source-readings/$($reading.id).txt"
            $path=Join-Path $OutputFolder $result.contentFile
            Set-Content -LiteralPath $path -Value $retrieved.text -Encoding UTF8 -NoNewline
            $result.contentSha256=(Get-FileHash -LiteralPath $path).Hash
            $result.resolvedUrl=$retrieved.resolvedUrl; $result.status='Read'
            $result.detail='Readable source text retrieved. Claim accuracy and permissions still require review.'
        } catch { $result.detail=$_.Exception.Message }
        $results.Add($result)
    }
    $issues=@($results | Where-Object status -ne 'Read' | ForEach-Object { "$($_.title): $($_.detail)" })
    foreach ($chapter in $Plan.chapters) {
        if (-not @($readings | Where-Object { 0 -in $_.chapters -or $chapter.number -in $_.chapters }).Count) { $issues += "Chapter $($chapter.number) has no assigned reading. Add its sources or an All chapters reading." }
    }
    $report=[pscustomobject]@{schemaVersion=1;checkedAt=(Get-Date).ToString('o');status=$(if($issues.Count -or -not $readings.Count){'FAIL'}else{'PASS'});readings=$results.ToArray();issues=$issues}
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputFolder 'required-source-report.json') -Encoding UTF8
    @('# Required source retrieval', '', "Status: $($report.status)", '', 'Read means text was retrieved, not that claims or permissions have been approved.', '') + @($results | ForEach-Object { "- $($_.title) | $($_.status) | $($_.url) | $($_.detail)" }) + $issues | Set-Content -LiteralPath (Join-Path $OutputFolder 'required-source-report.md') -Encoding UTF8
    return $report
}

function Get-EbookRequiredSourceReview {
    param([object]$Plan, [string]$OutputFolder, [AllowEmptyString()][string]$Markdown, [switch]$EvidenceOnly)
    $issues=[Collections.Generic.List[string]]::new()
    try { $report=Get-Content -LiteralPath (Join-Path $OutputFolder 'required-source-report.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $report=$null }
    $readings=@($Plan.requiredReadings)
    if (-not $readings.Count) { $issues.Add('The required reading list is empty. The course blueprint cannot substitute for assigned readings.') }
    foreach ($reading in $readings) {
        if ($reading.id -notmatch '^reading-[a-f0-9]{16}$') { $issues.Add('Invalid required-reading identifier. Save the reading list again.'); continue }
        $record=@($report.readings | Where-Object { $_.id -eq $reading.id -and $_.url -ceq $reading.url })
        if (-not $reading.url -or $record.Count -ne 1 -or $record[0].status -ne 'Read' -or $record[0].contentFile -cne "source-readings/$($reading.id).txt") { $issues.Add("Required reading has not been read: $($reading.title). Check required-source-report.md."); continue }
        $file=Join-Path $OutputFolder $record[0].contentFile
        if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash -ne $record[0].contentSha256) { $issues.Add("Source text is missing or changed: $($reading.title).") }
    }
    foreach ($chapter in $Plan.chapters) {
        $assigned=@($readings | Where-Object { 0 -in $_.chapters -or $chapter.number -in $_.chapters })
        if (-not $assigned.Count) { $issues.Add("Chapter $($chapter.number) has no assigned reading.") }
        if ($EvidenceOnly) { continue }
        $chapterText=[regex]::Match($Markdown, '(?ms)^# Chapter '+$chapter.number+':.*?(?=^# Chapter |\z)').Value
        $parts=[regex]::Split($chapterText,'(?m)^#{2,3} Scholarly Sources[^\r\n]*\r?\n',2)
        $body=$parts[0]; $notes=if($parts.Count -eq 2){$parts[1]}else{''}
        foreach ($reading in $assigned) {
            $note=@([regex]::Matches($notes,'(?m)^(\d+)\.\s+([^\r\n]+)') | Where-Object { $_.Groups[2].Value.Contains("]($($reading.url))") })
            if (-not $reading.url -or $note.Count -ne 1) { $issues.Add("Chapter $($chapter.number): required reading needs one numbered source note: $($reading.title)."); continue }
            $number=$note[0].Groups[1].Value
            if (-not $body.Contains("[$number](#chapter-$($chapter.number)-note-$number)")) { $issues.Add("Chapter $($chapter.number): $($reading.title) is listed but not cited in the teaching.") }
        }
        foreach ($link in [regex]::Matches($notes,'\]\((https?://[^\s]+?)\)')) { if ($link.Groups[1].Value -cnotin @($assigned.url)) { $issues.Add("Chapter $($chapter.number): bibliography contains an unassigned URL: $($link.Groups[1].Value).") } }
        foreach ($note in [regex]::Matches($notes,'(?m)^\d+\.\s+([^\r\n]+)')) {
            if (-not @($assigned | Where-Object { $_.url -and $note.Value.Contains("]($($_.url))") }).Count) { $issues.Add("Chapter $($chapter.number): a bibliography note does not identify an assigned reading. Do not cite the blueprint or production notes as teaching evidence.") }
        }
    }
    [pscustomobject]@{applicable=$true;status=$(if($issues.Count){'FAIL'}else{'PASS'});issues=$issues.ToArray();detail=$(if($issues.Count){$issues -join ' '}else{'Required source text, chapter assignments, bibliography URLs, and body citations verified. Human claim/permissions review remains required.'})}
}

function New-EbookRequiredSourceBrief {
    param([object]$Plan, [string]$OutputFolder, [object]$SourceContext)
    $review=Get-EbookRequiredSourceReview -Plan $Plan -OutputFolder $OutputFolder -Markdown '' -EvidenceOnly
    if ($review.status -ne 'PASS') { throw "Required source retrieval failed. $($review.detail)" }
    foreach ($chapter in $Plan.chapters) {
        $assigned=@($Plan.requiredReadings | Where-Object { 0 -in $_.chapters -or $chapter.number -in $_.chapters })
        $records=@(foreach ($reading in $assigned) {
            # Strip Get-Content's provider metadata before serializing the brief
            # (Windows PowerShell otherwise traverses the filesystem provider).
            $sourceText=[IO.File]::ReadAllText((Join-Path $OutputFolder "source-readings/$($reading.id).txt"),[Text.Encoding]::UTF8)
            [pscustomobject]@{title=$reading.title;url=$reading.url;source='Required reading';year='';authors=@();preview=$sourceText;contentFile="source-readings/$($reading.id).txt";id=$reading.id}
        })
        [pscustomobject]@{chapterNumber=$chapter.number;chapterTitle=$chapter.title;sourcePolicy=[pscustomobject]@{mode='Assigned';lockedWeeklyAssignments=$true;summary='Teach from every assigned reading using its retrieved text. Cite the actual reading URL, never the course blueprint, objectives, or production notes. No unassigned sources.'};sourceContext=@(Find-SourceContextForChapter -Chapter $chapter -SourceContext $SourceContext -AllMatches);openStax=@();researchCandidates=$records;assignedSources=$records}
    }
}
