#include "InteractionHeight.hpp"

#include <RED4ext/Scripting/Natives/Generated/game/interactions/ContainedInShapesPredicate.hpp>

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstring>

namespace
{
// Cyberpunk 2077 2.31: ContainedInShapesPredicate's camera/entity position selector.
constexpr uintptr_t kEvaluateOffset = 0x212D14;
using Evaluate = bool (*)(RED4ext::game::interactions::ContainedInShapesPredicate*, const void*, void*, void*);
Evaluate s_evaluate = nullptr;
void* s_target = nullptr;
bool s_available = false;

// The selector reads only the two positions. Preserve the rest of its input,
// including the owner at +0x10, without touching the shared worker context.
struct alignas(16) ActivatorInput
{
    std::array<std::byte, 0x10> header;
    const void* owner;
    std::array<std::byte, 0x48> actorData;
    RED4ext::Vector4 entityPosition;
    std::array<std::byte, 0x10> viewData;
    RED4ext::Vector4 cameraPosition;
};
static_assert(offsetof(ActivatorInput, owner) == 0x10);
static_assert(offsetof(ActivatorInput, entityPosition) == 0x60);
static_assert(offsetof(ActivatorInput, cameraPosition) == 0x80);
static_assert(sizeof(ActivatorInput) == 0x90);

// CET publishes on the game thread; interaction evaluation runs on workers.
// A generation prevents readers from combining different players and offsets.
std::atomic<uint64_t> s_generation{0};
std::atomic<const void*> s_player{nullptr};
std::atomic<float> s_offset{0.0f};

void Publish(const void* aPlayer, float aOffset)
{
    s_generation.fetch_add(1);
    s_player.store(aPlayer);
    s_offset.store(aOffset);
    s_generation.fetch_add(1);
}

float ReadOffset(const void* aPlayer)
{
    const auto generation = s_generation.load();
    if (generation & 1)
    {
        return 0.0f;
    }
    const auto* player = s_player.load();
    const float offset = s_offset.load();
    return player == aPlayer && s_generation.load() == generation ? offset : 0.0f;
}

bool EvaluateWithHeight(RED4ext::game::interactions::ContainedInShapesPredicate* aPredicate,
                        const void* aActivator, void* aHotspot, void* aLayer)
{
    if (!aPredicate->useCameraPosition)
    {
        return s_evaluate(aPredicate, aActivator, aHotspot, aLayer);
    }

    const void* owner;
    std::memcpy(&owner, static_cast<const std::byte*>(aActivator) + offsetof(ActivatorInput, owner), sizeof(owner));
    const float offset = ReadOffset(owner);
    if (offset == 0.0f)
    {
        return s_evaluate(aPredicate, aActivator, aHotspot, aLayer);
    }

    ActivatorInput adjusted;
    std::memcpy(&adjusted, aActivator, sizeof(adjusted));
    adjusted.cameraPosition.Z -= offset;
    return s_evaluate(aPredicate, &adjusted, aHotspot, aLayer);
}

void SetOffset(RED4ext::IScriptable* aContext, RED4ext::CStackFrame* aFrame, void*, int64_t)
{
    float offset = 0.0f;
    RED4ext::GetParameter(aFrame, &offset);
    aFrame->code++;
    if (!std::isfinite(offset) || offset < -0.5f || offset > 0.5f)
    {
        offset = 0.0f;
    }
    Publish(aContext, offset);
}

void ResetOffset(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame, void*, int64_t)
{
    aFrame->code++;
    Publish(nullptr, 0.0f);
}
}

bool InteractionHeight::Install(RED4ext::v1::PluginHandle aHandle, const RED4ext::v1::Sdk* aSdk)
{
    s_target = reinterpret_cast<std::byte*>(GetModuleHandleW(nullptr)) + kEvaluateOffset;
    // Check the entire selector before relying on its input layout or replacing it.
    constexpr uint8_t expected[] = {
        0x48,0x83,0xec,0x38,0x8a,0x41,0x30,0x4d,0x8b,0xd8,0xf6,0xd8,0x48,0x8d,0x4c,0x24,0x20,
        0x4d,0x1b,0xd2,0x41,0x83,0xe2,0x20,0xf3,0x41,0x0f,0x10,0x4c,0x12,0x60,0xe8,0x0c,0x80,
        0xfc,0xff,0xf3,0x41,0x0f,0x10,0x4c,0x12,0x64,0x48,0x8d,0x4c,0x24,0x24,0xe8,0xfb,0x7f,
        0xfc,0xff,0xf3,0x41,0x0f,0x10,0x4c,0x12,0x68,0x48,0x8d,0x4c,0x24,0x28,0xe8,0xea,0x7f,
        0xfc,0xff,0x4c,0x8d,0x44,0x24,0x20,0x49,0x8b,0xd1,0x49,0x8b,0xcb,0xe8,0x06,0x00,0x00,
        0x00,0x48,0x83,0xc4,0x38,0xc3
    };
    if (std::memcmp(s_target, expected, sizeof(expected)) != 0)
    {
        aSdk->logger->Warn(aHandle, "Interaction height selector is incompatible; height adjustment disabled.");
        return false;
    }
    s_available = aSdk->hooking->Attach(aHandle, s_target, reinterpret_cast<void*>(&EvaluateWithHeight),
                                       reinterpret_cast<void**>(&s_evaluate));
    if (!s_available)
    {
        aSdk->logger->Warn(aHandle, "Interaction height hook could not be installed; height adjustment disabled.");
    }
    return s_available;
}

void InteractionHeight::Uninstall(RED4ext::v1::PluginHandle aHandle, const RED4ext::v1::Sdk* aSdk)
{
    Publish(nullptr, 0.0f);
    if (s_available)
    {
        aSdk->hooking->Detach(aHandle, s_target);
        s_available = false;
    }
}

bool InteractionHeight::IsAvailable()
{
    return s_available;
}

void InteractionHeight::RegisterFunctions(RED4ext::CClass* aPuppetClass)
{
    auto* setter = RED4ext::CClassFunction::Create(aPuppetClass,
        "ImmersiveFirstPersonSetInteractionHeight", "ImmersiveFirstPersonSetInteractionHeight", &SetOffset);
    setter->flags = {.isNative = true};
    setter->AddParam("Float", "offsetMeters");
    aPuppetClass->RegisterFunction(setter);

    auto* reset = RED4ext::CGlobalFunction::Create(
        "ImmersiveFirstPersonResetInteractionHeight", "ImmersiveFirstPersonResetInteractionHeight", &ResetOffset);
    reset->flags = {.isNative = true, .isStatic = true};
    RED4ext::CRTTISystem::Get()->RegisterFunction(reset);
}
