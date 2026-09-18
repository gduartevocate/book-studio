function Test-EbookUploadedSourceEvidence {
    param([object]$Plan,[object]$ChapterSources,[object]$SourceContext)
    if($Plan.sourceMode -ne 'UploadedOnly' -or $ChapterSources.sourcePolicy.mode -ne 'UploadedOnly' -or $SourceContext.sourceMode -ne 'UploadedOnly'){return $false}
    if(-not @($SourceContext.files).Count -or -not @($ChapterSources.sourceContext).Count -or @(@($ChapterSources.openStax) + @($ChapterSources.oer) | Where-Object {$_}).Count -or @($ChapterSources.researchCandidates | Where-Object {$_}).Count){return $false}
    foreach($file in $SourceContext.files){
        if(-not $file.sha256 -or -not (Test-Path -LiteralPath $file.path -PathType Leaf) -or (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ne $file.sha256){return $false}
    }
    foreach($chunk in $ChapterSources.sourceContext){
        $metadata=@($SourceContext.files | Where-Object path -eq $chunk.sourceFile)[0]
        if($metadata.isCourseSpec -or $metadata.name -match '^book-studio-(brief|format-review)\.'){return $false}
        $original=@($SourceContext.chunks | Where-Object {$_.chunkId -eq $chunk.chunkId -and $_.sourceFile -eq $chunk.sourceFile})
        if($chunk.sourceFile -notin @($SourceContext.files.path) -or $original.Count -ne 1 -or [string]::IsNullOrWhiteSpace($chunk.excerpt) -or $original[0].rawText -cne $chunk.excerpt){return $false}
    }
    return $true
}

function Get-EbookUploadedSourceReview {
    param([object]$Plan,[object[]]$Sources,[object]$SourceContext,[string]$Markdown)
    $issues=New-Object Collections.Generic.List[string]
    if($Plan.sourceMode -ne 'UploadedOnly'){return [pscustomobject]@{applicable=$false;status='PASS';detail='Uploaded-only mode is not selected.'}}
    foreach($chapter in $Plan.chapters){
        $chapterSources=Get-ChapterSources -Sources $Sources -ChapterNumber $chapter.number
        if(-not (Test-EbookUploadedSourceEvidence -Plan $Plan -ChapterSources $chapterSources -SourceContext $SourceContext)){$issues.Add("Chapter $($chapter.number) has missing, changed, or invalid teaching evidence. The blueprint/production notes are not scholarly sources; select Required readings to use their assigned URLs.")}
    }
    if($Markdown -match '\]\(https?://'){$issues.Add('Uploaded-only mode cannot introduce external citation links. Use the provided document references and internal chapter notes.')}
    [pscustomobject]@{applicable=$true;status=$(if($issues.Count){'FAIL'}else{'PASS'});issues=@($issues);detail=$(if($issues.Count){$issues -join ' '}else{'Uploaded-only source boundary and current source-file hashes verified. Academic coverage still needs review.'})}
}
