[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaseAnimGraphJson,
    [Parameter(Mandatory)]
    [string] $MinimumHeightAnimGraphJson,
    [Parameter(Mandatory)]
    [string] $MaximumHeightAnimGraphJson,
    [ValidatePattern('^[a-z0-9-]+$')]
    [string] $VariantTag = 'signed-50cm',
    [ValidateRange(-0.50, -0.01)]
    [double] $MinimumHeightMeters = -0.50,
    [ValidateRange(0.01, 0.50)]
    [double] $MaximumHeightMeters = 0.50,
    [Parameter(Mandatory)]
    [string] $WolvenKit,
    [Parameter(Mandatory)]
    [string] $WorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$variableName = 'ifp_height_blend'
$contractVariableName = 'ifp_height_contract_v2_signed_50cm'
$debugName = 'ImmersiveFirstPerson_Runtime_Height_v2_signed_50cm'
$experimentsRoot = [IO.Path]::GetFullPath($WorkRoot)
$experimentRoot = Join-Path $experimentsRoot "animgraph-runtime-height-blend-proof-$VariantTag"
$jsonRoot = Join-Path $experimentRoot 'json'
$generatedRoot = Join-Path $experimentRoot 'generated'
$verifyRoot = Join-Path $experimentRoot 'verify'
$stageRoot = Join-Path $experimentRoot 'stage\base\gameplay\anim_graphs'

function Find-JsonObjectEnd {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [int] $ObjectStart
    )

    $depth = 0
    $inString = $false
    $escaped = $false
    for ($index = $ObjectStart; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq '\') {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
        } elseif ($character -eq '{') {
            $depth++
        } elseif ($character -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $index
            }
        }
    }

    throw "Unterminated JSON object at offset $ObjectStart"
}

function Get-HipsConstraintInputPose {
    param([Parameter(Mandatory)] [string] $Text)

    $constraintPattern = [regex]::new(
        '"HandleId"\s*:\s*"[0-9]+"\s*,\s*"Data"\s*:\s*\{\s*"\$type"\s*:\s*"animAnimNode_ParentConstraint"'
    )
    $candidates = @()
    foreach ($constraintMatch in $constraintPattern.Matches($Text)) {
        $constraintStart = $Text.LastIndexOf('{', $constraintMatch.Index)
        $constraintEnd = Find-JsonObjectEnd -Text $Text -ObjectStart $constraintStart
        $constraintObject = $Text.Substring($constraintStart, $constraintEnd - $constraintStart + 1)
        $tailLength = [Math]::Min(300000, $constraintObject.Length)
        $tail = $constraintObject.Substring($constraintObject.Length - $tailLength)
        if ($tail.Contains('"$value": "Torso_Hips_Driver_GRP"') -and
            $tail.Contains('"$value": "Hips"')) {
            $candidates += [pscustomobject]@{
                Start = $constraintStart
                Object = $constraintObject
            }
        }
    }

    if ($candidates.Count -ne 1) {
        throw "Expected exactly one Torso_Hips_Driver_GRP -> Hips parent constraint, found $($candidates.Count)"
    }

    $constraintStart = $candidates[0].Start
    $constraintObject = $candidates[0].Object
    $inputLinkOffset = $constraintObject.IndexOf('"inputLink"', [StringComparison]::Ordinal)
    $inputHandleOffset = $constraintObject.IndexOf('"HandleId"', $inputLinkOffset, [StringComparison]::Ordinal)
    if ($inputLinkOffset -lt 0 -or $inputHandleOffset -lt 0) {
        throw 'Hips parent constraint has no inline input pose'
    }

    $relativePoseStart = $constraintObject.LastIndexOf('{', $inputHandleOffset)
    $poseStart = $constraintStart + $relativePoseStart
    $poseEnd = Find-JsonObjectEnd -Text $Text -ObjectStart $poseStart
    [pscustomobject]@{
        Start = $poseStart
        End = $poseEnd
        Object = $Text.Substring($poseStart, $poseEnd - $poseStart + 1)
    }
}

foreach ($path in @($BaseAnimGraphJson, $MinimumHeightAnimGraphJson, $MaximumHeightAnimGraphJson, $WolvenKit)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

$baseSource = [IO.File]::ReadAllText([IO.Path]::GetFullPath($BaseAnimGraphJson))
$minimumSource = [IO.File]::ReadAllText([IO.Path]::GetFullPath($MinimumHeightAnimGraphJson))
$maximumSource = [IO.File]::ReadAllText([IO.Path]::GetFullPath($MaximumHeightAnimGraphJson))
if ($minimumSource.Contains($debugName) -or $maximumSource.Contains($debugName) -or
    $minimumSource.Contains(('"$value": "' + $variableName + '"')) -or
    $maximumSource.Contains(('"$value": "' + $variableName + '"'))) {
    throw 'Height graph is already wrapped by the runtime blend'
}

$basePose = Get-HipsConstraintInputPose -Text $baseSource
$minimumPose = Get-HipsConstraintInputPose -Text $minimumSource
$maximumPose = Get-HipsConstraintInputPose -Text $maximumSource

$originalHandleMatch = [regex]::Match($basePose.Object, '^\s*\{\s*"HandleId"\s*:\s*"(?<id>[0-9]+)"')
if (-not $originalHandleMatch.Success) {
    throw 'Could not read the original Hips input pose handle'
}
$originalHandle = $originalHandleMatch.Groups['id'].Value
function Get-EndpointBranch {
    param(
        [Parameter(Mandatory)] [string] $EndpointName,
        [Parameter(Mandatory)] [string] $EndpointPose,
        [Parameter(Mandatory)] [string] $OriginalPose,
        [Parameter(Mandatory)] [string] $OriginalPoseHandle
    )

    foreach ($marker in @(
        'ImmersiveFirstPerson_Left_Thigh_Extension',
        'ImmersiveFirstPerson_Left_Shin_Extension',
        'ImmersiveFirstPerson_Right_Thigh_Extension',
        'ImmersiveFirstPerson_Right_Shin_Extension',
        'ImmersiveFirstPerson_Grounded_Full_Height'
    )) {
        if (-not $EndpointPose.Contains($marker)) {
            throw "$EndpointName branch is missing $marker"
        }
    }

    $originalPoseOffset = $EndpointPose.IndexOf($OriginalPose, [StringComparison]::Ordinal)
    if ($originalPoseOffset -lt 0) {
        throw "Could not isolate the original pose inside the $EndpointName branch"
    }
    $originalPoseReference = '{ "HandleRefId": "' + $OriginalPoseHandle + '" }'
    return $EndpointPose.Substring(0, $originalPoseOffset) +
        $originalPoseReference +
        $EndpointPose.Substring($originalPoseOffset + $OriginalPose.Length)
}

$minimumBranch = Get-EndpointBranch `
    -EndpointName 'minimum-height' `
    -EndpointPose $minimumPose.Object `
    -OriginalPose $basePose.Object `
    -OriginalPoseHandle $originalHandle
$maximumBranch = Get-EndpointBranch `
    -EndpointName 'maximum-height' `
    -EndpointPose $maximumPose.Object `
    -OriginalPose $basePose.Object `
    -OriginalPoseHandle $originalHandle

# Both independently generated endpoints allocate the same wrapper handles.
# The maximum graph is the output base, so move the minimum branch above it.
$handleMatches = [regex]::Matches($maximumSource, '"HandleId"\s*:\s*"(?<id>[0-9]+)"')
$maxHandle = ($handleMatches | ForEach-Object { [uint64] $_.Groups['id'].Value } | Measure-Object -Maximum).Maximum
$nextHandle = [uint64] $maxHandle + 1
$minimumHandles = @(
    [regex]::Matches($minimumBranch, '"HandleId"\s*:\s*"(?<id>[0-9]+)"') |
        ForEach-Object { [uint64] $_.Groups['id'].Value } |
        Select-Object -Unique
)
foreach ($handle in $minimumHandles) {
    $replacement = [string] $nextHandle
    $minimumBranch = $minimumBranch.
        Replace(('"HandleId": "' + $handle + '"'), ('"HandleId": "' + $replacement + '"')).
        Replace(('"HandleRefId": "' + $handle + '"'), ('"HandleRefId": "' + $replacement + '"'))
    $nextHandle++
}

# Define the shared vanilla pose in the first branch so WolvenKit resolves it
# before the maximum branch's handle reference.
$originalPoseReference = '{ "HandleRefId": "' + $originalHandle + '" }'
$minimumBranch = $minimumBranch.Replace($originalPoseReference, $basePose.Object)

$blendHandle = $nextHandle
$floatNodeHandle = $nextHandle + 1
$variableHandle = $nextHandle + 2
$contractVariableHandle = $nextHandle + 3

$blendTemplate = @'
{
  "HandleId": "__BLEND_HANDLE__",
  "Data": {
    "$type": "animAnimNode_Blend2",
    "debugName": {
      "$type": "CName",
      "$storage": "string",
      "$value": "__DEBUG_NAME__"
    },
    "firstInputNode": {
      "$type": "animPoseLink",
      "node": __MINIMUM_POSE__
    },
    "id": 4294967295,
    "maxInputValue": 1,
    "minInputValue": 0,
    "poseInfoLogger": null,
    "secondInputNode": {
      "$type": "animPoseLink",
      "node": __MAXIMUM_POSE__
    },
    "syncMethod": null,
    "timeWarpingEnabled": 0,
    "visAxes": 0,
    "visMask": null,
    "visNames": 0,
    "visPostPose": 0,
    "visPostPoseColor": {
      "$type": "Color",
      "Alpha": 0,
      "Blue": 0,
      "Green": 0,
      "Red": 0
    },
    "visPrePose": 0,
    "visPrePoseColor": {
      "$type": "Color",
      "Alpha": 0,
      "Blue": 0,
      "Green": 0,
      "Red": 0
    },
    "visRigPartMask": {
      "$type": "CName",
      "$storage": "string",
      "$value": "None"
    },
    "visWhenActive": 0,
    "weightNode": {
      "$type": "animFloatLink",
      "node": {
        "HandleId": "__FLOAT_NODE_HANDLE__",
        "Data": {
          "$type": "animAnimNode_FloatVariable",
          "debugName": {
            "$type": "CName",
            "$storage": "string",
            "$value": "__DEBUG_NAME___Variable"
          },
          "id": 4294967295,
          "poseInfoLogger": null,
          "variableName": {
            "$type": "CName",
            "$storage": "string",
            "$value": "__VARIABLE_NAME__"
          },
          "visAxes": 0,
          "visMask": null,
          "visNames": 0,
          "visPostPose": 0,
          "visPostPoseColor": {
            "$type": "Color",
            "Alpha": 0,
            "Blue": 0,
            "Green": 0,
            "Red": 0
          },
          "visPrePose": 0,
          "visPrePoseColor": {
            "$type": "Color",
            "Alpha": 0,
            "Blue": 0,
            "Green": 0,
            "Red": 0
          },
          "visRigPartMask": {
            "$type": "CName",
            "$storage": "string",
            "$value": "None"
          },
          "visWhenActive": 0
        }
      }
    }
  }
}
'@

$blend = $blendTemplate.Replace('__BLEND_HANDLE__', [string] $blendHandle).
    Replace('__FLOAT_NODE_HANDLE__', [string] $floatNodeHandle).
    Replace('__MINIMUM_POSE__', $minimumBranch).
    Replace('__DEBUG_NAME__', $debugName).
    Replace('__VARIABLE_NAME__', $variableName).
    Replace('__MAXIMUM_POSE__', $maximumBranch)

$patched = $maximumSource.Substring(0, $maximumPose.Start) + $blend + $maximumSource.Substring($maximumPose.End + 1)

$variablesOffset = $patched.IndexOf('"variables": {', [StringComparison]::Ordinal)
$floatVariablesOffset = $patched.IndexOf('"floatVariables": [', $variablesOffset, [StringComparison]::Ordinal)
if ($variablesOffset -lt 0 -or $floatVariablesOffset -lt 0) {
    throw 'Could not locate the animgraph float variable container'
}
$variableInsertion = $patched.IndexOf('[', $floatVariablesOffset) + 1
$variableDefinition = @'

            {
              "HandleId": "__VARIABLE_HANDLE__",
              "Data": {
                "$type": "animAnimVariableFloat",
                "default": 0.5,
                "enableDebug": 0,
                "max": 1,
                "min": 0,
                "name": {
                  "$type": "CName",
                  "$storage": "string",
                  "$value": "__VARIABLE_NAME__"
                },
                "value": 0.5
              }
            },
'@
$variableDefinition = $variableDefinition.Replace('__VARIABLE_HANDLE__', [string] $variableHandle).
    Replace('__VARIABLE_NAME__', $variableName)
$contractVariableDefinition = $variableDefinition.
    Replace([string] $variableHandle, [string] $contractVariableHandle).
    Replace($variableName, $contractVariableName)
$patched = $patched.Insert($variableInsertion, $variableDefinition + $contractVariableDefinition)

New-Item -ItemType Directory -Path $jsonRoot, $generatedRoot, $verifyRoot, $stageRoot -Force | Out-Null
$jsonPath = Join-Path $jsonRoot 'player_base.animgraph.json'
[IO.File]::WriteAllText($jsonPath, $patched, [Text.UTF8Encoding]::new($false))

& $WolvenKit cr2w $jsonPath -d -o $generatedRoot -v Minimal
if ($LASTEXITCODE -ne 0) {
    throw 'WolvenKit failed to deserialize the runtime-blended player animgraph'
}
$generatedGraph = Join-Path $generatedRoot 'player_base.animgraph'
if (-not (Test-Path -LiteralPath $generatedGraph -PathType Leaf)) {
    throw "Generated player animgraph not found: $generatedGraph"
}

& $WolvenKit cr2w $generatedGraph -s -o $verifyRoot -v Minimal
if ($LASTEXITCODE -ne 0) {
    throw 'WolvenKit failed to serialize the runtime-blended graph for verification'
}
$verifiedJson = Join-Path $verifyRoot 'player_base.animgraph.json'
$verified = [IO.File]::ReadAllText($verifiedJson)
if (-not $verified.Contains($debugName) -or
    -not $verified.Contains('"$type": "animAnimNode_Blend2"') -or
    ([regex]::Matches($verified, ('"\$value"\s*:\s*"' + [regex]::Escape($variableName) + '"'))).Count -ne 2 -or
    ([regex]::Matches($verified, ('"\$value"\s*:\s*"' + [regex]::Escape($contractVariableName) + '"'))).Count -ne 1) {
    throw 'Round-trip verification did not retain the runtime blend contract'
}

Copy-Item -LiteralPath $generatedGraph -Destination (Join-Path $stageRoot 'player_base.animgraph') -Force
& $WolvenKit pack (Join-Path $experimentRoot 'stage') -o $experimentRoot -v Minimal
if ($LASTEXITCODE -ne 0) {
    throw 'WolvenKit failed to pack the runtime height proof'
}

$packed = [IO.Path]::GetFullPath((Join-Path $experimentRoot 'stage.archive'))
$disabled = [IO.Path]::GetFullPath((Join-Path $experimentRoot "ImmersiveFirstPersonHeight-animgraph-runtime-height-blend-proof-$VariantTag.archive.disabled"))
if (Test-Path -LiteralPath $disabled) {
    throw "Derived archive already exists: $disabled"
}
Move-Item -LiteralPath $packed -Destination $disabled

[pscustomobject]@{
    Archive = $disabled
    MinimumHeight = ('{0:R}m' -f $MinimumHeightMeters)
    MaximumHeight = ('{0:R}m' -f $MaximumHeightMeters)
    RuntimeVariable = $variableName
    ContractVariable = $contractVariableName
    DefaultBlend = 0.5
    BlendHandle = $blendHandle
    FloatNodeHandle = $floatNodeHandle
    VariableHandle = $variableHandle
    ContractVariableHandle = $contractVariableHandle
    Payload = 'base\gameplay\anim_graphs\player_base.animgraph'
} | Format-List
