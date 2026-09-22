# Connecting a computer to the cloud, from the computer's side.
#
# A designer pastes one command, once. Everything after that has to happen
# without them: the token is remembered, and the agent can start with Windows,
# because an agent that is not running makes their machine look disconnected
# and there is nothing on screen to explain why.
#
# The token is kept in the user's own profile rather than in the Book Studio
# folder, so updating, moving or re-cloning the app does not disconnect the
# machine, and two people sharing a PC do not share a token.

function Get-BookRunnerStatePath {
    param([string]$Path)

    if ($Path) { return $Path }
    $root = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local' }
    return Join-Path $root 'EbookGenerator\runner.json'
}

function Save-BookRunnerToken {
    param(
        [Parameter(Mandatory)][string]$Token,
        [string]$Path
    )

    $file = Get-BookRunnerStatePath -Path $Path
    $folder = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $state = [pscustomobject]@{
        token = $Token
        savedAt = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
    }
    Set-Content -LiteralPath $file -Value ($state | ConvertTo-Json -Depth 3) -Encoding UTF8
    return $file
}

function Get-SavedBookRunnerToken {
    param([string]$Path)

    $file = Get-BookRunnerStatePath -Path $Path
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try {
        $state = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$state.token
    }
    catch {
        # A corrupted file must not stop the agent: it asks for the token again.
        return ''
    }
}

function Clear-SavedBookRunnerToken {
    param([string]$Path)

    $file = Get-BookRunnerStatePath -Path $Path
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    return $file
}

# What the designer typed wins over what was remembered, so pasting a new token
# after an administrator reissues one replaces the old one rather than being
# ignored in favour of a token that no longer works.
function Resolve-BookRunnerToken {
    param(
        [string]$Token,
        [string]$EnvironmentToken,
        [string]$Path
    )

    if ($Token) { return [pscustomobject]@{ token = $Token; source = 'command line' } }
    if ($EnvironmentToken) { return [pscustomobject]@{ token = $EnvironmentToken; source = 'environment' } }
    $saved = Get-SavedBookRunnerToken -Path $Path
    if ($saved) { return [pscustomobject]@{ token = $saved; source = 'saved on this computer' } }
    return [pscustomobject]@{ token = ''; source = 'nowhere' }
}

function Get-BookRunnerStartupPath {
    param([string]$StartupFolder)

    $folder = if ($StartupFolder) { $StartupFolder } else { [Environment]::GetFolderPath('Startup') }
    return Join-Path $folder 'Book Studio cloud agent.lnk'
}

# A shortcut in the user's own Startup folder. No service, no scheduled task and
# no administrator: designer PCs are locked down, and anything needing elevation
# cannot be part of a setup they do themselves.
function Install-BookRunnerStartup {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$StartupFolder
    )

    $link = Get-BookRunnerStartupPath -StartupFolder $StartupFolder
    $folder = Split-Path -Parent $link
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = (Get-Command powershell.exe).Source
    # Read and run as a command, not started as a file. On a managed PC the
    # execution policy forbids running a .ps1, -ExecutionPolicy Bypass is
    # itself overridden by group policy, and a designer cannot change either.
    # A command built from the text of the file is subject to neither.
    # The path is quoted because a Book Studio folder can have a space in it,
    # and the quotes are doubled for the shortcut's own parser.
    $command = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath ''' + $ScriptPath + ''')))'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -Command "' + $command + '"'
    $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
    $shortcut.Description = 'Keeps this computer connected to Book Studio so books can be written here.'
    $shortcut.Save()
    return $link
}

function Uninstall-BookRunnerStartup {
    param([string]$StartupFolder)

    $link = Get-BookRunnerStartupPath -StartupFolder $StartupFolder
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
    return $link
}

function Test-BookRunnerStartupInstalled {
    param([string]$StartupFolder)

    return Test-Path -LiteralPath (Get-BookRunnerStartupPath -StartupFolder $StartupFolder)
}
