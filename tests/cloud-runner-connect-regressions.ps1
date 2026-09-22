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
    Check ($shortcut.Arguments -match '-File "') 'The script path must be quoted; a Book Studio folder with a space in its name silently starts nothing.'
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
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

"PASS: $checks connection assertions (token remembered and replaced, kept in the user profile, start with Windows without an administrator)."
