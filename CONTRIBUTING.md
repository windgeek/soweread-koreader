# Contributing to SoweRead

[English](CONTRIBUTING.en.md) | 中文

感谢你对轻松读感兴趣。这份文档说明这个项目的定位、来源，以及怎么参与。

## 项目定位

轻松读只想做好一件事：在越狱 Kindle + KOReader 上，安静地读微信读书的书。不做批注同步、想法评论、公众号文章、全文搜索——这是刻意的取舍，不是还没做完。如果你的 PR 是把这些功能加回来，大概率不会被合并；但如果是让"打开书、翻页、缓存、进度同步"这条主线更稳、更快、更省流量，非常欢迎。

## 来源与许可证

轻松读 fork 自 [MiuRead（觅阅）](https://github.com/miumiupy98-art/miuread-koreader)，而 MiuRead 本身是 `finlater/weread.koplugin` 的修改版本。项目基于 `AGPL-3.0-only` 分发——这意味着：

- 提交代码即表示你同意你的贡献以相同许可证发布。
- 任何基于本项目的再分发（包括修改版）也必须保持 AGPL-3.0-only 并保留 `NOTICE`/`THIRD_PARTY_NOTICES` 中的溯源信息。

我们认为坦诚说明代码的来龙去脉，比假装从零开始更值得信任。

## 怎么参与

- **报 bug**：用 Issue 模板，说明 KOReader 版本、设备型号、复现步骤。这是纯静态验证 + 用户真机测试的项目（见下），运行时问题的复现信息非常重要。
- **提功能建议**：先开 Issue 讨论，确认方向符合"只做阅读"这个定位，再动手写代码，避免白费功夫。
- **提 PR**：
  1. Lua 5.1 语法必须通过（`.github/workflows/release.yml` 会用真实 `luac5.1` 校验，不是 LuaJIT 近似替代）。
  2. 改动尽量小而聚焦，一个 PR 解决一件事。
  3. 涉及 `soweread/store.lua` 的 schema 迁移、`main.lua` 的核心生命周期方法时，请说明为什么必须改这里，而不是新开一个模块。
  4. 目前没有 KOReader 运行时或真机测试环境，静态语法检查通过后仍需要在真机上验证——PR 描述里请注明你是否在真机上跑过。

## 开发环境

这是一个 KOReader 插件（`.koplugin` 目录），用 Lua 5.1 编写。本地没有 KOReader 运行时的情况下：

```bash
docker run --rm -v "$(pwd):/repo" ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq lua5.1 && \
   find /repo/soweread.koplugin -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p"
```

这是和发布流水线一致的语法检查方式（LuaJIT 的 `loadfile` 曾经漏掉过一个真实的语法错误，不要用它替代）。

## 行为准则

保持友善、就事论事。分歧聚焦在技术方案上，不针对人。
