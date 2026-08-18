--[[--
Decides when a lazily-opened book should grow another few chapters.

A book opened by tap-to-read holds only the first few chapters of a longer
catalog. Growing it is deliberately *not* a bespoke fetch: it is the ordinary
download re-run with a larger `opt.limit`, so it inherits the proven download
pipeline (subprocess isolation, record persistence via _merge_download_result,
rate-limit backoff, resume, deferred install while the book is open). Two
properties of that pipeline are what make repeated growth cheap and safe:

- `opt.keep_partial_cache` keeps the download checkpoint after a successful
  build, and `Downloader.process_one` reuses any chapter already in the
  checkpoint without touching the network. Each extension therefore costs only
  the chapters it adds. Dropping the checkpoint would re-fetch from chapter 1
  every time -- O(n^2) requests, exactly the rate-limit trouble this fork set
  out to fix.
- `opt.limit` keeps the record non-`partial_range`, so progress sync stays
  enabled and the EPUB keeps its existing path. Same path is what lets
  KOReader restore the reading position after the rebuilt file is installed.
  (The `range_start_index`/`range_end_index` route would disable sync -- see
  `sync_enabled=not partial_range` in downloader.lua.)

This module owns the decision only, never the request; main.lua owns every
network entry point, as it does for all other subsystems here.
--]]--

local BookExtender = {}
BookExtender.__index = BookExtender

function BookExtender:new(config)
    local instance = setmetatable({}, self)
    instance.config = type(config) == "table" and config or {}
    instance.suspended = false
    instance.in_flight_target = nil
    instance.in_flight_book = nil
    instance.last_attempt_at = 0
    return instance
end

function BookExtender:_number(key, fallback)
    return tonumber(self.config[key]) or fallback
end

--- Should the open book grow, and to how many chapters?
-- `installed`: chapters currently in the built EPUB.
-- `total`: chapters in the book's full catalog.
-- `ratio`: 0..1 position through the installed content.
-- `now`: os.time(). `network_state`: a NetworkState instance (optional).
-- Returns the target chapter count, or nil plus a reason string.
function BookExtender:should_extend(book_id, installed, total, ratio, now, network_state)
    book_id = tostring(book_id or "")
    if book_id == "" then return nil, "no_book" end
    if self.suspended then return nil, "suspended" end
    now = tonumber(now) or 0
    -- Release a slot that has been held too long instead of trusting a
    -- completion callback to arrive. Plugin:download's `done` callback runs only
    -- on success -- _finish_download_runtime returns early on failure without
    -- calling it -- and the reader may also have been suspended or the task
    -- killed mid-flight. A slot that can only be cleared by a callback that may
    -- never come is a slot that eventually wedges extension for good, which is
    -- exactly how the prefetch this replaced used to die.
    if self.in_flight_target and now - (tonumber(self.last_attempt_at) or 0) >= self:_number("stale_after", 300) then
        self.in_flight_book = nil
        self.in_flight_target = nil
    end
    if self.in_flight_target then return nil, "already_extending" end
    installed = tonumber(installed) or 0
    total = tonumber(total) or 0
    if installed <= 0 or total <= 0 then return nil, "unknown_extent" end
    if installed >= total then return nil, "complete" end
    if network_state and not network_state:can_prefetch() then
        return nil, "network_state:" .. tostring(network_state:current())
    end
    local interval = self:_number("min_interval", 45)
    if now - (tonumber(self.last_attempt_at) or 0) < interval then return nil, "cooling_down" end
    local trigger = self:_number("trigger_ratio", 0.5)
    if (tonumber(ratio) or 0) < trigger then return nil, "not_far_enough" end
    local chunk = math.max(1, math.floor(self:_number("chunk", 10)))
    local target = math.min(total, installed + chunk)
    if target <= installed then return nil, "nothing_to_add" end
    return target
end

function BookExtender:mark_in_flight(book_id, target, now)
    self.in_flight_book = tostring(book_id or "")
    self.in_flight_target = tonumber(target)
    self.last_attempt_at = tonumber(now) or 0
end

function BookExtender:mark_done(book_id)
    if book_id ~= nil and tostring(book_id) ~= tostring(self.in_flight_book or "") then return false end
    self.in_flight_book = nil
    self.in_flight_target = nil
    return true
end

function BookExtender:busy()
    return self.in_flight_target ~= nil
end

function BookExtender:on_suspend()
    self.suspended = true
    -- Nothing to cancel: the download pipeline has its own suspend handling
    -- (DownloadTask:on_suspend), and an extension already in flight is a normal
    -- background download from its point of view.
    return true
end

function BookExtender:on_resume()
    self.suspended = false
    -- Release the slot rather than trusting a callback that may have been lost
    -- across the suspend, so a fresh decision can be made on resume.
    self.in_flight_book = nil
    self.in_flight_target = nil
    self.last_attempt_at = 0
    return true
end

return BookExtender
