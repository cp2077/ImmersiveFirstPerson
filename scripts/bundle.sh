#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repository_root"

mod_version="${MOD_VERSION:-0.0.0-dev}"
native_dll="${NATIVE_DLL:-build/native/Release/ImmersiveFirstPerson.dll}"
height_archive="${HEIGHT_ARCHIVE:-optional/ImmersiveFirstPersonHeight.archive}"
itp_archive="optional/0_ImmersiveFirstPerson_ITP_Compat.archive"
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

if [[ ! -f "$itp_archive" ]]; then
    echo "ITP compatibility archive was not found at '$itp_archive'" >&2
    exit 1
fi
itp_archive="$(realpath "$itp_archive")"

create_zip() {
    local output="$1"
    shift

    rm -f "$output"
    if command -v zip >/dev/null 2>&1; then
        zip -r "$output" "$@"
    elif [[ -x /c/Windows/System32/tar.exe ]]; then
        /c/Windows/System32/tar.exe -a -c -f "$output" "$@"
    else
        echo "Neither zip nor Windows tar.exe is available" >&2
        exit 1
    fi
}

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
cp ../../r6/scripts/ImmersiveFirstPerson/*.reds r6/scripts/ImmersiveFirstPerson/
cp "$height_archive" archive/pc/mod/ImmersiveFirstPersonHeight.archive
create_zip "../Immersive First Person.zip" bin red4ext r6 archive

rm archive/pc/mod/ImmersiveFirstPersonHeight.archive
cp "$itp_archive" archive/pc/mod/0_ImmersiveFirstPerson_ITP_Compat.archive
create_zip "../Immersive First Person - ITP Compatibility.zip" archive
rm -rf bin red4ext r6 archive
