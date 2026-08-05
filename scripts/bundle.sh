#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repository_root"

mod_version="${MOD_VERSION:-0.0.0-dev}"
native_dll="${NATIVE_DLL:-build/native/Release/ImmersiveFirstPerson.dll}"
height_archive="${HEIGHT_ARCHIVE:-optional/ImmersiveFirstPersonHeight.archive}"
if [[ "$mod_version" != "0.0.0-dev" && ! "$mod_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "MOD_VERSION must be stable SemVer or 0.0.0-dev; got '$mod_version'" >&2
    exit 1
fi

if [[ ! -f "$native_dll" ]]; then
    echo "Native DLL was not found at '$native_dll'; run scripts/build-native.ps1 or set NATIVE_DLL" >&2
    exit 1
fi
native_dll="$(realpath "$native_dll")"

if [[ ! -f "$height_archive" ]]; then
    echo "Height archive was not found at '$height_archive'; set HEIGHT_ARCHIVE" >&2
    exit 1
fi
height_archive="$(realpath "$height_archive")"

package_root="build/package"
rm -rf "$package_root"
mkdir -p "$package_root"
cd "$package_root"
mkdir -p bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/
mkdir -p red4ext/plugins/ImmersiveFirstPerson/
mkdir -p r6/scripts/ImmersiveFirstPerson/
mkdir -p archive/pc/mod/
staged_init="bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/init.lua"
cp ../../init.lua "$staged_init"

marker='version = "0.0.0-dev"'
marker_count=$(grep -Fc "$marker" "$staged_init" || true)
if [[ "$marker_count" -ne 1 ]]; then
    echo "Expected exactly one development version marker in init.lua; found $marker_count" >&2
    exit 1
fi

if [[ "$mod_version" != "0.0.0-dev" ]]; then
    sed -i 's/version = "0\.0\.0-dev"/version = "'"$mod_version"'"/' "$staged_init"
fi

cp -r ../../Modules bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/
cp "$native_dll" red4ext/plugins/ImmersiveFirstPerson/ImmersiveFirstPerson.dll
cp ../../r6/scripts/ImmersiveFirstPerson/LookAt.reds r6/scripts/ImmersiveFirstPerson/LookAt.reds
cp "$height_archive" archive/pc/mod/ImmersiveFirstPersonHeight.archive
zip -r "../Immersive First Person.zip" bin red4ext r6 archive
rm -rf bin red4ext r6 archive
