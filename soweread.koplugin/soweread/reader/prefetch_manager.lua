--[[--
Decides *when* it's safe to prefetch the next chapter. Never decides
*how* — the actual fetch is the same Downloader:book(book,{chapter_uid=...})
call chapter_provider.lua describes, run through main.lua's existing
Async pattern at PREFETCH priority via request_scheduler.lua.

Single-slot by construction: `mark_in_flight`/`mark_done` track at most
one uid at a time, and `should_prefetch` refuses to suggest a new target
while one is in flight or already cached. There is deliberately no
"prefetch succeeded, now prefetch the one after that" call anywhere in
this codebase — recursive prefetch is prevented by this module simply
never being asked to chain, not by a depth counter.

Suspend/resume mirrors download_task.lua's DownloadTask:on_suspend/
on_resume: on suspend, drop whatever's in flight outright (a prefetch is
cheap to redo and has no checkpoint worth preserving mid-flight, unlike a
multi-chapter download); on resume, do not resume anything automatically
— the next onPageUpdate/reader-ready call naturally re-evaluates from
scratch, matching "wake, wait, re-check, resume only what's needed."
--]]--

local PrefetchManager = {}
PrefetchManager.__index = PrefetchManager

function PrefetchManager:new(store, cache, config)
    return setmetatable({
        store = store,
        cache = cache,
        config = config or {},
        in_flight_uid = nil,
        suspended = false,
    }, self)
end

local function percent_through(page, pages)
    page, pages = tonumber(page), tonumber(pages)
    if not page or not pages or pages <= 0 then return 0 end
    return math.max(0, math.min(1, page / pages))
end

--- `book_id`, `current_uid`: current chapter. `page`/`pages`: position
-- within the current chapter (any consistent unit — page index, or a
-- 0..1 ratio via page=ratio,pages=1). `catalog`: the book's chapter list
-- (for finding the next uid). `network_state`: a NetworkState instance.
-- Returns the uid to prefetch, or nil with a reason string if refusing.
function PrefetchManager:should_prefetch(book_id, current_uid, page, pages, catalog, network_state)
    if self.suspended then return nil, "suspended" end
    if network_state and not network_state:can_prefetch() then
        return nil, "network_state:" .. tostring(network_state:current())
    end
    if self.in_flight_uid then return nil, "already_in_flight" end
    local trigger = tonumber(self.config.trigger_percent) or 0.75
    if percent_through(page, pages) < trigger then return nil, "not_far_enough" end
    local ChapterProvider = require("soweread.reader.chapter_provider")
    local next_uid = ChapterProvider.next_uid(catalog, current_uid)
    if not next_uid then return nil, "no_next_chapter" end
    if self.cache:has(book_id, next_uid) then return nil, "already_cached" end
    return next_uid
end

function PrefetchManager:mark_in_flight(uid)
    self.in_flight_uid = tostring(uid)
end

function PrefetchManager:mark_done(uid)
    if self.in_flight_uid == tostring(uid) then self.in_flight_uid = nil end
end

function PrefetchManager:busy()
    return self.in_flight_uid ~= nil
end

function PrefetchManager:on_suspend()
    self.suspended = true
    -- Nothing to cancel here: the actual subprocess/Async call this
    -- decision feeds is owned and cancelled by the caller (main.lua),
    -- same as download_task.lua's own on_suspend does for downloads.
    -- Clearing in_flight_uid lets a fresh decision be made on resume
    -- rather than assuming a suspended fetch will ever complete.
    self.in_flight_uid = nil
end

function PrefetchManager:on_resume()
    self.suspended = false
end

return PrefetchManager
