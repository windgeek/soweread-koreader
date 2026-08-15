local lfs = require("libs/libkoreader-lfs")

local LocalLibrary = {}

local SUPPORTED = {
    epub=true, pdf=true, mobi=true, azw=true, azw3=true, fb2=true,
    txt=true, html=true, htm=true, rtf=true,
    cbz=true, cbr=true, cb7=true, djvu=true, xps=true, oxps=true,
    md=true, chm=true,
}

local SKIP_DIRS = {
    ["."]=true, [".."]=true, [".sdr"]=true, [".git"]=true,
    ["koreader"]=true, ["plugins"]=true, ["extensions"]=true,
    ["system"]=true, ["linkss"]=true, ["fonts"]=true,
    ["screensaver"]=true, ["screensavers"]=true, ["thumbnails"]=true,
    ["cache"]=true, ["tmp"]=true,
}

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]+$") or ""
end

local function stem(path)
    local name=basename(path)
    return (name:gsub("%.[^%.]+$",""))
end

local function extension(path)
    return (tostring(path or ""):match("%.([%w]+)$") or ""):lower()
end

local function exists(path)
    return path and lfs.attributes(path,"mode")=="file"
end

local function cover_path(path)
    local dir=dirname(path)
    local base=stem(path)
    local candidates={
        dir.."/"..base..".sdr/cover.jpg",
        dir.."/"..base..".sdr/cover.jpeg",
        dir.."/"..base..".sdr/cover.png",
        path..".sdr/cover.jpg",
        path..".sdr/cover.jpeg",
        path..".sdr/cover.png",
        dir.."/"..base..".jpg",
        dir.."/"..base..".jpeg",
        dir.."/"..base..".png",
    }
    for _,candidate in ipairs(candidates) do
        if exists(candidate) then return candidate end
    end
    return nil
end

local function title_from_path(path)
    local title=stem(path)
    title=title:gsub("[_%-]+"," "):gsub("%s+"," ")
    title=title:gsub("^%s+",""):gsub("%s+$","")
    return title~="" and title or "未命名"
end

local function should_skip_dir(name, full, root)
    local lower=tostring(name or ""):lower()
    if lower:sub(1,1)=="." then return true end
    if SKIP_DIRS[lower] then return true end
    if lower:match("%.sdr$") then return true end
    -- When the KOReader home is /mnt/us, avoid descending into its runtime
    -- and support directories. User book folders remain visible.
    if root=="/mnt/us" and (lower=="kmc" or lower=="documents/.sdr") then return true end
    return false
end

local function should_skip_file(name)
    local lower=tostring(name or ""):lower()
    -- Hidden files created by macOS/Linux/Kindle support tools are never books
    -- even when their suffix looks like a supported reader format.
    if lower:sub(1,1)=="." then return true end
    if lower:sub(1,2)=="._" then return true end
    if lower:sub(-1)=="~" then return true end
    if lower:match("%.part$") or lower:match("%.tmp$") or lower:match("%.download$")
        or lower:match("%.crdownload$") then return true end
    return false
end


local function normalized_path(path)
    return tostring(path or ""):gsub("\\","/"):gsub("/+","/"):lower()
end

function LocalLibrary.is_likely_dictionary(path, title)
    local normalized=normalized_path(path)
    local ext=extension(path)
    if normalized:find("/dictionaries/",1,true) or normalized:find("/dictionary/",1,true)
        or normalized:find("/dict/",1,true) or normalized:find("/system/dictionaries/",1,true) then
        return true
    end
    -- Kindle dictionaries are commonly AZW/MOBI files placed among ordinary
    -- downloads. Restrict name-based filtering to those container formats so
    -- a normal EPUB whose title mentions a dictionary is not hidden by mistake.
    if ext=="azw" or ext=="azw3" or ext=="mobi" then
        local name=(tostring(title or "").." "..basename(path)):lower()
        for _,token in ipairs({"词典","字典","辞典","dictionary","thesaurus","lexicon"}) do
            if name:find(token,1,true) then return true end
        end
    end
    return false
end

function LocalLibrary.is_supported(path)
    return SUPPORTED[extension(path)]==true
end

function LocalLibrary.scan(root, options)
    options=options or {}
    root=tostring(root or "")
    local limit=math.max(1,tonumber(options.limit) or 800)
    local max_depth=math.max(0,tonumber(options.max_depth) or 8)
    local rows={}
    local visited={}
    local stopped=false

    local function walk(dir,depth)
        if stopped or depth>max_depth or visited[dir] then return end
        visited[dir]=true
        local ok,iter,state,var=pcall(lfs.dir,dir)
        if not ok or not iter then return end
        while true do
            local name=iter(state,var)
            var=name
            if not name then break end
            if name~="." and name~=".." then
                local full=(dir=="/" and "/"..name or dir.."/"..name)
                local attr=lfs.attributes(full)
                if attr and attr.mode=="directory" then
                    if not should_skip_dir(name,full,root) then walk(full,depth+1) end
                elseif attr and attr.mode=="file" and not should_skip_file(name) and LocalLibrary.is_supported(full) then
                    local title=title_from_path(full)
                    if options.include_dictionaries==true or not LocalLibrary.is_likely_dictionary(full,title) then
                    rows[#rows+1]={
                        file=full,
                        title=title,
                        author="",
                        format=extension(full):upper(),
                        size=tonumber(attr.size) or 0,
                        modified_at=tonumber(attr.modification) or 0,
                        cover_path=options.include_cover==true and cover_path(full) or nil,
                    }
                    if #rows>=limit then stopped=true; break end
                    end
                end
            end
        end
    end

    if lfs.attributes(root,"mode")=="directory" then walk(root,0) end
    table.sort(rows,function(a,b)
        local am,bm=tonumber(a.modified_at) or 0,tonumber(b.modified_at) or 0
        if am~=bm then return am>bm end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return {root=root,scanned_at=os.time(),books=rows,truncated=stopped==true}
end


function LocalLibrary.normalize(path)
    path=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    if #path>1 then path=path:gsub("/$","") end
    return path
end

function LocalLibrary.basename(path) return basename(LocalLibrary.normalize(path)) end
function LocalLibrary.dirname(path) return dirname(LocalLibrary.normalize(path)) end
function LocalLibrary.title_from_path(path) return title_from_path(path) end

-- Fast folder browsing: inspect only the selected directory itself. This never
-- descends into child folders and never opens book containers. The scanner can
-- run to completion in a subprocess or advance in small UI-thread batches on
-- devices where subprocess workers are unavailable.
local DirectoryScan={}
DirectoryScan.__index=DirectoryScan

function DirectoryScan:_close()
    if self._closed then return end
    self._closed=true
    pcall(function()
        if self.state and self.state.close then self.state:close() end
    end)
end

function DirectoryScan:cancel()
    self.cancelled=true
    self.done=true
    self:_close()
end

function DirectoryScan:_accept(name)
    if name=="." or name==".." then return end
    local full=(self.path=="/" and "/"..name or self.path.."/"..name)
    local attr=lfs.attributes(full)
    if attr and attr.mode=="directory" then
        if not should_skip_dir(name,full,self.path) then
            self.folders[#self.folders+1]={
                kind="folder",local_folder=true,title=name,
                path=full,folder_path=full,modified_at=tonumber(attr.modification) or 0,
            }
            self.seen=self.seen+1
        end
    elseif attr and attr.mode=="file" and not should_skip_file(name) and LocalLibrary.is_supported(full) then
        local title=title_from_path(full)
        if self.options.include_dictionaries==true or not LocalLibrary.is_likely_dictionary(full,title) then
            self.books[#self.books+1]={
                file=full,title=title,author="",format=extension(full):upper(),
                size=tonumber(attr.size) or 0,modified_at=tonumber(attr.modification) or 0,
                cover_path=self.include_cover and cover_path(full) or nil,
                local_file=true,source="local",
            }
            self.seen=self.seen+1
        end
    end
    if self.seen>=self.limit then
        self.truncated=true
        self.done=true
        self:_close()
    end
end

function DirectoryScan:step(batch_size)
    if self.done or self.cancelled then return true end
    batch_size=math.max(1,tonumber(batch_size) or 32)
    local processed=0
    while processed<batch_size and not self.done do
        local ok,name=pcall(self.iter,self.state,self.var)
        if not ok then
            self.error=tostring(name or "无法读取目录")
            self.done=true
            self:_close()
            break
        end
        self.var=name
        if not name then
            self.done=true
            self:_close()
            break
        end
        processed=processed+1
        self:_accept(name)
    end
    return self.done
end

function DirectoryScan:snapshot()
    if not self._sorted then
        table.sort(self.folders,function(a,b)
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        end)
        table.sort(self.books,function(a,b)
            local am,bm=tonumber(a.modified_at) or 0,tonumber(b.modified_at) or 0
            if self.options.sort=="name" then
                return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
            end
            if am~=bm then return am>bm end
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        end)
        self._sorted=true
    end
    return {
        path=self.path,scanned_at=os.time(),folders=self.folders,books=self.books,
        truncated=self.truncated==true,direct_count=#self.folders+#self.books,
        error=self.error,
    }
end

function LocalLibrary.new_directory_scan(path, options)
    options=options or {}
    path=LocalLibrary.normalize(path)
    local scanner=setmetatable({
        path=path,options=options,limit=math.max(20,tonumber(options.limit) or 1600),
        include_cover=options.include_cover==true,folders={},books={},seen=0,
        truncated=false,done=false,cancelled=false,
    },DirectoryScan)
    local ok,iter,state,var=pcall(lfs.dir,path)
    if not ok or not iter then
        scanner.done=true
        scanner.error=tostring(iter or state or "无法读取目录")
        return scanner
    end
    scanner.iter,scanner.state,scanner.var=iter,state,var
    return scanner
end

function LocalLibrary.list_directory(path, options)
    local scanner=LocalLibrary.new_directory_scan(path,options)
    while not scanner:step(256) do end
    return scanner:snapshot()
end

return LocalLibrary
