$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$index=Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
foreach($id in @('bookChatHeading','bookChatForm','bookChatJobSelect','bookChatScopeSelect','bookChatNew','bookChatThread','bookChatMessage','bookChatConnectionStatus','bookChatTestConnection','bookChatAllowEdits','bookChatStatus','bookChatSend')) {
  if(([regex]::Matches($index,('id="'+$id+'"'))).Count -ne 1){throw "Chat control ID is duplicated or missing: $id"}
}
if(([regex]::Matches($index,'class="chat-panel"')).Count -ne 1 -or ([regex]::Matches($index,'class="book-library"')).Count -ne 1){throw 'The page must have one chat panel and one book library sidebar.'}
if($index -notmatch '<section class="workspace-main"[\s\S]*class="chat-panel"'){throw 'Ask Codex must live in the main content stack.'}
$source=Get-Content -LiteralPath (Join-Path $root 'book-studio/app.js') -Raw -Encoding UTF8
# Every element the app looks up must exist in the page, unless the lookup is
# optional (?.). A missing element throws at load and stops the app before it
# fetches the book list, which hides every book.
foreach($lookup in [regex]::Matches($source,'getElementById\("([^"]+)"\)(\?\.)?')) {
  if($lookup.Groups[2].Success){continue}
  if($index -notmatch ('id="'+[regex]::Escape($lookup.Groups[1].Value)+'"')){throw "app.js references an element that index.html does not define: $($lookup.Groups[1].Value)"}
}
if($index -notmatch 'Allow Codex to edit book source files' -or $source -notmatch 'Edit book content' -or $source -notmatch 'bookChatPanel\.hidden = false'){throw 'The review workspace must expose direct editing and a working format-review Codex action.'}
$browser=@('C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Microsoft/Edge/Application/msedge.exe') | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(-not $browser){throw 'Chrome or Edge is required for the readiness UI smoke test.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ebook-ui-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
$html=@'
<!doctype html><meta charset="utf-8"><body>RUNNING<script>
try {
  const source = new TextDecoder().decode(Uint8Array.from(atob('__APP__'), c => c.charCodeAt(0)));
  new Function(source); // Parse the entire real application, without booting it.
  const match = source.match(/function renderJobQaSummary\(container, job\) \{[\s\S]*?(?=\nfunction )/);
  if (!match) throw new Error('Real QA rendering function missing');
  function makeElement(tag, className, text) { const e = document.createElement(tag); e.className = className; if (text) e.textContent = text; return e; }
  const render = new Function('makeElement', match[0] + '; return renderJobQaSummary;')(makeElement);
  function check(qa, wanted, absent) {
    const host = document.createElement('div'); render(host, {qaSummary: qa});
    if (!host.textContent.includes(wanted) || (absent && host.textContent.includes(absent))) throw new Error(host.textContent);
  }
  check({status:'PASS', draftReadyForReview:true, publicationReady:false}, 'Not publication-approved: human approvals required', 'Publication approvals recorded');
  check({status:'PASS'}, 'Draft not cleared by current gates', 'Technical/editorial gates passed');
  check({status:'FAIL', draftReadyForReview:false}, 'QA FAIL - Needs revision', 'Technical/editorial gates passed');
  check({status:'PASS', draftReadyForReview:true, publicationReady:true}, 'Publication approvals recorded', 'Not publication-approved');
  const formatSource = source.match(/function renderFormatReviewPanel\(job, panel\) \{[\s\S]*?(?=\nfunction )/);
  if (!formatSource) throw new Error('Actual format panel function missing');
  const loadOutlineEditor = (container) => container.append(makeElement('p', 'outline-editor-loading', 'Loading the current planned outline...'));
  const renderFormat = new Function('makeElement','getWorkflowStage','activeStatuses','loadOutlineEditor',formatSource[0]+'; return renderFormatReviewPanel;')(makeElement, job => job.workflowStage, new Set(['Queued','Running']), loadOutlineEditor);
  const panel = document.createElement('div');
  renderFormat({id:'fixture',status:'Completed',workflowStage:'format-review',outputFolder:'fixture',formatReview:{status:'Needs revision'},formatState:{layout:'large-text',fingerprint:'current-fingerprint'},intake:{readFiles:2,uploadedFiles:2,primarySource:'blueprint.docx'},options:{sourceMode:'UploadedOnly'}},panel);
  if (panel.hidden || panel.querySelector('select').value !== 'large-text' || !panel.querySelector('iframe').src.includes('current-fingerprint') || !panel.querySelector('.outline-editor-panel')) throw new Error('Format setting, outline editor, or preview version missing');
  if (!panel.textContent.includes('2/2 files read') || !panel.textContent.includes('no additional reading search') || !panel.textContent.includes('notes do not change the layout automatically')) throw new Error('Intake or notes boundary missing');
  const approve = [...panel.querySelectorAll('button')].find(button => button.textContent.startsWith('Approve format'));
  approve.click(); // Must fail locally until the review checkbox is confirmed.
  if (!panel.textContent.includes('confirm the checkbox before approval')) throw new Error('Unchecked review was not blocked');
  const parserSource = source.match(/function parseSuggestedOutlineChanges\(text\) \{[\s\S]*?\n\}(?=\r?\n)/);
  if (!parserSource) throw new Error('Outline suggestion parser missing');
  const parse = new Function(parserSource[0] + '; return parseSuggestedOutlineChanges;')();
  const reply = 'Recommendations...\n\nSUGGESTED OUTLINE CHANGES\nChapter 2 title: Claims That Get Paid\nChapter 2 focus: clean claim submission and payer rules\n- Chapter 2 guidance: Use one clinic scenario throughout.\nContinue it into the toolbox.\nChapter 9 title: Ignored later\nEND SUGGESTED OUTLINE CHANGES\nThanks.';
  const parsed = parse(reply);
  if (parsed.length !== 4 || parsed[0].number !== 2 || parsed[0].field !== 'title' || parsed[1].value !== 'clean claim submission and payer rules' || parsed[2].value !== 'Use one clinic scenario throughout. Continue it into the toolbox.') throw new Error('Outline suggestion block was not parsed: ' + JSON.stringify(parsed));
  if (parse('No block here').length !== 0) throw new Error('A reply without a block must yield no suggestions');
  const sourceChoice = source.match(/function refreshSourceChoices\(\) \{[\s\S]*?\n\}(?=\r?\nform\.elements\.files)/);
  if (!sourceChoice) throw new Error('Actual source-selection function missing');
  const primary = document.createElement('select'); primary.id='primarySourceSelect'; document.body.append(primary);
  const form = {elements:{files:{files:[{name:'same.docx'},{name:'same.docx'}]},sourceMode:{value:'UploadedOnly'},skipResearch:{type:'checkbox'},skipOpenStaxFetch:{type:'checkbox'},maxResearchPerChapter:{type:'number'}}};
  new Function('form',sourceChoice[0]+'; refreshSourceChoices();')(form);
  if (primary.value !== '' || primary.options.length !== 3 || !form.elements.skipResearch.disabled || !form.elements.skipResearch.checked) throw new Error('Explicit blueprint choice or uploaded-only default failed');
  document.body.textContent = 'PASS: full app.js syntax, 4 QA states, format/intake rendering, approval checkbox, and explicit source selection';
} catch(error) { document.body.textContent = 'FAIL: ' + error.message; }
</script>
'@
$page=Join-Path $fixture 'test.html'
$html.Replace('__APP__',$encoded) | Set-Content -LiteralPath $page -Encoding UTF8
$stdout=Join-Path $fixture 'stdout.txt';$stderr=Join-Path $fixture 'stderr.txt'
$args=@('--headless','--disable-gpu','--disable-extensions','--no-first-run','--no-default-browser-check','--dump-dom',('--user-data-dir="'+(Join-Path $fixture 'profile')+'"'),('"'+([uri]$page).AbsoluteUri+'"'))
$process=Start-Process -FilePath $browser -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if(-not $process.WaitForExit(45000)){throw "Browser test exceeded 45 seconds. Test-only process ID: $($process.Id)"}
$result=Get-Content -LiteralPath $stdout -Raw -Encoding UTF8
if($result -notmatch '<body>PASS: full app.js syntax, 4 QA states, format/intake rendering, approval checkbox, and explicit source selection\s*</body>'){throw "Browser readiness test failed; inspect $fixture"}
Write-Output 'PASS: full app.js syntax, 4 QA states, format/intake rendering, approval checkbox, and explicit source selection.'
