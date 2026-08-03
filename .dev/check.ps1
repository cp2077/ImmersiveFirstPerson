[CmdletBinding()]
param(
    [switch] $Strict,
    [string] $LiveModRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sourceInit = Join-Path $workspace 'init.lua'
$sourceModules = Join-Path $workspace 'Modules'
$packagedModRoot = Join-Path $workspace 'bin\x64\plugins\cyber_engine_tweaks\mods\ImmersiveFirstPerson'
$configPath = Join-Path $PSScriptRoot '.luarc.json'
$luaJitFallback = 'C:\Users\bn\AppData\Local\Programs\LuaJIT\luajit.exe'
$luaLsFallback = 'C:\Users\bn\AppData\Local\Programs\LuaLS\bin\lua-language-server.exe'

function Resolve-DevTool {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string] $Fallback
    )

    $resolved = Get-Command $Command -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Source
    }

    if (Test-Path -LiteralPath $Fallback) {
        return $Fallback
    }

    throw "Required development tool was not found: $Command"
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

$luaJit = Resolve-DevTool -Command 'luajit.exe' -Fallback $luaJitFallback
$luaLanguageServer = Resolve-DevTool -Command 'lua-language-server.exe' -Fallback $luaLsFallback

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

$logPath = Join-Path $PSScriptRoot 'logs\luals'
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
