#!/usr/bin/env bash
set -euo pipefail

mod_version="${MOD_VERSION:-0.0.0-dev}"
if [[ "$mod_version" != "0.0.0-dev" && ! "$mod_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "MOD_VERSION must be stable SemVer or 0.0.0-dev; got '$mod_version'" >&2
    exit 1
fi

rm -rf build
mkdir build
cd build
mkdir -p bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/
staged_init="bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/init.lua"
cp ../init.lua "$staged_init"

marker='version = "0.0.0-dev"'
marker_count=$(grep -Fc "$marker" "$staged_init" || true)
if [[ "$marker_count" -ne 1 ]]; then
    echo "Expected exactly one development version marker in init.lua; found $marker_count" >&2
    exit 1
fi

if [[ "$mod_version" != "0.0.0-dev" ]]; then
    sed -i 's/version = "0\.0\.0-dev"/version = "'"$mod_version"'"/' "$staged_init"
fi

cp -r ../Modules bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson/
zip -r "Immersive First Person.zip" bin
rm -rf bin
