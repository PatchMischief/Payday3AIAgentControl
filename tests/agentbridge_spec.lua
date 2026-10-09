-- Runtime doubles for executing the shipped AgentBridge in a real Lua 5.4 VM.
-- File IO is real; native methods enforce the mocked game-thread boundary.
local h = {
    queue = {}, loops = {}, logs = {}, world = "menu", pawn_kind = "valid",
    native_calls = 0, cross_thread_calls = 0, invalid_member_calls = 0,
    thread = "load", position = {X = 125, Y = -250, Z = 350},
    pawn_name = "BP_Player_C /Game/Maps/Test.Test:PersistentLevel.Player_0",
    unbounded_command_reads = 0, largest_command_read = 0,
    write_opens = 0, native_writes = 0,
}

local original_open = io.open
io.open = function(path, mode)
    local file, message = original_open(path, mode)
    if file and mode and mode:match("^[wa]") then h.write_opens = h.write_opens + 1 end
    if not file or not tostring(path):match("[/\\]command%.json$")
        or (mode ~= "r" and mode ~= "rb") then return file, message end
    return {
        read = function(_, format)
            if type(format) ~= "number" then
                h.unbounded_command_reads = h.unbounded_command_reads + 1
            else
                h.largest_command_read = math.max(h.largest_command_read, format)
            end
            return file:read(format)
        end,
        close = function() return file:close() end,
    }
end

local function native(fn)
    return function(...)
        h.native_calls = h.native_calls + 1
        if h.thread ~= "game" then
            h.cross_thread_calls = h.cross_thread_calls + 1
            error("Native call outside the game thread")
        end
        return fn(...)
    end
end

-- UE4SS's invalid native UObject is userdata, not Lua nil. Unknown members
-- chain to another null object and may be callable, unlike ordinary tables.
local null = assert(io.tmpfile())
local original_null_metatable = debug.getmetatable(null)
debug.setmetatable(null, {
    __index = function(_, field)
        if field == "IsValid" then return native(function() return false end) end
        return null
    end,
    __call = native(function()
        h.invalid_member_calls = h.invalid_member_calls + 1
        error("Attempted to call a member of a null UObject")
    end),
})

local pawn = {
    IsValid = native(function() return h.pawn_kind ~= "invalid" end),
    GetFullName = native(function() return h.pawn_name end),
    GetName = native(function() return h.pawn_name end),
    K2_GetActorLocation = native(function()
        if h.pawn_kind == "error" then error("Pawn was destroyed during the sample") end
        return h.position
    end),
}
setmetatable(pawn, {
    __index = native(function() return null end),
    __newindex = native(function(object, field, value)
        h.native_writes = h.native_writes + 1
        rawset(object, field, value)
    end),
})
h.pawn, h.null, h.native = pawn, null, native
local object_fields, next_address = setmetatable({}, {__mode = "k"}), 100
function h.object(fields, name)
    next_address = next_address + 1
    local address = next_address
    fields = fields or {}
    fields.IsValid = fields.IsValid or native(function() return fields.invalid ~= true end)
    fields.GetAddress = fields.GetAddress or native(function() return address end)
    fields.GetFullName = fields.GetFullName or native(function() return name or "Test_Object" end)
    local object = setmetatable({}, {
        __index = native(function(_, field)
            if fields[field] ~= nil then return fields[field] end
            return null
        end),
        __newindex = native(function(_, field, value)
            h.native_writes = h.native_writes + 1
            fields[field] = value
        end),
    })
    object_fields[object] = fields
    return object
end
function h.set(object, field, value)
    -- Fixture setup changes backing values without masquerading as engine IO.
    local fields = object_fields[object]
    if fields then fields[field] = value else rawset(object, field, value) end
end
rawset(pawn, "GetAddress", native(function() return 1 end))
local function current_pawn()
    if h.world ~= "heist" or h.pawn_kind == "missing" then return nil end
    if h.pawn_kind == "null" then return null end
    return h.pawn
end
local controller = setmetatable({
    IsValid = native(function() return h.world ~= "invalid_controller" end),
    IsLocalPlayerController = native(function() return h.world ~= "remote" end),
    IsA = native(function(_, class_name)
        assert(class_name == "/Script/Starbreeze.SBZPlayerControllerMainMenu")
        return h.world == "menu"
    end),
    GetPawn = native(function() return current_pawn() end),
}, {
    __index = function(_, field)
        if field == "Pawn" then return native(current_pawn)() end
        return null
    end,
})
h.controller = controller

_G.FindAllOf = native(function(class_name)
    assert(class_name == "PlayerController", "Unexpected engine class lookup: " .. tostring(class_name))
    if h.world == "transition" then return {} end
    return {controller}
end)
local function make_fname(name)
    return {ToString = native(function() return name end)}
end
_G.FName = native(make_fname)
h.static_objects = {}
_G.StaticFindObject = native(function(path) return h.static_objects[path] or null end)
_G.LoopAsync = function(interval, callback)
    assert(type(interval) == "number" and type(callback) == "function")
    h.loops[#h.loops + 1] = {interval = interval, callback = callback, cancelled = false}
end
_G.ExecuteInGameThread = function(callback)
    assert(type(callback) == "function")
    if h.enqueue_failure then error("Scheduler temporarily unavailable") end
    h.queue[#h.queue + 1] = callback
end
_G.print = function(message) h.logs[#h.logs + 1] = tostring(message) end

function h.tick(count)
    for _ = 1, count or 1 do
        h.thread = "async"
        -- UE4SS cancels when a loop returns true; loops registered inside a
        -- callback begin on a later tick, rather than in this same iteration.
        local snapshot = {}
        for _, loop in ipairs(h.loops) do snapshot[#snapshot + 1] = loop end
        for _, loop in ipairs(snapshot) do
            if not loop.cancelled and loop.callback() == true then loop.cancelled = true end
        end
        h.thread = "test"
    end
end
function h.active_loop_count(interval)
    local count = 0
    for _, loop in ipairs(h.loops) do
        if not loop.cancelled and (interval == nil or loop.interval == interval) then count = count + 1 end
    end
    return count
end
function h.run_next()
    local callback = table.remove(h.queue, 1)
    if callback then
        h.thread = "game"
        callback()
        h.thread = "test"
        return true
    end
    return false
end
function h.drain()
    local count = 0
    while h.run_next() do
        count = count + 1
        assert(count <= 10, "Unbounded game-thread rescheduling")
    end
end
function h.configure_character()
    h.world, h.masked, h.casing_tags, h.paused = "heist", true, 0, false
    h.fire_presses, h.fire_releases, h.fire_delta = 0, 0, 1
    h.release_failures, h.fire_pressed, h.console_calls = 0, false, 0
    local attributes = {}
    for key, value in pairs({Health = 85, HealthMax = 100, Armor = 75, ArmorMax = 100,
        ArmorChunkCount = 3, ConsumableCount = 1, PrimaryEquippableAmmoLoaded = 30,
        PrimaryEquippableAmmoInventory = 90, SecondaryEquippableAmmoLoaded = 12,
        SecondaryEquippableAmmoInventory = 36, TertiaryEquippableAmmoLoaded = 0,
        TertiaryEquippableAmmoInventory = 0, PrimaryThrowableAmmoInventory = 3,
        SecondaryThrowableAmmoInventory = 0, TertiaryThrowableAmmoInventory = 0}) do
        attributes[key] = {CurrentValue = value}
    end
    h.attributes = attributes
    h.weapon = h.object({AmmoLoaded = 30, AmmoInventory = 90, bIsReloading = false}, "Rifle_0")
    h.fire_data = h.object({FireMode = 0, AmmoPerFiredRound = 1, StartFireMinBuildup = 0})
    h.game_world = h.object({GameState = h.object({CurrentHeistState = 0})}, "Heist_World_0")
    h.asc = h.object({
        GetGameplayTagCount = native(function(_, tag)
            assert(tag.TagName:ToString() == "Character.Action.IsCasing")
            return h.casing_tags
        end),
        PressInputID = native(function(_, id)
            assert(id == 6)
            h.fire_presses, h.fire_pressed = h.fire_presses + 1, true
            if h.press_error then error("Press failed after activation") end
            attributes.PrimaryEquippableAmmoLoaded.CurrentValue =
                attributes.PrimaryEquippableAmmoLoaded.CurrentValue - h.fire_delta
            h.set(h.weapon, "AmmoLoaded", attributes.PrimaryEquippableAmmoLoaded.CurrentValue)
        end),
        ReleaseInputID = native(function(_, id)
            assert(id == 6)
            h.fire_releases = h.fire_releases + 1
            if h.release_failures > 0 then
                h.release_failures = h.release_failures - 1
                error("Release temporarily failed")
            end
            h.fire_pressed = false
        end),
    })
    h.set(h.pawn, "PlayerAttributeSet", h.object(attributes))
    h.set(h.pawn, "GetWorld", native(function() return h.game_world end))
    h.set(h.pawn, "IsCasing", native(function() return not h.masked end))
    h.set(h.pawn, "AbilitySystem", h.asc)
    h.set(h.pawn, "EquipState", 2)
    h.set(h.pawn, "CurrentEquippableIndex", 0)
    h.set(h.pawn, "CurrentEquippable", h.weapon)
    h.set(h.pawn, "CurrentEquippableConfig", {EquippableData = h.object({FireData = h.fire_data})})
    h.set(h.pawn, "EquippableArray", {h.weapon,
        h.object({AmmoLoaded = 12, AmmoInventory = 36}, "Pistol_0"),
        h.object({AmmoLoaded = 0, AmmoInventory = 0}, "Empty_0")})
    h.set(h.pawn, "CurrentThrowableIndex", 0)
    h.set(h.pawn, "ReplicatedThrowableArray", {h.object({Data = h.object({
        IsA = native(function(_, class) return class == "/Script/Starbreeze.SBZGrenadeData" end),
    })})})
    h.set(h.pawn, "StoredConsumableConfigArray", {{EquippableData = h.object({
        IsA = native(function(_, class) return class == "/Script/Starbreeze.SBZPlaceableHealthData" end),
    }, "FirstAid_0")}})
    h.static_objects["/Script/Engine.Default__GameplayStatics"] = h.object({
        IsGamePaused = native(function() return h.paused end),
    })
    h.shared = {["AgentBridge.UnmaskAgain.Version"] = "1"}
    _G.ModRef = {GetSharedVariable = function(_, key) return h.shared[key] end}
    h.static_objects["/Script/Engine.Default__KismetSystemLibrary"] = h.object({
        ExecuteConsoleCommand = native(function(_, context, command, pc)
            assert(context == h.pawn and pc == h.controller)
            local desired, token = command:match("^AgentBridge_UnmaskAgain (%a+) ([A-Za-z0-9_-]+)$")
            assert(desired and token)
            h.console_calls = h.console_calls + 1
            h.console_desired, h.console_token = desired, token
        end),
    })
end
function h.replace_character()
    local fields = {}
    for key, value in pairs(h.pawn) do if key ~= "GetAddress" then fields[key] = value end end
    h.wrong_pawn_actions = 0
    fields.AbilitySystem = h.object({
        PressInputID = native(function() h.wrong_pawn_actions = h.wrong_pawn_actions + 1 end),
        ReleaseInputID = native(function() h.wrong_pawn_actions = h.wrong_pawn_actions + 1 end),
    })
    h.pawn_name = "Replacement_Player_1"
    h.pawn = h.object(fields, h.pawn_name)
end
function h.use_callable_fname()
    -- UE4SS exposes FName as a callable userdata, not a Lua function.
    local value = assert(io.tmpfile())
    h.fname_handle, h.fname_metatable = value, debug.getmetatable(value)
    debug.setmetatable(value, {__call = native(function(_, name) return make_fname(name) end)})
    _G.FName = value
end
function h.close()
    if h.closed then return end
    h.closed = true
    io.open = original_open
    if h.fname_handle then
        debug.setmetatable(h.fname_handle, h.fname_metatable)
        h.fname_handle:close()
    end
    debug.setmetatable(null, original_null_metatable)
    null:close()
end
return h
