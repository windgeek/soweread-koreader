--[[--
Decision logic for "open exactly what's needed to read right now."

This module is deliberately network-free and side-effect-free except for
ChapterCache reads/writes — it decides *what* to fetch and interprets
*what was fetched*, but the actual network call always goes through the
existing, proven Downloader:book(book, {chapter_uid=uid}, progress) path
(the same standalone-single-chapter build MiuRead already used for
"download this chapter" — see ARCHITECTURE_ANALYSIS.md §8). That call has
to run inside a subprocess via one of main.lua's existing Async
instances, exactly like every other network operation in this codebase,
so the actual fetch + subprocess wiring lives in main.lua, not here.
This module's job is to keep that call site simple and correct: tell it
which chapter to fetch, and interpret the resulting record.

Known tradeoff, accepted deliberately for this version: Downloader:book
always re-fetches the chapter catalog internally (self:catalog(book_id)),
even for a single already-known chapter uid — there is no "skip catalog,
I already have a fresh one" option in the existing downloader.lua, and
adding one was judged not worth the added risk of touching that file
again. So every chapter open/prefetch costs one catalog round-trip plus
one chapter round-trip, not just the chapter. This still respects the
scheduler's pacing/priority and is far cheaper than a whole-book
download; revisit only if real-device testing shows the catalog refetch
itself is a meaningful part of the "请求过快" problem.
--]]--

local U = require("soweread.util")

local ChapterProvider = {}
ChapterProvider.__index = ChapterProvider

function ChapterProvider:new(store, cache)
    return setmetatable({ store = store, cache = cache }, self)
end

local function chapter_uid(chapter)
    return tostring(chapter and (chapter.chapterUid or chapter.uid or chapter.chapter_uid) or "")
end

--- Given a full chapter list (as returned by Reader:catalog / stored in
-- store:book(id).catalog) and a target uid, finds its index. Returns nil
-- if not found (e.g. catalog is stale or empty).
function ChapterProvider.index_of(catalog, uid)
    uid = tostring(uid or "")
    if uid == "" then return nil end
    for index, chapter in ipairs(catalog or {}) do
        if chapter_uid(chapter) == uid then return index end
    end
    return nil
end

--- Computes the set of chapter uids that should be in the cache window
-- around `current_uid`, given `catalog` (ordered chapter list) and a
-- PREFETCH config table ({window_previous=N, window_current=N,
-- window_next=N}). Pure function, no I/O — this is what
-- ChapterCache:evict_outside_window's keep-set should be built from.
-- Returns an ordered list of uids and a set (uid -> true) for convenience.
function ChapterProvider.window_uids(catalog, current_uid, prefetch_config)
    local index = ChapterProvider.index_of(catalog, current_uid)
    local list, set = {}, {}
    if not index then
        if tostring(current_uid or "") ~= "" then
            list[1] = tostring(current_uid)
            set[tostring(current_uid)] = true
        end
        return list, set
    end
    local before = math.max(0, tonumber(prefetch_config and prefetch_config.window_previous) or 1)
    local after = math.max(0, tonumber(prefetch_config and prefetch_config.window_next) or 1)
    local first = math.max(1, index - before)
    local last = math.min(#catalog, index + after)
    for i = first, last do
        local uid = chapter_uid(catalog[i])
        if uid ~= "" then
            list[#list + 1] = uid
            set[uid] = true
        end
    end
    return list, set
end

--- The uid immediately after `current_uid` in `catalog`, or nil if it's
-- the last chapter or the catalog doesn't contain current_uid.
function ChapterProvider.next_uid(catalog, current_uid)
    local index = ChapterProvider.index_of(catalog, current_uid)
    if not index or not catalog[index + 1] then return nil end
    return chapter_uid(catalog[index + 1])
end

function ChapterProvider.previous_uid(catalog, current_uid)
    local index = ChapterProvider.index_of(catalog, current_uid)
    if not index or index <= 1 then return nil end
    return chapter_uid(catalog[index - 1])
end

--- Fast, no-network check: is this chapter already available to open
-- (cache hit or an existing deliberate-download variant covers it)?
-- Checks the lazy cache first, then falls back to any already-downloaded
-- standalone/range/full variant already tracked in store.lua, since a
-- book the user separately downloaded in full obviously doesn't need
-- re-fetching one chapter at a time.
function ChapterProvider:cached_path(book_id, uid)
    local cached = self.cache:get(book_id, uid)
    if cached then return cached, "lazy_cache" end
    -- store.lua's variant/chapter_variant records are never cleaned up by
    -- ChapterCache:evict_outside_window (that only removes this cache's own
    -- tracked files), so a record here can point at a file the window
    -- already evicted. Always verify on disk before trusting either path.
    local standalone = self.store:chapter_variant(book_id, uid, "clean")
    if standalone and standalone.file and U.file_exists(standalone.file) then
        return standalone.file, "chapter_variant"
    end
    for _, kind in ipairs({ "clean", "range_clean", "preview_clean" }) do
        local variant = self.store:variant(book_id, kind)
        if variant and variant.file and U.file_exists(variant.file) then
            -- A full/range/preview download only "contains" this chapter if
            -- its chapter_map says so; a plain file-exists check would
            -- wrongly claim every chapter is cached once any variant exists.
            for _, chapter in ipairs(variant.chapter_map or {}) do
                if chapter_uid(chapter) == tostring(uid) then return variant.file, kind end
            end
        end
    end
    return nil
end

--- The options table to pass to Downloader:book(book, opt, progress) to
-- fetch exactly one chapter as a standalone mini-EPUB. Reuses the exact
-- shape download_plan.lua already expects (opt.chapter_uid) — see
-- ARCHITECTURE_ANALYSIS.md §8 for why this is safe to call without
-- opt.previous_chapters (the superset/regression check in
-- EpubInstaller.validate is opt-in per call and this path never sets it).
function ChapterProvider.fetch_options(uid)
    return { chapter_uid = tostring(uid) }
end

--- After a successful Downloader:book() call for a single chapter,
-- records the result in the lazy cache (not in store.lua's variants —
-- see the module header). `record` is Downloader:book's return value.
function ChapterProvider:remember(book_id, uid, index, record)
    if not record or not record.file then return false, "no_file" end
    return self.cache:put(book_id, uid, index, record.file)
end

return ChapterProvider
