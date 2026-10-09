-- A scalar result channel is supported by the installed UE4SS 0290beda.
-- No Lua functions or transient UObjects are shared between mods.
local M = {}
local VERSION_KEY = "AgentBridge.UnmaskAgain.Version"
local RESULT_KEY = "AgentBridge.UnmaskAgain.Result"
local seen, count = {}, 0

function M.report(token, status, detail)
    local text = tostring(detail or ""):gsub("[|\r\n]", " "):sub(1, 1000)
    ModRef:SetSharedVariable(RESULT_KEY, token .. "|" .. status .. "|" .. text)
    print("[UnmaskAgain] AgentBridge token=" .. token .. " status=" .. status .. " detail=" .. text .. "\n")
end

function M.register(request)
    ModRef:SetSharedVariable(VERSION_KEY, nil)
    ModRef:SetSharedVariable(RESULT_KEY, "")
    RegisterConsoleCommandGlobalHandler("AgentBridge_UnmaskAgain", function(_, parameters)
        local action, token = parameters[1], parameters[2]
        if #parameters ~= 2 or (action ~= "masked" and action ~= "unmasked") or
            type(token) ~= "string" or #token < 1 or #token > 64 or not token:match("^[A-Za-z0-9_-]+$") then
            return true
        end
        -- Duplicate dispatch must never turn into a second toggle.
        if seen[token] then return true end
        if count >= 4096 then M.report(token, "error", "Endpoint session command limit reached"); return true end
        seen[token], count = true, count + 1
        M.report(token, "pending", "queued")
        local queued, error_text = pcall(ExecuteInGameThread, function()
            local ok, accepted, status, detail = pcall(request, action, token)
            if not ok then M.report(token, "error", accepted)
            elseif not accepted then M.report(token, "error", status)
            else M.report(token, status, detail) end
        end)
        if not queued then M.report(token, "error", "Scheduling failed: " .. tostring(error_text)) end
        return true
    end)
    ModRef:SetSharedVariable(VERSION_KEY, "1")
end

return M
