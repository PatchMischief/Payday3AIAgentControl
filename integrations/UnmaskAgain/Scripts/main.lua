-- UnmaskAgain 0.5.4-network-diagnostics, Steam build 25617818 / PD3 3.9.2.
-- F4 requests a per-player transition through chat; F10 reports real state.
local PREFIX = "[UnmaskAgain] "
local CHAT_CLASS = "SBZChatInGame"
local CHAT_HOOK = "/Script/Starbreeze.SBZChatInGame:ServerChatMessageReceived"
local CHAT_EVENT = "/Script/Starbreeze.SBZChatInGame:MulticastChatMessageReceived"
local MASK_HOOK = "/Script/Starbreeze.SBZAbilitySystemComponent:Multicast_MaskOn"
local LIBRARY = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary"
local TAG_LIBRARY = "/Script/GameplayTags.Default__BlueprintGameplayTagLibrary"
local HOLDER_CLASS = "/Script/GameplayTags.EditableGameplayTagQueryExpression_AnyTagsMatch"
local managed, client_managed, seen = {}, {}, {}
local hook_ids, hooks_ready = {}, false
local request, sequence = nil, 0
local key_pending, key_locked = false, false
local diagnostics_pending = false
local input_stats = {received = 0, queued = 0, started = 0, suppressed = 0, diagnostics = 0}
local chat_stats = {server = 0, multicast = 0, ignored_host = 0}
local bridge_endpoint
local function bridge_result(active, status, detail)
    if bridge_endpoint and active and active.bridge_token then
        bridge_endpoint.report(active.bridge_token, status, detail)
    end
end

local function log(message) print(PREFIX .. tostring(message) .. "\n") end
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end
local function read(object, field)
    local ok, result = pcall(function() return object[field] end)
    if ok then return result end
end
local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end
local function unbox(param)
    local ok, result = pcall(function() return param:get() end)
    return ok and result or param
end
local function text(value)
    if type(value) == "string" then return value end
    local ok, result = pcall(function() return value:ToString() end)
    if ok and type(result) == "string" then return result end
end
local function controllers() return FindAllOf("PlayerController") or {} end
local function local_controller()
    for _, pc in ipairs(controllers()) do
        if valid(pc) then
            local ok, is_local = pcall(function() return pc:IsLocalPlayerController() end)
            if ok and is_local == true and valid(read(pc, "Pawn")) then return pc end
        end
    end
end
local function heist_state(pawn)
    local state = read(read(pawn:GetWorld(), "GameState"), "CurrentHeistState")
    if type(state) == "string" then return state:match("([^:]+)$") end
    local enum = StaticFindObject("/Script/Starbreeze.EPD3HeistState")
    if state == nil or not valid(enum) then return nil end
    return enum:GetNameByValue(state):ToString():match("([^:]+)$")
end
local function tag()
    local name = FName("Character.Action.IsCasing")
    if name:ToString() ~= "Character.Action.IsCasing" then error("Casing tag name unavailable.") end
    return {TagName = name}
end
local function tag_container(pawn)
    -- Exact UE4SS revision 0290beda returns function-result structs as Lua
    -- tables, but nested TArray Set reads stack index 1 (the outer table).
    -- A native holder plus DIRECT array-property assignment bypasses that
    -- path. Never alter a class default or another gameplay object's tags.
    local cls, tags = StaticFindObject(HOLDER_CLASS), StaticFindObject(TAG_LIBRARY)
    if not valid(cls) or not valid(tags) then error("Native tag storage class/library unavailable.") end
    local holder = StaticConstructObject(cls, pawn)
    if not valid(holder) then error("Native tag storage construction failed.") end
    local container = holder.Tags
    container.GameplayTags = {tag()}
    local array_count = container.GameplayTags:GetArrayNum()
    local count = tags:GetNumGameplayTagsInContainer(container)
    local contains = tags:HasTag(container, tag(), true)
    if array_count ~= 1 or count ~= 1 or contains ~= true then
        error("Native tag storage preflight failed: array=" .. tostring(array_count) ..
            " count=" .. tostring(count) .. " contains=" .. tostring(contains) .. "; no casing write attempted.")
    end
    -- Keep the carrier in caller scope until the synchronous native call ends.
    return container, holder
end
local function library()
    local lib = StaticFindObject(LIBRARY)
    if not valid(lib) then error("Ability library unavailable.") end
    for _, method in ipairs({"AddLooseGameplayTags", "RemoveLooseGameplayTags"}) do
        if not valid(StaticFindObject("/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:" .. method)) then
            error("Tag function unavailable: " .. method)
        end
    end
    return lib
end
local function chat_for(pc)
    local world, found = pc.Pawn:GetWorld(), nil
    for _, chat in ipairs(FindAllOf(CHAT_CLASS) or {}) do
        if valid(chat) and same(chat:GetWorld(), world) then
            if found and not same(found, chat) then return nil end
            found = chat
        end
    end
    return found
end
local function player_name(state)
    for _, method in ipairs({"GetAccelBytePlayerName", "GetPlayerName", "GetPlayerDisplayName"}) do
        local ok, value = pcall(function() return state[method](state) end)
        local name = ok and text(value)
        if name and name ~= "" then return name:gsub("[%c%[%]]", " ") end
    end
    return "Player " .. tostring(read(state, "PlayerId"))
end
local function message(state, action, phase, nonce)
    return player_name(state) .. " " .. action .. " [UA5 " .. phase .. " " .. nonce .. "]"
end
local function parse(value)
    if type(value) ~= "string" then return nil end
    local name, action, phase, nonce = value:match("^(.-) ([a-z]+) %[UA5 ([a-z]+) (%d+%-%d+)%]$")
    if not name or (action ~= "masked" and action ~= "unmasked") or
        (phase ~= "request" and phase ~= "apply" and phase ~= "ack") then return nil end
    return {action = action, phase = phase, nonce = nonce}
end
local function ready(pawn, action)
    local casing = pawn:IsCasing()
    local asc = read(pawn, "AbilitySystem")
    if not valid(asc) then return false end
    local count = asc:GetGameplayTagCount(tag())
    -- Both supplied logs confirm real casing after the applied event. The
    -- mask/equip fields were never established as confirmation prerequisites;
    -- requiring them caused successful transitions to time out and remask.
    if action == "unmasked" then
        return casing == true and count == 1
    end
    return casing == false and count == 0
end
local function presentation_snapshot(pawn)
    if not valid(pawn) then return "Pawn unavailable" end
    local mask, state = read(pawn, "EquippedMask"), read(pawn, "PlayerState")
    local asc = read(pawn, "AbilitySystem")
    return "IsCasing=" .. tostring(pawn:IsCasing()) ..
        " Count=" .. tostring(valid(asc) and asc:GetGameplayTagCount(tag()) or "unavailable") ..
        " PlayerStateMask=" .. tostring(read(state, "bIsMaskOn")) ..
        " MaskActor=" .. tostring(read(mask, "bIsMaskOn")) ..
        " EquipState=" .. tostring(read(pawn, "EquipState"))
end
local function cleanup(record, reason)
    if not valid(record.asc) then return false end
    local address = record.asc:GetAddress()
    if managed[address] ~= record or record.cleaning then return false end
    record.cleaning = true
    local ok, err = pcall(function()
        if not valid(record.pawn) then return end
        local count = record.asc:GetGameplayTagCount(tag())
        if count ~= 0 and count ~= 1 then error("Conflicting casing count: " .. tostring(count)) end
        local container, holder = tag_container(record.pawn)
        if library():RemoveLooseGameplayTags(record.pawn, container, true) ~= true then
            error("Replicated tag removal refused.")
        end
        record.pawn:ForceNetUpdate()
        if not valid(holder) then error("Tag storage lost during native call.") end
    end)
    if ok then managed[address] = nil; log("Replicated casing cleared: " .. reason)
    else record.cleaning = false; log("Casing cleanup failed: " .. tostring(err)) end
    return ok
end
local function announce(chat, state, action, nonce)
    -- This is the game's reliable server multicast, not a new Lua-only event.
    if chat:HasAuthority() ~= true then error("Only host can publish an applied transition.") end
    chat:MulticastChatMessageReceived(state.PlayerId, {
        PlayerState = state, Message = message(state, action, "apply", nonce)
    })
    log("Host published applied " .. action .. " event; PlayerId=" .. tostring(state.PlayerId) .. " nonce=" .. nonce)
end
local function apply_host(chat, pawn, state, packet)
    if pawn:HasAuthority() ~= true then error("Host authority required.") end
    local asc = read(pawn, "AbilitySystem")
    if not valid(asc) then error("Character AbilitySystem unavailable.") end
    local address, record = asc:GetAddress(), managed[asc:GetAddress()]
    if packet.action == "masked" then
        asc:Server_MaskOn()
        if record and not cleanup(record, "F4 mask-up") then error("Mask-up tag cleanup failed.") end
        if pawn:IsCasing() ~= false then error("Native mask-up did not clear casing.") end
        announce(chat, state, "masked", packet.nonce)
        return
    end
    local heist = heist_state(pawn)
    if heist ~= "Stealth" and heist ~= "Search" then error("Unmask refused: heist state is " .. tostring(heist)) end
    if pawn:IsCasing() == true or asc:GetGameplayTagCount(tag()) ~= 0 or record then
        error("Already casing or previous transition still managed.")
    end
    local lib = library()
    local container, holder = tag_container(pawn)
    record = {pawn = pawn, asc = asc, state = state, chat = chat, nonce = packet.nonce, confirmed = false}
    managed[address] = record
    local ok, err = pcall(function()
        if lib:AddLooseGameplayTags(pawn, container, true) ~= true then error("Replicated tag addition refused.") end
        if pawn:IsCasing() ~= true or asc:GetGameplayTagCount(tag()) ~= 1 then error("Authoritative casing transition failed.") end
        pawn:ForceNetUpdate()
        if not valid(holder) then error("Tag storage lost during native call.") end
    end)
    if not ok then cleanup(record, "failed transition"); error(err) end
    -- Arm rollback before publishing; a failed send must not strand the pawn.
    ExecuteWithDelay(6500, function()
        ExecuteInGameThread(function()
            if managed[address] ~= record or record.confirmed then return end
            log("No client casing confirmation for " .. record.nonce .. "; restoring masking. " .. presentation_snapshot(pawn))
            local restored, restore_error = pcall(function()
                if not valid(pawn) or not valid(asc) then return end
                asc:Server_MaskOn()
                if not cleanup(record, "confirmation timeout") then error("Confirmation timeout tag cleanup failed.") end
                if valid(chat) and valid(state) and pawn:IsCasing() == false then
                    announce(chat, state, "masked", record.nonce)
                end
            end)
            if not restored then log("Native mask restore failed: " .. tostring(restore_error)) end
        end)
    end)
    announce(chat, state, "unmasked", packet.nonce)
end
local function ignored_host(packet, id, reason)
    chat_stats.ignored_host = chat_stats.ignored_host + 1
    log("Host packet ignored: " .. reason .. "; PlayerId=" .. tostring(id) .. " nonce=" .. packet.nonce)
end
local function host_event(chat, id, event, packet)
    if packet.phase ~= "request" and packet.phase ~= "ack" then return end
    local pc = local_controller()
    if not pc then ignored_host(packet, id, "no active local controller"); return end
    if pc.Pawn:HasAuthority() ~= true then ignored_host(packet, id, "local pawn lacks authority"); return end
    if not valid(chat) then ignored_host(packet, id, "chat unavailable"); return end
    if chat:HasAuthority() ~= true then ignored_host(packet, id, "chat lacks authority"); return end
    if not same(chat, chat_for(pc)) then
        ignored_host(packet, id, "chat does not match selected heist chat"); return
    end
    local state = event.PlayerState
    if not valid(state) or type(id) ~= "number" or read(state, "PlayerId") ~= id then
        log("Chat request refused: sender PlayerState/PlayerId mismatch.")
        ignored_host(packet, id, "sender PlayerState/PlayerId mismatch"); return
    end
    local sender
    for _, candidate in ipairs(controllers()) do
        if valid(candidate) and same(read(candidate, "PlayerState"), state) then sender = candidate; break end
    end
    if not sender then ignored_host(packet, id, "sender controller unavailable"); return end
    if sender:HasAuthority() ~= true then ignored_host(packet, id, "sender controller lacks authority"); return end
    local pawn = read(sender, "Pawn")
    if not valid(pawn) then ignored_host(packet, id, "sender pawn unavailable"); return end
    if not same(pawn:GetWorld(), pc.Pawn:GetWorld()) then
        ignored_host(packet, id, "sender pawn belongs to another world"); return
    end
    local asc = read(pawn, "AbilitySystem")
    if packet.phase == "ack" then
        local record = valid(asc) and managed[asc:GetAddress()]
        if packet.action == "unmasked" and record and record.nonce == packet.nonce and
            same(record.state, state) and same(record.pawn, pawn) and ready(pawn, "unmasked") then
            record.confirmed = true
            log("Client casing state confirmed; PlayerId=" .. tostring(id) .. " nonce=" .. packet.nonce)
        end
        return
    end
    local dedupe = tostring(chat:GetAddress()) .. ":" .. tostring(id) .. ":" .. packet.nonce
    if seen[dedupe] then ignored_host(packet, id, "duplicate request"); return end
    seen[dedupe] = true
    log("Host received " .. packet.action .. " request; PlayerId=" .. tostring(id) .. " nonce=" .. packet.nonce)
    local ok, err = pcall(function() apply_host(chat, pawn, state, packet) end)
    if not ok then log("Host request failed: " .. tostring(err)) end
end
local function applied_event(chat, id, event, packet)
    if packet.phase ~= "apply" then return end
    local pc = local_controller()
    if not pc or not same(chat, chat_for(pc)) then return end
    local pawn, state = pc.Pawn, pc.PlayerState
    if not same(event.PlayerState, state) or read(state, "PlayerId") ~= id then return end
    local asc = read(pawn, "AbilitySystem")
    if not valid(asc) then return end
    local record = client_managed[asc:GetAddress()]
    local active = request
    local matches = active and same(active.pawn, pawn) and active.nonce == packet.nonce and
        active.id == id and same(active.state, state)
    local rollback = packet.action == "masked" and record and record.nonce == packet.nonce
    if not matches and not rollback then return end
    if packet.action == "unmasked" and (not matches or active.action ~= "unmasked") then return end
    if packet.action == "masked" and matches and active.action == "unmasked" then
        log("Host reverted request " .. packet.nonce .. " to masking.")
        request = nil
        bridge_result(active, "error", "Host reverted the request to masking")
    end
    if pawn:HasAuthority() ~= true then
        local count = asc:GetGameplayTagCount(tag())
        if count ~= 0 and count ~= 1 then error("Conflicting client casing count: " .. tostring(count)) end
        if packet.action == "unmasked" then
            local heist = heist_state(pawn)
            if heist ~= "Stealth" and heist ~= "Search" then return end
            if count == 0 then
                local container, holder = tag_container(pawn)
                if library():AddLooseGameplayTags(pawn, container, false) ~= true then error("Local casing transition refused.") end
                if not valid(holder) then error("Local tag storage lost.") end
            end
            client_managed[asc:GetAddress()] = {pawn = pawn, asc = asc, nonce = packet.nonce}
        else
            if count == 1 then
                local container, holder = tag_container(pawn)
                if library():RemoveLooseGameplayTags(pawn, container, false) ~= true then error("Local mask restore refused.") end
                if not valid(holder) then error("Local tag storage lost.") end
            end
            client_managed[asc:GetAddress()] = nil
        end
    end
    if matches and request == active and active.action == packet.action then active.applied = true end
    log("Applied chat event read locally: " .. packet.action .. " nonce=" .. packet.nonce ..
        " IsCasing=" .. tostring(pawn:IsCasing()))
end
local function register_chat(path, handler, post)
    local function callback(context, id_param, data_param)
        local ok, chat, id, event = pcall(function()
            local input = unbox(data_param)
            -- Snapshot RPC parameters now; native parameter storage is temporary.
            return unbox(context), unbox(id_param), {
                PlayerState = read(input, "PlayerState"), Message = text(read(input, "Message"))
            }
        end)
        if not ok then log("Chat event parameter read failed."); return end
        local packet = parse(event.Message)
        if not packet then return end
        -- Record delivery before session/authority filters. Do not log ordinary
        -- chat contents; a returned send call alone does not prove delivery.
        local route = path == CHAT_HOOK and "server" or "multicast"
        chat_stats[route] = chat_stats[route] + 1
        log("Chat packet observed: " .. route .. " phase=" .. packet.phase ..
            " PlayerId=" .. tostring(id) .. " nonce=" .. packet.nonce)
        ExecuteInGameThread(function()
            local action_ok, err = pcall(function() handler(chat, id, event, packet) end)
            if not action_ok then log("Chat event processing failed: " .. tostring(err)) end
        end)
    end
    local pre_id, post_id
    if post then pre_id, post_id = RegisterHook(path, function() end, callback)
    else pre_id, post_id = RegisterHook(path, callback) end
    table.insert(hook_ids, {pre_id, post_id})
    log("Event hook registered: " .. path)
end
local function ensure_hooks()
    if hooks_ready then return true end
    -- Do not install duplicate partial hooks after an unsuccessful attempt.
    if #hook_ids > 0 then return false end
    local ok, err = pcall(function()
        register_chat(CHAT_HOOK, host_event, false)
        register_chat(CHAT_EVENT, applied_event, true)
        local pre_id, post_id = RegisterHook(MASK_HOOK, function() end, function(context)
            local asc = unbox(context)
            if not valid(asc) then return end
            -- Capture the transition that this native event actually ended.
            -- A later F4 can create a new record before queued work runs.
            local address = asc:GetAddress()
            local record, local_record = managed[address], client_managed[address]
            local active = request
            ExecuteInGameThread(function()
                if record then cleanup(record, "native mask-up") end
                if local_record and client_managed[address] == local_record then
                    client_managed[address] = nil
                    log("Local casing tracking cleared by native mask-up.")
                end
                local ended = local_record or record
                if ended and active and request == active and active.action == "unmasked" and
                    active.nonce == ended.nonce and same(active.pawn, ended.pawn) then
                    request = nil
                    log("Pending unmask request ended by native mask-up.")
                    bridge_result(active, "error", "Unmask request interrupted by native mask-up")
                end
            end)
        end)
        table.insert(hook_ids, {pre_id, post_id})
    end)
    if not ok then log("Required hooks unavailable: " .. tostring(err)); return false end
    hooks_ready = true
    return true
end
local function poll(active, remaining)
    ExecuteWithDelay(200, function()
        ExecuteInGameThread(function()
            if request ~= active then return end
            -- The controller was resolved once when F4 was pressed. Recheck
            -- its live identity without scanning all game objects every 200ms.
            local pc = active.pc
            if not valid(pc) or not same(read(pc, "Pawn"), active.pawn) or
                not same(read(pc, "PlayerState"), active.state) then
                request = nil
                bridge_result(active, "error", "Player identity changed during request")
                return
            end
            local ok, err = pcall(function()
                if active.applied and ready(active.pawn, active.action) then
                    active.chat:SendChatMessageToServer({PlayerState = active.state,
                        Message = message(active.state, active.action, "ack", active.nonce)})
                    request = nil
                    log("Local " .. active.action .. " casing state confirmed; nonce=" .. active.nonce)
                    log("Presentation snapshot: " .. presentation_snapshot(active.pawn))
                    bridge_result(active, "completed", active.nonce)
                    return
                end
                if remaining > 1 then poll(active, remaining - 1)
                else
                    request = nil
                    log("Request timed out without an applied event and matching local casing state; nonce=" .. active.nonce ..
                        " Applied=" .. tostring(active.applied) .. " " .. presentation_snapshot(active.pawn) ..
                        ". Host will restore masking if unconfirmed. Press F10 on both PCs.")
                    bridge_result(active, "error", "Request timed out: applied=" .. tostring(active.applied) .. " " .. presentation_snapshot(active.pawn))
                end
            end)
            if not ok then
                request = nil; log("State confirmation failed: " .. tostring(err))
                bridge_result(active, "error", "State confirmation failed: " .. tostring(err))
            end
        end)
    end)
end
local function toggle(desired_action, bridge_token)
    if not ensure_hooks() then log("No transition attempted because required hooks are unavailable."); return false, "Required hooks unavailable" end
    if request then log("Previous F4 request is still pending."); return false, "Previous request is still pending" end
    local pc = local_controller()
    if not pc then log("No active heist character."); return false, "No active heist character" end
    local pawn, state = pc.Pawn, pc.PlayerState
    if not valid(state) then log("PlayerState unavailable."); return false, "PlayerState unavailable" end
    local action = desired_action or (pawn:IsCasing() == true and "masked" or "unmasked")
    if desired_action and ready(pawn, action) then return true, "completed", "already_ready" end
    if action == "unmasked" then
        local heist = heist_state(pawn)
        if heist ~= "Stealth" and heist ~= "Search" then
            log("Unmask refused: heist state is " .. tostring(heist))
            return false, "Unmask refused: heist state is " .. tostring(heist)
        end
    end
    local chat = chat_for(pc)
    if not valid(chat) then log("No unique chat actor in the current heist."); return false, "No unique chat actor" end
    sequence = sequence + 1
    local active = {pc = pc, pawn = pawn, state = state, chat = chat, id = state.PlayerId,
        nonce = tostring(os.time()) .. "-" .. tostring(sequence), action = action, applied = false, bridge_token = bridge_token}
    request = active
    local ok, err = pcall(function()
        chat:SendChatMessageToServer({PlayerState = state, Message = message(state, action, "request", active.nonce)})
    end)
    if not ok then request = nil; log("Chat send failed: " .. tostring(err)); return false, "Chat send failed: " .. tostring(err) end
    log((bridge_token and "AgentBridge" or "F4") .. " sent named " .. action .. " request; PlayerId=" .. tostring(active.id) .. " nonce=" .. active.nonce)
    poll(active, 30)
    return true, "pending", active.nonce
end
local function diagnostics()
    log("Version 0.5.4-network-diagnostics; Steam build 25617818 / PAYDAY 3 3.9.2.")
    log("F4/F10 modifier bindings: bare, Ctrl, Shift, Ctrl+Shift.")
    log("F4 input state: Received=" .. input_stats.received .. " Queued=" .. input_stats.queued ..
        " Started=" .. input_stats.started .. " Suppressed=" .. input_stats.suppressed ..
        " PendingGameThread=" .. tostring(key_pending) .. " Cooldown=" .. tostring(key_locked) ..
        " F10Received=" .. input_stats.diagnostics)
    log("Required chat/mask hooks ready: " .. tostring(hooks_ready))
    log("Chat event counters: Server=" .. chat_stats.server .. " Multicast=" .. chat_stats.multicast ..
        " IgnoredHost=" .. chat_stats.ignored_host)
    local pc = local_controller()
    if not pc then log("No active heist character."); return end
    local pawn, state = pc.Pawn, pc.PlayerState
    local current_world = pawn:GetWorld()
    log("Local controller: " .. pc:GetFullName() .. " World=" ..
        (valid(current_world) and current_world:GetFullName() or "unavailable"))
    local selected_chat = chat_for(pc)
    for _, candidate in ipairs(FindAllOf(CHAT_CLASS) or {}) do
        if valid(candidate) and same(candidate:GetWorld(), current_world) then
            log("Current-world chat candidate: " .. candidate:GetFullName() ..
                " Selected=" .. tostring(same(candidate, selected_chat)) ..
                " HasAuthority=" .. tostring(candidate:HasAuthority()))
        end
    end
    local asc, mask = read(pawn, "AbilitySystem"), read(pawn, "EquippedMask")
    log("Pawn: " .. pawn:GetFullName())
    log("Player: " .. player_name(state) .. " PlayerId=" .. tostring(read(state, "PlayerId")))
    log("HasAuthority: " .. tostring(pawn:HasAuthority()))
    log("IsCasing: " .. tostring(pawn:IsCasing()))
    log("Casing tag count: " .. tostring(valid(asc) and asc:GetGameplayTagCount(tag()) or "unavailable"))
    log("PlayerState mask on: " .. tostring(read(state, "bIsMaskOn")))
    log("Mask actor on: " .. tostring(read(mask, "bIsMaskOn")))
    log("EquipState: " .. tostring(read(pawn, "EquipState")))
    log("Heist state: " .. tostring(heist_state(pawn)))
    log("Pending request: " .. tostring(request and request.nonce or "none"))
    local ok, result = pcall(function()
        local container, holder = tag_container(pawn)
        return "array=" .. tostring(container.GameplayTags:GetArrayNum()) .. " holder=" .. tostring(valid(holder))
    end)
    log("Native tag storage preflight: " .. tostring(ok) .. " " .. tostring(result))
end
local function schedule(action)
    if key_pending or key_locked then
        input_stats.suppressed = input_stats.suppressed + 1
        log("F4 input ignored: " .. (key_pending and "previous action is queued" or "750 ms cooldown"))
        return
    end
    key_pending = true
    input_stats.queued = input_stats.queued + 1
    log("F4 action queued; sequence=" .. input_stats.queued)
    ExecuteInGameThread(function()
        key_pending = false
        input_stats.started = input_stats.started + 1
        log("F4 action started on game thread; sequence=" .. input_stats.started)
        local ok, err = pcall(action)
        if not ok then log("Failed: " .. tostring(err)) end
    end)
    key_locked = true
    ExecuteWithDelay(750, function() key_locked = false end)
end
local function toggle_input()
    input_stats.received = input_stats.received + 1
    log("F4 input received; sequence=" .. input_stats.received)
    schedule(toggle)
end
local function diagnostics_input()
    input_stats.diagnostics = input_stats.diagnostics + 1
    log("F10 input received; F4Pending=" .. tostring(key_pending) .. " F4Cooldown=" .. tostring(key_locked))
    -- Diagnose F4 even while it is queued or cooling down. Never unlock or
    -- replay a mask request: missing input and failed transitions differ.
    if diagnostics_pending then log("F10 diagnostics already queued."); return end
    diagnostics_pending = true
    ExecuteInGameThread(function()
        diagnostics_pending = false
        local ok, err = pcall(diagnostics)
        if not ok then log("Diagnostics failed: " .. tostring(err)) end
    end)
end
-- UE4SS matches the entire modifier set. Bare F4/F10 otherwise disappear
-- while crouch or sprint is held. Each set invokes the same guarded callback.
-- Alt is deliberately excluded so Alt+F4 retains its Windows meaning.
for _, modifiers in ipairs({{}, {ModifierKey.CONTROL}, {ModifierKey.SHIFT},
        {ModifierKey.CONTROL, ModifierKey.SHIFT}}) do
    RegisterKeyBind(Key.F4, modifiers, toggle_input)
    RegisterKeyBind(Key.F10, modifiers, diagnostics_input)
end
ensure_hooks()
-- Fixed commands exercise the same request/apply/ack path as F4. This adds
-- no polling loop and does not relax UnmaskAgain's heist restrictions.
if type(RegisterConsoleCommandGlobalHandler) == "function" and ModRef then
    local ok, result = pcall(function()
        local endpoint = require("agentbridge_endpoint")
        endpoint.register(toggle)
        return endpoint
    end)
    if ok then bridge_endpoint = result
    else log("AgentBridge endpoint unavailable: " .. tostring(result)) end
end
log("Loaded 0.5.4 network diagnostics. F4: request mask/unmask, including Ctrl/Shift. " ..
    "F10: input and chat/session diagnostics. Install the same version on everyone. " ..
    "Request failures remain under investigation; masking rules are unchanged.")
