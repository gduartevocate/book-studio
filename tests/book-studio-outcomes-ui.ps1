$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$browser=@('C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Microsoft/Edge/Application/msedge.exe') | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(-not $browser){throw 'Chrome or Edge is required.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('bs-outcomes-ui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $root 'book-studio/outcomes.js'))))
$appEncoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $root 'book-studio/app.js'))))
$html=@'
<!doctype html><meta charset="utf-8"><body>RUNNING<script>
(async () => { try {
  const decode=text=>new TextDecoder().decode(Uint8Array.from(atob(text), c=>c.charCodeAt(0)));
  const source=decode('__SCRIPT__'), app=decode('__APP__'); new Function(app);
  const makeElement=(tag,cls,text)=>{const e=document.createElement(tag);e.className=cls;if(text)e.textContent=text;return e;};
  const calls=[];let reloads=0;
  const api=async(path,options)=>{calls.push({path,body:JSON.parse(options.body)});return {planHash:'reviewed-hash',previousCount:2,newCount:4,uniqueOutcomes:4,chapters:[{number:1,title:'Records',previous:[{objectiveId:'LO1',objective:'Old wording.'}],records:[{objectiveId:'LO1.1',objective:'New wording.'}]}]};};
  const loadJobs=async()=>{reloads++;};
  const append=new Function('makeElement','api','loadJobs',source+';return appendOutcomeReplacement;')(makeElement,api,loadJobs);
  const renderSource=app.match(/function renderOutlineEditor\(container, job, outline\) \{[\s\S]*?(?=\nasync function loadOutlineEditor)/);
  if(!renderSource)throw new Error('Outline renderer not found');
  const editors=new Map();
  const render=new Function('makeElement','appendOutcomeReplacement','outlineEditors','api','loadJobs',renderSource[0]+';return renderOutlineEditor;')(makeElement,append,editors,api,loadJobs);
  const host=document.createElement('div');document.body.append(host);
  const outline={planHash:'original-hash',lastUpdate:{message:'Saved outline changes. Word/Markdown files refreshed.'},chapters:[{number:1,title:'Records',focus:'Records',guidance:'Align to CO1. Use a records example.',objectives:['Old wording.']},{number:2,title:'Handoffs',focus:'Handoffs',guidance:'Align to CO2. Use a handoff example.',objectives:['Old second wording.']}]};
  render(host,{id:'fixture'},outline);
  if(!host.querySelector('[role=status]').textContent.includes('Word/Markdown'))throw new Error('Persisted receipt not displayed on render');
  if(editors.get('fixture').planHash!=='original-hash')throw new Error('Stale-write token missing');
  editors.get('fixture').outcomeEditor.openWithText('CO1: Records.\nLO1.1: New wording.\nCO2: Handoffs.\nLO2.1: New second wording.');
  const panel=host.querySelector('.outcome-replacement');
  const inputs=[...panel.querySelectorAll('input')];
  if(!panel.open || inputs[0].value!=='CO1' || inputs[1].value!=='CO2')throw new Error('Chat-to-review loading or suggested assignments failed');
  const buttons=[...panel.querySelectorAll('button')];const preview=buttons[0],apply=buttons[1],confirm=panel.querySelector('[type=checkbox]');
  const tick=()=>new Promise(resolve=>setTimeout(resolve,30));
  if(!apply.disabled || calls.length)throw new Error('Review changed a book before explicit action');
  preview.click();await tick();
  if(!panel.textContent.includes('Old wording.') || !panel.textContent.includes('New wording.') || !apply.disabled)throw new Error('Comparison/confirmation gate failed');
  inputs[2].value='Fixture ID';inputs[2].dispatchEvent(new Event('input'));
  inputs[3].value='Approved replacement';inputs[3].dispatchEvent(new Event('input'));
  confirm.checked=true;confirm.dispatchEvent(new Event('change'));
  if(apply.disabled)throw new Error('Reviewer metadata erased the comparison');
  inputs[0].value='LO1.1';inputs[0].dispatchEvent(new Event('input'));
  if(!apply.disabled || confirm.checked || panel.querySelector('.outcome-diff').textContent)throw new Error('Changed assignment retained old confirmation');
  preview.click();await tick();confirm.checked=true;confirm.dispatchEvent(new Event('change'));apply.click();apply.click();await tick();
  const applied=calls.filter(c=>c.path.endsWith('/apply'));
  if(applied.length!==1 || applied[0].body.planHash!=='reviewed-hash' || !applied[0].body.confirm || applied[0].body.reviewedBy!=='Fixture ID' || reloads!==1)throw new Error('Reviewed replacement was not applied exactly once');
  render(host,{id:'fixture'},outline);
  if(!host.querySelector('.outline-update-receipt'))throw new Error('Receipt vanished after re-render');
  document.body.textContent='PASS: outcome review, explicit confirmation, stale-comparison invalidation, single apply, UTF-8 script parsing, and persistent receipt';
}catch(error){document.body.textContent='FAIL: '+error.message;} })();
</script>
'@
$page=Join-Path $fixture 'test.html'
$html.Replace('__SCRIPT__',$encoded).Replace('__APP__',$appEncoded) | Set-Content -LiteralPath $page -Encoding UTF8
$stdout=Join-Path $fixture 'stdout.txt';$stderr=Join-Path $fixture 'stderr.txt'
$args=@('--headless','--disable-gpu','--disable-extensions','--no-first-run','--no-default-browser-check','--virtual-time-budget=5000','--dump-dom',('--user-data-dir="'+(Join-Path $fixture 'profile')+'"'),('"'+([uri]$page).AbsoluteUri+'"'))
$process=Start-Process -FilePath $browser -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if(-not $process.WaitForExit(45000)){throw "Browser test exceeded 45 seconds. Fixture: $fixture"}
$result=Get-Content -LiteralPath $stdout -Raw -Encoding UTF8
if($result -notmatch '<body>PASS: outcome review[^<]+</body>'){throw "Outcome UI test failed; inspect $stdout"}
'PASS: outcome review, explicit confirmation, stale-comparison invalidation, single apply, and persistent receipt.'
