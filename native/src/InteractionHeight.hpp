#pragma once

#include <RED4ext/RED4ext.hpp>

namespace InteractionHeight
{
bool Install(RED4ext::v1::PluginHandle aHandle, const RED4ext::v1::Sdk* aSdk);
void Uninstall(RED4ext::v1::PluginHandle aHandle, const RED4ext::v1::Sdk* aSdk);
bool IsAvailable();
void RegisterFunctions(RED4ext::CClass* aPuppetClass);
}
