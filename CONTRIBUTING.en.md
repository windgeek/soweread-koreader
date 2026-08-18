# Contributing to SoweRead

English | [中文](CONTRIBUTING.md)

Thanks for your interest in SoweRead. This document explains what the project is for, where it comes from, and how to get involved.

## Project scope

SoweRead is trying to do one thing well: quietly read WeRead (微信读书) books on a jailbroken Kindle running KOReader. It deliberately does not do annotation sync, thoughts/comments, official-account (公众号) articles, or full-text search — that's an intentional cut, not an unfinished list. A PR that adds any of those back is unlikely to be merged; a PR that makes the core loop (open a book, turn pages, cache, sync progress) more reliable, faster, or lighter on network usage is very welcome.

## Origin and license

SoweRead is forked from [MiuRead (觅阅)](https://github.com/miumiupy98-art/miuread-koreader), which itself is a modified version of `finlater/weread.koplugin`. The project is distributed under `AGPL-3.0-only`, which means:

- By contributing code, you agree your contribution is released under the same license.
- Any redistribution of this project (including modified versions) must also stay AGPL-3.0-only and preserve the provenance chain documented in `NOTICE`/`THIRD_PARTY_NOTICES`.

We think being upfront about where the code came from is more trustworthy than pretending this started from scratch.

## How to contribute

- **Bug reports**: use the issue template, and include your KOReader version, device model, and reproduction steps. This project is verified statically and by the maintainer's own device — reproduction details matter a lot for runtime issues.
- **Feature requests**: open an issue first to confirm the idea fits the "just reading" scope before writing code, so effort isn't wasted.
- **Pull requests**:
  1. Must pass Lua 5.1 syntax checks (the release workflow uses real `luac5.1`, not a LuaJIT approximation).
  2. Keep changes small and focused — one PR, one concern.
  3. If your change touches `soweread/store.lua`'s schema migration or a core lifecycle method in `main.lua`, explain in the PR why it has to live there rather than in a new module.
  4. There's no KOReader runtime or physical device available for CI — a passing syntax check still needs on-device verification. Note in the PR whether you tested on real hardware.

## Development environment

This is a KOReader plugin (a `.koplugin` directory) written in Lua 5.1. Without a local KOReader runtime, verify syntax the same way the release pipeline does:

```bash
docker run --rm -v "$(pwd):/repo" ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq lua5.1 && \
   find /repo/soweread.koplugin -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p"
```

(A LuaJIT-based `loadfile` check once missed a real syntax error that `luac5.1` caught — don't substitute it.)

## Code of conduct

Be kind, keep disagreements about the technical approach, not the person.
