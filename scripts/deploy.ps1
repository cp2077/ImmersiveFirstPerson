[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $GameRoot,
    [Parameter(Mandatory)]
    [string] $CMake,
    [Parameter(Mandatory)]
    [string] $Red4extSdkPath,
    [string] $LuaJit = '',
    [string] $LuaLanguageServer = '',
    [switch] $LuaOnly,
    [switch] $DryRun,
    [switch] $SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$gameRootFull = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $gameRootFull -PathType Container)) {
    throw "Cyberpunk game root was not found: $gameRootFull"
}

if (-not $LuaOnly -and -not $DryRun -and (Get-Process -Name 'Cyberpunk2077' -ErrorAction SilentlyContinue)) {
    throw 'Close Cyberpunk 2077 before a full deployment. The game locks the native DLL.'
}

$targetRelative = 'bin\x64\plugins\cyber_engine_tweaks\mods\ImmersiveFirstPerson'
$targetRoot = [IO.Path]::GetFullPath((Join-Path $gameRootFull $targetRelative)).TrimEnd('\')
$nativeTarget = [IO.Path]::GetFullPath((Join-Path $gameRootFull 'red4ext\plugins\ImmersiveFirstPerson\ImmersiveFirstPerson.dll'))
$redscriptTarget = [IO.Path]::GetFullPath((Join-Path $gameRootFull 'r6\scripts\ImmersiveFirstPerson\LookAt.reds'))
$legacyRedscriptTarget = [IO.Path]::GetFullPath((Join-Path $gameRootFull 'r6\scripts\ImmersiveFirstPerson\NativeHeight.reds'))
$heightArchiveTarget = [IO.Path]::GetFullPath((Join-Path $gameRootFull 'archive\pc\mod\ImmersiveFirstPersonHeight.archive'))
$gamePrefix = $gameRootFull + '\'
foreach ($candidate in @($targetRoot + '\', $nativeTarget, $redscriptTarget, $legacyRedscriptTarget, $heightArchiveTarget)) {
    if (-not $candidate.StartsWith($gamePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe deployment target: $candidate"
    }
}

$sourceInit = Join-Path $repositoryRoot 'init.lua'
$sourceModules = Join-Path $repositoryRoot 'Modules'
if (-not (Test-Path -LiteralPath $sourceInit -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceModules -PathType Container)) {
    throw "The repository runtime payload is incomplete: $repositoryRoot"
}

$sourceFiles = @(
    Get-Item -LiteralPath $sourceInit
    Get-ChildItem -LiteralPath $sourceModules -Filter '*.lua' -File -Recurse
) | Sort-Object FullName

if (-not $SkipValidation) {
    Write-Host 'Validating source before deployment'
    & (Join-Path $PSScriptRoot 'check.ps1') -GameRoot $gameRootFull -CMake $CMake -Red4extSdkPath $Red4extSdkPath -LuaJit $LuaJit -LuaLanguageServer $LuaLanguageServer
}

$nativeSource = Join-Path $repositoryRoot 'build\native\Release\ImmersiveFirstPerson.dll'
$redscriptSource = Join-Path $repositoryRoot 'r6\scripts\ImmersiveFirstPerson\LookAt.reds'
$heightArchiveSource = Join-Path $repositoryRoot 'optional\ImmersiveFirstPersonHeight.archive'
if (-not $LuaOnly) {
    foreach ($required in @($nativeSource, $redscriptSource)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "A required runtime payload is missing: $required"
        }
    }
}
if (-not $LuaOnly -and -not (Test-Path -LiteralPath $heightArchiveSource -PathType Leaf)) {
    throw "The height archive is missing: $heightArchiveSource"
}

$heightArchiveDirectory = Split-Path -Parent $heightArchiveTarget
$obsoleteHeightArchives = if (-not $LuaOnly -and (Test-Path -LiteralPath $heightArchiveDirectory -PathType Container)) {
    @(Get-ChildItem -LiteralPath $heightArchiveDirectory -Filter 'ImmersiveFirstPersonHeight*.archive' -File | Where-Object {
        $_.FullName -ne $heightArchiveTarget
    })
} else {
    @()
}

$manifest = @{}
foreach ($file in $sourceFiles) {
    $relativePath = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\')
    $manifest[$relativePath.ToLowerInvariant()] = [pscustomobject]@{
        Source = $file.FullName
        Relative = $relativePath
        Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

$existingLua = if (Test-Path -LiteralPath $targetRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $targetRoot -Filter '*.lua' -File -Recurse)
} else {
    @()
}
$staleLua = @(
    $existingLua | Where-Object {
        $relativePath = $_.FullName.Substring($targetRoot.Length).TrimStart('\').ToLowerInvariant()
        -not $manifest.ContainsKey($relativePath)
    }
)

Write-Host "Source: $repositoryRoot"
Write-Host "Target: $targetRoot"
Write-Host "Runtime files: $($sourceFiles.Count); stale live Lua files: $($staleLua.Count)"
if (-not $LuaOnly) {
    Write-Host "Native target: $nativeTarget"
    Write-Host "REDscript target: $redscriptTarget"
}

if (Test-Path -LiteralPath (Join-Path $targetRoot '__folder_managed_by_vortex')) {
    Write-Warning 'The live mod still has a Vortex ownership marker. Disable the Vortex deployment before continuing.'
}

if ($DryRun) {
    foreach ($entry in $manifest.Values | Sort-Object Relative) {
        Write-Output "COPY $($entry.Relative)"
    }
    foreach ($file in $staleLua) {
        Write-Output "REMOVE $($file.FullName.Substring($targetRoot.Length).TrimStart('\'))"
    }
    if (-not $LuaOnly) {
        Write-Output 'COPY red4ext\plugins\ImmersiveFirstPerson\ImmersiveFirstPerson.dll'
        Write-Output 'COPY r6\scripts\ImmersiveFirstPerson\LookAt.reds'
        if (Test-Path -LiteralPath $legacyRedscriptTarget -PathType Leaf) {
            Write-Output 'REMOVE r6\scripts\ImmersiveFirstPerson\NativeHeight.reds'
        }
    }
    if (-not $LuaOnly) {
        Write-Output 'COPY archive\pc\mod\ImmersiveFirstPersonHeight.archive'
        foreach ($archive in $obsoleteHeightArchives) {
            Write-Output "REMOVE archive\pc\mod\$($archive.Name)"
        }
    }
    Write-Host 'Dry run completed; no files were changed.'
    return
}

New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
foreach ($entry in $manifest.Values) {
    $destination = Join-Path $targetRoot $entry.Relative
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $entry.Source -Destination $destination -Force
}

$targetPrefix = $targetRoot + '\'
foreach ($file in $staleLua) {
    $resolvedFile = [IO.Path]::GetFullPath($file.FullName)
    if (-not $resolvedFile.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a Lua file outside the live mod: $resolvedFile"
    }
    Remove-Item -LiteralPath $resolvedFile -Force
}

if (-not $LuaOnly) {
    foreach ($payload in @(
        [pscustomobject]@{ Source = $nativeSource; Destination = $nativeTarget },
        [pscustomobject]@{ Source = $redscriptSource; Destination = $redscriptTarget }
    )) {
        $destinationDirectory = Split-Path -Parent $payload.Destination
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $payload.Source -Destination $payload.Destination -Force
    }

    if (Test-Path -LiteralPath $legacyRedscriptTarget -PathType Leaf) {
        Remove-Item -LiteralPath $legacyRedscriptTarget -Force
    }
}

if (-not $LuaOnly) {
    New-Item -ItemType Directory -Path $heightArchiveDirectory -Force | Out-Null
    Copy-Item -LiteralPath $heightArchiveSource -Destination $heightArchiveTarget -Force
    $heightArchivePrefix = $heightArchiveDirectory.TrimEnd('\') + '\'
    foreach ($archive in $obsoleteHeightArchives) {
        $resolvedArchive = [IO.Path]::GetFullPath($archive.FullName)
        if (-not $resolvedArchive.StartsWith($heightArchivePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an archive outside the mod directory: $resolvedArchive"
        }
        Remove-Item -LiteralPath $resolvedArchive -Force
    }
}

$verificationFailures = @()
foreach ($entry in $manifest.Values) {
    $destination = Join-Path $targetRoot $entry.Relative
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $verificationFailures += "$($entry.Relative) is missing"
        continue
    }
    $liveHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($liveHash -ne $entry.Hash) {
        $verificationFailures += "$($entry.Relative) has a hash mismatch"
    }
}
if (-not $LuaOnly) {
    foreach ($payload in @(
        [pscustomobject]@{ Source = $nativeSource; Destination = $nativeTarget },
        [pscustomobject]@{ Source = $redscriptSource; Destination = $redscriptTarget }
    )) {
        if (-not (Test-Path -LiteralPath $payload.Destination -PathType Leaf)) {
            $verificationFailures += "$($payload.Destination) is missing"
            continue
        }
        $sourceHash = (Get-FileHash -LiteralPath $payload.Source -Algorithm SHA256).Hash
        $liveHash = (Get-FileHash -LiteralPath $payload.Destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $liveHash) {
            $verificationFailures += "$($payload.Destination) has a hash mismatch"
        }
    }
}
if (-not $LuaOnly) {
    $sourceHash = (Get-FileHash -LiteralPath $heightArchiveSource -Algorithm SHA256).Hash
    $liveHash = (Get-FileHash -LiteralPath $heightArchiveTarget -Algorithm SHA256).Hash
    if ($sourceHash -ne $liveHash) {
        $verificationFailures += "$heightArchiveTarget has a hash mismatch"
    }
}

if ($verificationFailures.Count -gt 0) {
    throw "Deployment verification failed:`n$($verificationFailures -join "`n")"
}

if ($LuaOnly) {
    Write-Host "Lua-only deployment completed and verified ($($manifest.Count) files)."
} else {
    Write-Host "Deployment completed and verified ($($manifest.Count) Lua files, native DLL, REDscript, height archive)."
}
