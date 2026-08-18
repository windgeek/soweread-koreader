# SoweRead · 轻松读

轻松读（SoweRead）是面向 KOReader 的非官方微信读书客户端，专注于"打开书 → 立刻开始读"这一件事：登录、书架、按章节按需加载、离线缓存、阅读进度同步。不包含批注/划线同步、想法/评论、公众号文章阅读、书内全文搜索等功能。

## 这是什么

本项目 fork 自 [MiuRead（觅阅）](https://github.com/miumiupy98-art/miuread-koreader)，在其成熟的登录、微信读书接口、EPUB 生成与 KOReader 集成基础上：

- 移除了批注、想法/评论、公众号文章、全文搜索等功能，聚焦纯阅读体验。
- 重新设计了打开书籍与加载章节的方式：点击一本从未打开过的书，不再要求先"下载并阅读"整本书，而是只取当前这一章，几秒内进入阅读；翻到章节末尾时才在后台悄悄预取下一章。全书/区间下载仍然保留，通过长按书籍进入。
- 收紧了网络请求节奏：单次并发、共享跨进程限流与退避，目标是"少请求"而不是"快请求"，避免触发微信读书的"请求过快"限制。

具体设计和现状记录在仓库内的 `ARCHITECTURE_ANALYSIS.md`（对 MiuRead 原有架构的完整分析）和 `IMPLEMENTATION_PLAN.md`（新架构设计）中。

## 安装

1. 在 GitHub Releases 下载最新正式版 `soweread-vX.Y.Z-full.zip`。
2. 解压后将完整的 `soweread.koplugin` 目录放入 KOReader 的插件目录。
3. 完整重启 KOReader。
4. 后续正式版可使用轻松读内置更新功能升级。

## OTA 更新通道

正式版更新清单由 GitHub Actions 在发布时自动生成，并发布到固定 `stable-channel` Release：`stable-channel/update.json`。

## Release 流程

- 正式 tag：`vX.Y.Z`
- 正式 Release：GitHub 正式 Release
- 版本记录：统一维护 `CHANGELOG.md`
- 创建正式 tag 后，GitHub Actions 自动校验版本、执行 Lua 5.1 语法检查、构建 full.zip、校验 SHA-256 与公开下载地址，并更新固定正式 OTA 清单。
- tag、`soweread.koplugin/soweread/config.lua` 与 `soweread.koplugin/_meta.lua` 中的版本必须一致。

## 来源与许可证

轻松读（SoweRead）fork 自 MiuRead（觅阅），而 MiuRead 本身是 `finlater/weread.koplugin` v0.1.1 的修改版本，经过大量重构、修改与扩展后发展而来。

轻松读是非官方社区项目，与微信读书、腾讯、KOReader 及其维护者均无关联，未获得其认可或授权。

本项目基于 GNU Affero General Public License version 3 only（`AGPL-3.0-only`）分发。详见 `LICENSE`、`NOTICE` 与 `THIRD_PARTY_NOTICES`。
