function Test-BookStudioUploadRequest {
    param([Parameter(Mandatory)][object]$Request)
    $files=@($Request.files)
    if($files.Count -lt 1 -or $files.Count -gt 50){throw 'Upload 1 to 50 documents. Nothing was saved.'}
    $primary=0
    if($files.Count -gt 1 -and $null -eq $Request.primaryFileIndex){throw 'Select the authoritative course blueprint before uploading multiple files.'}
    if($null -ne $Request.primaryFileIndex -and (-not [int]::TryParse([string]$Request.primaryFileIndex,[ref]$primary) -or $primary -lt 0 -or $primary -ge $files.Count)){throw 'The selected course blueprint is not in this upload.'}
    if($Request.sourceMode -and $Request.sourceMode -notin @('UploadedOnly','Discovery','Assigned')){throw 'Unknown source mode.'}
    if($Request.imageContext -and $Request.imageContext -notin @('Generic','Healthcare','Business','Custom')){throw 'Unknown image setting.'}
    if(([string]$Request.requiredSources).Length -gt 40000 -or ([string]$Request.imageInstructions).Length -gt 4000){throw 'Required sources or image instructions exceed the input limit.'}
    if($Request.imageContext -eq 'Custom' -and [string]::IsNullOrWhiteSpace([string]$Request.imageInstructions)){throw 'Describe the custom image setting.'}
    $total=0L;$decoded=New-Object Collections.ArrayList
    foreach($file in $files){
        $extension=[IO.Path]::GetExtension([string]$file.name).ToLowerInvariant()
        if($extension -notin @('.docx','.txt','.md','.json','.html','.htm')){throw "Unsupported source: $($file.name). Use DOCX, TXT, Markdown, HTML, or JSON. Convert PDF/scanned files to readable DOCX or TXT first."}
        try{$bytes=[Convert]::FromBase64String([string]$file.contentBase64)}catch{throw "Invalid upload data: $($file.name)"}
        if($bytes.Length -eq 0 -or $bytes.Length -ge 5000000){throw "Each document must be nonempty and smaller than 5 MB: $($file.name)"}
        $total+=$bytes.Length
        if($total -gt 40000000){throw 'This upload exceeds 40 MB. Split or reduce the source documents.'}
        [void]$decoded.Add([pscustomobject]@{originalName=[string]$file.name;bytes=$bytes})
    }
    # Whether the authoritative document still needs the designer's outcome
    # analysis is the designer's call, not a guess from the layout. Getting it
    # wrong either skips the analysis a curriculum draft needs or demands one
    # for outcomes that are already final.
    if([string]::IsNullOrWhiteSpace([string]$Request.courseDocumentKind)){throw 'Say whether the authoritative course document is a curriculum draft that still needs its learning objectives analyzed, or an ebook-ready course file whose outcomes are final.'}
    if($Request.courseDocumentKind -notin @('CurriculumDraft','EbookReady')){throw 'Unknown course document kind.'}
    [pscustomobject]@{primaryFileIndex=$primary;files=@($decoded);sourceMode=$(if($Request.sourceMode){$Request.sourceMode}else{'UploadedOnly'});courseDocumentKind=[string]$Request.courseDocumentKind}
}
