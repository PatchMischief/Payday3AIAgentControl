[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GamePath = 'C:\Program Files (x86)\Steam\steamapps\common\PAYDAY3',
    [string]$ModPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentBridge'),
    [switch]$WithUnmaskAgainEndpoint
)

$ErrorActionPreference = 'Stop'
$resolvedGame = (Resolve-Path -LiteralPath $GamePath).Path.TrimEnd('\', '/')
$resolvedMod = (Resolve-Path -LiteralPath $ModPath).Path
foreach ($requiredFile in @('enabled.txt', 'Scripts\main.lua', 'Scripts\game_adapter.lua')) {
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedMod $requiredFile) -PathType Leaf)) {
        throw "Required AgentBridge file is missing: $requiredFile"
    }
}
if (-not $WhatIfPreference -and (Get-Process -Name 'PAYDAY3-Win64-Shipping' -ErrorAction SilentlyContinue)) {
    throw 'Close PAYDAY 3 before installing AgentBridge.'
}
$candidateWin64 = @(
    (Join-Path $resolvedGame 'PAYDAY3\Binaries\Win64'),
    (Join-Path $resolvedGame 'Binaries\Win64')
)
$loaderRoots = @($candidateWin64 | ForEach-Object {
    $candidateLoader = Join-Path $_ 'ue4ss'
    if ((Test-Path -LiteralPath (Join-Path $candidateLoader 'Mods') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $candidateLoader 'UE4SS.dll') -PathType Leaf)) {
        (Resolve-Path -LiteralPath $candidateLoader).Path
    }
} | Select-Object -Unique)
if ($loaderRoots.Count -ne 1) {
    throw 'Expected one existing PAYDAY 3 UE4SS installation. Provide its game folder; this installer does not install a loader.'
}
$modsRoot = Join-Path $loaderRoots[0] 'Mods'
$target = Join-Path $modsRoot 'AgentBridge'
$stage = Join-Path $modsRoot ('.AgentBridge-install-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $loaderRoots[0] 'ModBackups'
$backup = Join-Path $backupRoot ('AgentBridge.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.backup')
$unmaskScripts = Join-Path $modsRoot 'UnmaskAgain\Scripts'
$unmaskSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'integrations\UnmaskAgain\Scripts'
$unmaskBackup = Join-Path $backupRoot ('UnmaskAgain.AgentBridge.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.backup')
$integrationFiles = @('main.lua', 'agentbridge_endpoint.lua')

function Assert-ContainedDestination {
    param([string]$Path)
    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    $gamePrefix = $resolvedGame + [System.IO.Path]::DirectorySeparatorChar
    if (-not $absolutePath.StartsWith($gamePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside GamePath: $absolutePath"
    }
    $currentPath = $absolutePath
    while ($currentPath.Length -ge $resolvedGame.Length) {
        if (Test-Path -LiteralPath $currentPath) {
            $entry = Get-Item -LiteralPath $currentPath -Force
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to install through a junction or symbolic link: $currentPath"
            }
        }
        if ($currentPath.Equals($resolvedGame, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $currentPath = Split-Path -Parent $currentPath
    }
}

foreach ($destination in @($target, $stage, $backupRoot, $backup)) {
    Assert-ContainedDestination $destination
}
if ($WithUnmaskAgainEndpoint) {
    foreach ($destination in @($unmaskScripts, $unmaskBackup)) { Assert-ContainedDestination $destination }
    foreach ($name in $integrationFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $unmaskSource $name) -PathType Leaf)) {
            throw "Missing UnmaskAgain integration source: $name"
        }
        Assert-ContainedDestination (Join-Path $unmaskScripts $name)
    }
    $installedUnmask = Join-Path $unmaskScripts 'main.lua'
    if (-not (Test-Path -LiteralPath $installedUnmask -PathType Leaf)) { throw 'UnmaskAgain must already be installed.' }
    $currentUnmaskHash = (Get-FileHash -LiteralPath $installedUnmask).Hash
    $newUnmaskHash = (Get-FileHash -LiteralPath (Join-Path $unmaskSource 'main.lua')).Hash
    if ($currentUnmaskHash -ne '5884718BE82D79498CEBD4412E64F3DC5A7CE1D81872A9EBBB5A4EFF248D20E3' -and
        $currentUnmaskHash -ne $newUnmaskHash) {
        throw 'Installed UnmaskAgain differs from the inspected 0.5.4 source. Review that version before adding the endpoint.'
    }
}
if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Container)) {
    throw "Destination is not a directory: $target"
}
$luaFiles = @(Get-ChildItem -LiteralPath (Join-Path $resolvedMod 'Scripts') -Filter '*.lua' -File)
if (-not $PSCmdlet.ShouldProcess($target, 'Install AgentBridge and preserve any previous version outside the Mods directory')) {
    return
}
$backupCreated = $false
$unmaskUpdated = $false
$previousIntegrationFiles = @()
try {
    New-Item -ItemType Directory -Path (Join-Path $stage 'Scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stage 'bridge') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $resolvedMod 'enabled.txt') -Destination $stage
    foreach ($luaFile in $luaFiles) {
        Copy-Item -LiteralPath $luaFile.FullName -Destination (Join-Path $stage 'Scripts')
    }
    if ($WithUnmaskAgainEndpoint) {
        New-Item -ItemType Directory -Path $unmaskBackup -Force | Out-Null
        foreach ($name in $integrationFiles) {
            $existing = Join-Path $unmaskScripts $name
            if (Test-Path -LiteralPath $existing -PathType Leaf) {
                Copy-Item -LiteralPath $existing -Destination (Join-Path $unmaskBackup $name)
                $previousIntegrationFiles += $name
            }
        }
        $unmaskUpdated = $true
        foreach ($name in $integrationFiles) {
            $source = Join-Path $unmaskSource $name
            $destination = Join-Path $unmaskScripts $name
            Copy-Item -LiteralPath $source -Destination $destination
            if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
                throw "Installed UnmaskAgain integration differs: $name"
            }
        }
    }
    # Runtime data goes beside this mod, independent of the game's working dir.
    $bridgeLuaPath = (Join-Path $target 'bridge').Replace('\', '/')
    if ($bridgeLuaPath.Contains(']]')) { throw 'GamePath cannot contain ]] for the Lua path file.' }
    $runtimePaths = 'return {bridge_dir = [[' + $bridgeLuaPath + ']]}' + "`n"
    [System.IO.File]::WriteAllText((Join-Path $stage 'Scripts\agentbridge_paths.lua'), $runtimePaths, [System.Text.UTF8Encoding]::new($false))
    foreach ($luaFile in $luaFiles) {
        $destination = Join-Path (Join-Path $stage 'Scripts') $luaFile.Name
        if ((Get-FileHash -LiteralPath $luaFile.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
            throw "Staged script differs from source: $($luaFile.Name)"
        }
    }
    if (Test-Path -LiteralPath $target -PathType Container) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Move-Item -LiteralPath $target -Destination $backup
        $backupCreated = $true
    }
    Move-Item -LiteralPath $stage -Destination $target
    Write-Output "Installed: $target"
    if ($backupCreated) { Write-Output "Previous version: $backup" }
    if ($WithUnmaskAgainEndpoint) { Write-Output "UnmaskAgain endpoint installed; previous scripts: $unmaskBackup" }
}
catch {
    if ($unmaskUpdated) {
        foreach ($name in $integrationFiles) {
            $destination = Join-Path $unmaskScripts $name
            Assert-ContainedDestination $destination
            if ($previousIntegrationFiles -contains $name) {
                Copy-Item -LiteralPath (Join-Path $unmaskBackup $name) -Destination $destination
            } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
                Remove-Item -LiteralPath $destination -Force
            }
        }
    }
    if ($backupCreated -and -not (Test-Path -LiteralPath $target)) {
        Assert-ContainedDestination $backup
        Move-Item -LiteralPath $backup -Destination $target
    }
    throw
}
finally {
    Assert-ContainedDestination $stage
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
