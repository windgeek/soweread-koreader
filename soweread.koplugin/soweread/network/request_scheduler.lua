--[[--
Priority-aware gate in front of soweread/http.lua's Http:request.

Honest about what this can and can't do: KOReader's Lua runtime is
single-threaded, and this codebase's "concurrency" comes from separate OS
subprocesses (Async workers, the download subprocess) that each make
their own blocking HTTP calls. A true cross-process mutex around
in-flight request *execution* would need real IPC this codebase doesn't
have. What it already has, and what this module builds on instead, is
Http:_reserve_shared_pacing — a cross-process, file-lock-backed "no two
callers may claim a start time closer together than N seconds" gate.
Pacing, not mutual exclusion, is also the actually-correct primitive for
the stated goal (never burst requests at the server) — it doesn't matter
whether two processes' requests briefly overlap in wall-clock execution
time, only that they don't fire back-to-back with no gap.

Before this module, that pacing gate was opt-in per call site (only
annotation reads/writes used it, per ARCHITECTURE_ANALYSIS.md). This
module makes it the default for every WeRead-bound call issued by the
new lazy-chapter subsystems, at a priority-scaled interval: higher
priority (READ) wait less, lower priority (PREFETCH/DOWNLOAD) wait the
full configured interval. AUTH and READ are never blocked by this gate at
all — reading is never held up waiting on a background priority's turn,
matching the existing download subsystem's "reading always wins"
principle. The download subprocess itself is unaffected: it already
paces itself internally (Http's own min_weread_interval plus its own
respect_reader_priority loop) and is not routed through this module.
--]]--

local Backoff = require("soweread.network.backoff")

local RequestScheduler = {}

RequestScheduler.PRIORITY = {
    AUTH = 1, READ = 2, METADATA = 3, SYNC = 4, PREFETCH = 5, DOWNLOAD = 6,
}

local PRIORITY_SCOPE = {
    [1] = "auth", [2] = "read", [3] = "metadata", [4] = "sync", [5] = "prefetch", [6] = "download",
}

local function pause(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then socket.sleep(seconds) end
end

local function priority_value(priority)
    if type(priority) == "number" then return priority end
    return RequestScheduler.PRIORITY[tostring(priority or "READ"):upper()] or RequestScheduler.PRIORITY.READ
end

--- Runs `fn()` once scheduling allows it. `http` must be a live Http
-- instance so this can reuse its shared-pacing/rate-limit state; `network`
-- is the NETWORK config table (min_request_interval, jitter); `state` is
-- an optional NetworkState instance — if given and priority is PREFETCH or
-- lower, a non-can_prefetch() state refuses the call outright rather than
-- waiting, since prefetch/download must never run through backoff/suspend.
-- Returns fn()'s return values, or nil, error-string on refusal.
function RequestScheduler.run(http, network, state, priority, fn)
    local level = priority_value(priority)
    if state and level >= RequestScheduler.PRIORITY.PREFETCH and not state:can_prefetch() then
        return nil, "scheduler_refused:" .. tostring(state:current())
    end
    -- AUTH/READ bypass the pacing gate entirely; Http:request's own
    -- pacing/backoff still applies underneath.
    if level <= RequestScheduler.PRIORITY.READ then
        return fn()
    end
    if type(http) == "table" and type(http._reserve_shared_pacing) == "function" then
        local interval = tonumber(network and network.min_request_interval) or 2.5
        local jitter = tonumber(network and network.jitter) or 0.5
        -- Lower-priority callers wait proportionally longer, so a
        -- PREFETCH request never queues ahead of a SYNC request that
        -- reserved its slot first, without needing a real queue.
        local scale = 1 + (level - RequestScheduler.PRIORITY.METADATA) * 0.2
        local wait = http:_reserve_shared_pacing(PRIORITY_SCOPE[level] or "background", interval * scale, jitter)
        if wait and wait > 0 then pause(wait) end
    end
    return fn()
end

--- Convenience: run fn(), classify a raised error via Backoff, and update
-- `state` accordingly (RATE_LIMITED/OFFLINE) rather than leaving that to
-- every call site. Returns ok, result_or_error.
function RequestScheduler.run_guarded(http, network, state, priority, fn)
    local ok, result_or_err = pcall(function() return RequestScheduler.run(http, network, state, priority, fn) end)
    if ok then
        if state then state:set("IDLE", "request_ok") end
        return true, result_or_err
    end
    if state then
        if Backoff.is_rate_limited_error(require("soweread.http"), result_or_err) then
            local remaining = Backoff.remaining(http)
            state:enter_rate_limited(remaining > 0 and remaining or 30)
        elseif Backoff.is_network_error(require("soweread.http"), result_or_err) then
            state:set("OFFLINE", "request_network_error")
        end
    end
    return false, result_or_err
end

return RequestScheduler
