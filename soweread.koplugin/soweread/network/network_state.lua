--[[--
Explicit network state for the new lazy-chapter subsystems
(ChapterProvider, PrefetchManager, RequestScheduler).

This is scoped to the NEW subsystems only. It does not replace or touch
sync.lua's own state string or download_task.lua's pause-reason flags —
those already work and are left alone (see ARCHITECTURE_ANALYSIS.md).
This exists because the new subsystems would otherwise need their own
ad-hoc booleans, which is exactly the pattern the architecture review
flagged as a maintainability risk elsewhere in the codebase.

States: IDLE, READING, PREFETCHING, DOWNLOADING, OFFLINE, BACKOFF,
RATE_LIMITED, SUSPENDED.

Transitions are last-writer-wins with one exception: SUSPENDED and
RATE_LIMITED are "sticky" against lower-priority states — once set, only
an explicit resume()/clear_rate_limit() (or a higher-priority state, i.e.
another suspend/rate-limit) can move out of them. This mirrors the
existing download subsystem's own principle: suspend/backoff should never
be silently overridden by a routine reading-state update racing in.
--]]--

local NetworkState = {}
NetworkState.__index = NetworkState

local STATES = {
    IDLE = true, READING = true, PREFETCHING = true, DOWNLOADING = true,
    OFFLINE = true, BACKOFF = true, RATE_LIMITED = true, SUSPENDED = true,
}

local STICKY = { SUSPENDED = true, RATE_LIMITED = true }

function NetworkState:new()
    return setmetatable({
        state = "IDLE",
        changed_at = os.time(),
        rate_limited_until = 0,
        suspended = false,
    }, self)
end

function NetworkState:current()
    return self.state
end

function NetworkState:set(state, reason)
    if not STATES[state] then return false, "unknown_state" end
    if STICKY[self.state] and self.state ~= state and not STICKY[state] then
        -- Refuse to silently leave a sticky state; caller must use
        -- resume()/clear_rate_limit() explicitly.
        return false, "sticky:" .. self.state
    end
    if self.state ~= state then
        self.state = state
        self.changed_at = os.time()
        self.last_reason = reason
    end
    return true
end

function NetworkState:is(state)
    return self.state == state
end

--- True when the new subsystems are allowed to issue any request at all
-- (READ requests still bypass this at the scheduler priority level, but
-- PREFETCH/METADATA must check it before ever queuing).
function NetworkState:can_prefetch()
    return self.state ~= "SUSPENDED" and self.state ~= "RATE_LIMITED"
        and self.state ~= "OFFLINE" and self.state ~= "BACKOFF"
end

function NetworkState:enter_suspended()
    self.suspended = true
    self.state = "SUSPENDED"
    self.changed_at = os.time()
end

--- Resume never jumps straight back to PREFETCHING/DOWNLOADING — the
-- caller re-evaluates from IDLE, matching the existing download
-- subsystem's "wake, wait, re-check, only resume what's needed" pattern
-- rather than resuming a backlog.
function NetworkState:resume()
    self.suspended = false
    if self.state == "SUSPENDED" then
        self.state = "IDLE"
        self.changed_at = os.time()
    end
end

function NetworkState:enter_rate_limited(seconds)
    self.rate_limited_until = os.time() + math.max(1, tonumber(seconds) or 1)
    self.state = "RATE_LIMITED"
    self.changed_at = os.time()
end

function NetworkState:clear_rate_limit()
    if self.state == "RATE_LIMITED" and os.time() >= self.rate_limited_until then
        self.state = "IDLE"
        self.changed_at = os.time()
        return true
    end
    return false
end

--- Call periodically (e.g. before deciding to prefetch) to let an expired
-- rate limit fall back to IDLE without an explicit external trigger.
function NetworkState:refresh()
    if self.state == "RATE_LIMITED" then self:clear_rate_limit() end
    return self.state
end

return NetworkState
