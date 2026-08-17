--[[--
SoweRead 章节坐标 HTML 统一入口。

这里故意把”坐标 HTML 的来源”与 PosMap 分开：
- 章节解码完成后的完整 XHTML（仅去 UTF-8 BOM）就是 coord_html。
- 不裁剪 body，不折叠空白，不改写实体/资源 URL，避免改变服务端字符坐标。
- 2026-08 真机诊断已用微信读书现有 range 对齐：完整 raw XHTML 与服务端坐标一致；
  body-inner 会丢失 head/body 前缀并造成整体前移。
--]]--

local PosMap = require(“soweread.textmap.posmap”)
local Runes = require(“soweread.textmap.runes”)

local Coord = {}

--- 章节解码结果 -> 服务端坐标 HTML。
-- 关键约束：保留完整 XHTML，只剥离 UTF-8 BOM。
-- 不能使用 Codec.body()，否则每章都会丢失长度不固定的 XML/head/body 前缀。
function Coord.fromDownloadedXhtml(xhtml)
    return Runes.stripLeadingBOM(tostring(xhtml or “”))
end

function Coord.build(coord_html)
    return PosMap.build(Coord.fromDownloadedXhtml(coord_html))
end

return Coord
