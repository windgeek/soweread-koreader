--[[--
Sliding chapter-window cache — deliberately distinct from a "download".

Per ARCHITECTURE_ANALYSIS.md: store.lua's `variants` map (used by
deliberate downloads) has a documented history of regretted fine-grained
state (schema bumped 112 times partly from over-embedding state there),
and its EpubInstaller.validate superset check assumes a variant only ever
grows. A sliding window needs to shrink/shift, so THIS module's own index
(window.json below) lives in its own path namespace and never writes to
`variants` itself.

One unavoidable interaction: the chapter file is built via the existing
Downloader:_save standalone-chapter path, which *always* also registers
it as a "clean" chapter_variant in store.lua (that behavior lives deep in
downloader.lua and was intentionally not touched further — see
chapter_provider.lua). So a lazily-fetched chapter is, unavoidably, also
a legitimate store.lua chapter_variant. When this module evicts a
chapter, it deletes the physical file and drops it from window.json, but
does NOT reach into store.lua to clear that now-stale chapter_variant
record — the existing store:prune_missing_files() sweep already exists to
clean up file records that no longer exist on disk, so this is consistent
with how the rest of the codebase already tolerates stale file references
rather than a new failure mode. Every caller that reads a path from
either index (this cache or store.lua's variants) must check the file
still exists before trusting it — see chapter_provider.lua:cached_path.

Layout:
    <data_dir>/cache/books/<book_id>/
        window.json                 -- {book_id, chapters:[{uid,index,file,built_at}]}
        chapter-<uid>.epub          -- one standalone mini-EPUB per cached chapter,
                                        built via the existing Downloader:_save
                                        standalone-chapter path (see chapter_provider.lua)

Eviction is synchronous and immediate: whenever the window slides, any
cached chapter file outside the new keep-set is deleted right away. At
the configured window size (previous=1, current=1, next=1) this is at
most 3 small files per book, so no background sweep is needed.
--]]--

local U = require("soweread.util")
local Json = require("soweread.json")

local ChapterCache = {}
ChapterCache.__index = ChapterCache

function ChapterCache:new(store)
    return setmetatable({ store = store }, self)
end

function ChapterCache:_root(book_id)
    local root = tostring(self.store.data_dir or "") .. "/cache/books/" .. U.id_name(book_id)
    U.mkdir(root)
    return root
end

function ChapterCache:_window_path(book_id)
    return self:_root(book_id) .. "/window.json"
end

function ChapterCache:_load_window(book_id)
    local raw = U.read_file(self:_window_path(book_id), true)
    if not raw then return { book_id = tostring(book_id), chapters = {} } end
    local ok, decoded = pcall(Json.decode, raw)
    if not ok or type(decoded) ~= "table" then return { book_id = tostring(book_id), chapters = {} } end
    decoded.chapters = type(decoded.chapters) == "table" and decoded.chapters or {}
    return decoded
end

function ChapterCache:_save_window(book_id, window)
    local ok, encoded = pcall(Json.encode, window)
    if not ok then return false, encoded end
    return U.atomic_write(self:_window_path(book_id), encoded, true)
end

function ChapterCache:_chapter_path(book_id, uid)
    return self:_root(book_id) .. "/chapter-" .. U.id_name(uid) .. ".epub"
end

--- Fast, no-network lookup: does a cached, on-disk file already exist for
-- this chapter? Returns the file path or nil. Callers must still
-- validate the file exists on disk before trusting it (window.json can
-- go stale if something else touched the cache dir).
function ChapterCache:get(book_id, uid)
    local window = self:_load_window(book_id)
    for _, entry in ipairs(window.chapters) do
        if tostring(entry.uid) == tostring(uid) then
            if entry.file and U.file_exists(entry.file) then return entry.file, entry end
            return nil
        end
    end
    return nil
end

function ChapterCache:has(book_id, uid)
    return self:get(book_id, uid) ~= nil
end

--- Records a freshly-built standalone chapter EPUB into the window index.
-- Does not itself evict anything — call evict_outside_window separately
-- once the caller knows the full new keep-set (prev/current/next uids),
-- so a slide never has a moment where the cache is inconsistent.
function ChapterCache:put(book_id, uid, index, file_path)
    local window = self:_load_window(book_id)
    local found = false
    for _, entry in ipairs(window.chapters) do
        if tostring(entry.uid) == tostring(uid) then
            entry.file = file_path
            entry.index = index
            entry.built_at = os.time()
            found = true
            break
        end
    end
    if not found then
        window.chapters[#window.chapters + 1] = {
            uid = tostring(uid), index = index, file = file_path, built_at = os.time(),
        }
    end
    window.book_id = tostring(book_id)
    return self:_save_window(book_id, window)
end

--- Deletes every cached chapter file not in `keep_uids` (a set: {uid=true, ...}).
-- Synchronous — the working set is at most a handful of small files.
function ChapterCache:evict_outside_window(book_id, keep_uids)
    keep_uids = keep_uids or {}
    local window = self:_load_window(book_id)
    local kept = {}
    for _, entry in ipairs(window.chapters) do
        if keep_uids[tostring(entry.uid)] then
            kept[#kept + 1] = entry
        elseif entry.file then
            os.remove(entry.file)
        end
    end
    window.chapters = kept
    return self:_save_window(book_id, window)
end

--- Removes the entire per-book cache directory (e.g. when the book is
-- deleted, or the user opens a different book and the previous one's
-- cache should not linger indefinitely). Safe to call even if nothing
-- was ever cached for this book.
function ChapterCache:clear(book_id)
    U.remove_tree(self:_root(book_id))
end

function ChapterCache:chapter_path_for_build(book_id, uid)
    return self:_chapter_path(book_id, uid)
end

return ChapterCache
