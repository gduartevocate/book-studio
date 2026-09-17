$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/EbookGenerator.psm1') -Force
& (Get-Module EbookGenerator) {
    $script:layoutChecks=0
    function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:layoutChecks++}
    $fixture="# Chapter 1: Example`n`n> **Supervisor:** Use *verified* information. [Reading](https://example.com/reading)`n`n>`n`n| Field | Entry |`n| --- | --- |`n| Goal | Reliable service |`n| Owner | Alex |`n"
    [xml]$doc=ConvertTo-WordDocumentXml -Markdown $fixture
    $ns=[Xml.XmlNamespaceManager]::new($doc.NameTable);$ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $text=($doc.SelectNodes('//w:t',$ns) | ForEach-Object InnerText) -join ' '
    Check ($text -notmatch '>\s|\*verified\*') 'Quote or emphasis markers print in Word.'
    Check ($doc.SelectNodes('//w:r[w:rPr/w:i]/w:t',$ns).InnerText -contains 'verified') 'Single-star emphasis is not italic in Word.'
    Check ($doc.SelectNodes('//w:r[w:rPr/w:b]/w:t',$ns).InnerText -contains 'Supervisor:') 'Bold quote label was lost.'
    Check ($doc.SelectNodes('//w:p[w:pPr/w:ind/@w:left="360"]',$ns).Count -eq 1) 'Quote paragraph is not indented or an empty quote was emitted.'
    Check ($doc.SelectNodes('//w:hyperlink',$ns).Count -eq 1) 'Quote citation was lost.'
    Check ($doc.SelectSingleNode('//w:pgNumType/@w:start',$ns).Value -eq '1') 'Chapter-first numbering starts at zero.'
    Check ($doc.SelectNodes('//w:tbl/w:tr[1]/w:tc/w:p/w:pPr/w:keepNext',$ns).Count -eq 2) 'A header can be orphaned.'
    Check ($doc.SelectNodes('//w:tbl/w:tr[position()>1]/w:tc/w:p/w:pPr/w:keepNext',$ns).Count -eq 0) 'All table data rows were incorrectly chained together.'
    [xml]$styles=Get-WordStylesXml
    Check (@(Get-EbookWordTemplateIssues $styles $doc).Count -eq 0) 'Current layout failed its gate.'
    [xml]$bad=$doc.OuterXml.Replace('<w:keepNext />','').Replace('<w:keepNext/>','')
    Check (@(Get-EbookWordTemplateIssues $styles $bad).Count -gt 0) 'Orphan-header regression passed the gate.'
    [xml]$bad=$doc.OuterXml.Replace('w:start="1"','w:start="0"')
    Check (@(Get-EbookWordTemplateIssues $styles $bad).Count -gt 0) 'Cover-zero regression passed the gate.'
    $html=ConvertTo-SimpleHtmlFromMarkdown -Markdown $fixture
    Check ($html -match '<strong>Supervisor:</strong>' -and $html -match '<em>verified</em>') 'HTML emphasis differs from Word.'
    Check ($html -notmatch '&gt;\s*(?:&quot;|<strong>)') 'HTML prints quote markers.'
    Check ($html -match 'href="https://example.com/reading"') 'HTML link lost during emphasis rendering.'
    [xml]$cover=ConvertTo-WordDocumentXml -Markdown $fixture -IncludeCoverPage
    Check ($cover.SelectSingleNode('//w:pgNumType/@w:start',$ns).Value -eq '0') 'Explicit cover workflow was changed.'
    Write-Output "PASS: $script:layoutChecks Word/HTML layout regression assertions."
}
