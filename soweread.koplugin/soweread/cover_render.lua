local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local M = {}

local function free(bb)
    if bb and type(bb.free) == "function" then pcall(bb.free, bb) end
end

local function file_mtime(path)
    return tonumber(lfs.attributes(tostring(path or ""), "modification") or 0) or 0
end

local function file_ok(path)
    return tostring(path or "") ~= "" and lfs.attributes(path, "mode") == "file"
end

local function load(path)
    if not file_ok(path) then return nil end
    local ok, image = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
    if not ok or not image then return nil end
    local w = tonumber(image:getWidth()) or 0
    local h = tonumber(image:getHeight()) or 0
    if w <= 0 or h <= 0 then free(image); return nil end
    return image, w, h
end

function M.lower_priority()
    -- Image conversion is intentionally background-only. Keep it below reader
    -- interaction and normal KOReader work on slower Kindle devices.
    pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[int setpriority(int which, int who, int prio);]]
        ffi.C.setpriority(0, 0, 19)
    end)
end

function M.best_source(paths)
    local best_path, best_area = nil, 0
    local seen = {}
    for _, raw in ipairs(paths or {}) do
        local path = tostring(raw or "")
        if path ~= "" and not seen[path] then
            seen[path] = true
            local image, w, h = load(path)
            if image then
                local area = w * h
                if area > best_area then
                    best_path, best_area = path, area
                end
                free(image)
            end
        end
    end
    return best_path, best_area
end

function M.is_fresh(target, source)
    if not file_ok(target) then return false end
    local tm = file_mtime(target)
    local sm = file_mtime(source)
    return tm > 0 and tm >= sm
end

local function write_png(canvas, target)
    local tmp = tostring(target) .. ".tmp"
    os.remove(tmp)
    local ok, err = pcall(canvas.writePNG, canvas, tmp)
    if not ok then os.remove(tmp); return nil, err end
    -- POSIX rename replaces the old file atomically. Keep the old cover visible
    -- until the new PNG is complete so the UI never observes a missing-image
    -- window (the checkerboard/blank-cover flash seen on Kindle).
    local renamed, rename_err = os.rename(tmp, target)
    if not renamed then
        -- Conservative fallback for filesystems that refuse replacement.
        os.remove(target)
        renamed, rename_err = os.rename(tmp, target)
    end
    if not renamed then os.remove(tmp); return nil, rename_err or "rename failed" end
    return target
end

-- High-quality edge-to-edge renderer. The source is scaled with KOReader's
-- normal RenderImage path, center-cropped, then receives only a small e-ink
-- ink-density boost. Expensive Lua per-pixel sharpening is deliberately
-- avoided so all of this remains safe for a low-priority subprocess.
function M.render_fill(source, target, width, height, options)
    options = options or {}
    width, height = tonumber(width) or 0, tonumber(height) or 0
    if width <= 0 or height <= 0 then return nil, "invalid target size" end
    local image, iw, ih = load(source)
    if not image then return nil, "cover decode failed" end

    local scaled, canvas
    local ok, result = xpcall(function()
        local scale = math.max(width / iw, height / ih)
        local sw = math.max(width, math.floor(iw * scale + 0.5))
        local sh = math.max(height, math.floor(ih * scale + 0.5))
        scaled = RenderImage:scaleBlitBuffer(image, sw, sh, false)
        if not scaled then error("cover scale failed") end
        canvas = Blitbuffer.new(width, height, scaled:getType())
        canvas:fill(Blitbuffer.COLOR_WHITE)
        local sx = math.max(0, math.floor((sw - width) / 2))
        local sy = math.max(0, math.floor((sh - height) / 2))
        canvas:blitFrom(scaled, 0, 0, sx, sy, width, height)
        local boost = math.max(0, math.min(.14, tonumber(options.ink_boost) or 0))
        if boost > 0 and type(canvas.darkenRect) == "function" then
            pcall(canvas.darkenRect, canvas, 0, 0, width, height, boost)
        end
        local path, err = write_png(canvas, target)
        if not path then error(err or "cover write failed") end
        return path
    end, debug.traceback)

    if scaled == image then scaled = nil end
    free(image)
    free(scaled)
    free(canvas)
    if not ok then
        logger.warn("[SoweRead][CoverRender] render failed", tostring(result))
        return nil, result
    end
    return result
end

-- Home thumbnails use a modest portrait target and a gentler boost. They are
-- rendered once in the background and then reused, keeping image conversion
-- completely off the home gesture path.
function M.render_home(source, target, width, height)
    return M.render_fill(source, target, width, height, {ink_boost = .035})
end

return M
