$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$browser=@('C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Microsoft/Edge/Application/msedge.exe') | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(-not $browser){throw 'Chrome or Edge is required.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('bs-outcome-analysis-ui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $root 'book-studio/outcome-analysis.js'))))
$appEncoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $root 'book-studio/app.js'))))
$html=@'
<!doctype html><meta charset="utf-8"><body>RUNNING<script>
(async () => { try {
  const decode=text=>new TextDecoder().decode(Uint8Array.from(atob(text), c=>c.charCodeAt(0)));
  const source=decode('__SCRIPT__'), app=decode('__APP__');
  // A real dialog blocks headless Chrome forever, so the panel must never open one.
  for(const name of ['confirm','alert','prompt']) window[name]=()=>{throw new Error('The outcome review opened a blocking '+name+' dialog');};
  const makeElement=(tag,cls,text)=>{const e=document.createElement(tag);e.className=cls;if(text)e.textContent=text;return e;};
  const calls=[];let runs=0,reloads=0;
  const analysis={
    status:'Suggested',statusDetail:'Review the analysis.',
    findings:['LO2 says "understand", which is not observable.'],
    catalogText:'CO1: Organize office records using clear naming rules.\nLO1.1: Identify the record types an office keeps.\nCO2: Coordinate office workflow using task ownership.\nLO2.1: Assign an owner to each workflow step.',
    assignments:[{number:1,ids:'CO1'},{number:2,ids:'CO2'}],
    objectiveFidelity:[],catalogError:'',reviewedBy:'',reason:'',
    courseObjectives:[{objectiveId:'CO1',objective:'Organize office records using clear naming rules.'},{objectiveId:'CO2',objective:'Coordinate office workflow using task ownership.'}],
    chapters:[
      {number:1,title:'Office Records',courseObjectiveIds:['CO1'],draftObjectives:[{objectiveId:'LO1',objective:'Understand office records.'}]},
      {number:2,title:'Workflow Coordination',courseObjectiveIds:['CO2'],draftObjectives:[{objectiveId:'LO2',objective:'Understand workflow coordination.'}]}
    ],
    promptUrl:'',responseUrl:'',errorUrl:''};
  const api=async(path,options)=>{
    calls.push({path,body:options&&options.body?JSON.parse(options.body):null});
    if(path.endsWith('/outcome-analysis'))return analysis;
    if(path.endsWith('/preview'))return {previousCount:2,newCount:2,uniqueOutcomes:2,chapters:[{number:1,title:'Office Records',previous:[{objectiveId:'LO1',objective:'Understand office records.'}],records:[{objectiveId:'LO1.1',objective:'Identify the record types an office keeps.'}]}]};
    return {status:'Approved'};
  };
  const runJob=async()=>{runs++;};
  const loadJobs=async()=>{reloads++;};
  const draw=new Function('makeElement','api','runJob','loadJobs',source+';return drawOutcomeAnalysisPanel;')(makeElement,api,runJob,loadJobs);
  const tick=()=>new Promise(resolve=>setTimeout(resolve,30));
  const panel=document.createElement('div');document.body.append(panel);
  const button=label=>[...panel.querySelectorAll('button')].find(b=>b.textContent.includes(label));

  draw({id:'fixture'},panel,analysis);
  if(!panel.textContent.includes('Organize office records using clear naming rules.'))throw new Error('Course objectives are not shown for reference');
  if(!panel.textContent.includes('Understand office records.'))throw new Error("The curriculum draft's own objectives are not shown");
  if(!panel.textContent.includes('not observable'))throw new Error('Analysis findings are not shown');
  const editor=panel.querySelector('.outline-editor-panel');
  const text=editor.querySelector('textarea');
  const inputs=[...editor.querySelectorAll('input')].filter(i=>i.type!=='checkbox');
  if(!text.value.startsWith('CO1: Organize office records'))throw new Error('The suggested outcomes did not prefill the editor');
  if(inputs[0].value!=='CO1'||inputs[1].value!=='CO2')throw new Error('Suggested chapter assignments did not prefill');
  const check=button('Check outcomes'),approve=button('Approve outcomes'),confirm=editor.querySelector('[type=checkbox]');
  if(!approve.disabled||calls.length)throw new Error('The review changed a book before any explicit action');

  check.click();await tick();
  if(!panel.textContent.includes('Understand office records.')||!panel.textContent.includes('Identify the record types an office keeps.'))throw new Error('The before/after comparison is missing');
  if(!approve.disabled)throw new Error('Approval was enabled without the confirmation checkbox');
  inputs[2].value='Fixture ID';inputs[2].dispatchEvent(new Event('input'));
  inputs[3].value='Reviewed against the draft';inputs[3].dispatchEvent(new Event('input'));
  confirm.checked=true;confirm.dispatchEvent(new Event('change'));
  if(approve.disabled)throw new Error('Entering the reviewer name invalidated the check');

  // A changed outcome must invalidate the comparison the designer approved.
  text.value=text.value+'\nLO2.2: Record each handoff.';text.dispatchEvent(new Event('input'));
  if(!approve.disabled||confirm.checked)throw new Error('An edited outcome list kept its old approval');
  check.click();await tick();confirm.checked=true;confirm.dispatchEvent(new Event('change'));
  approve.click();approve.click();await tick();
  const applied=calls.filter(c=>c.path.endsWith('/outcome-analysis/apply'));
  if(applied.length!==1)throw new Error('Approval was sent '+applied.length+' times');
  if(!applied[0].body.confirm||applied[0].body.reviewedBy!=='Fixture ID'||applied[0].body.reason!=='Reviewed against the draft')throw new Error('Approval was sent without its reviewed-by confirmation');
  if(applied[0].body.assignments.length!==2||applied[0].body.assignments[1].number!==2)throw new Error('Chapter assignments were not sent');
  if(runs!==1||reloads!==1)throw new Error('Approval did not start the format preview exactly once');

  // With no suggestion yet, the editor starts from the course objectives as
  // the draft states them, and never invents a learning objective.
  const blank=Object.assign({},analysis,{status:'Not analyzed',catalogText:'',assignments:[],findings:[]});
  const second=document.createElement('div');document.body.append(second);
  draw({id:'fixture'},second,blank);
  const blankText=second.querySelector('.outline-editor-panel textarea');
  if(blankText.value!=='CO1: Organize office records using clear naming rules.\nCO2: Coordinate office workflow using task ownership.')throw new Error('The fallback editor did not start from the course objectives alone');
  const blankInputs=[...second.querySelectorAll('.outline-editor-panel input')].filter(i=>i.type!=='checkbox');
  if(blankInputs[0].value!=='CO1')throw new Error("The draft's weekly course-objective mapping did not prefill the assignments");

  // A reply that reworded a course objective must be visible, not silent.
  const drifted=Object.assign({},analysis,{objectiveFidelity:[{objectiveId:'CO2',kind:'reworded',message:'CO2 was reworded. The course document states: "Coordinate office workflow using task ownership."'}]});
  const third=document.createElement('div');document.body.append(third);
  draw({id:'fixture'},third,drifted);
  if(!third.textContent.includes('CO2 was reworded'))throw new Error('A reworded course objective was not reported to the designer');

  // A book parked at its outcome review has no runner. Reported as processing,
  // its review action disappears and the list re-renders on every poll.
  const busyAt=app.indexOf('function isJobProcessing(job) {');
  if(busyAt<0)throw new Error('isJobProcessing not found in app.js');
  const busySource=[app.slice(busyAt, app.indexOf(String.fromCharCode(10)+'}', busyAt)+2)];
  const isBusy=new Function('activeStatuses',busySource[0]+';return isJobProcessing;')(new Set(['Queued','Running']));
  if(isBusy({workflowStage:'outcomes-analysis',status:'Queued'}))throw new Error('A book parked at its outcome review reports as generating');
  if(isBusy({workflowStage:'outcomes-analysis',status:'Review'}))throw new Error('A parked book with its own status reports as generating');
  if(!isBusy({workflowStage:'outcomes-analysis',status:'Running',runnerProcessId:42}))throw new Error('A book with a live runner must still report as busy');
  if(!isBusy({workflowStage:'generating',status:'Running'}))throw new Error('A generating book must report as busy');

  // Re-rendering must not discard a half-written review.
  const refresh=new Function('makeElement','api','runJob','loadJobs',source+';return refreshOutcomeAnalysisPanel;')(makeElement,api,runJob,loadJobs);
  const live=document.createElement('div');document.body.append(live);
  await refresh({id:'fixture'},live);
  const typed=live.querySelector('.outline-editor-panel textarea');
  typed.value='CO1: half-written edit in progress';
  const typedAssignment=[...live.querySelectorAll('.outline-editor-panel input')].filter(i=>i.type!=='checkbox')[0];
  typedAssignment.value='LO1.1';
  await refresh({id:'fixture'},live);
  await refresh({id:'fixture'},live);
  const after=live.querySelector('.outline-editor-panel textarea');
  if(after.value!=='CO1: half-written edit in progress')throw new Error('A poll rebuilt the panel and discarded the designer edit');
  if([...live.querySelectorAll('.outline-editor-panel input')].filter(i=>i.type!=='checkbox')[0].value!=='LO1.1')throw new Error('A poll discarded the chapter assignment being edited');
  analysis.status='Failed';analysis.errorDetail='Analysis stopped.';
  await refresh({id:'fixture'},live);
  if(!live.textContent.includes('Analysis stopped.'))throw new Error('A changed analysis did not redraw the panel');

  // Once the book moves on, the approved outcomes and the reusable course
  // file must still be reachable.
  const render=new Function('makeElement','api','runJob','loadJobs','formatDate',source+';return renderOutcomeAnalysisPanel;')(makeElement,api,runJob,loadJobs,v=>v);
  const done=document.createElement('div');document.body.append(done);
  render({id:'fixture',workflowStage:'format-review',outcomeAnalysis:{status:'Approved',statusDetail:'Approved by Fixture ID.',reason:'Reviewed',documents:[{name:'Ebook-ready course file (reusable)',fileName:'QA1000 - Ebook Course File.md'}]}},done);
  if(done.hidden)throw new Error('The approved outcomes were hidden once the book moved on');
  const link=done.querySelector('a');
  if(!link||!link.getAttribute('href').includes('outcome-analysis/file?name=QA1000%20-%20Ebook%20Course%20File.md'))throw new Error('The reusable course file is not downloadable after approval');
  const other=document.createElement('div');document.body.append(other);
  render({id:'fixture',workflowStage:'id-review',outcomeAnalysis:null},other);
  if(!other.hidden)throw new Error('A book with no outcome review showed an empty panel');

  document.body.textContent='PASS: outcome analysis review, explicit confirmation, stale-comparison invalidation, single approval, verbatim-objective warning, and fallback editor';
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
if($result -notmatch '<body>PASS: outcome analysis review[^<]+</body>'){throw "Outcome analysis UI test failed; inspect $stdout"}
Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
'PASS: outcome analysis review, explicit confirmation, stale-comparison invalidation, single approval, verbatim-objective warning, and fallback editor.'
