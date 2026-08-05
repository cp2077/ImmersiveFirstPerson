[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaseAnimGraphJson,
    [Parameter(Mandatory)]
    [string] $HeightAnimGraphJson,
    [ValidatePattern('^[a-z0-9-]+$')]
    [string] $VariantTag = '30cm',
    [ValidateRange(0.01, 0.50)]
    [double] $MaximumHeightMeters = 0.30,
    [Parameter(Mandatory)]
    [string] $WolvenKit,
    [Parameter(Mandatory)]
    [string] $WorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$variableName = 'ifp_height_blend'
$contractVariableName = 'ifp_height_contract_v1_30cm'
$debugName = 'ImmersiveFirstPerson_Runtime_Height_v1_30cm'
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

foreach ($path in @($BaseAnimGraphJson, $HeightAnimGraphJson, $WolvenKit)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

$baseSource = [IO.File]::ReadAllText([IO.Path]::GetFullPath($BaseAnimGraphJson))
$heightSource = [IO.File]::ReadAllText([IO.Path]::GetFullPath($HeightAnimGraphJson))
if ($heightSource.Contains($debugName) -or $heightSource.Contains(('"$value": "' + $variableName + '"'))) {
    throw 'Height graph is already wrapped by the runtime proof'
}

$basePose = Get-HipsConstraintInputPose -Text $baseSource
$heightPose = Get-HipsConstraintInputPose -Text $heightSource
if (-not $heightPose.Object.Contains('ImmersiveFirstPerson_Left_Thigh_Extension') -or
    -not $heightPose.Object.Contains('ImmersiveFirstPerson_Left_Shin_Extension') -or
    -not $heightPose.Object.Contains('ImmersiveFirstPerson_Right_Thigh_Extension') -or
    -not $heightPose.Object.Contains('ImmersiveFirstPerson_Right_Shin_Extension') -or
    -not $heightPose.Object.Contains('ImmersiveFirstPerson_Grounded_Full_Height')) {
    throw 'Expected the grounded full-height transform chain at the Hips constraint input'
}

$originalHandleMatch = [regex]::Match($basePose.Object, '^\s*\{\s*"HandleId"\s*:\s*"(?<id>[0-9]+)"')
if (-not $originalHandleMatch.Success) {
    throw 'Could not read the original Hips input pose handle'
}
$originalHandle = $originalHandleMatch.Groups['id'].Value
if (-not $heightPose.Object.Contains(('"HandleId": "' + $originalHandle + '"'))) {
    throw "The height branch no longer contains original pose handle $originalHandle"
}
$originalPoseOffset = $heightPose.Object.IndexOf($basePose.Object, [StringComparison]::Ordinal)
if ($originalPoseOffset -lt 0) {
    throw 'Could not isolate the original pose inside the fixed height branch'
}
$originalPoseReference = '{ "HandleRefId": "' + $originalHandle + '" }'
$heightBranch = $heightPose.Object.Substring(0, $originalPoseOffset) +
    $originalPoseReference +
    $heightPose.Object.Substring($originalPoseOffset + $basePose.Object.Length)

$handleMatches = [regex]::Matches($heightSource, '"HandleId"\s*:\s*"(?<id>[0-9]+)"')
$maxHandle = ($handleMatches | ForEach-Object { [uint64] $_.Groups['id'].Value } | Measure-Object -Maximum).Maximum
$blendHandle = $maxHandle + 1
$floatNodeHandle = $maxHandle + 2
$variableHandle = $maxHandle + 3
$contractVariableHandle = $maxHandle + 4

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
      "node": __ORIGINAL_POSE__
    },
    "id": 4294967295,
    "maxInputValue": 1,
    "minInputValue": 0,
    "poseInfoLogger": null,
    "secondInputNode": {
      "$type": "animPoseLink",
      "node": __HEIGHT_POSE__
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
    Replace('__ORIGINAL_POSE__', $basePose.Object).
    Replace('__DEBUG_NAME__', $debugName).
    Replace('__VARIABLE_NAME__', $variableName).
    Replace('__HEIGHT_POSE__', $heightBranch)

$patched = $heightSource.Substring(0, $heightPose.Start) + $blend + $heightSource.Substring($heightPose.End + 1)

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
                "default": 0,
                "enableDebug": 0,
                "max": 1,
                "min": 0,
                "name": {
                  "$type": "CName",
                  "$storage": "string",
                  "$value": "__VARIABLE_NAME__"
                },
                "value": 0
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
    MaximumHeight = ('{0:R}m' -f $MaximumHeightMeters)
    RuntimeVariable = $variableName
    ContractVariable = $contractVariableName
    DefaultBlend = 0.0
    BlendHandle = $blendHandle
    FloatNodeHandle = $floatNodeHandle
    VariableHandle = $variableHandle
    ContractVariableHandle = $contractVariableHandle
    Payload = 'base\gameplay\anim_graphs\player_base.animgraph'
} | Format-List
