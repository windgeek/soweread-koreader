local U = require("soweread.util")
local PosMap = require("soweread.textmap.posmap")
local WRCo = require("soweread.wr_co")

local M = {}

local MAX_SOURCE_BYTES = 2 * 1024 * 1024

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end

local function chapter_uid(chapter)
    return scalar(type(chapter) == "table" and
        (chapter.chapterUid or chapter.uid or chapter.chapter_uid) or nil)
end

local function chapter_index(chapter, fallback)
    return tonumber(type(chapter) == "table" and
        (chapter.chapterIdx or chapter.index or chapter.chapter_index or chapter.chapter_idx) or nil)
        or tonumber(fallback or 0) or 0
end

local function chapter_words(chapter)
    if type(chapter) ~= "table" or chapter.structural == true then return 0 end
    return math.max(0, tonumber(chapter.wordCount or chapter.word_count or 0) or 0)
end

local function cache_root(reader)
    local store = reader and reader.store or nil
    local root = store and tostring(store.temp_dir or "") or ""
    if root == "" then return nil end
    return root .. "/progress-source-position"
end

local function cache_path(reader, book_id, uid, version)
    local root = cache_root(reader)
    if not root then return nil end
    local dir = root .. "/" .. U.id_name(tostring(book_id or "unknown"))
    U.mkdir(root)
    U.mkdir(dir)
    return dir .. "/" .. U.id_name(tostring(uid or "unknown"))
        .. "-v" .. U.id_name(tostring(version or 0)) .. ".xhtml"
end

local function read_cached(path)
    if not path then return nil end
    local size = U.file_size(path)
    if not size or size <= 0 or size > MAX_SOURCE_BYTES then return nil end
    local value = U.read_file(path, true)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

local function fetch_coord_html(reader, record, anchor)
    if not (reader and type(reader.chapter) == "function") then
        return nil, nil, "reader_chapter_unavailable"
    end
    record = type(record) == "table" and record or {}
    local book = type(record.book) == "table" and record.book or {}
    local uid = tostring(anchor.chapter_uid or "")
    if uid == "" then return nil, nil, "chapter_uid_missing" end

    local version = tonumber(anchor.book_version or book.version or book.bookVersion
        or (record.record and (record.record.book_version or record.record.bookVersion))) or 0
    local path = cache_path(reader, book.book_id or book.bookId, uid, version)
    local cached = read_cached(path)
    if cached then return cached, true end

    local chapter = {
        uid = uid,
        chapterUid = uid,
        chapterIdx = tonumber(anchor.chapter_index) or 0,
        index = tonumber(anchor.chapter_index) or 0,
        title = tostring(anchor.chapter_title or ""),
    }
    local book_arg = {
        bookId = tostring(book.book_id or book.bookId or ""),
        book_id = tostring(book.book_id or book.bookId or ""),
        title = book.title,
        author = book.author,
    }
    if book_arg.bookId == "" then return nil, nil, "book_id_missing" end

    local ok, downloaded, _, _, state = pcall(reader.chapter, reader,
        book_arg, chapter, "epub", {images=false})
    if not ok then return nil, nil, "coord_fetch_failed:" .. tostring(downloaded) end

    local coord_html = type(state) == "table" and tostring(state.coord_html or "") or ""
    if coord_html == "" then coord_html = tostring(downloaded or "") end
    if coord_html == "" then return nil, nil, "coord_html_missing" end
    if #coord_html > MAX_SOURCE_BYTES then return nil, nil, "coord_html_too_large" end

    if path then pcall(U.atomic_write, path, coord_html, true) end
    return coord_html, false
end

local function norm_count_before(map, text_boundary)
    local norm_map = type(map) == "table" and map.norm_map or nil
    if type(norm_map) ~= "table" or #norm_map == 0 then return nil end
    text_boundary = math.max(1, math.floor(tonumber(text_boundary) or 1))
    local lo, hi, found = 1, #norm_map, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if tonumber(norm_map[mid]) and norm_map[mid] < text_boundary then
            found = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

local function locate_anchor(map, anchor)
    local text = U.trim(tostring(anchor.anchor_text or ""))
    if text == "" then return nil, "anchor_text_missing" end
    local range_key, html_start, html_end_pos = PosMap.locate(map, text, {
        context_before = tostring(anchor.context_before or ""),
        context_after = tostring(anchor.context_after or ""),
    })
    if not range_key then return nil, tostring(html_start or "not_found") end
    local text_start, text_end_pos = PosMap.htmlToText(map, html_start, html_end_pos)
    if not text_start or not text_end_pos then return nil, "text_map_failed" end

    local point_side = tostring(anchor.point_side or "start")
    local boundary = point_side == "end" and text_end_pos or text_start
    local html_boundary = html_start
    local html_boundary_kind = "anchor_start"
    if point_side == "end" then
        -- Backward anchors end immediately before the current XPointer. A raw
        -- half-open HTML end can land on a closing tag, which Web Reader never
        -- exposes as a text `data-wr-co`. Prefer the next visible source rune;
        -- at chapter end fall back to the last visible anchor rune.
        local next_text
        for i = text_end_pos, #(map.text_runes or {}) do
            local r = map.text_runes[i]
            if r and not r:match("%s") and r ~= "*" then
                next_text = i
                break
            end
        end
        if next_text and map.text_to_html[next_text] then
            html_boundary = map.text_to_html[next_text]
            html_boundary_kind = "next_visible_text"
        else
            html_boundary = map.text_to_html[text_end_pos - 1] or html_end_pos
            html_boundary_kind = "last_visible_text"
        end
    end
    local norm_before = norm_count_before(map, boundary)
    local norm_total = type(map.norm_map) == "table" and #map.norm_map or 0
    if norm_before == nil or norm_total <= 0 then return nil, "normalized_text_missing" end

    return {
        range = range_key,
        html_start = html_start,
        html_end_pos = html_end_pos,
        text_start = text_start,
        text_end_pos = text_end_pos,
        text_boundary = boundary,
        html_boundary = html_boundary,
        html_boundary_kind = html_boundary_kind,
        norm_before = norm_before,
        norm_total = norm_total,
    }
end

function M.locate(reader, record, anchor)
    anchor = type(anchor) == "table" and anchor or {}
    local words = math.max(0, tonumber(anchor.chapter_word_count) or 0)
    local total_words = math.max(0, tonumber(anchor.total_word_count) or 0)
    local words_before = math.max(0, tonumber(anchor.words_before) or 0)
    if words <= 0 or total_words <= 0 then return nil, "catalog_word_counts_missing" end

    local coord_html, cache_hit, fetch_error = fetch_coord_html(reader, record, anchor)
    if not coord_html then return nil, fetch_error end
    local built_ok, map = pcall(PosMap.build, coord_html)
    if not built_ok or type(map) ~= "table" then
        return nil, "source_map_build_failed:" .. tostring(map)
    end

    local located, locate_error = locate_anchor(map, anchor)
    if not located then return nil, locate_error end

    local within = U.clamp(located.norm_before / located.norm_total, 0, 1)
    -- Keep the old word-space candidate only for progress/fallback diagnostics.
    -- Native Web Reader `co` is a raw source coordinate and is not bounded by
    -- chapter.wordCount.
    local source_word_offset = math.max(0, math.min(words, math.floor(words * within + 0.5)))
    local progress = U.clamp(((words_before + source_word_offset) / total_words) * 100, 0, 100)

    local native, native_error = WRCo.fromMap(map, located.html_boundary)
    local native_ok = type(native) == "table" and tonumber(native.co) ~= nil
    local offset = native_ok and math.max(0, math.floor(tonumber(native.co))) or source_word_offset

    return {
        progress = progress,
        chapter_uid = tostring(anchor.chapter_uid or ""),
        chapter_index = tonumber(anchor.chapter_index) or 0,
        offset = offset,
        chapter_offset = offset,
        chapter_word_count = words,
        total_word_count = total_words,
        words_before = words_before,
        chapter_percent = math.floor(within * 100 + 0.5),
        chapter_ratio = within,
        summary = tostring(anchor.chapter_title or ""),
        safe = true,
        precise = true,
        standalone = anchor.standalone == true,
        source = native_ok and "weread_native_wr_co" or "weread_source_anchor",
        position_basis = native_ok and "wr_data_co" or "weread_source_norm_anchor",
        offset_basis = native_ok and "wr_data_co" or "weread_source_norm_anchor",
        native_offset = native_ok,
        confidence = native_ok and "native" or "exact",
        source_cache_hit = cache_hit == true,
        source_html_start = located.html_start,
        source_html_boundary = located.html_boundary,
        source_html_boundary_kind = located.html_boundary_kind,
        source_text_start = located.text_start,
        source_text_boundary = located.text_boundary,
        source_norm_start = located.norm_before,
        source_norm_total = located.norm_total,
        source_word_offset = source_word_offset,
        source_wr_co = native_ok and offset or nil,
        source_wr_co_basis = native_ok and tostring(native.basis or "raw_xhtml_utf16") or nil,
        source_wr_co_rune_boundary = native_ok and tonumber(native.rune_boundary) or nil,
        source_wr_co_utf16_extra = native_ok and tonumber(native.utf16_extra) or nil,
        source_wr_co_error = native_ok and nil or tostring(native_error or "wr_co_unavailable"),
        precision_anchor = tostring(anchor.anchor_kind or "source_anchor"),
        precision_anchor_chars = tonumber(anchor.anchor_chars) or 0,
    }
end

return M
