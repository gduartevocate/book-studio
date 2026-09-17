# Codex sandbox policy shared by the generator, image pass, chat, and the
# connection test.
#
# Codex CLI on Windows has two workspace-write sandboxes. The default
# "elevated" one needs a one-time administrator setup (it creates local
# accounts, firewall rules, and ACLs); when that setup is missing or broken,
# Codex silently downgrades every session to read-only and the model cannot
# save a single file. Book Studio must work on locked-down PCs without admin
# rights, so every Codex call asks for the "unelevated" restricted-token
# sandbox instead. It needs no setup and still confines writes to the package
# folder. Every caller also verifies the session header Codex prints
# ("sandbox: workspace-write") so a downgrade is reported plainly instead of
# surfacing as "Codex did not modify the manuscript".

function Get-EbookCodexSandboxConfigArgument {
    # For PowerShell script text that pipes a prompt into codex.exe.
    return "-c 'windows.sandbox=`"unelevated`"'"
}

function Get-EbookCodexSandboxArgumentList {
    # For Start-Process -ArgumentList; the escaped quotes survive the command line.
    return @('-c', 'windows.sandbox=\"unelevated\"')
}

function Get-EbookCodexSandboxMode {
    # The mode Codex actually used, from the session header it prints to stderr.
    param([AllowNull()][string]$Text)
    $header = [regex]::Match([string]$Text, '(?im)^\s*sandbox:\s*([a-z-]+)')
    if ($header.Success) { return $header.Groups[1].Value.ToLowerInvariant() }
    return ''
}

function Get-EbookCodexSandboxFailure {
    # Returns a learner-facing explanation when a write session was downgraded,
    # or an empty string when the session ran with the requested access.
    param(
        [AllowNull()][string]$Text,
        [string]$ExpectedSandbox = 'workspace-write'
    )
    if ($ExpectedSandbox -ne 'workspace-write' -or [string]::IsNullOrWhiteSpace($Text)) { return '' }
    $mode = Get-EbookCodexSandboxMode -Text $Text
    $downgraded = $mode -and $mode -ne 'workspace-write' -and $mode -ne 'danger-full-access'
    $blocked = $Text -match '(?i)helper_sandbox_lock_failed|Windows sandbox setup|only permits reading files|read-only filesystem access|workspace is read-only|filesystem access is read-only'
    if (-not $downgraded -and -not $blocked) { return '' }
    $actual = if ($mode) { $mode } else { 'read-only' }
    return "Codex ran with $actual file access instead of workspace-write, so it could not save any changes. Book Studio requests Codex's non-admin sandbox (windows.sandbox=unelevated), which needs no administrator rights. If this keeps happening, update Codex CLI with 'codex update', confirm the Codex executable path in Settings, and run Test connection again. No book files were changed."
}
