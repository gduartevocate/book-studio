# Course-specific editorial reconstruction. Shared export/quality rules stay in EbookGenerator.
function ConvertFrom-Gm1025ReferenceDocx {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('word/document.xml').Open())
        try { [xml]$document = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $ns = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $parts = [Collections.Generic.List[string]]::new()
        $inNotes = $false; $listNumber = 0; $lastNum = ''
        foreach ($node in $document.SelectNodes('/w:document/w:body/*',$ns)) {
            if ($node.LocalName -eq 'tbl' -and -not $inNotes) {
                $rows = @($node.SelectNodes('w:tr',$ns)); $rowIndex = 0
                $table = @()
                foreach ($row in $rows) {
                    $cells = @($row.SelectNodes('w:tc',$ns) | ForEach-Object { (($_.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join '').Trim().Replace('|','/') })
                    $table += '| ' + ($cells -join ' | ') + ' |'
                    if ($rowIndex -eq 0) { $table += '| ' + ((@($cells | ForEach-Object {'---'})) -join ' | ') + ' |' }
                    $rowIndex++
                }
                $parts.Add(($table -join "`n")); $lastNum = ''; continue
            }
            if ($node.LocalName -ne 'p') { continue }
            $styleNode = $node.SelectSingleNode('w:pPr/w:pStyle',$ns)
            $style = if ($styleNode) { [string]$styleNode.val } else { '' }
            $text = ((@($node.SelectNodes('.//w:r',$ns) | ForEach-Object {
                $runText = ($_.SelectNodes('.//w:t',$ns) | ForEach-Object InnerText) -join ''
                $runStyle = $_.SelectSingleNode('w:rPr/w:rStyle',$ns)
                # Legacy note numerals are detached Hyperlink-styled runs in the supplied Word draft.
                if (-not ($runStyle -and $runStyle.val -eq 'Hyperlink' -and $runText.Trim() -match '^\d+$')) { $runText }
            })) -join '').Trim()
            if (-not $text) { continue }
            if ($text -match '^Chapter [1-5]:') { $inNotes=$false; $style='Heading1' }
            if ($text -match '^Scholarly Sources') { $inNotes=$true }
            if ($inNotes) { continue }
            if ($style -match '^Heading([1-4])$') { $text=('#' * [int]$Matches[1]) + ' ' + $text; $lastNum='' }
            elseif ($text -match '^(Vocabulary Review|Reflection Activity|Workplace Challenge|Knowledge Checks?|Check Your Reasoning|Chapter Summary)$') { $text='### ' + $text; $lastNum='' }
            else {
                $num = $node.SelectSingleNode('w:pPr/w:numPr/w:numId',$ns)
                if ($num) {
                    # Reconstruct list boundaries; decimal items get local numbering during Word export.
                    $numId=[string]$num.val
                    if ($numId -ne $lastNum) { $listNumber=0 }
                    $listNumber++; $lastNum=$numId
                    $text='- ' + $text
                } else { $lastNum='' }
            }
            $parts.Add($text)
        }
        return ($parts -join "`n`n") + "`n"
    } finally { $zip.Dispose() }
}
