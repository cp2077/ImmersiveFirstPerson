#include <RED4ext/RED4ext.hpp>
#include <RED4ext/Scripting/Natives/entEntity.hpp>
#include <RED4ext/Scripting/Natives/Generated/anim/AnimGraph.hpp>
#include <RED4ext/Scripting/Natives/Generated/anim/AnimNode_Root.hpp>
#include <RED4ext/Scripting/Natives/Generated/anim/AnimVariableContainer.hpp>
#include <RED4ext/Scripting/Natives/Generated/anim/AnimVariableFloat.hpp>
#include <RED4ext/Scripting/Natives/Generated/ent/AnimatedComponent.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/Puppet.hpp>

#include <atomic>
#include <cstdint>
#include <string>

namespace
{
constexpr RED4ext::CName kHeightInput("ifp_height_blend");
constexpr RED4ext::CName kHeightContract("ifp_height_contract_v1_30cm");

enum class HeightGraphStatus : int32_t
{
    WaitingForGraph = 0,
    Compatible = 1,
    IncompatibleContract = 2,
    MissingOrOverridden = 3,
};

RED4ext::v1::PluginHandle s_pluginHandle;
const RED4ext::v1::Logger* s_logger = nullptr;
std::atomic<bool> s_headLookAtEnabled{false};

void LogInfo(const std::string& aMessage)
{
    if (s_logger)
    {
        s_logger->Info(s_pluginHandle, aMessage.c_str());
    }
}

RED4ext::ent::Entity* GetEntity(RED4ext::IScriptable* aContext)
{
    if (!aContext)
    {
        return nullptr;
    }

    const auto* entityType = RED4ext::CRTTISystem::Get()->GetClass("entEntity");
    if (!entityType || !aContext->GetType()->IsA(entityType))
    {
        return nullptr;
    }

    return static_cast<RED4ext::ent::Entity*>(aContext);
}

RED4ext::ent::AnimatedComponent* FindRootAnimatedComponent(RED4ext::ent::Entity* aEntity)
{
    if (!aEntity)
    {
        return nullptr;
    }

    const auto* animatedType = RED4ext::CRTTISystem::Get()->GetClass(RED4ext::ent::AnimatedComponent::NAME);
    if (!animatedType)
    {
        return nullptr;
    }

    RED4ext::ent::AnimatedComponent* firstAnimated = nullptr;
    for (const auto& componentHandle : aEntity->components)
    {
        auto* component = componentHandle.GetPtr();
        if (!component || !component->GetType()->IsA(animatedType))
        {
            continue;
        }

        auto* animated = static_cast<RED4ext::ent::AnimatedComponent*>(component);
        if (!firstAnimated)
        {
            firstAnimated = animated;
        }
        if (animated->name == RED4ext::CName("root"))
        {
            return animated;
        }
    }

    return firstAnimated;
}

bool HasFloatVariable(const RED4ext::anim::AnimVariableContainer* aVariables, RED4ext::CName aName)
{
    if (!aVariables)
    {
        return false;
    }

    for (const auto& variableHandle : aVariables->floatVariables)
    {
        const auto* variable = variableHandle.GetPtr();
        if (variable && variable->name == aName)
        {
            return true;
        }
    }

    return false;
}

HeightGraphStatus InspectHeightGraph(RED4ext::ent::Entity* aEntity)
{
    auto* component = FindRootAnimatedComponent(aEntity);
    if (!component || !component->graph.IsLoaded())
    {
        return HeightGraphStatus::WaitingForGraph;
    }

    const auto* graph = component->graph.Get().GetPtr();
    if (!graph || !graph->rootNode || !graph->variables)
    {
        return HeightGraphStatus::WaitingForGraph;
    }

    const auto* variables = graph->variables.GetPtr();
    const bool hasInput = HasFloatVariable(variables, kHeightInput);
    const bool hasContract = HasFloatVariable(variables, kHeightContract);
    if (hasInput && hasContract)
    {
        return HeightGraphStatus::Compatible;
    }
    if (hasInput || hasContract)
    {
        return HeightGraphStatus::IncompatibleContract;
    }
    return HeightGraphStatus::MissingOrOverridden;
}

void GetHeightGraphStatus(RED4ext::IScriptable* aContext, RED4ext::CStackFrame* aFrame,
                          int32_t* aOut, int64_t)
{
    aFrame->code++;
    if (aOut)
    {
        *aOut = static_cast<int32_t>(InspectHeightGraph(GetEntity(aContext)));
    }
}

void SetHeadLookAtEnabled(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame,
                          bool* aOut, int64_t)
{
    bool enabled = false;
    RED4ext::GetParameter(aFrame, &enabled);
    aFrame->code++;
    s_headLookAtEnabled.store(enabled, std::memory_order_release);
    if (aOut)
    {
        *aOut = true;
    }
}

void IsHeadLookAtEnabled(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame,
                         bool* aOut, int64_t)
{
    aFrame->code++;
    if (aOut)
    {
        *aOut = s_headLookAtEnabled.load(std::memory_order_acquire);
    }
}
} // namespace

RED4EXT_C_EXPORT void RED4EXT_CALL RegisterTypes()
{
}

RED4EXT_C_EXPORT void RED4EXT_CALL PostRegisterTypes()
{
    auto* rtti = RED4ext::CRTTISystem::Get();

    // RED4ext validates the native declaration in LookAt.reds during startup.
    // Register the global before any optional class lookup or early return.
    {
        auto* function = RED4ext::CGlobalFunction::Create(
            "ImmersiveFirstPerson_IsHeadLookAtEnabled",
            "ImmersiveFirstPerson_IsHeadLookAtEnabled",
            &IsHeadLookAtEnabled);
        function->flags = {.isNative = true, .isStatic = true};
        function->SetReturnType("Bool");
        rtti->RegisterFunction(function);
    }

    // CET calls these on V. Registering on gamePuppet avoids REDscript native
    // method declarations and makes a missing plugin fail safely in Lua.
    auto* puppetClass = rtti->GetClass(RED4ext::game::Puppet::NAME);
    if (!puppetClass)
    {
        if (s_logger)
        {
            s_logger->Error(s_pluginHandle, "gamePuppet RTTI class was not found; runtime controls unavailable.");
        }
        return;
    }

    {
        auto* function = RED4ext::CClassFunction::Create(
            puppetClass,
            "ImmersiveFirstPersonGetHeightGraphStatus",
            "ImmersiveFirstPersonGetHeightGraphStatus",
            &GetHeightGraphStatus);
        function->flags = {.isNative = true};
        function->SetReturnType("Int32");
        puppetClass->RegisterFunction(function);
    }

    {
        auto* function = RED4ext::CClassFunction::Create(
            puppetClass,
            "ImmersiveFirstPersonSetHeadLookAtEnabled",
            "ImmersiveFirstPersonSetHeadLookAtEnabled",
            &SetHeadLookAtEnabled);
        function->flags = {.isNative = true};
        function->AddParam("Bool", "enabled");
        function->SetReturnType("Bool");
        puppetClass->RegisterFunction(function);
    }

    LogInfo("Runtime height contract and look-at controls registered.");
}

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle,
                                       RED4ext::v1::EMainReason aReason,
                                       const RED4ext::v1::Sdk* aSdk)
{
    switch (aReason)
    {
    case RED4ext::v1::EMainReason::Load:
        s_pluginHandle = aHandle;
        s_logger = aSdk->logger;
        RED4ext::CRTTISystem::Get()->AddRegisterCallback(RegisterTypes);
        RED4ext::CRTTISystem::Get()->AddPostRegisterCallback(PostRegisterTypes);
        LogInfo("Immersive First Person native plugin loaded.");
        break;
    case RED4ext::v1::EMainReason::Unload:
        s_headLookAtEnabled.store(false, std::memory_order_release);
        break;
    }
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"Immersive First Person";
    aInfo->author = L"Immersive First Person contributors";
    aInfo->version = RED4EXT_V1_SEMVER(0, 2, 0);
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_2_31;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
