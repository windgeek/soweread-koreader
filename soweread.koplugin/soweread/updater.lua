local Config=require("soweread.config")
local Digests=require("soweread.digests")
local U=require("soweread.util")
local logger=require("logger")
local Updater={}; Updater.__index=Updater

function Updater:new(http,store,version,plugin_root)
    return setmetatable({http=http,store=store,version=version,plugin_root=plugin_root},self)
end

local function valid_https(url)
    return type(url)=="string" and url:match("^https://")~=nil
end

local function append_unique(out,seen,value)
    if valid_https(value) and not seen[value] then
        seen[value]=true
        out[#out+1]=value
    end
end

local function is_github_resource(url)
    if type(url)~="string" then return false end
    return url:match("^https://github%.com/")
        or url:match("^https://raw%.githubusercontent%.com/")
end

local function with_github_mirrors(url,out,seen)
    append_unique(out,seen,url)
    if not is_github_resource(url) then return end
    for _,prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
        if valid_https(prefix) then
            if prefix:sub(-1)~="/" then prefix=prefix.."/" end
            append_unique(out,seen,prefix..url)
        end
    end
end

function Updater:manifest_urls()
    local out,seen={},{}
    local configured=Config.UPDATE_MANIFESTS
    if type(configured)=="table" then
        for _,url in ipairs(configured) do with_github_mirrors(url,out,seen) end
    else
        with_github_mirrors(Config.UPDATE_MANIFEST,out,seen)
    end
    return out
end

function Updater:manifest_url()
    return self:manifest_urls()[1]
end

local function collect_table_urls(value,out,seen)
    if type(value)~="table" then return end
    for _,url in ipairs(value) do with_github_mirrors(url,out,seen) end
end

local function package_urls(manifest)
    local out,seen={},{}
    if type(manifest)~="table" then return out end
    with_github_mirrors(manifest.package_url or manifest.url,out,seen)
    collect_table_urls(manifest.package_urls,out,seen)
    collect_table_urls(manifest.mirror_urls,out,seen)
    collect_table_urls(manifest.mirrors,out,seen)
    return out
end

local function command_ok(rc)
    return rc==true or rc==0
end

local function file_bytes(path)
    local data=U.read_file(path,true)
    if type(data)~="string" then return nil end
    return data
end

local function update_artifact_kind(path)
    local name=tostring(path or ""):match("([^/]+)$") or ""
    if name:match("^stage%-") then return "stage" end
    if name:match("^backup%-") then return "backup" end
    if name:match("^soweread%-.+%.zip$") then return "package" end
    return nil
end

local function path_inside(root,path)
    root=tostring(root or ""):gsub("/+$","")
    path=tostring(path or "")
    return root~="" and path:sub(1,#root+1)==root.."/"
end

function Updater:_remove_download(path)
    if not path_inside(self.store.updates_dir,path) or update_artifact_kind(path)~="package" then return false end
    local removed,err=U.remove_tree(path)
    if not removed then
        logger.warn("[SoweRead][Updater] unable to remove update package",tostring(path),tostring(err))
        return false
    end
    return true
end

function Updater:_cleanup_update_artifacts(protected)
    protected=type(protected)=="table" and protected or {}
    local removed={stage=0,backup=0,package=0}
    for _,path in ipairs(U.list(self.store.updates_dir)) do
        local kind=update_artifact_kind(path)
        if kind and not protected[path] then
            local ok,err=U.remove_tree(path)
            if ok then
                removed[kind]=removed[kind]+1
            else
                logger.warn("[SoweRead][Updater] artifact cleanup failed",tostring(path),tostring(err))
            end
        end
    end
    if removed.stage+removed.backup+removed.package>0 then
        logger.info("[SoweRead][Updater] artifacts cleaned",
            "stage=",tostring(removed.stage),
            "backup=",tostring(removed.backup),
            "package=",tostring(removed.package))
    end
    return removed
end

local function clean_notes(value)
    local text=tostring(value or "")
    if not U.is_valid_utf8(text) or U.contains_replacement_char(text) then return nil end
    text=text:gsub("\r\n","\n"):gsub("\r","\n")
    -- Lua patterns operate on bytes, so a UTF-8 character class such as
    -- [•●▪◦] can corrupt unrelated multibyte text. Replace each symbol as a
    -- complete string instead.
    text=text:gsub("•","-"):gsub("●","-"):gsub("▪","-"):gsub("◦","-")
    text=text:gsub("：",":"):gsub("，",","):gsub("。","."):gsub("、",",")
    text=text:gsub("“",""):gsub("”",""):gsub("‘",""):gsub("’","")
    text=text:gsub("—","-"):gsub("–","-"):gsub("·","-")
    text=text:gsub("[%z\1-\8\11\12\14-\31]","")
    if not U.is_valid_utf8(text) or U.contains_replacement_char(text) then return nil end
    local lines={}
    for line in text:gmatch("[^\n]+") do
        line=line:gsub("^%s+",""):gsub("%s+$","")
        if line~="" then
            lines[#lines+1]=line
            if #lines>=4 then break end
        end
    end
    return table.concat(lines,"\n")
end

local function clean_manifest_text(m)
    local notes=m and m.notes~=nil and clean_notes(m.notes) or nil
    local summary=m and m.summary~=nil and clean_notes(m.summary) or nil
    local name=m and m.name~=nil and clean_notes(m.name) or nil
    if m and m.notes~=nil and notes==nil then return nil,"更新说明包含损坏的 UTF-8 文本" end
    if m and m.summary~=nil and summary==nil then return nil,"更新摘要包含损坏的 UTF-8 文本" end
    if m and m.name~=nil and name==nil then return nil,"更新名称包含损坏的 UTF-8 文本" end
    if summary=="" then summary=nil end
    return {notes=notes or "",summary=summary or notes or "",name=name}
end

local function validate_manifest(m)
    if type(m)~="table" or type(m.version)~="string" or m.version=="" then
        return nil,"更新清单缺少版本号"
    end
    local expected_channel=tostring(Config.UPDATE_CHANNEL or "stable")
    local manifest_channel=tostring(m.channel or "")
    if manifest_channel=="" and expected_channel=="stable" then manifest_channel="stable" end
    if manifest_channel~=expected_channel then
        return nil,"更新清单通道不匹配：当前为"..expected_channel.."，清单为"..(manifest_channel~="" and manifest_channel or "未标记")
    end
    if m.package_type~=nil and tostring(m.package_type)~="full" then
        return nil,"更新清单不是全量包"
    end
    if #package_urls(m)==0 then return nil,"更新清单缺少安装包地址" end
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then return nil,"更新清单缺少 SHA-256" end
    return true
end

function Updater:check()
    local urls=self:manifest_urls()
    if #urls==0 then return nil,"更新地址未配置" end
    local errors={}
    local fallback
    for _,url in ipairs(urls) do
        local ok,m=pcall(function()
            return self.http:get_json(url,{auth=false,retries=1,redirects=8,timeout={15,45}})
        end)
        if ok then
            local valid,reason=validate_manifest(m)
            if valid then
                local cleaned,text_error=clean_manifest_text(m)
                if not cleaned then
                    fallback=fallback or U.copy(m)
                    fallback.notes="更新说明显示异常 可继续下载安装"
                    fallback.summary=fallback.notes
                    fallback.name=tostring(m.name or "")
                    errors[#errors+1]=text_error
                    logger.warn("[SoweRead][Updater] manifest text rejected",url,
                        "replacement_chars=",tostring(U.replacement_char_count(m.notes or "")),
                        "reason=",tostring(text_error))
                else
                    m.notes=cleaned.notes
                    m.summary=cleaned.summary
                    if cleaned.name~=nil then m.name=cleaned.name end
                    logger.info("[SoweRead][Updater] manifest loaded",url,"version=",tostring(m.version),
                        "notes_utf8_valid=true")
                    if not U.semver_newer(m.version,self.version) then
                        return {current=true,version=m.version,name=m.name,notes=m.notes}
                    end
                    return m
                end
            else
                errors[#errors+1]=reason
            end
        else
            errors[#errors+1]=tostring(m)
            logger.warn("[SoweRead][Updater] manifest failed",url,tostring(m))
        end
    end
    if fallback then
        if not U.semver_newer(fallback.version,self.version) then
            return {current=true,version=fallback.version,name=fallback.name,notes=fallback.notes}
        end
        return fallback
    end
    return nil,errors[#errors] or "无法读取更新清单"
end

local function curl_download(url,path)
    local cmd="curl -L --fail --silent --show-error --connect-timeout 20 --max-time 180 -o "
        ..U.shell_quote(path).." "..U.shell_quote(url).." 2>/dev/null"
    logger.info("[SoweRead][Updater] curl fallback download",url)
    return command_ok(os.execute(cmd))
end

local function download_one(self,url,path)
    os.remove(path)
    local ok,data=pcall(function()
        return self.http:download(url,{auth=false,retries=2,redirects=10,timeout={20,150}})
    end)
    if ok and type(data)=="string" and #data>0 then
        local wrote,err=U.atomic_write(path,data,true)
        if not wrote then return nil,err or "无法保存更新包" end
        return true
    end
    logger.warn("[SoweRead][Updater] Lua download unavailable or empty; using curl",url,tostring(data))
    if curl_download(url,path) then return true end
    return nil,tostring(data or "下载失败")
end

function Updater:download(m)
    local pending=self.store:update_state()
    if pending.pending then error("上次更新尚未确认，请完整重启 KOReader 后再更新") end
    self:_cleanup_update_artifacts()
    local urls=package_urls(m)
    if #urls==0 then error("更新包地址无效") end
    local p=self.store.updates_dir.."/soweread-"..U.id_name(m.version)..".zip"
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then error("更新清单缺少 SHA-256") end
    local expected_size=tonumber(m.size or m.bytes or m.package_size)
    local last_error="下载失败"

    for index,url in ipairs(urls) do
        local downloaded,err=download_one(self,url,p)
        local raw=downloaded and file_bytes(p) or nil
        if type(raw)=="string" and #raw>0 then
            if expected_size and expected_size>0 and #raw~=expected_size then
                last_error="更新包大小不符"
                logger.warn("[SoweRead][Updater] size mismatch",url,"expected=",tostring(expected_size),"actual=",tostring(#raw))
            else
                local actual=Digests.sha256(raw):lower()
                if actual==expected then
                    logger.info("[SoweRead][Updater] package downloaded",
                        "source=",tostring(index),"bytes=",tostring(#raw),"version=",tostring(m.version))
                    return p
                end
                last_error="更新包校验失败"
                logger.warn("[SoweRead][Updater] sha256 mismatch",url)
            end
        else
            last_error=err or "更新包下载失败或文件为空"
        end
        os.remove(p)
    end
    error(last_error)
end

local function safe_relative(rel)
    if type(rel)~="string" or rel=="" or rel:sub(1,1)=="/" or rel:find("\\",1,true) then return nil end
    for part in rel:gmatch("[^/]+") do if part==".." or part=="." or part=="" then return nil end end
    return rel
end

function Updater:install(path,manifest)
    local pending=self.store:update_state()
    if pending.pending then
        self:_remove_download(path)
        return nil,"上次更新尚未确认，请完整重启 KOReader 后再更新"
    end
    self:_cleanup_update_artifacts({[path]=true})

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=self.store.updates_dir.."/stage-"..stamp
    local unpacked=stage.."/unpacked"
    local backup=self.store.updates_dir.."/backup-"..stamp
    U.remove_tree(stage); U.remove_tree(backup); U.mkdir(unpacked)

    local function fail(message)
        U.remove_tree(stage)
        U.remove_tree(backup)
        self:_remove_download(path)
        return nil,message
    end

    -- 全量包必须只包含一个 soweread.koplugin 根目录。
    local rc=os.execute("unzip -q "..U.shell_quote(path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
    if not command_ok(rc) then return fail("解压更新包失败") end

    local incoming=unpacked.."/soweread.koplugin"
    if not U.file_exists(incoming.."/main.lua") or not U.file_exists(incoming.."/_meta.lua") then
        return fail("更新包缺少 soweread.koplugin 或插件文件不完整")
    end
    local incoming_config=U.read_file(incoming.."/soweread/config.lua",true) or ""
    local incoming_version=incoming_config:match('VERSION%s*=%s*["\']([^"\']+)["\']')
    local incoming_channel=incoming_config:match('UPDATE_CHANNEL%s*=%s*["\']([^"\']+)["\']') or "stable"
    if tostring(incoming_version or "")~=tostring(manifest.version or "") then
        return fail("更新包版本与清单不一致")
    end
    if tostring(incoming_channel)~=tostring(Config.UPDATE_CHANNEL or "stable") then
        return fail("更新包通道不匹配，已拒绝安装")
    end
    local roots=U.list(unpacked)
    if #roots~=1 or roots[1]~=incoming then
        return fail("更新包根目录必须只包含 soweread.koplugin")
    end

    local ok,e=U.copy_tree(self.plugin_root,backup)
    if not ok then return fail("备份当前插件失败："..tostring(e)) end

    local function rollback(message)
        U.remove_tree(self.plugin_root)
        local restored,re=U.copy_tree(backup,self.plugin_root)
        U.remove_tree(stage)
        self:_remove_download(path)
        if not restored then
            return nil,tostring(message).."；回滚也失败："..tostring(re).."；备份已保留在 "..tostring(backup)
        end
        U.remove_tree(backup)
        return nil,tostring(message).."；已恢复旧版本"
    end

    U.remove_tree(self.plugin_root)
    local moved=os.rename(incoming,self.plugin_root)
    if not moved then
        local copied,ce=U.copy_tree(incoming,self.plugin_root)
        if not copied then return rollback("安装新文件失败："..tostring(ce)) end
    end
    if not U.file_exists(self.plugin_root.."/main.lua") or not U.file_exists(self.plugin_root.."/_meta.lua") then
        return rollback("安装后的插件文件不完整")
    end

    -- 兼容旧清单；全量替换通常不再需要 delete_list。
    if type(manifest.delete_list)=="table" then
        for _,rel in ipairs(manifest.delete_list) do
            rel=safe_relative(rel)
            if not rel then return rollback("delete_list 包含不安全路径") end
            local target=self.plugin_root.."/"..rel
            local removed=U.remove_tree(target)
            if removed==false then return rollback("无法删除旧文件："..rel) end
        end
    end

    U.remove_tree(stage)
    self.store:save_update_state({
        pending=true,
        expected=manifest.version,
        backup=backup,
        package=path,
        installed_at=os.time(),
    })
    logger.info("[SoweRead][Updater] update installed",
        "version=",tostring(manifest.version),
        "backup=",tostring(backup),
        "package=",tostring(path))
    return true
end

function Updater:startup()
    local s=self.store:update_state()
    if not s.pending then
        self:_cleanup_update_artifacts()
        return nil
    end

    if tostring(s.expected)==tostring(self.version) then
        if s.backup then U.remove_tree(s.backup) end
        if s.package then self:_remove_download(s.package) end
        self.store:save_update_state({})
        self:_cleanup_update_artifacts()
        logger.info("[SoweRead][Updater] update confirmed; rollback files removed",
            "version=",tostring(self.version))
        return "updated"
    end

    local protected={}
    if type(s.backup)=="string" and s.backup~="" then protected[s.backup]=true end
    if type(s.package)=="string" and s.package~="" then protected[s.package]=true end
    self:_cleanup_update_artifacts(protected)
    logger.warn("[SoweRead][Updater] update still pending",
        "expected=",tostring(s.expected),
        "running=",tostring(self.version))
    return "mismatch"
end

return Updater
