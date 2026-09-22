$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$browser=@('C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Microsoft/Edge/Application/msedge.exe') | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(-not $browser){throw 'Chrome or Edge is required.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('book-production-ui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $root 'book-studio/production.js'))))
$html=@'
<!doctype html><meta charset="utf-8"><body>RUNNING<script>
(async () => { try {
  const source = new TextDecoder().decode(Uint8Array.from(atob('__SCRIPT__'), c => c.charCodeAt(0)));
  const makeElement = (tag, cls, text) => { const e=document.createElement(tag); e.className=cls; if(text) e.textContent=text; return e; };
  const state={sourceMode:'Assigned',requiredSources:'Week 1:\nhttps://example.org/read',readings:[{id:'r1',title:'Reading',url:'https://example.org/read',chapters:[1]}],imageSettings:{context:'Generic',instructions:''},sourceReport:{readings:[{id:'r1',url:'https://example.org/read',status:'Blocked',detail:'Needs accessible full text.'}]}};
  const calls=[];
  const api=async (path,options={}) => { calls.push({path,...options}); if(options.method==='POST' && path.endsWith('/production-settings')) { const saved=JSON.parse(options.body); state.sourceMode=saved.sourceMode;state.requiredSources=saved.requiredSources;state.imageSettings={context:saved.imageContext,instructions:saved.imageInstructions}; } return path.endsWith('/check-sources') ? {message:'Source check started.'} : state; };
  const mount=new Function('makeElement','api','loadJobs',source+'; return appendProductionPreferences;')(makeElement,api,async()=>{});
  document.body.textContent='';const host=document.createElement('div');document.body.append(host);
  mount(host,{id:'fixture',artifacts:[{fileName:'Test - E-Book.md'}]});
  if(calls.length) throw new Error('Settings fetched before expansion');
  const tick=()=>new Promise(resolve=>setTimeout(resolve,30));
  const panel=host.querySelector('details');panel.open=true;panel.dispatchEvent(new Event('toggle'));await tick();
  if(calls.length!==1 || !host.textContent.includes('Needs accessible full text.')) throw new Error('Reading status not visible or duplicate load');
  const fieldByLabel=(caption)=>{
    const label=[...host.querySelectorAll('label')].find(l=>l.textContent.includes(caption));
    if(!label) throw new Error('Control not found: '+caption);
    return label.querySelector('select,input,textarea');
  };
  if(fieldByLabel('Sources to use').value!=='Assigned' || fieldByLabel('Image setting').value!=='Generic') throw new Error('Wrong initial preferences');
  if(fieldByLabel('Reading level').value!=='8') throw new Error('Reading level must default to grade 8');
  const click=async(label)=>{[...host.querySelectorAll('button')].find(button=>button.textContent===label).click();await tick();};
  const imageField=fieldByLabel('Image setting');imageField.value='Business';imageField.dispatchEvent(new Event('input'));
  await click('Check required sources');
  if(calls.length!==1 || !host.textContent.includes('Save your settings first')) throw new Error('Unsaved settings used for retrieval');
  await click('Save settings');
  if(state.imageSettings.context!=='Business' || !host.textContent.includes('Existing manuscript and images are unchanged')) throw new Error('Save did not persist preferences');
  await click('Check required sources');
  if(!calls.some(call=>call.path.endsWith('/check-sources')) || !host.textContent.includes('Source check started')) throw new Error('Source action not wired');
  window.confirm=()=>false;const count=calls.length;
  await click('Generate images for saved setting');
  if(calls.length!==count) throw new Error('Cancelled generation still submitted');
  window.confirm=()=>true;await click('Generate images for saved setting');
  if(!calls.some(call=>call.path.endsWith('/generate-images'))) throw new Error('Image generation action not wired');
  const readingBox=host.querySelector('textarea');
  readingBox.value='Week 1:\nDescribe the stages of the revenue cycle\n[Reading](https://example.org/read)\nWeek 2:\nExplain how departments contribute\nWeek 3:\nhttps://example.org/other';
  await click('Remove entries with no URL');
  const cleaned=readingBox.value;
  if(cleaned.includes('Describe the stages') || cleaned.includes('Explain how departments')) throw new Error('Objectives without a URL were kept');
  if(!cleaned.includes('https://example.org/read') || !cleaned.includes('https://example.org/other')) throw new Error('Genuine readings were removed');
  if(cleaned.includes('Week 2:')) throw new Error('An emptied week heading was kept');
  if(!cleaned.includes('Week 1:') || !cleaned.includes('Week 3:')) throw new Error('Headings with readings were removed');
  if(!host.textContent.includes('Review the list, then Save settings')) throw new Error('Cleanup did not ask for a save');
  await click('Remove entries with no URL');
  if(!host.textContent.includes('Every entry already has a URL')) throw new Error('A clean list was not reported as clean');
  state.readings=[];state.requiredSources='';await click('Refresh source results');
  if(!host.textContent.includes('No required readings found')) throw new Error('Missing readings are not explained');
  document.body.textContent='PASS: production controls, persistence, dirty-state guard, URL-less entry cleanup, source failures, and explicit image generation';
} catch(error) { document.body.textContent='FAIL: '+error.message; } })();
</script>
'@
$page=Join-Path $fixture 'test.html'
$html.Replace('__SCRIPT__',$encoded) | Set-Content -LiteralPath $page -Encoding UTF8
$stdout=Join-Path $fixture 'stdout.txt';$stderr=Join-Path $fixture 'stderr.txt'
$args=@('--headless','--disable-gpu','--disable-extensions','--no-first-run','--no-default-browser-check','--virtual-time-budget=4000','--dump-dom',('--user-data-dir="'+(Join-Path $fixture 'profile')+'"'),('"'+([uri]$page).AbsoluteUri+'"'))
$process=Start-Process -FilePath $browser -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if(-not $process.WaitForExit(45000)){throw "Browser test exceeded 45 seconds. Fixture: $fixture"}
$result=Get-Content -LiteralPath $stdout -Raw -Encoding UTF8
# The panel must live in a container the active-book view shows; the
# workflow panel it used to share is hidden there.
$index=Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
$app=Get-Content -LiteralPath (Join-Path $root 'book-studio/app.js') -Raw -Encoding UTF8
$css=Get-Content -LiteralPath (Join-Path $root 'book-studio/styles.css') -Raw -Encoding UTF8
if($index -notmatch 'class="production-panel"'){throw 'The job template has no production-panel container.'}
if($app -notmatch 'appendProductionPreferences\(productionPanel'){throw 'Production preferences are not rendered into the visible container.'}
if($css -match '\.active-job-panel[^
]*\.production-panel[^
]*display:\s*none'){throw 'The active-book view hides the production panel.'}
if($result -notmatch '<body>PASS: production controls[^<]+</body>'){throw "Production UI test failed; inspect $fixture"}
'PASS: production controls, persistence, dirty-state guard, source failures, and explicit image generation.'
