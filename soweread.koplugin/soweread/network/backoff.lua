--[[--
Thin wrapper around soweread/http.lua's existing rate-limit machinery.

http.lua already implements real 429/403/"请求过快" detection, a tuned
backoff schedule (RATE_LIMIT_DELAYS = {15,30,60,90}), and a cross-process
shared cooldown file (Http:_shared_rate_limit/_set_shared_rate_limit).
That logic is already correct and already exercised by every existing
download; this module does not reimplement it, it only exposes it to
callers that need to ask "are we currently backed off" without going
through a full Http:request call, and that may not always have a live
Http instance — currently main.lua's lazy-reading extension check, which
uses it to skip an extension that would only walk into a live cooldown.
--]]--

local Backoff = {}

--- Delegates to Http's own error classification. `err` is whatever a
-- pcall'd Http:request/Reader:chapter call raised.
function Backoff.is_rate_limited_error(Http, err)
    return type(Http) == "table" and type(Http.is_rate_limit_error) == "function"
        and Http.is_rate_limit_error(err) == true
end

function Backoff.is_auth_error(Http, err)
    return type(Http) == "table" and type(Http.is_auth_error) == "function"
        and Http.is_auth_error(err) == true
end

function Backoff.is_network_error(Http, err)
    return type(Http) == "table" and type(Http.is_network_error) == "function"
        and Http.is_network_error(err) == true
end

--- Reads the shared, cross-process rate-limit cooldown http.lua already
-- maintains. Returns remaining seconds (0 if not currently limited) and
-- the raw state table (or nil). `http` must be a live Http instance
-- (soweread/http.lua's Http:new(store) result) — this only reads state
-- http.lua itself already writes, it never writes its own.
function Backoff.remaining(http, scope)
    if type(http) ~= "table" or type(http._shared_rate_limit) ~= "function" then return 0, nil end
    local ok, remaining, state = pcall(http._shared_rate_limit, http, scope)
    if not ok then return 0, nil end
    return tonumber(remaining) or 0, state
end

function Backoff.is_limited(http, scope)
    return Backoff.remaining(http, scope) > 0
end

return Backoff
