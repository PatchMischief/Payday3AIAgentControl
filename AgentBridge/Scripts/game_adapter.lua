-- PAYDAY 3 bridge adapter. Call every exported method on the game thread.
-- Signatures were read from the installed build 25617818 CXXHeaderDump.
-- This module retains only scalar operation identities between callbacks.
local M = {}
local SLOT_NAMES = {"primary", "secondary", "tertiary"}
local PREFIXES = {"Primary", "Secondary", "Tertiary"}
local FIRE_INPUT = 6 -- Starbreeze_enums.hpp ESBZAbilityInput::Fire.
local UA_VERSION = "AgentBridge.UnmaskAgain.Version"
local UA_RESULT = "AgentBridge.UnmaskAgain.Result"

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function count(value) return finite(value) and value >= 0 and value % 1 == 0 end
local function valid(object)
    if object == nil or (type(object) ~= "userdata" and type(object) ~= "table") then return false end
    local ok, result = pcall(function()
        local method = object.IsValid
        return type(method) == "function" and method(object) == true
    end)
    return ok and result == true
end
local function member(object, field)
    if not valid(object) then return nil end
    local ok, value = pcall(function() return object[field] end)
    if ok then return value end
end
local function callable(object, method)
    if not valid(object) then return nil end
    local value = member(object, method)
    if type(value) == "function" or valid(value) then return value end
end
local function call(object, method, ...)
    local func = callable(object, method)
    if not func then return false, "Native method unavailable: " .. method end
    return pcall(func, object, ...)
end
local function struct_field(value, field)
    if type(value) == "table" then return value[field] end
    if type(value) ~= "userdata" then return nil end
    local ok, kind = pcall(function()
        local method = value.type
        return type(method) == "function" and method(value)
    end)
    -- Missing properties are null UObject userdata, not UScriptStructs.
    if not ok or kind ~= "UScriptStruct" or not valid(value) then return nil end
    local read_ok, result = pcall(function() return value[field] end)
    if read_ok then return result end
end
local function array(value)
    if type(value) == "table" then return value end
    if type(value) ~= "userdata" then return nil end
    local ok, kind = pcall(function()
        local method = value.type
        return type(method) == "function" and method(value)
    end)
    if not ok or kind ~= "TArray" then return nil end
    local result = {}
    local read_ok = pcall(function()
        local each = value.ForEach
        assert(type(each) == "function", "Native TArray.ForEach unavailable")
        each(value, function(index, wrapped)
            assert(index >= 1 and index <= 64, "Unexpected inventory array size")
            local get = wrapped and wrapped.get
            if type(get) == "function" then result[index] = get(wrapped)
            else result[index] = wrapped end
        end)
    end)
    if read_ok then return result end
end
local function object_name(object)
    local ok, result = call(object, "GetFullName")
    if ok and type(result) == "string" then return result:sub(1, 512) end
end
local function find(path)
    if type(StaticFindObject) ~= "function" then return nil end
    local ok, value = pcall(StaticFindObject, path)
    if ok and valid(value) then return value end
end
local function shared(key)
    if ModRef == nil then return nil end
    local ok, result = pcall(function()
        local method = ModRef.GetSharedVariable
        if type(method) ~= "function" then return nil end
        return method(ModRef, key)
    end)
    if ok then return result end
end
local function enum(value)
    if finite(value) then return value end
    if type(value) == "string" then return value:match("([^:]+)$") end
end
local function casing_count(asc)
    if FName == nil then return nil end
    -- UE4SS exposes this constructor as callable userdata, not a Lua function.
    local name_ok, name = pcall(function()
        local value = FName("Character.Action.IsCasing")
        local to_string = value.ToString
        if type(to_string) ~= "function" or to_string(value) ~= "Character.Action.IsCasing" then
            error("Casing tag name unavailable")
        end
        return value
    end)
    if not name_ok then return nil end
    local ok, result = call(asc, "GetGameplayTagCount", {TagName = name})
    if ok and count(result) then return result end
end
local function paused(pawn)
    local library = find("/Script/Engine.Default__GameplayStatics")
    local ok, result = call(library, "IsGamePaused", pawn)
    if ok and type(result) == "boolean" then return result end
end
local function identity(pawn)
    local ok, address = call(pawn, "GetAddress")
    local world_ok, world = call(pawn, "GetWorld")
    local name = object_name(pawn)
    local world_name = world_ok and object_name(world)
    if not ok or not finite(address) or not name or not world_name then return nil end
    return {pawn_address = address, pawn_name = name, world_name = world_name}
end
local function matches(operation, pawn)
    local current = identity(pawn)
    return current and current.pawn_address == operation.pawn_address
        and current.pawn_name == operation.pawn_name and current.world_name == operation.world_name
end
local function fire_data(pawn)
    local config = member(pawn, "CurrentEquippableConfig")
    local data = struct_field(config, "EquippableData")
    return member(data, "FireData")
end
local function fire_preflight(pawn)
    local data = fire_data(pawn)
    if not valid(data) then return false, "Current weapon FireData is unavailable" end
    local mode = enum(member(data, "FireMode"))
    if mode ~= 0 and mode ~= 2 and mode ~= "Single" and mode ~= "Auto" then
        return false, "FIRE_ONCE supports verified Single/Auto modes; burst or unknown mode refused"
    end
    local per_round = member(data, "AmmoPerFiredRound")
    if per_round ~= 1 then return false, "FIRE_ONCE requires verified one-ammo-per-round fire data" end
    local buildup = member(data, "StartFireMinBuildup")
    if not finite(buildup) or buildup > 0 then
        return false, "FIRE_ONCE refuses unknown or charged fire buildup"
    end
    local asc = member(pawn, "AbilitySystem")
    if not callable(asc, "PressInputID") or not callable(asc, "ReleaseInputID") then
        return false, "AbilitySystem PressInputID/ReleaseInputID is unavailable"
    end
    return true
end

function M.new(options)
    local null = assert(options and options.null, "Adapter requires the core JSON null sentinel")
    local adapter = {}
    local function attr(attributes, field)
        local value = struct_field(member(attributes, field), "CurrentValue")
        if finite(value) then return value end
    end
    local function stats_from(snapshot)
        return snapshot and snapshot.player and snapshot.player.stats or snapshot
    end
    function adapter.sample(controller, pawn)
        local out = {unknowns = {}, weapons = {}, throwables = {}, stored_consumables = {}, capabilities = {}}
        local function put(key, value, reason)
            if value ~= nil then out[key] = value
            else out[key], out.unknowns[key] = null, reason or "Native value unavailable" end
        end
        local state = member(pawn, "PlayerState")
        if not valid(state) then state = member(controller, "PlayerState") end
        local attributes = member(pawn, "PlayerAttributeSet")
        if not valid(attributes) then attributes = member(state, "AttributeSet") end
        for key, field in pairs({health = "Health", health_max = "HealthMax", armor = "Armor",
                armor_max = "ArmorMax", armor_chunks = "ArmorChunkCount", consumable_count = "ConsumableCount"}) do
            put(key, attr(attributes, field), "PlayerAttributeSet." .. field .. ".CurrentValue unavailable")
        end
        local casing_ok, casing = call(pawn, "IsCasing")
        put("masked", casing_ok and type(casing) == "boolean" and not casing or nil, "IsCasing unavailable")
        -- Lua's 'and/or' idiom cannot preserve false, so set it explicitly.
        if casing_ok and type(casing) == "boolean" then out.masked = not casing; out.unknowns.masked = nil end
        local asc = member(pawn, "AbilitySystem")
        put("casing_tag_count", casing_count(asc), "Casing gameplay tag count unavailable")
        local state_mask = member(state, "bIsMaskOn")
        put("player_state_mask_on", type(state_mask) == "boolean" and state_mask or nil)
        if type(state_mask) == "boolean" then out.player_state_mask_on = state_mask; out.unknowns.player_state_mask_on = nil end
        local mask = member(pawn, "EquippedMask")
        local mask_on = member(mask, "bIsMaskOn")
        put("mask_actor_on", type(mask_on) == "boolean" and mask_on or nil)
        if type(mask_on) == "boolean" then out.mask_actor_on = mask_on; out.unknowns.mask_actor_on = nil end
        put("equip_state", enum(member(pawn, "EquipState")))
        local is_paused = paused(pawn)
        put("paused", is_paused)
        local world_ok, world = call(pawn, "GetWorld")
        local game_state = world_ok and member(world, "GameState")
        put("heist_state", enum(member(game_state, "CurrentHeistState")))
        local current_index = member(pawn, "CurrentEquippableIndex")
        local current_slot = count(current_index) and SLOT_NAMES[current_index + 1] or nil
        put("current_weapon_slot", current_slot)
        local weapons = array(member(pawn, "EquippableArray"))
        local throwable_actors = array(member(pawn, "ReplicatedThrowableArray"))
        for index, slot in ipairs(SLOT_NAMES) do
            local prefix, weapon = PREFIXES[index], weapons and weapons[index]
            local magazine = attr(attributes, prefix .. "EquippableAmmoLoaded")
            local reserve = attr(attributes, prefix .. "EquippableAmmoInventory")
            if not count(magazine) then magazine = nil; out.unknowns[slot .. "_magazine"] = "AmmoLoaded CurrentValue unavailable" end
            if not count(reserve) then reserve = nil; out.unknowns[slot .. "_reserve"] = "AmmoInventory CurrentValue unavailable" end
            local actor_magazine, actor_reserve = member(weapon, "AmmoLoaded"), member(weapon, "AmmoInventory")
            out.weapons[slot] = {magazine = magazine or null, reserve = reserve or null,
                name = object_name(weapon) or null,
                actor_magazine = count(actor_magazine) and actor_magazine or null,
                actor_reserve = count(actor_reserve) and actor_reserve or null}
            local remaining = attr(attributes, prefix .. "ThrowableAmmoInventory")
            if not count(remaining) then remaining = nil end
            local throwable = throwable_actors and throwable_actors[index]
            out.throwables[slot] = {count = remaining or null, name = object_name(throwable) or null}
        end
        local throwable_index = member(pawn, "CurrentThrowableIndex")
        local throwable_slot = count(throwable_index) and SLOT_NAMES[throwable_index + 1] or nil
        local throwable_actor = throwable_slot and throwable_actors and throwable_actors[throwable_index + 1]
        local throwable_data = member(throwable_actor, "Data")
        local grenade_ok, is_grenade = call(throwable_data, "IsA", "/Script/Starbreeze.SBZGrenadeData")
        local selected = throwable_slot and out.throwables[throwable_slot].count
        if grenade_ok and is_grenade == true and selected ~= null then
            put("grenade_count", selected)
        else put("grenade_count", nil, "Selected throwable is not a verified grenade or its count is unavailable") end
        local stored = array(member(pawn, "StoredConsumableConfigArray"))
        local stored_count, health_count, classified = 0, 0, true
        if stored then
            for index, config in ipairs(stored) do
                stored_count = stored_count + 1
                local data = struct_field(config, "EquippableData")
                local name = object_name(data)
                local health_ok, is_health = call(data, "IsA", "/Script/Starbreeze.SBZPlaceableHealthData")
                local known_health = health_ok and is_health == true
                if known_health then health_count = health_count + 1 else classified = false end
                out.stored_consumables[tostring(index)] = {name = name or null, verified_health_data = known_health}
            end
        else classified = false end
        if out.consumable_count == 0 then put("health_packs", 0)
        elseif classified and stored_count == out.consumable_count then
            put("health_packs", health_count)
        else put("health_packs", nil, "ConsumableCount is generic; stored first-aid item identity is unverified") end
        out.capabilities.MASK_UP = shared(UA_VERSION) == "1" and casing_ok and type(casing) == "boolean"
        out.capabilities.UNMASK = out.capabilities.MASK_UP
        out.capabilities.FIRE_ONCE = fire_preflight(pawn) == true
        return out
    end
    function adapter.begin(command, controller, pawn, snapshot, protocol)
        if type(command) == "string" then command = protocol or {command = command} end
        if not valid(controller) or not valid(pawn) then return nil, "Local heist character unavailable" end
        local details = stats_from(snapshot)
        if not details then return nil, "Current diagnostics unavailable" end
        if details.paused ~= false then return nil, "Action requires a verified unpaused heist" end
        local operation = identity(pawn)
        if not operation then return nil, "Cannot establish a stable pawn/world identity" end
        operation.command, operation.started = command.command, os.time()
        if command.command == "MASK_UP" or command.command == "UNMASK" then
            operation.desired_masked = command.command == "MASK_UP"
            operation.expected_tags = operation.desired_masked and 0 or 1
            if type(details.masked) ~= "boolean" or not count(details.casing_tag_count) then
                return nil, "Mask/casing tag diagnostics unavailable"
            end
            if shared(UA_VERSION) ~= "1" then return nil, "UnmaskAgain bridge console endpoint unavailable" end
            if details.masked == operation.desired_masked and details.casing_tag_count == operation.expected_tags then
                operation.already_ready = true
                return operation
            end
            if command.command == "UNMASK" and details.heist_state ~= 0 and details.heist_state ~= 1
                and details.heist_state ~= "Stealth" and details.heist_state ~= "Search" then
                return nil, "Unmask requires verified Stealth/Search heist state"
            end
            if type(command.id) ~= "string" or not command.id:match("^[A-Za-z0-9_-]+$") or #command.id > 64 then
                return nil, "Invalid console request token"
            end
            operation.token = command.id
            local library = find("/Script/Engine.Default__KismetSystemLibrary")
            local desired = operation.desired_masked and "masked" or "unmasked"
            local ok, reason = call(library, "ExecuteConsoleCommand", pawn,
                "AgentBridge_UnmaskAgain " .. desired .. " " .. operation.token, controller)
            if not ok then return nil, "UnmaskAgain console request failed: " .. tostring(reason) end
            return operation
        elseif command.command == "FIRE_ONCE" then
            if details.masked ~= true or details.casing_tag_count ~= 0 then return nil, "Mask up before firing" end
            local supported, reason = fire_preflight(pawn)
            if not supported then return nil, reason end
            local slot = details.current_weapon_slot
            local weapon = type(slot) == "string" and details.weapons and details.weapons[slot]
            if not weapon or not count(weapon.magazine) or weapon.magazine < 1 then
                return nil, "Current weapon has no verified loaded ammunition"
            end
            local actor = member(pawn, "CurrentEquippable")
            local actor_name = object_name(actor)
            if not actor_name then return nil, "Current equippable identity unavailable" end
            local reloading = member(actor, "bIsReloading")
            if reloading ~= false then return nil, "Current weapon reload state is unavailable or active" end
            operation.slot, operation.magazine_before = slot, weapon.magazine
            operation.weapon_name, operation.pulse_count = actor_name, 1
            local asc = member(pawn, "AbilitySystem")
            operation.release_needed = true
            -- One immediate pulse, with release attempted even if press throws.
            -- No timers retain a pressed input or a UObject across callbacks.
            local pressed, press_reason = call(asc, "PressInputID", FIRE_INPUT)
            local released, release_reason = call(asc, "ReleaseInputID", FIRE_INPUT)
            operation.release_needed = not released
            if not released then
                -- Retry once synchronously before returning an uncertain action.
                released, release_reason = call(asc, "ReleaseInputID", FIRE_INPUT)
                operation.release_needed = not released
            end
            if not pressed or not released then
                operation.failure = "Fire pulse failed: press=" .. tostring(pressed) .. " release=" .. tostring(released)
                    .. " " .. tostring(press_reason or release_reason)
                return operation
            end
            return operation
        end
        return nil, "Unsupported gameplay action"
    end
    function adapter.poll(operation, controller, pawn, snapshot)
        if not valid(pawn) or not matches(operation, pawn) then
            return true, nil, "Pawn/world changed during command; result is inconclusive"
        end
        local details = stats_from(snapshot)
        if not details then return true, nil, "Current diagnostics unavailable" end
        if operation.failure then return true, nil, operation.failure end
        if operation.command == "MASK_UP" or operation.command == "UNMASK" then
            local completed, nonce = operation.already_ready, "already_ready"
            if not completed then
                local value = shared(UA_RESULT)
                if type(value) == "string" then
                    local token, status, text = value:match("^([^|]+)|([^|]+)|(.*)$")
                    if token == operation.token then
                        if status == "error" then return true, nil, "UnmaskAgain: " .. text end
                        completed, nonce = status == "completed", text
                    end
                end
            end
            if completed and details.masked == operation.desired_masked
                and details.casing_tag_count == operation.expected_tags then
                return true, {masked = details.masked, casing_tag_count = details.casing_tag_count,
                    unmaskagain_confirmation = nonce, already_ready = operation.already_ready == true}
            end
            return false
        elseif operation.command == "FIRE_ONCE" then
            if operation.release_needed then return true, nil, "Fire input release was not confirmed" end
            if details.current_weapon_slot ~= operation.slot
                or object_name(member(pawn, "CurrentEquippable")) ~= operation.weapon_name then
                return true, nil, "Weapon changed before shot confirmation"
            end
            local weapon = details.weapons and details.weapons[operation.slot]
            if not weapon or not count(weapon.magazine) then return true, nil, "Ammo confirmation unavailable" end
            local used = operation.magazine_before - weapon.magazine
            if used == 1 then return true, {input_pulses = 1, ammo_consumed = 1,
                magazine_before = operation.magazine_before, magazine_after = weapon.magazine,
                slot = operation.slot, input_released = true} end
            if used > 1 then return true, nil, "Unexpected multiple-round consumption: " .. tostring(used) end
            if used < 0 then return true, nil, "Ammo increased during shot confirmation" end
            return false
        end
        return true, nil, "Unknown pending gameplay command"
    end
    function adapter.cleanup(operation, controller, pawn, reason)
        if not operation or not operation.release_needed then return true end
        -- DISABLE may deliberately pass no native context. Reacquire locally;
        -- never send release to a replacement pawn or another player's ASC.
        if not valid(pawn) and type(FindAllOf) == "function" then
            local ok, values = pcall(FindAllOf, "PlayerController")
            if ok and type(values) == "table" then
                for _, pc in pairs(values) do
                    local local_ok, is_local = call(pc, "IsLocalPlayerController")
                    local candidate = member(pc, "Pawn")
                    if local_ok and is_local == true and valid(candidate) and matches(operation, candidate) then
                        controller, pawn = pc, candidate
                        break
                    end
                end
            end
        end
        if not valid(pawn) or not matches(operation, pawn) then
            return false, "Release cleanup skipped because the original pawn/world is unavailable"
        end
        local ok, message = call(member(pawn, "AbilitySystem"), "ReleaseInputID", FIRE_INPUT)
        operation.release_needed = not ok
        return ok, ok and nil or tostring(message)
    end
    return adapter
end

return M
