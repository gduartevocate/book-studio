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
  const selectors=host.querySelectorAll('select');
  if(selectors[0].value!=='Assigned' || selectors[1].value!=='Generic') throw new Error('Wrong initial preferences');
  const click=async(label)=>{[...host.querySelectorAll('button')].find(button=>button.textContent===label).click();await tick();};
  selectors[1].value='Business';selectors[1].dispatchEvent(new Event('input'));
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
  document.body.textContent='PASS: production controls, persistence, dirty-state guard, source failures, and explicit image generation';
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
if($result -notmatch '<body>PASS: production controls[^<]+</body>'){throw "Production UI test failed; inspect $fixture"}
'PASS: production controls, persistence, dirty-state guard, source failures, and explicit image generation.'
