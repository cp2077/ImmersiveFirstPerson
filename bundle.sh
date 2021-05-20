#!/bin/bash
rm -rf build
mkdir build
cd build
mkdir -p bin/x64/plugins/cyber_engine_tweaks/mods/SlightlyLessunimersiveFirstPerson/
cp ../init.lua bin/x64/plugins/cyber_engine_tweaks/mods/SlightlyLessunimersiveFirstPerson/init.lua
cp -r ../Modules bin/x64/plugins/cyber_engine_tweaks/mods/SlightlyLessunimersiveFirstPerson/
zip -r bin.zip bin
rm -rf bin
