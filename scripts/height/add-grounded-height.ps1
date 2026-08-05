[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [double] $DeltaMeters,
    [Parameter(Mandatory)]
    [string] $AnimGraphJson,
    [Parameter(Mandatory)]
    [string] $WolvenKit,
    [Parameter(Mandatory)]
    [string] $WorkRoot,
    [ValidateSet('BeforeHipsConstraint', 'BeforeChestConstraint', 'GroundedFullHeight', 'PostProcess')]
    [string] $Placement = 'BeforeHipsConstraint',
    [ValidatePattern('^[a-z0-9-]*$')]
    [string] $VariantTag = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

if (-not (Test-Path -LiteralPath $AnimGraphJson -PathType Leaf)) {
    throw "Player animgraph JSON not found: $AnimGraphJson"
}
if (-not (Test-Path -LiteralPath $WolvenKit -PathType Leaf)) {
    throw "WolvenKit CLI not found: $WolvenKit"
}
if ($DeltaMeters -eq 0.0 -or [Math]::Abs($DeltaMeters) -gt 0.50) {
    throw "DeltaMeters must be non-zero and between -0.50 and 0.50"
}

$placementSlug = switch ($Placement) {
    'BeforeHipsConstraint' { 'cog-before-hips' }
    'BeforeChestConstraint' { 'chest-before-spine3' }
    'GroundedFullHeight' { 'grounded-full-height' }
    'PostProcess' { 'cog-postprocess' }
}
$experimentSlug = if ($VariantTag) { "$placementSlug-$VariantTag" } else { $placementSlug }
$debugName = switch ($Placement) {
    'BeforeHipsConstraint' { 'ImmersiveFirstPerson_COG_Height_Before_Hips' }
    'BeforeChestConstraint' { 'ImmersiveFirstPerson_Chest_Height_Before_Spine3' }
    'GroundedFullHeight' { 'ImmersiveFirstPerson_Grounded_Full_Height' }
    'PostProcess' { 'ImmersiveFirstPerson_COG_Height_PostProcess' }
}
$translatedBone = if ($Placement -eq 'BeforeChestConstraint') {
    'Torso_Chest_Control_GRP'
} else {
    'Torso_COG_Control_JNT'
}
$experimentRoot = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ("animgraph-$experimentSlug")
$jsonRoot = Join-Path $experimentRoot 'json'
$generatedRoot = Join-Path $experimentRoot 'generated'
$verifyRoot = Join-Path $experimentRoot 'verify'
$stageRoot = Join-Path $experimentRoot 'stage\base\gameplay\anim_graphs'
New-Item -ItemType Directory -Path $jsonRoot, $generatedRoot, $verifyRoot, $stageRoot -Force | Out-Null

$source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($AnimGraphJson))
if (-not $source.Contains('"$type": "animAnimGraph"')) {
    throw 'Input is not a serialized animAnimGraph'
}
if ($source.Contains('ImmersiveFirstPerson_COG_Height_')) {
    throw 'Input animgraph is already wrapped by this experiment'
}

$handleMatches = [regex]::Matches($source, '"HandleId"\s*:\s*"(?<id>[0-9]+)"')
if ($handleMatches.Count -eq 0) {
    throw 'No animgraph handles found'
}
$maxHandle = ($handleMatches | ForEach-Object { [uint64] $_.Groups['id'].Value } | Measure-Object -Maximum).Maximum
$nextHandle = $maxHandle + 1

if ($Placement -eq 'PostProcess') {
    # The first handles in the cooked player graph are Root=0, Output=1, and
    # the complete final player pose=2. Wrapping handle 2 is a deliberately
    # late camera/control-bone experiment; it runs after normal animation/IK.
    $rootMarker = '"HandleId": "0"'
    $outputMarker = '"HandleId": "1"'
    $poseMarker = '"HandleId": "2"'
    $rootOffset = $source.IndexOf($rootMarker, [StringComparison]::Ordinal)
    $outputOffset = $source.IndexOf($outputMarker, $rootOffset + $rootMarker.Length, [StringComparison]::Ordinal)
    $poseOffset = $source.IndexOf($poseMarker, $outputOffset + $outputMarker.Length, [StringComparison]::Ordinal)
    if ($rootOffset -lt 0 -or $outputOffset -lt 0 -or $poseOffset -lt 0) {
        throw 'Expected Root/Output/final-pose handle sequence was not found'
    }

    $poseObjectStart = $source.LastIndexOf('{', $poseOffset)
    $poseObjectEnd = Find-JsonObjectEnd -Text $source -ObjectStart $poseObjectStart
    $poseObject = $source.Substring($poseObjectStart, $poseObjectEnd - $poseObjectStart + 1)
    if (-not $poseObject.Contains('"$type": "animAnimNode_Switch"')) {
        throw 'Handle 2 is not the expected final player-pose switch'
    }
} else {
    if ($Placement -in @('BeforeHipsConstraint', 'GroundedFullHeight')) {
        # The real Hips bone is a sibling of COG under Root. Insert immediately
        # before CDPR copies the COG-descendant hips driver into real Hips.
        $constraintSource = 'Torso_Hips_Driver_GRP'
        $constraintTarget = 'Hips'
    } else {
        # Chest Control is a COG child and a parent of the camera-control chain.
        # Insert before CDPR copies its descendant chest driver into real Spine3:
        # feet/Hips stay fixed while chest, camera, and upper body move upward.
        $constraintSource = 'Torso_Chest_Driver_GRP'
        $constraintTarget = 'Spine3'
    }
    $constraintPattern = [regex]::new(
        '"HandleId"\s*:\s*"[0-9]+"\s*,\s*"Data"\s*:\s*\{\s*"\$type"\s*:\s*"animAnimNode_ParentConstraint"'
    )
    $candidates = @()
    foreach ($constraintMatch in $constraintPattern.Matches($source)) {
        $constraintStart = $source.LastIndexOf('{', $constraintMatch.Index)
        $constraintEnd = Find-JsonObjectEnd -Text $source -ObjectStart $constraintStart
        $constraintObject = $source.Substring($constraintStart, $constraintEnd - $constraintStart + 1)
        $tailLength = [Math]::Min(300000, $constraintObject.Length)
        $tail = $constraintObject.Substring($constraintObject.Length - $tailLength)
        if ($tail.Contains(('"$value": "' + $constraintSource + '"')) -and
            $tail.Contains(('"$value": "' + $constraintTarget + '"'))) {
            $candidates += [pscustomobject]@{
                Start = $constraintStart
                Object = $constraintObject
            }
        }
    }
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one $constraintSource -> $constraintTarget parent constraint, found $($candidates.Count)"
    }

    $constraintStart = $candidates[0].Start
    $constraintObject = $candidates[0].Object
    $inputLinkOffset = $constraintObject.IndexOf('"inputLink"', [StringComparison]::Ordinal)
    $inputHandleOffset = $constraintObject.IndexOf('"HandleId"', $inputLinkOffset, [StringComparison]::Ordinal)
    if ($inputLinkOffset -lt 0 -or $inputHandleOffset -lt 0) {
        throw "$constraintTarget parent constraint has no input pose handle"
    }
    $relativePoseStart = $constraintObject.LastIndexOf('{', $inputHandleOffset)
    $poseObjectStart = $constraintStart + $relativePoseStart
    $poseObjectEnd = Find-JsonObjectEnd -Text $source -ObjectStart $poseObjectStart
    $poseObject = $source.Substring($poseObjectStart, $poseObjectEnd - $poseObjectStart + 1)
}

$wrapperTemplate = @'
{
  "HandleId": "__TRANSLATE_HANDLE__",
  "Data": {
    "$type": "animAnimNode_TranslateBone",
    "biasValue": {
      "$type": "Vector4",
      "W": 0,
      "X": 0,
      "Y": 0,
      "Z": 0
    },
    "bone": {
      "$type": "animTransformIndex",
      "name": {
        "$type": "CName",
        "$storage": "string",
        "$value": "__BONE_NAME__"
      }
    },
    "debugName": {
      "$type": "CName",
      "$storage": "string",
      "$value": "__DEBUG_NAME__"
    },
    "id": 4294967295,
    "inputNode": {
      "$type": "animPoseLink",
      "node": __ORIGINAL_POSE__
    },
    "inputTranslation": {
      "$type": "animVectorLink",
      "node": {
        "HandleId": "__VECTOR_HANDLE__",
        "Data": {
          "$type": "animAnimNode_VectorConstant",
          "debugName": {
            "$type": "CName",
            "$storage": "string",
            "$value": "__DEBUG_NAME___Vector"
          },
          "id": 4294967295,
          "poseInfoLogger": null,
          "value": {
            "$type": "Vector4",
            "W": 0,
            "X": __X__,
            "Y": __Y__,
            "Z": __Z__
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
    },
    "poseInfoLogger": null,
    "resetOnActivation": 1,
    "scale": {
      "$type": "Vector4",
      "W": 1,
      "X": 1,
      "Y": 1,
      "Z": 1
    },
    "useIncrementalMode": 0,
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
'@

if ($Placement -eq 'GroundedFullHeight') {
    $halfDelta = $DeltaMeters * 0.5
    # The actual leg segment translations are mirrored local X in both player
    # rigs. Extend each thigh and shin by half the COG rise, then let the Hips
    # parent constraint raise pelvis/camera by the complete requested amount.
    $translations = @(
        [pscustomobject]@{ Debug = 'ImmersiveFirstPerson_Left_Thigh_Extension'; Bone = 'LeftLeg'; X = $halfDelta; Y = 0.0; Z = 0.0 },
        [pscustomobject]@{ Debug = 'ImmersiveFirstPerson_Left_Shin_Extension'; Bone = 'LeftFoot'; X = $halfDelta; Y = 0.0; Z = 0.0 },
        [pscustomobject]@{ Debug = 'ImmersiveFirstPerson_Right_Thigh_Extension'; Bone = 'RightLeg'; X = -$halfDelta; Y = 0.0; Z = 0.0 },
        [pscustomobject]@{ Debug = 'ImmersiveFirstPerson_Right_Shin_Extension'; Bone = 'RightFoot'; X = -$halfDelta; Y = 0.0; Z = 0.0 },
        [pscustomobject]@{ Debug = $debugName; Bone = 'Torso_COG_Control_JNT'; X = 0.0; Y = 0.0; Z = $DeltaMeters }
    )
} else {
    $translations = @(
        [pscustomobject]@{ Debug = $debugName; Bone = $translatedBone; X = 0.0; Y = 0.0; Z = $DeltaMeters }
    )
}

$wrapper = $poseObject
$allocatedHandles = @()
foreach ($translation in $translations) {
    $translateHandle = $nextHandle
    $vectorHandle = $nextHandle + 1
    $nextHandle += 2
    $allocatedHandles += $translateHandle, $vectorHandle
    $xText = ([double] $translation.X).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $yText = ([double] $translation.Y).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $zText = ([double] $translation.Z).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $wrapper = $wrapperTemplate.Replace('__TRANSLATE_HANDLE__', [string] $translateHandle).
        Replace('__VECTOR_HANDLE__', [string] $vectorHandle).
        Replace('__DEBUG_NAME__', $translation.Debug).
        Replace('__BONE_NAME__', $translation.Bone).
        Replace('__X__', $xText).
        Replace('__Y__', $yText).
        Replace('__Z__', $zText).
        Replace('__ORIGINAL_POSE__', $wrapper)
}
$patched = $source.Substring(0, $poseObjectStart) + $wrapper + $source.Substring($poseObjectEnd + 1)

$jsonPath = Join-Path $jsonRoot 'player_base.animgraph.json'
[IO.File]::WriteAllText($jsonPath, $patched, [Text.UTF8Encoding]::new($false))

& $WolvenKit cr2w $jsonPath -d -o $generatedRoot -v Minimal
if ($LASTEXITCODE -ne 0) {
    throw 'WolvenKit failed to deserialize the patched player animgraph'
}
$generatedGraph = Join-Path $generatedRoot 'player_base.animgraph'
if (-not (Test-Path -LiteralPath $generatedGraph -PathType Leaf)) {
    throw "Generated player animgraph not found: $generatedGraph"
}

& $WolvenKit cr2w $generatedGraph -s -o $verifyRoot -v Minimal
if ($LASTEXITCODE -ne 0) {
    throw 'WolvenKit failed to serialize the generated player animgraph for verification'
}
$verifiedJson = Join-Path $verifyRoot 'player_base.animgraph.json'
$verified = [IO.File]::ReadAllText($verifiedJson)
foreach ($translation in $translations) {
    if (([regex]::Matches($verified, ([regex]::Escape($translation.Debug) + '"'))).Count -ne 1 -or
        -not $verified.Contains(('"$value": "' + $translation.Bone + '"'))) {
        throw "Round-trip verification did not retain $($translation.Debug) on $($translation.Bone)"
    }
}

Copy-Item -LiteralPath $generatedGraph -Destination (Join-Path $stageRoot 'player_base.animgraph') -Force
& $WolvenKit pack (Join-Path $experimentRoot 'stage') -o $experimentRoot -v Minimal
if ($LASTEXITCODE -ne 0) {
    throw 'WolvenKit failed to pack the COG animgraph experiment'
}

$packed = [IO.Path]::GetFullPath((Join-Path $experimentRoot 'stage.archive'))
$disabled = [IO.Path]::GetFullPath((Join-Path $experimentRoot ("ImmersiveFirstPersonHeight-animgraph-$experimentSlug.archive.disabled")))
$experimentPrefix = [IO.Path]::GetFullPath($experimentRoot).TrimEnd('\') + '\'
if (-not $packed.StartsWith($experimentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not $disabled.StartsWith($experimentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe derived archive path below: $experimentRoot"
}
if (Test-Path -LiteralPath $disabled) {
    throw "Derived archive already exists: $disabled"
}
Move-Item -LiteralPath $packed -Destination $disabled

[pscustomobject]@{
    Archive = $disabled
    DeltaMeters = $DeltaMeters
    Placement = $Placement
    VariantTag = $VariantTag
    TranslateNodeCount = $translations.Count
    AllocatedHandles = ($allocatedHandles -join ',')
    Payload = 'base\gameplay\anim_graphs\player_base.animgraph'
} | Format-List
