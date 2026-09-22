$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

. (Join-Path $root 'lib/EbookCloudRunner.ps1')

# Connecting a computer has to cost a designer one pasted command, once. These
# are the rules that make the second start, and every start after it, cost
# nothing: the token is remembered in the person's own profile, a newly pasted
# token replaces a remembered one, and the machine can reconnect on its own
# without an administrator anywhere in it.

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-connect-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $state = Join-Path $fixture 'state\runner.json'
    $startup = Join-Path $fixture 'startup'

    # 1. With nothing to go on, the agent must say what to do, not guess.
    $none = Resolve-BookRunnerToken -Path $state
    Check ($none.token -eq '') 'A token must not be invented when there is none.'
    Check ($none.source -eq 'nowhere') 'The agent must be able to say where a token came from.'

    # 2. A pasted token is remembered, and found again on the next start with
    #    nothing on the command line. This is the whole point: paste once.
    $saved = Save-BookRunnerToken -Token 'first-token' -Path $state
    Check (Test-Path -LiteralPath $saved) 'Saving a token must write the file it reports.'
    $remembered = Resolve-BookRunnerToken -Path $state
    Check ($remembered.token -eq 'first-token') 'A saved token must be found on the next start.'
    Check ($remembered.source -like '*saved*') 'The agent must say the token came from this computer.'

    # 3. A newly pasted token wins over the remembered one. An administrator
    #    reissuing a password or a token must not be defeated by a stale file.
    $pasted = Resolve-BookRunnerToken -Token 'second-token' -Path $state
    Check ($pasted.token -eq 'second-token') 'A token given on the command line must win over the saved one.'
    Check ($pasted.source -eq 'command line') 'The source of the winning token must be reported.'
    Save-BookRunnerToken -Token 'second-token' -Path $state | Out-Null
    Check ((Resolve-BookRunnerToken -Path $state).token -eq 'second-token') 'Pasting a new token must replace what was remembered.'

    # 4. The environment still works, because the .env file on the machine that
    #    was set up before this existed is read into it.
    $fromEnvironment = Resolve-BookRunnerToken -EnvironmentToken 'env-token' -Path $state
    Check ($fromEnvironment.token -eq 'env-token') 'A token in the environment must still be honoured.'
    Check ((Resolve-BookRunnerToken -Token 'typed' -EnvironmentToken 'env-token' -Path $state).token -eq 'typed') 'The typed token must win over the environment.'

    # 5. A corrupted state file must not stop the agent starting; it asks again.
    Set-Content -LiteralPath $state -Value 'not json at all' -Encoding UTF8
    Check ((Resolve-BookRunnerToken -Path $state).token -eq '') 'A damaged token file must be ignored rather than thrown.'
    Save-BookRunnerToken -Token 'third-token' -Path $state | Out-Null
    Check ((Get-SavedBookRunnerToken -Path $state) -eq 'third-token') 'Saving over a damaged file must work.'

    # 6. The token lives in the user's profile by default, not in the Book
    #    Studio folder: updating or re-cloning the app must not disconnect the
    #    machine, and two people on one PC must not share a token.
    $default = Get-BookRunnerStatePath
    Check ($default -like "$env:LOCALAPPDATA*") "The token must be kept in the user's own profile, not in the app folder; got $default"
    Check ($default -notlike "$root*") 'The token must not be kept inside the Book Studio folder.'

    # 7. Starting with Windows is a shortcut in the person's own Startup folder.
    #    Designer PCs are locked down, so anything needing an administrator
    #    cannot be part of a setup they do themselves.
    Check (-not (Test-BookRunnerStartupInstalled -StartupFolder $startup)) 'Nothing must start with Windows until it is asked for.'
    $scriptPath = Join-Path $root 'cloud-book-runner.ps1'
    $link = Install-BookRunnerStartup -ScriptPath $scriptPath -StartupFolder $startup
    Check (Test-Path -LiteralPath $link) 'Asking for it must create the shortcut.'
    Check (Test-BookRunnerStartupInstalled -StartupFolder $startup) 'An installed shortcut must be reported as installed.'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    Check ($shortcut.TargetPath -like '*powershell.exe') 'The shortcut must start PowerShell.'
    # Quoted, because a Book Studio folder can have a space in it, and read as a
    # command rather than started as a file, because a managed computer refuses
    # to run a .ps1 at all and a designer cannot change that.
    Check ($shortcut.Arguments -match "LiteralPath '") 'The script path must be quoted; a Book Studio folder with a space in its name silently starts nothing.'
    Check ($shortcut.Arguments -match [regex]::Escape($scriptPath)) 'The shortcut must start this copy of the agent.'
    Check ($shortcut.Arguments -match '-WindowStyle Minimized') 'The agent must not sit in front of the designer all day.'
    Check ($shortcut.Arguments -notmatch 'Token') 'The shortcut must not carry the token; that is what the saved file is for.'

    # 8. And it can be taken off again by the same person, without an installer.
    Uninstall-BookRunnerStartup -StartupFolder $startup | Out-Null
    Check (-not (Test-BookRunnerStartupInstalled -StartupFolder $startup)) 'Removing it must stop it starting with Windows.'
    Uninstall-BookRunnerStartup -StartupFolder $startup | Out-Null
    Check ($true) 'Removing it twice must not fail.'

    # 9. The agent itself must accept what the connect page tells a designer to
    #    type, and must explain itself when there is no token at all.
    $runner = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    Check ($runner -match '(?m)^\s*\[string\]\$Token\s*=') 'The agent must take -Token, which is what the connect page shows.'
    Check ($runner -match '(?m)^\s*\[switch\]\$StartWithWindows') 'The agent must take -StartWithWindows.'
    Check ($runner -match '(?m)^\s*\[switch\]\$StopStartingWithWindows') 'There must be a way to undo it.'
    Check ($runner -match 'Resolve-BookRunnerToken') 'The agent must resolve its token through the tested path.'
    Check ($runner -match 'Save-BookRunnerToken') 'The agent must remember a token that was pasted.'
    Check ($runner -match '/connect') 'A missing token must point at the page that issues one.'
    # The agent dials one address and the designer signs in at another. Naming
    # the machine-facing one sends someone to a page they have no account on.
    Check ($runner -match 'SignInUrl\s*=\s*"https://ebook\.vocate\.app/connect"') 'The agent must point a designer at the address they sign in at.'
    Check ($runner -match 'Sign in at \$SignInUrl') 'The missing-token message must use the sign-in address, not the address the agent dials.'
    Check ($runner -notmatch 'deploy-ebook-generator-cloudflare\.ps1 once to create it') 'A designer must not be told to run a deployment script.'
    Check ($runner -match "EbookCloudRunner\.ps1") 'The agent must dot-source the connection library.'
    # A designer watching the window must be able to tell a computer that
    # reported itself from one that quietly could not: the web page looks the
    # same either way until it is refreshed.
    Check ($runner -match 'now visible in Book Studio') 'The agent must say when the cloud has accepted this computer.'
    Check ($runner -match 'could not report itself') 'The agent must say when it could not, rather than looking healthy.'
    Check ($runner -match 'reportedOnce') 'That confirmation must be said once, not on every poll.'
    # A function that returns a value prints it when the caller ignores it, so
    # the word True appeared in the middle of what a designer was reading.
    Check ($runner -notmatch '(?m)^\s*Publish-CodexStatus[^|
]*$') 'The result of reporting must be consumed, or it is printed at the designer.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# 10. The one command the connect page hands a designer fetches a setup script
#     from the worker and runs it. It is the only thing most people will ever
#     type, so it has to be valid PowerShell, has to survive being run twice,
#     and has to say what to do about the two things it cannot install.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $fixture2 = Join-Path ([IO.Path]::GetTempPath()) ('setup-script-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture2 | Out-Null
    $render = Join-Path $fixture2 'render.js'
    $rendered = Join-Path $fixture2 'setup.ps1'
    $workerPath = (Join-Path $root 'cloudflare/ebook-generator-worker.js').Replace('\', '/')
    @(
        "const {readFileSync,writeFileSync,mkdtempSync}=require('fs');const {tmpdir}=require('os');const {join}=require('path');",
        "const d=mkdtempSync(join(tmpdir(),'setup-'));const c=join(d,'w.mjs');writeFileSync(c,readFileSync('$workerPath'));",
        "import(require('url').pathToFileURL(c).href).then(async m=>{",
        "  const kv={async get(){return null},async put(){},async delete(){},async list(){return{keys:[]}}};",
        "  const r=await m.default.fetch(new Request('https://ebook.vocate.app/setup.ps1?token=testtoken123'),{BOOK_STUDIO_KV:kv,BOOK_STUDIO_FILES:{},REQUIRE_ACCESS:'false'});",
        "  writeFileSync(process.argv[2], await r.text());",
        "});"
    ) -join "`n" | Set-Content -LiteralPath $render -Encoding UTF8
    & $node.Source $render $rendered | Out-Null
    Check (Test-Path -LiteralPath $rendered) 'The worker must serve a setup script at /setup.ps1.'
    $setup = Get-Content -LiteralPath $rendered -Raw -Encoding UTF8
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($setup, [ref]$null, [ref]$errors) | Out-Null
    Check ($errors.Count -eq 0) "The setup command a designer pastes is not valid PowerShell: $($errors | Select-Object -First 1)"
    Check ($setup -match "testtoken123") 'The setup script must carry the token the page issued.'
    Check ($setup -match 'git-scm\.com') 'The setup script must say where to get Git when it is missing.'
    Check ($setup -match 'npm install -g @openai/codex') 'The setup script must say how to install Codex.'
    Check ($setup -match 'codex login') 'The setup script must say Codex has to be signed in.'
    Check ($setup -match 'git clone' -and $setup -match 'git -C \$folder pull') 'The setup script must install Book Studio, and update it when it is already there.'
    Check ($setup -match '-StartWithWindows') 'The setup script must leave the computer connecting on its own.'
    Check ($setup -match 'LOCALAPPDATA') 'Book Studio must land somewhere that needs no administrator.'
    Check ($setup -notmatch 'Program Files') 'The setup script must not install anywhere that needs an administrator.'
    Check ($setup -notmatch '(?m)^\s*Remove-Item') 'The setup script must not delete anything on a designer PC.'
    Remove-Item -LiteralPath $fixture2 -Recurse -Force -ErrorAction SilentlyContinue
}
else { Write-Warning 'node was not found; the setup script was not rendered or parsed.' }

# 11. A designer PC refuses to run a .ps1 file at all. That is not a setting
#     they can change: the policy comes from their organisation, and even
#     -ExecutionPolicy Bypass is overridden by it. The first version of the
#     setup command died exactly there, after cloning, with "running scripts is
#     disabled on this system". So both ways of starting the agent are run here
#     under a Restricted policy: the file must fail, and the way Book Studio
#     actually starts it must work.
$policyFixture = Join-Path ([IO.Path]::GetTempPath()) ('exec-policy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $policyFixture | Out-Null
try {
    $sample = Join-Path $policyFixture 'sample agent.ps1'
    Set-Content -LiteralPath $sample -Value 'param([string]$Token)' -Encoding UTF8
    Add-Content -LiteralPath $sample -Value 'Write-Output ("agent ran with " + $Token)' -Encoding UTF8

    # Output goes to files, never through a pipe: PowerShell 5.1 turns a native
    # program's stderr into a terminating error, and a blocked script writing to
    # stderr is exactly what this is trying to observe.
    function Invoke-Restricted([string[]]$Arguments, [string]$Name) {
        $out = Join-Path $policyFixture "$Name.out"
        $err = Join-Path $policyFixture "$Name.err"
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $process.WaitForExit(60000)) { $process.Kill() }
        return ((Get-Content -LiteralPath $out -Raw) + '' ) + ((Get-Content -LiteralPath $err -Raw) + '')
    }

    $asFile = Invoke-Restricted @('-NoProfile', '-ExecutionPolicy', 'Restricted', '-File', "`"$sample`"", '-Token', 'abc') 'file'
    Check ($asFile -notmatch 'agent ran with abc') 'This computer is not enforcing a restricted policy, so the check below proves nothing.'
    Check ($asFile -match 'cannot be loaded') "A restricted policy must refuse a script file; got: $asFile"

    $command = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath ''' + $sample + '''))) -Token abc'
    $asCommand = Invoke-Restricted @('-NoProfile', '-ExecutionPolicy', 'Restricted', '-Command', "`"$command`"") 'command'
    Check ($asCommand -match 'agent ran with abc') "Book Studio must start its agent on a computer that forbids running script files; got: $asCommand"

    # And the startup shortcut has to use that same way in, or the machine
    # connects once and never again after a restart.
    $startup2 = Join-Path $policyFixture 'startup'
    $link = Install-BookRunnerStartup -ScriptPath $sample -StartupFolder $startup2
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    Check ($shortcut.Arguments -match 'scriptblock\]::Create') 'The startup shortcut must start the agent as a command, not as a file.'
    Check ($shortcut.Arguments -notmatch '-File ') 'The startup shortcut must not start a file; a managed PC refuses to run one.'
    $shortcutCommand = [regex]::Match($shortcut.Arguments, '-Command "(.+)"$').Groups[1].Value
    Check ([bool]$shortcutCommand) 'The shortcut must carry a command to run.'
    $fromShortcut = Invoke-Restricted @('-NoProfile', '-ExecutionPolicy', 'Restricted', '-Command', "`"$shortcutCommand`"") 'shortcut'
    Check ($fromShortcut -match 'agent ran') "What the startup shortcut runs must work under a restricted policy; got: $fromShortcut"
}
finally {
    Remove-Item -LiteralPath $policyFixture -Recurse -Force -ErrorAction SilentlyContinue
}

# 12. The setup script must say the same thing: a file is never started, and
#     the per-user policy is only ever attempted, never required.
if ($node) {
    Check ($setup -match 'scriptblock\]::Create') 'The setup script must run the agent as a command, or a managed PC stops after cloning.'
    Check ($setup -match 'Set-ExecutionPolicy -Scope CurrentUser') 'The setup script should try to make this easier for the next time.'
    Check ($setup -match '(?s)try \{ Set-ExecutionPolicy.*?catch') 'A refused policy change must not stop the setup.'
    Check ($setup -notmatch 'Scope LocalMachine') 'Nothing may need an administrator.'
    Check ($setup -match '-ProjectRoot \$folder') 'Run as a command, the agent cannot work out its own folder; it must be told.'
    # The cloud and the copy of Book Studio on a PC are released separately, so
    # the PC can legitimately be behind. Saying so is the difference between a
    # designer knowing to ask for a release and reading a binding error about
    # an empty string, which is what actually happened.
    Check ($setup -match "needed = '\d{4}\.\d{2}\.\d{2}\.\d+'") 'The setup script must know the oldest Book Studio the cloud can drive.'
    Check ($setup -match 'older than the cloud expects') 'A version that is too old must be explained in words.'
    Check ($setup -match 'version\.json') 'The check must read the version actually installed.'
    Check ($setup -match '(?s)older than the cloud expects.*?return') 'A version that is too old must stop, not carry on into a confusing error.'
    # "Which version do I have?" must be answerable by reading the window, not
    # by reading the code.
    Check ($setup -match 'Book Studio on this computer: ') 'The setup script must say which version is on that computer.'
    Check ($setup -match '(?s)git -C \$folder pull --ff-only.*?LASTEXITCODE') 'A failed update must be reported, not passed over in silence.'
}

"PASS: $checks connection assertions (token remembered and replaced, kept in the user profile, start with Windows without an administrator)."
