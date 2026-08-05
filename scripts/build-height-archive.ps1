[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $GameRoot,
    [Parameter(Mandatory)]
    [string] $WolvenKit,
    [string] $Output = '',
    [switch] $UpdateTrackedArchive,
    [switch] $KeepWorkFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$gameRootFull = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\')
$wolvenKitFull = [IO.Path]::GetFullPath($WolvenKit)
$sourceArchive = Join-Path $gameRootFull 'archive\pc\content\basegame_1_engine.archive'
$resourcePath = 'base\gameplay\anim_graphs\player_base.animgraph'
$vanillaHash = 'DFF7C3BDEF154B9F9CCF87BDCA0FAF3EAC4565E4428714FB52D46F4C4F7D0EB3'
$builtGraphHash = 'CB4DE8B3CAA3AC8422926FEC5D00AD60CA9CA541DAC8A92BB409862FDC92CA02'

foreach ($required in @($sourceArchive, $wolvenKitFull)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file was not found: $required"
    }
}

if (-not $Output) {
    $Output = Join-Path $repositoryRoot 'build\height\ImmersiveFirstPersonHeight.archive'
}
$outputFull = [IO.Path]::GetFullPath($Output)
$workRoot = Join-Path $repositoryRoot ('build\height-work-' + [Guid]::NewGuid().ToString('N'))
$extractRoot = Join-Path $workRoot 'vanilla'
$jsonRoot = Join-Path $workRoot 'vanilla-json'
$verifyExtractRoot = Join-Path $workRoot 'verify-archive'

New-Item -ItemType Directory -Path $extractRoot, $jsonRoot, $verifyExtractRoot -Force | Out-Null
try {
    Write-Host 'Extracting the vanilla player animgraph'
    & $wolvenKitFull extract $sourceArchive -w $resourcePath -o $extractRoot -v Minimal
    if ($LASTEXITCODE -ne 0) {
        throw "WolvenKit extraction failed with exit code $LASTEXITCODE."
    }

    $vanillaGraph = Join-Path $extractRoot $resourcePath
    if (-not (Test-Path -LiteralPath $vanillaGraph -PathType Leaf)) {
        throw "The vanilla player animgraph was not extracted: $vanillaGraph"
    }
    $actualVanillaHash = (Get-FileHash -LiteralPath $vanillaGraph -Algorithm SHA256).Hash
    if ($actualVanillaHash -ne $vanillaHash) {
        throw "The vanilla player animgraph does not match game 2.31. Expected $vanillaHash, got $actualVanillaHash."
    }

    Write-Host 'Converting the vanilla animgraph to JSON'
    & $wolvenKitFull cr2w $vanillaGraph -s -o $jsonRoot -v Minimal
    if ($LASTEXITCODE -ne 0) {
        throw "WolvenKit serialization failed with exit code $LASTEXITCODE."
    }
    $vanillaJson = Join-Path $jsonRoot 'player_base.animgraph.json'

    Write-Host 'Adding the 30 cm grounded height pose'
    & (Join-Path $PSScriptRoot 'height\add-grounded-height.ps1') `
        -DeltaMeters 0.30 `
        -AnimGraphJson $vanillaJson `
        -WolvenKit $wolvenKitFull `
        -WorkRoot $workRoot `
        -Placement GroundedFullHeight `
        -VariantTag '30cm'

    $heightJson = Join-Path $workRoot 'animgraph-grounded-full-height-30cm\json\player_base.animgraph.json'
    Write-Host 'Adding the runtime blend input'
    & (Join-Path $PSScriptRoot 'height\add-runtime-blend.ps1') `
        -BaseAnimGraphJson $vanillaJson `
        -HeightAnimGraphJson $heightJson `
        -VariantTag '30cm' `
        -MaximumHeightMeters 0.30 `
        -WolvenKit $wolvenKitFull `
        -WorkRoot $workRoot

    $builtArchive = Join-Path $workRoot 'animgraph-runtime-height-blend-proof-30cm\ImmersiveFirstPersonHeight-animgraph-runtime-height-blend-proof-30cm.archive.disabled'
    if (-not (Test-Path -LiteralPath $builtArchive -PathType Leaf)) {
        throw "The height archive was not built: $builtArchive"
    }

    Write-Host 'Checking the built archive'
    $verificationArchive = Join-Path $workRoot 'ImmersiveFirstPersonHeight.archive'
    Copy-Item -LiteralPath $builtArchive -Destination $verificationArchive
    & $wolvenKitFull extract $verificationArchive -w $resourcePath -o $verifyExtractRoot -v Minimal
    if ($LASTEXITCODE -ne 0) {
        throw "WolvenKit verification extraction failed with exit code $LASTEXITCODE."
    }
    $verifiedGraph = Join-Path $verifyExtractRoot $resourcePath
    $actualBuiltHash = (Get-FileHash -LiteralPath $verifiedGraph -Algorithm SHA256).Hash
    if ($actualBuiltHash -ne $builtGraphHash) {
        throw "The built animgraph is not the known 30 cm graph. Expected $builtGraphHash, got $actualBuiltHash."
    }

    $outputDirectory = Split-Path -Parent $outputFull
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Copy-Item -LiteralPath $builtArchive -Destination $outputFull -Force
    Write-Host "Built: $outputFull"

    if ($UpdateTrackedArchive) {
        $trackedArchive = Join-Path $repositoryRoot 'optional\ImmersiveFirstPersonHeight.archive'
        Copy-Item -LiteralPath $outputFull -Destination $trackedArchive -Force
        Write-Host "Updated: $trackedArchive"
    }
} finally {
    if ($KeepWorkFiles) {
        Write-Host "Work files: $workRoot"
    } elseif (Test-Path -LiteralPath $workRoot -PathType Container) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
