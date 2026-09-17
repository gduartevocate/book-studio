$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# No Codex is started here. These checks guard the policy that lets Book Studio
# edit files on locked-down PCs: every Codex call must request the non-admin
# sandbox, and a downgraded (read-only) session must be reported as such.
. (Join-Path $root 'lib/EbookCodexSandbox.ps1')

Check ((Get-EbookCodexSandboxConfigArgument) -eq "-c 'windows.sandbox=`"unelevated`"'") 'Script-text sandbox argument must select the unelevated Windows sandbox.'
$list = @(Get-EbookCodexSandboxArgumentList)
Check ($list.Count -eq 2 -and $list[0] -eq '-c' -and $list[1] -eq 'windows.sandbox=\"unelevated\"') 'Start-Process sandbox argument list must select the unelevated Windows sandbox.'

$readOnlyHeader = "workdir: C:\fixture`nmodel: fixture`napproval: never`nsandbox: read-only`n--------`nuser`nEdit the book."
$writeHeader = "workdir: C:\fixture`napproval: never`nsandbox: workspace-write [workdir, /tmp, `$TMPDIR]`n--------`ncodex`nDone."
Check ((Get-EbookCodexSandboxMode -Text $readOnlyHeader) -eq 'read-only' -and (Get-EbookCodexSandboxMode -Text $writeHeader) -eq 'workspace-write') 'Sandbox mode must be read from the Codex session header.'
Check ((Get-EbookCodexSandboxFailure -Text $readOnlyHeader -ExpectedSandbox 'workspace-write') -match 'read-only file access instead of workspace-write') 'A downgraded write session must be explained.'
Check ((Get-EbookCodexSandboxFailure -Text $writeHeader -ExpectedSandbox 'workspace-write') -eq '') 'A real workspace-write session must not be flagged.'
Check ((Get-EbookCodexSandboxFailure -Text $readOnlyHeader -ExpectedSandbox 'read-only') -eq '') 'Read-only chat sessions are expected to be read-only.'
Check ((Get-EbookCodexSandboxFailure -Text $readOnlyHeader -ExpectedSandbox '') -eq '') 'Without an expectation nothing is flagged.'
Check ((Get-EbookCodexSandboxFailure -Text 'setup error: helper_sandbox_lock_failed: lock sandbox bin dir failed: 5' -ExpectedSandbox 'workspace-write') -ne '') 'A failed elevated sandbox setup must be explained.'
Check ((Get-EbookCodexSandboxFailure -Text 'I could not create hello.txt because this session only permits reading files.' -ExpectedSandbox 'workspace-write') -ne '') 'A read-only refusal in the model response must be explained.'

# Static guard: every Codex exec launch in the app requests the non-admin sandbox.
$launchers = @('ebook-generator.ps1', 'lib/EbookCodexImages.ps1', 'lib/BookStudio.psm1', 'lib/BookStudioConnection.ps1')
foreach ($file in $launchers) {
    $lines = Get-Content -LiteralPath (Join-Path $root $file) -Encoding UTF8
    $launches = @($lines | Where-Object { $_ -match "--sandbox" -and $_ -match "\bexec\b" -and $_ -notmatch '^\s*#' })
    Check ($launches.Count -gt 0) "$file must contain at least one Codex exec launch."
    foreach ($launch in $launches) {
        Check ($launch -match 'Get-EbookCodexSandbox(ConfigArgument|ArgumentList)|\$sandboxFlags') "$file launches Codex without the non-admin sandbox: $($launch.Trim().Substring(0, [Math]::Min(100, $launch.Trim().Length)))"
    }
}

# The Book Studio classifier reports the sandbox problem ahead of generic failures.
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
$failure = & $studio { param($t) Get-BookStudioCodexFailure -Text $t -ExpectedSandbox 'workspace-write' } $readOnlyHeader
Check ($failure.kind -eq 'sandbox' -and $failure.message -match 'non-admin sandbox') 'Downgraded edit sessions must be classified as sandbox failures.'
Check ((& $studio { param($t) Get-BookStudioCodexFailure -Text $t } $readOnlyHeader).kind -eq 'execution') 'Without an expected sandbox the generic classification stays.'
Check ((& $studio { param($t) Get-BookStudioCodexFailure -Text $t -ExpectedSandbox 'workspace-write' } "$readOnlyHeader`nError: 429 rate limit").kind -eq 'sandbox') 'The sandbox cause takes precedence over later noise in the log.'
Check ((& $studio { param($t) Get-BookStudioCodexFailure -Text $t -ExpectedSandbox 'workspace-write' } "$writeHeader`nError: 429 rate limit").kind -eq 'quota') 'A healthy write session still classifies other failures normally.'

Write-Output "PASS: $checks Codex sandbox policy assertions (non-admin sandbox on every launch, downgrade detection, classifier precedence)."
