-- AgentBridge 0.2.0: opt-in instrumentation for private PAYDAY 3 playtests.
-- UE4SS 3.0.1-compatible scheduling; never access Unreal objects from LoopAsync.
local VERSION, SCHEMA = "0.2.0", 1
local INTERVAL_MS, CONTROL_POLL_MS, MAX_COMMAND_BYTES, MAX_COMMANDS = 300, 1000, 1024, 4096
local MAX_ACTION_TICKS, MAX_ACTION_SECONDS = 30, 10
local MAX_SEQ = 9007199254740991
local NULL = {}

local function log(message) print("[AgentBridge] " .. tostring(message) .. "\n") end
local function absolute(path)
    return type(path) == "string" and (path:match("^%a:[/\\]") or path:sub(1, 1) == "/")
end
local function resolve_bridge_dir()
    -- The installer writes this module. ModRef:GetModPath does not exist in
    -- the installed runtime; do not infer its availability from newer docs.
    local ok, config = pcall(require, "agentbridge_paths")
    if ok and type(config) == "table" and absolute(config.bridge_dir) then
        return config.bridge_dir:gsub("\\", "/"):gsub("/+$", "")
    end
    local source = debug.getinfo(1, "S").source
    if type(source) == "string" and source:sub(1, 1) == "@" then
        local script = source:sub(2):gsub("\\", "/")
        local root = script:match("^(.*)/[Ss]cripts/main%.lua$")
        if absolute(root) then return root .. "/bridge" end
    end
    error("No absolute bridge path. Install with Install-AgentBridge.ps1.")
end
local bridge_dir = resolve_bridge_dir()
local paths = {
    state = bridge_dir .. "/state.json", events = bridge_dir .. "/events.jsonl",
    command = bridge_dir .. "/command.json", ack = bridge_dir .. "/ack.json",
}
local session_id = string.format("%d-%d-%s", os.time(), math.floor(os.clock() * 1000000),
    tostring({}):gsub("[^%w]", ""))
local state_seq, command_seq, command_count = 0, 0, 0
local seen_ids, pending = {}, false
local enabled, generation, action = false, 0, nil
local cleanup_pending = nil
local control_polls, async_callbacks, game_thread_ticks, sample_count, queued_callbacks = 0, 0, 0, 0, 0
local last_sample_timestamp, last_snapshot = NULL, nil
local last_input, last_status = nil, nil
local error_times = {}
local supported_commands = {PING = true, SNAPSHOT = true, ENABLE = true, DISABLE = true,
    MASK_UP = true, UNMASK = true, FIRE_ONCE = true}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        return string.format("\\u%04x", string.byte(c))
    end) .. '"'
end
local function json(value)
    if value == NULL or value == nil then return "null" end
    local kind = type(value)
    if kind == "string" then return quote(value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        assert(finite(value), "Non-finite JSON number")
        return string.format("%.17g", value)
    end
    assert(kind == "table", "Only scalar telemetry may be serialized")
    local keys, parts = {}, {}
    for key in pairs(value) do assert(type(key) == "string"); keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = quote(key) .. ":" .. json(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function write_file(path, text, mode)
    local file, reason = io.open(path, mode or "wb")
    if not file then return false, reason end
    local ok, message = file:write(text)
    local closed, close_message = file:close()
    if not ok then return false, message end
    if not closed then return false, close_message end
    return true
end
local function event(kind, fields)
    local entry = fields or {}
    entry.event, entry.schema_version, entry.bridge_version = kind, SCHEMA, VERSION
    entry.session_id, entry.timestamp = session_id, os.time()
    local ok, reason = write_file(paths.events, json(entry) .. "\n", "ab")
    if not ok then log("Event write failed: " .. tostring(reason)) end
    return ok
end
local function report_error(code, message)
    local now = os.time()
    if not error_times[code] or now - error_times[code] >= 5 then
        error_times[code] = now
        local text = tostring(message):sub(1, 1000)
        event("error", {code = code, message = text})
        log(code .. ": " .. text)
    end
end

-- UE4SS represents missing reflected members as null UObject userdata.
-- Calling such a userdata may crash the native loader before pcall helps.
local function valid(object)
    if object == nil then return false end
    local kind = type(object)
    if kind ~= "userdata" and kind ~= "table" then return false end
    local ok, result = pcall(function()
        local method = object.IsValid
        if type(method) ~= "function" then return false end
        return method(object)
    end)
    return ok and result == true
end
local function read(object, field)
    if not valid(object) then return nil end
    local ok, value = pcall(function() return object[field] end)
    if ok then return value end
    error(value)
end
local function call(object, method, ...)
    if not valid(object) then error("Invalid object before " .. method) end
    local callable = object[method]
    if type(callable) ~= "function" and not valid(callable) then
        error("Unavailable native method " .. method)
    end
    return callable(object, ...)
end
local adapter = require("game_adapter").new({null = NULL})
local function sample()
    -- Reacquire on each game-thread callback; keep no UObject across travel.
    local snapshot = {status = "no_pawn", player = {pawn_name = NULL, position = NULL}}
    local controllers = FindAllOf("PlayerController")
    if controllers == nil then return snapshot end
    assert(type(controllers) == "table", "FindAllOf returned an unexpected type")
    for _, controller in pairs(controllers) do
        if valid(controller) and call(controller, "IsLocalPlayerController") == true then
            if call(controller, "IsA", "/Script/Starbreeze.SBZPlayerControllerMainMenu") == true then
                snapshot.status = "menu"
                return snapshot
            end
            local pawn = read(controller, "Pawn")
            if not valid(pawn) then return snapshot end
            local name = call(pawn, "GetFullName")
            local location = call(pawn, "K2_GetActorLocation")
            -- FVector is a UScriptStruct, not a UObject. Read its components
            -- only after the verified K2_GetActorLocation return succeeded.
            assert(location ~= nil, "K2_GetActorLocation returned nil")
            local x, y, z = location.X, location.Y, location.Z
            assert(type(name) == "string" and finite(x) and finite(y) and finite(z),
                "Pawn telemetry has an unexpected type")
            snapshot.status = "in_heist"
            snapshot.player = {pawn_name = name:sub(1, 512), position = {x = x, y = y, z = z}}
            local details = adapter.sample(controller, pawn)
            if details then
                snapshot.player.stats = details
                snapshot.capabilities = details.capabilities
            end
            return snapshot, controller, pawn
        end
    end
    return snapshot
end
local function publish(snapshot)
    state_seq = state_seq + 1
    snapshot.schema_version, snapshot.bridge_version = SCHEMA, VERSION
    snapshot.session_id, snapshot.seq, snapshot.timestamp = session_id, state_seq, os.time()
    snapshot.command_seq, snapshot.command_count, snapshot.command_capacity = command_seq, command_count, MAX_COMMANDS
    snapshot.interval_ms, snapshot.control_poll_ms, snapshot.supported_commands = INTERVAL_MS, CONTROL_POLL_MS, supported_commands
    snapshot.enabled, snapshot.telemetry_frozen = enabled, not enabled
    snapshot.last_sample_timestamp = last_sample_timestamp
    snapshot.counters = {control_polls = control_polls, async_callbacks = async_callbacks,
        game_thread_ticks = game_thread_ticks, sample_count = sample_count, queued_callbacks = queued_callbacks}
    snapshot.pending = pending
    snapshot.action_pending = action and action.command.id or NULL
    snapshot.cleanup_required = cleanup_pending ~= nil
    local ok, reason = write_file(paths.state, json(snapshot) .. "\n")
    if not ok then report_error("state_write_failed", reason); return false end
    if last_status ~= snapshot.status then
        event("status_changed", {previous = last_status or NULL, status = snapshot.status, state_seq = state_seq})
        last_status = snapshot.status
    end
    last_snapshot = snapshot
    return true
end

-- Restricted JSON grammar for five flat protocol fields. Tokens are ASCII;
-- escapes, nested values, duplicate keys, unknown fields and trailing text
-- are rejected. This is data parsing and never Lua evaluation.
local function parse_command(raw)
    if #raw > MAX_COMMAND_BYTES then return nil, "Command exceeds 1024 bytes" end
    local at, count, result = 1, 0, {}
    local function whitespace()
        local _, finish = raw:find("^[ \t\r\n]*", at)
        at = (finish or at - 1) + 1
    end
    local function take(character)
        whitespace()
        if raw:sub(at, at) ~= character then return false end
        at = at + 1
        return true
    end
    local function token()
        whitespace()
        local value, finish = raw:match('^"([A-Za-z0-9_-]*)"()', at)
        if value then at = finish; return value end
    end
    if not take("{") then return nil, "Expected a JSON object" end
    while true do
        whitespace()
        if raw:sub(at, at) == "}" then at = at + 1; break end
        local key = token()
        if not key or not take(":") then return nil, "Invalid JSON key" end
        if result[key] ~= nil then return nil, "Duplicate JSON key" end
        whitespace()
        local value
        if raw:sub(at, at) == '"' then
            value = token()
        else
            local number, finish = raw:match("^([0-9]+)()", at)
            if number and (#number == 1 or number:sub(1, 1) ~= "0") then
                value, at = tonumber(number), finish
            end
        end
        if value == nil then return nil, "Invalid JSON value" end
        result[key], count = value, count + 1
        whitespace()
        local separator = raw:sub(at, at)
        if separator == "}" then at = at + 1; break end
        if not take(",") then return nil, "Expected a JSON separator" end
        whitespace()
        if raw:sub(at, at) == "}" then return nil, "Trailing JSON comma" end
    end
    whitespace()
    if at <= #raw then return nil, "Trailing JSON text" end
    local fields = {schema_version = true, session_id = true, id = true, seq = true, command = true}
    for key in pairs(result) do if not fields[key] then return nil, "Unknown command field" end end
    if count ~= 5 then return nil, "Exactly five command fields are required" end
    if result.schema_version ~= SCHEMA then return nil, "Unsupported schema_version" end
    for _, key in ipairs({"session_id", "id", "command"}) do
        if type(result[key]) ~= "string" or #result[key] < 1 or #result[key] > 64 then
            return nil, "Invalid " .. key
        end
    end
    if not finite(result.seq) or result.seq < 1 or result.seq > MAX_SEQ or result.seq % 1 ~= 0 then
        return nil, "Invalid command seq"
    end
    return result
end
local function read_command()
    local file = io.open(paths.command, "rb")
    if not file then return nil end
    local raw = file:read(MAX_COMMAND_BYTES + 1)
    file:close()
    if not raw or raw == last_input then return nil end
    last_input = raw
    local command, reason = parse_command(raw)
    if not command then report_error("invalid_command", reason); return nil end
    return command
end
local function acknowledge(command, status, result, reason)
    local ack = {
        schema_version = SCHEMA, bridge_version = VERSION, session_id = session_id,
        timestamp = os.time(), id = command.id, seq = command.seq,
        command = command.command, status = status, result = result or NULL,
    }
    if reason then ack.error = reason end
    local ok, message = write_file(paths.ack, json(ack) .. "\n")
    if not ok then report_error("ack_write_failed", message) end
    event("command_ack", ack)
end
local function admit_command(command)
    if command.session_id ~= session_id then
        return "Wrong session_id; read fresh state.json"
    elseif not supported_commands[command.command] then
        return "Unsupported command"
    elseif seen_ids[command.id] then
        -- Never execute the same id again, even with a higher seq.
        return "Duplicate command id"
    elseif command.seq <= command_seq then
        return "Command seq must increase"
    elseif command_count >= MAX_COMMANDS then
        return "Command capacity exhausted; restart the game"
    end
    -- Mark accepted commands before publication/execution. ACK failure must not
    -- cause execution again. This guarantee ends with this Lua runtime/session.
    seen_ids[command.id] = true
    command_seq, command_count = command.seq, command_count + 1
end
local function empty_snapshot(status)
    return {status = status, player = {pawn_name = NULL, position = NULL}}
end
local function finish_action(status, result, reason)
    if not action then return end
    local command = action.command
    action = nil
    acknowledge(command, status, result, reason)
end
local function cleanup_action(controller, pawn, reason)
    local operation = action and action.operation or cleanup_pending
    if not operation then return true end
    local ok, cleaned, message = pcall(adapter.cleanup, operation, controller, pawn, reason)
    if not ok or cleaned ~= true then
        -- Preserve scalar identity only. Explicit DISABLE can retry Release
        -- later without replaying Press or doing any native work while idle.
        if operation.release_needed == true then cleanup_pending = operation end
        local detail = tostring(ok and message or cleaned):sub(1, 1000)
        report_error("action_cleanup_failed", detail)
        return false, detail
    end
    if cleanup_pending == operation then cleanup_pending = nil end
    return true
end

local queue_game_tick, start_active_loop
local function game_tick(command)
    local snapshot, controller, pawn, sample_ok
    local acknowledgements = {}
    local function defer_ack(request, status, result, reason)
        acknowledgements[#acknowledgements + 1] = {command = request, status = status,
            result = result, reason = reason}
    end
    -- DISABLE is allowed to finish native cleanup, but never takes another
    -- telemetry sample. Cleanup reacquires its own objects only if needed.
    if command and command.command == "DISABLE" then
        local cleaned, reason = cleanup_action(nil, nil, "disabled")
        if action then
            defer_ack(action.command, "error", {accepted = true, completed = false},
                "Action observation stopped by DISABLE" .. (cleaned and "" or ": " .. tostring(reason)))
            action = nil
        end
        enabled, generation = false, generation + 1
        snapshot = empty_snapshot("disabled")
        defer_ack(command, cleaned and "ok" or "error", {enabled = false, completed = cleaned,
            cleanup_required = cleanup_pending ~= nil}, reason)
        return snapshot, acknowledgements
    end
    if command and command.command == "ENABLE" then
        enabled, generation = true, generation + 1
    end
    sample_count = sample_count + 1
    sample_ok, snapshot, controller, pawn = pcall(sample)
    if not sample_ok then
        report_error("sample_failed", snapshot)
        local message = tostring(snapshot):sub(1, 1000)
        snapshot, controller, pawn = empty_snapshot("no_pawn"), nil, nil
        snapshot.sample_error = message
    else last_sample_timestamp = os.time() end

    -- Native action operations contain scalar identities/baselines only.
    -- Poll once per fresh game-thread sample and never resend the action.
    if action then
        action.ticks = action.ticks + 1
        local expired = action.ticks > MAX_ACTION_TICKS or os.time() - action.started_at >= MAX_ACTION_SECONDS
        if not sample_ok or snapshot.status ~= "in_heist" or expired then
            local reason = expired and "Action timed out before its state assertion" or "Local pawn unavailable during action"
            local cleaned, message = cleanup_action(controller, pawn, reason)
            defer_ack(action.command, "error", {accepted = true, completed = false,
                cleanup_required = cleanup_pending ~= nil},
                reason .. (cleaned and "" or "; cleanup: " .. tostring(message)))
            action = nil
        else
            local ok, done, result, reason = pcall(adapter.poll, action.operation, controller, pawn, snapshot)
            if not ok or reason then
                local detail = tostring(ok and reason or done):sub(1, 1000)
                local cleaned, message = cleanup_action(controller, pawn, detail)
                if not cleaned then detail = detail .. "; cleanup: " .. tostring(message) end
                defer_ack(action.command, "error", {accepted = true, completed = false,
                    cleanup_required = cleanup_pending ~= nil}, detail)
                action = nil
            elseif done then
                assert(type(result) == "table", "Action result must be scalar telemetry")
                result.accepted, result.completed = true, true
                result.state_seq = state_seq + 1
                defer_ack(action.command, "ok", result)
                action = nil
            end
        end
    end
    if command then
        if command.command == "ENABLE" then
            local reason
            if not sample_ok then reason = "Bridge enabled, but initial sampling failed" end
            defer_ack(command, sample_ok and "ok" or "error", {enabled = true, state_seq = state_seq + 1},
                reason)
        elseif command.command == "SNAPSHOT" then
            local reason
            if not sample_ok then reason = "Snapshot sampling failed" end
            defer_ack(command, sample_ok and "ok" or "error", {state_seq = state_seq + 1,
                enabled = enabled, one_shot = not enabled}, reason)
        else
            if not enabled then defer_ack(command, "error", nil, "Bridge disabled; send ENABLE first")
            elseif cleanup_pending then defer_ack(command, "error", nil, "Fire input cleanup required; send DISABLE first")
            elseif action then defer_ack(command, "error", nil, "Another action is awaiting its state assertion")
            elseif not sample_ok or snapshot.status ~= "in_heist" then
                defer_ack(command, "error", nil, "A valid local heist pawn is required")
            else
                local ok, operation, reason = pcall(adapter.begin, command.command, controller, pawn, snapshot, command)
                if not ok or not operation then
                    defer_ack(command, "error", nil, tostring(ok and reason or operation):sub(1, 1000))
                else
                    action = {command = command, operation = operation, ticks = 0, started_at = os.time()}
                    event("action_accepted", {id = command.id, seq = command.seq, command = command.command,
                        state_seq = state_seq + 1, completed = false})
                end
            end
        end
    end
    return snapshot, acknowledgements
end
queue_game_tick = function(command)
    if pending then return false end
    pending, queued_callbacks = true, queued_callbacks + 1
    local queued, reason = pcall(ExecuteInGameThread, function()
        game_thread_ticks = game_thread_ticks + 1
        local ok, snapshot, acknowledgements = pcall(game_tick, command)
        pending = false
        if not ok then
            report_error("tick_failed", snapshot)
            cleanup_action(nil, nil, "game-thread callback failed")
            finish_action("error", {accepted = true, completed = false}, "Game-thread callback failed")
            snapshot = empty_snapshot(enabled and "no_pawn" or "disabled")
            snapshot.sample_error = "Game-thread callback failed"
            acknowledgements = {}
            if command then acknowledgements[1] = {command = command, status = "error", reason = "Game-thread callback failed"} end
        end
        local publish_ok, published = pcall(publish, snapshot)
        if not publish_ok then
            report_error("state_publication_failed", published)
            published = false
        end
        for _, ack in ipairs(acknowledgements) do
            if not published and ack.status == "ok" then
                acknowledge(ack.command, "error", ack.result, "State publication failed after execution; do not retry the action")
            else acknowledge(ack.command, ack.status, ack.result, ack.reason) end
        end
        if enabled then start_active_loop() end
    end)
    if not queued then
        pending = false
        report_error("queue_failed", reason)
        publish(last_snapshot or empty_snapshot(enabled and "no_pawn" or "disabled"))
        if command then acknowledge(command, "error", nil, "Game-thread scheduling failed; command will not be retried") end
        return false
    end
    return true
end
local active_loop_generation = nil
start_active_loop = function()
    if not enabled or active_loop_generation == generation then return end
    local loop_generation = generation
    active_loop_generation = loop_generation
    LoopAsync(INTERVAL_MS, function()
        async_callbacks = async_callbacks + 1
        if not enabled or loop_generation ~= generation then return true end
        queue_game_tick(nil)
        return false
    end)
end
local function control_tick()
    control_polls, async_callbacks = control_polls + 1, async_callbacks + 1
    if pending then return end
    local command = read_command()
    if not command then return end
    local rejection = admit_command(command)
    if rejection then acknowledge(command, "error", nil, rejection); return end
    -- Admission precedes state gating: even rejected/failed actions cannot be
    -- replayed under the same ID after a later ENABLE or successful travel.
    if command.command == "PING" then
        publish(last_snapshot or empty_snapshot(enabled and "no_pawn" or "disabled"))
        acknowledge(command, "ok", {pong = true, enabled = enabled, telemetry_frozen = not enabled,
            control_polls = control_polls, game_thread_ticks = game_thread_ticks, sample_count = sample_count,
            pending = pending})
    elseif command.command == "DISABLE" and not action and not cleanup_pending then
        enabled, generation = false, generation + 1
        publish(empty_snapshot("disabled"))
        acknowledge(command, "ok", {enabled = false, completed = true})
    elseif command.command == "ENABLE" and enabled then
        publish(last_snapshot)
        acknowledge(command, "ok", {enabled = true, already_enabled = true})
    elseif command.command ~= "ENABLE" and command.command ~= "DISABLE"
        and command.command ~= "SNAPSHOT" and not enabled then
        publish(last_snapshot or empty_snapshot("disabled"))
        acknowledge(command, "error", nil, "Bridge disabled; send ENABLE first")
    elseif command.command ~= "ENABLE" and command.command ~= "DISABLE"
        and command.command ~= "SNAPSHOT" and cleanup_pending then
        publish(last_snapshot)
        acknowledge(command, "error", nil, "Fire input cleanup required; send DISABLE first")
    elseif action and command.command ~= "DISABLE" then
        publish(last_snapshot)
        acknowledge(command, "error", nil, "Another action is awaiting its state assertion")
    else queue_game_tick(command) end
end

local initial = empty_snapshot("disabled")
if not publish(initial) then error("Bridge directory is missing or not writable") end
for _, name in ipairs({"LoopAsync", "ExecuteInGameThread", "FindAllOf"}) do
    if type(_G[name]) ~= "function" then
        report_error("unsupported_runtime", "Required API missing: " .. name)
        error("Required UE4SS API missing: " .. name)
    end
end
event("mod_loaded", {interval_ms = INTERVAL_MS, control_poll_ms = CONTROL_POLL_MS,
    command_capacity = MAX_COMMANDS, enabled = false})
LoopAsync(CONTROL_POLL_MS, function()
    local ok, message = pcall(control_tick)
    if not ok then report_error("control_tick_failed", message) end
    return false
end)
log("Loaded " .. VERSION .. "; bridge=" .. bridge_dir .. "; session=" .. session_id)
