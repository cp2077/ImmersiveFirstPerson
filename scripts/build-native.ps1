[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [Parameter(Mandatory)]
    [string] $CMake,
    [Parameter(Mandatory)]
    [string] $Red4extSdkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = Join-Path $repositoryRoot 'native'
$buildRoot = Join-Path $repositoryRoot 'build\native'
$cmake = [IO.Path]::GetFullPath($CMake)
if (-not (Test-Path -LiteralPath $cmake -PathType Leaf)) {
    throw "CMake was not found: $cmake"
}

if (-not (Test-Path -LiteralPath (Join-Path $Red4extSdkPath 'CMakeLists.txt') -PathType Leaf)) {
    throw "RED4ext SDK checkout was not found: $Red4extSdkPath"
}

& $cmake `
    -S $sourceRoot `
    -B $buildRoot `
    -G 'Visual Studio 17 2022' `
    -A x64 `
    "-DRED4EXT_SDK_PATH=$Red4extSdkPath"
if ($LASTEXITCODE -ne 0) {
    throw "Native configure failed with exit code $LASTEXITCODE."
}

& $cmake --build $buildRoot --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) {
    throw "Native build failed with exit code $LASTEXITCODE."
}

$output = Join-Path $buildRoot "$Configuration\ImmersiveFirstPerson.dll"
if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Native build did not produce: $output"
}

Write-Output $output
