[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Pattern,

    [ValidateSet('All', 'NativeDB', 'Scripts')]
    [string] $Source = 'All',

    [ValidateRange(1, 500)]
    [int] $Limit = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$referenceRoot = Join-Path $env:LOCALAPPDATA 'Cyberpunk2077Modding\references'
$nativeDBRoot = Join-Path $referenceRoot 'nativedb'
$scriptsRoot = Join-Path $referenceRoot 'decompiled-scripts'
$literalPattern = [regex]::Escape($Pattern)

if ($Source -in @('All', 'NativeDB')) {
    if (-not (Test-Path -LiteralPath $nativeDBRoot)) {
        throw "NativeDB reference directory was not found: $nativeDBRoot"
    }

    Write-Host 'NativeDB top-level entries'
    $nativeMatches = 0

    foreach ($fileName in @('classes.json', 'globals.json', 'enums.json', 'bitfields.json')) {
        $filePath = Join-Path $nativeDBRoot $fileName
        $category = [IO.Path]::GetFileNameWithoutExtension($fileName)
        $entries = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json

        foreach ($entry in $entries) {
            if ($nativeMatches -ge $Limit) {
                break
            }

            $serialized = $entry | ConvertTo-Json -Compress -Depth 32
            if ($serialized -match $literalPattern) {
                $entryName = if ($fileName -eq 'classes.json') { $entry.b } else { $entry.a }
                Write-Output "[$category] $entryName"
                $nativeMatches++
            }
        }

        if ($nativeMatches -ge $Limit) {
            break
        }
    }

    if ($nativeMatches -eq 0) {
        Write-Output '(no NativeDB matches)'
    } elseif ($nativeMatches -ge $Limit) {
        Write-Output "(NativeDB results limited to $Limit)"
    }
}

if ($Source -in @('All', 'Scripts')) {
    if (-not (Test-Path -LiteralPath $scriptsRoot)) {
        throw "Decompiled script reference directory was not found: $scriptsRoot"
    }

    Write-Host 'Decompiled script call sites'
    $ripgrep = Get-Command 'rg.exe' -ErrorAction SilentlyContinue
    if (-not $ripgrep) {
        $ripgrep = Get-Command 'rg' -ErrorAction SilentlyContinue
    }
    if (-not $ripgrep) {
        throw 'ripgrep (rg) is required to search the decompiled scripts.'
    }

    $scriptMatches = @(
        & $ripgrep.Source --line-number --ignore-case --fixed-strings --glob '*.swift' -- $Pattern $scriptsRoot |
            Select-Object -First $Limit
    )

    if ($LASTEXITCODE -notin @(0, 1)) {
        throw "ripgrep failed with exit code $LASTEXITCODE"
    }

    if ($scriptMatches.Count -eq 0) {
        Write-Output '(no decompiled-script matches)'
    } else {
        $scriptMatches | Write-Output
        if ($scriptMatches.Count -ge $Limit) {
            Write-Output "(script results limited to $Limit)"
        }
    }
}
