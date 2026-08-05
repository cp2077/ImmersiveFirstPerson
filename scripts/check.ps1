[CmdletBinding()]
param(
    [switch] $Strict,
    [string] $LiveModRoot = '',
    [Parameter(Mandatory)]
    [string] $GameRoot,
    [Parameter(Mandatory)]
    [string] $CMake,
    [Parameter(Mandatory)]
    [string] $Red4extSdkPath,
    [string] $LuaJit = '',
    [string] $LuaLanguageServer = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sourceInit = Join-Path $workspace 'init.lua'
$sourceModules = Join-Path $workspace 'Modules'
$packagedModRoot = Join-Path $workspace 'bin\x64\plugins\cyber_engine_tweaks\mods\ImmersiveFirstPerson'
$configPath = Join-Path $workspace '.luarc.json'

function Resolve-DevTool {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [string] $Requested = ''
    )

    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) {
            throw "Required development tool was not found: $Requested"
        }
        return (Resolve-Path -LiteralPath $Requested).Path
    }

    $resolved = Get-Command $Command -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Source
    }

    throw "Required development tool was not found on PATH: $Command"
}

if ((Test-Path -LiteralPath $sourceInit -PathType Leaf) -and (Test-Path -LiteralPath $sourceModules -PathType Container)) {
    $modRoot = $workspace
    $luaFiles = @(
        Get-Item -LiteralPath $sourceInit
        Get-ChildItem -LiteralPath $sourceModules -Filter '*.lua' -File -Recurse
    ) | Sort-Object FullName
} elseif (Test-Path -LiteralPath $packagedModRoot -PathType Container) {
    $modRoot = $packagedModRoot
    $luaFiles = @(Get-ChildItem -LiteralPath $modRoot -Filter '*.lua' -File -Recurse | Sort-Object FullName)
} else {
    throw "Neither a source-layout nor packaged CET mod root was found below: $workspace"
}

$luaJit = Resolve-DevTool -Command 'luajit.exe' -Requested $LuaJit
$luaLanguageServer = Resolve-DevTool -Command 'lua-language-server.exe' -Requested $LuaLanguageServer

if ($luaFiles.Count -eq 0) {
    throw "No Lua files were found below: $modRoot"
}

Write-Host "LuaJIT syntax check ($($luaFiles.Count) files)"
$syntaxFailures = @()

foreach ($file in $luaFiles) {
    $expression = "local f, err = loadfile([==[$($file.FullName)]==]); if not f then io.stderr:write(err, '\n'); os.exit(1) end"
    & $luaJit -e $expression
    if ($LASTEXITCODE -ne 0) {
        $syntaxFailures += $file.FullName
    }
}

if ($syntaxFailures.Count -gt 0) {
    throw "LuaJIT rejected $($syntaxFailures.Count) file(s):`n$($syntaxFailures -join "`n")"
}

Write-Host 'LuaJIT syntax check passed.'

if ($modRoot -eq $workspace) {
    Write-Host 'Configuration and runtime height tests'
    Push-Location $workspace
    try {
        & $luaJit (Join-Path $workspace 'tests\config-height-migration.lua')
        if ($LASTEXITCODE -ne 0) {
            throw "Config height migration tests failed with exit code $LASTEXITCODE."
        }
        & $luaJit (Join-Path $workspace 'tests\runtime-height.lua')
        if ($LASTEXITCODE -ne 0) {
            throw "Runtime height tests failed with exit code $LASTEXITCODE."
        }
        & $luaJit (Join-Path $workspace 'tests\player-state-cache.lua')
        if ($LASTEXITCODE -ne 0) {
            throw "Player-state cache tests failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

if ($modRoot -eq $workspace) {
    Write-Host 'RED4ext native build'
    & (Join-Path $PSScriptRoot 'build-native.ps1') -CMake $CMake -Red4extSdkPath $Red4extSdkPath | Write-Host

    $redscriptRoot = Join-Path $workspace 'r6\scripts'
    if (-not (Test-Path -LiteralPath $redscriptRoot -PathType Container)) {
        throw "REDscript source root was not found: $redscriptRoot"
    }

    Write-Host 'REDscript compile against installed game cache'
    $redscriptCompiler = Join-Path $GameRoot 'engine\tools\scc.exe'
    $redscriptCache = Join-Path $GameRoot 'r6\cache\final.redscripts'
    if (-not (Test-Path -LiteralPath $redscriptCompiler -PathType Leaf)) {
        throw "REDscript compiler was not found: $redscriptCompiler"
    }
    if (-not (Test-Path -LiteralPath $redscriptCache -PathType Leaf)) {
        throw "REDscript cache was not found: $redscriptCache"
    }
    $redscriptStage = Join-Path $workspace ('build\check\redscript-' + [Guid]::NewGuid().ToString('N'))
    $stagedScripts = Join-Path $redscriptStage 'r6\scripts'
    $stagedCache = Join-Path $redscriptStage 'r6\cache'
    New-Item -ItemType Directory -Path $stagedScripts, $stagedCache -Force | Out-Null
    try {
        Copy-Item -LiteralPath $redscriptCache -Destination (Join-Path $stagedCache 'final.redscripts')
        foreach ($source in Get-ChildItem -LiteralPath $redscriptRoot -File -Recurse) {
            $relativePath = $source.FullName.Substring($redscriptRoot.TrimEnd('\').Length).TrimStart('\')
            $destination = Join-Path $stagedScripts $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source.FullName -Destination $destination
        }
        $redscriptOutput = Join-Path $stagedCache 'ImmersiveFirstPerson.redscripts'
        & $redscriptCompiler -compile $stagedScripts $redscriptOutput
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $redscriptOutput -PathType Leaf)) {
            throw "REDscript compile failed with exit code $LASTEXITCODE."
        }
    } finally {
        if (Test-Path -LiteralPath $redscriptStage -PathType Container) {
            Remove-Item -LiteralPath $redscriptStage -Recurse -Force
        }
    }
}

if ($LiveModRoot -and (Test-Path -LiteralPath $LiveModRoot -PathType Container)) {
    Write-Host 'Source/deployed mod comparison'
    $deploymentFailures = @()

    foreach ($file in $luaFiles) {
        $relativePath = $file.FullName.Substring($modRoot.Length).TrimStart('\')
        $liveFile = Join-Path $LiveModRoot $relativePath

        if (-not (Test-Path -LiteralPath $liveFile)) {
            $deploymentFailures += "$relativePath (missing from live mod)"
            continue
        }

        $stagedHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $liveHash = (Get-FileHash -LiteralPath $liveFile -Algorithm SHA256).Hash
        if ($stagedHash -ne $liveHash) {
            $deploymentFailures += "$relativePath (hash mismatch)"
        }
    }

    if ($deploymentFailures.Count -gt 0) {
        throw "Source/deployed mod comparison failed:`n$($deploymentFailures -join "`n")"
    }

    Write-Host 'Source/deployed mod comparison passed.'
} elseif ($LiveModRoot) {
    Write-Warning "Live CET mod was not found; deployment comparison skipped: $LiveModRoot"
}

$logPath = Join-Path $workspace 'build\check\luals'
New-Item -ItemType Directory -Path $logPath -Force | Out-Null

Write-Host 'LuaLS workspace diagnostics'
$checkLevel = if ($Strict) { 'Warning' } else { 'Error' }
& $luaLanguageServer `
    "--check=$workspace" `
    "--checklevel=$checkLevel" `
    '--check_format=pretty' `
    "--configpath=$configPath" `
    "--logpath=$logPath"

if ($LASTEXITCODE -ne 0) {
    throw "LuaLS failed with exit code $LASTEXITCODE."
}

Write-Host 'Development checks completed.'
