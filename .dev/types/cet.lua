---@meta

-- Minimal LuaLS declarations for the CET surface currently used by this mod.
-- Native Cyberpunk objects deliberately return `any`: their authoritative
-- signatures come from the installed game's RTTI and NativeDB.

---@param eventName string
---@param callback fun(...)
function registerForEvent(eventName, callback) end

---@param id string
---@param description string
---@param callback fun()
function registerHotkey(id, description, callback) end

---@param id string
---@param description string
---@param callback fun(keydown: boolean)
function registerInput(id, description, callback) end

---@param className string
---@param methodName string
---@param callback fun(...)
function Observe(className, methodName, callback) end

---@param className string
---@param methodName string
---@param callback fun(...)
function ObserveAfter(className, methodName, callback) end

---@param className string
---@param methodName string
---@param callback fun(...)
function Override(className, methodName, callback) end

---@return string
function GetVersion() end

---@param name string
---@return any
function GetSingleton(name) end

---@param name string
---@return any
function GetMod(name) end

---@param object any
---@param detailed? boolean
---@return string
function Dump(object, detailed) end

---@param typeName string
---@param detailed? boolean
---@return string
function DumpType(typeName, detailed) end

---@param object any
---@return string
function GameDump(object) end

---@class CETDirEntry
---@field name string
---@field type? string

---@param path string
---@return CETDirEntry[]
function dir(path) end

---@class CETGame
Game = {}

---@return any
function Game.GetAllBlackboardDefs() end
---@return any
function Game.GetBlackboardSystem() end
---@return any
function Game.GetPlayer() end
---@return any
function Game.GetQuestsSystem() end
---@return any
function Game.GetSettingsSystem() end
---@return any
function Game.GetSimTime() end
---@return any
function Game.GetTeleportationFacility() end
---@return any
function Game.GetTimeSystem() end
---@return any
function Game.GetTransactionSystem() end
---@return any
function Game.GetWorkspotSystem() end
---@param name any
---@return string
function Game.NameToString(name) end

---@class CETJson
json = {}
---@param value any
---@return string
function json.encode(value) end
---@param value string
---@return any
function json.decode(value) end

---@class CETSpdlog
spdlog = {}
---@param message string
function spdlog.debug(message) end
---@param message string
function spdlog.trace(message) end
---@param message string
function spdlog.info(message) end
---@param message string
function spdlog.warning(message) end
---@param message string
function spdlog.error(message) end
---@param message string
function spdlog.critical(message) end

---@class CETImGui
ImGui = {}
---@param ... any
---@return boolean
function ImGui.Begin(...) end
---@param ... any
---@return boolean
function ImGui.Button(...) end
---@param ... any
function ImGui.BeginTooltip(...) end
---@param value boolean
---@param ... any
---@return boolean value
---@return boolean changed
function ImGui.Checkbox(_, value, ...) end
function ImGui.End() end
function ImGui.EndTooltip() end
---@return boolean
function ImGui.IsItemHovered() end
---@param ... any
function ImGui.PopStyleColor(...) end
---@param ... any
function ImGui.PopStyleVar(...) end
---@param ... any
function ImGui.PushStyleColor(...) end
---@param ... any
function ImGui.PushStyleVar(...) end
---@param ... any
function ImGui.SetTooltip(...) end
---@param label string
---@param value integer
---@param min integer
---@param max integer
---@return integer value
---@return boolean changed
function ImGui.SliderInt(label, value, min, max) end
---@param ... any
---@return boolean
function ImGui.SmallButton(...) end
---@param ... any
function ImGui.Text(...) end

---@class CETEnumTable
---@field [string] integer

---@type CETEnumTable
ImGuiStyleVar = {}
---@type CETEnumTable
ImGuiWindowFlags = {}
---@type CETEnumTable
ImGuiCol = {}

---@class CETStatusEffectSystem
StatusEffectSystem = {}
---@param object any
---@param effectType any
---@return boolean
function StatusEffectSystem.ObjectHasStatusEffectOfType(object, effectType) end

---@class PlayerPuppet
---@field GetEntityID fun(self: PlayerPuppet): any
---@field IsReplacer fun(self: PlayerPuppet): boolean

---@class CETConstructor
---@field new fun(...: any): any

---@class CETQuaternionConstructor:CETConstructor
---@field MulInverse fun(a: any, b: any): any
---@field SetAxisAngle fun(axis: any, angle: number): any

---@type CETConstructor
Vector4 = { new = function(...) return {} end }
---@type CETQuaternionConstructor
Quaternion = { new = function(...) return {} end }
---@type CETConstructor
EulerAngles = { new = function(...) return {} end }
---@type CETConstructor
CName = { new = function(...) return {} end }
---@type CETConstructor
TweakDBID = { new = function(...) return {} end }

---@class CETMatrix
---@field GetTranslation fun(matrix: any): any
Matrix = {}

---@class CETWorldTransform
---@field TransformInvPoint fun(transform: any, point: any): any
WorldTransform = {}
