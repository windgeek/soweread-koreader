# SoweRead · 轻松读

English | [中文](README.md)

An unofficial WeRead (微信读书, WeChat Reading) client for jailbroken Kindles running KOReader.

## Why this exists

Jailbreaking a Kindle and installing KOReader is usually about escaping the stock, bloated reading experience for something simpler. There are already a few ways to read WeRead books inside KOReader, but most of them bundle in a full feature set on top of reading — annotation sync, comments/thoughts, official-account (公众号) articles, full-text search. That's a lot of surface area, and in practice it often means tapping a book makes you wait for the *entire book* to download before you can start reading, and ordinary page-turning can quietly trigger background network requests. On a low-power, slow-refresh device like a Kindle, that's not a relaxed experience — and it makes WeRead's own "too many requests" rate limiting easier to trip.

SoweRead tries to do one thing well: **just reading, kept light**. Login, shelf, tap-to-read, offline caching, progress sync — that's the whole feature set. Tapping a book you've never opened shows its first page within seconds, not a download queue. Every network request is treated as a cost worth avoiding, not something to fire off eagerly.

## What this is

This project is forked from [MiuRead (觅阅)](https://github.com/miumiupy98-art/miuread-koreader), reusing its mature login flow, WeRead API integration, EPUB generation, and KOReader integration, with two deliberate changes:

- Removed annotation/highlight sync, thoughts/comments, official-account article reading, and full-text search — keeping only what pure reading needs.
- Redesigned how books open and chapters load: tapping a never-opened book no longer requires downloading the whole book first — it fetches only the current chapter and opens it within seconds, then quietly prefetches the next chapter as you approach the end of the current one. Full-book and chapter-range downloads are still available via long-press.
- Tightened network request pacing: single concurrency, shared cross-process throttling and backoff — the goal is fewer requests, not faster ones, to avoid triggering WeRead's rate limiting.

The design and current state are documented in [`docs/ARCHITECTURE_ANALYSIS.md`](docs/ARCHITECTURE_ANALYSIS.md) (a full trace of MiuRead's original architecture) and [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) (the new architecture's design).

## Installation

1. Download the latest stable `soweread-vX.Y.Z-full.zip` from [GitHub Releases](https://github.com/windgeek/soweread-koreader/releases).
2. Unzip it and place the full `soweread.koplugin` directory into KOReader's plugin directory (typically `koreader/plugins/`). If you previously had MiuRead installed (`miuread.koplugin`), remove it first to avoid the two plugins conflicting.
3. Fully restart KOReader (not just close and reopen — a real restart).
4. Open the plugin and scan the QR code to log in to your WeRead account. Future stable releases can be installed via the plugin's built-in updater.

## OTA update channel

The stable update manifest is generated automatically by GitHub Actions on release and published to a fixed `stable-channel` Release: `stable-channel/update.json`.

## Release process

- Stable tag: `vX.Y.Z`
- Stable release: a GitHub Release
- Version history: maintained in `CHANGELOG.md`
- Pushing a stable tag triggers GitHub Actions to validate the version, run a Lua 5.1 syntax check, build `full.zip`, verify its SHA-256 and public download URL, and update the fixed stable OTA manifest.
- The tag, the version in `soweread.koplugin/soweread/config.lua`, and the version in `soweread.koplugin/_meta.lua` must all match.

## Contributing

Bug reports, feature suggestions, and PRs are welcome — see [`CONTRIBUTING.en.md`](CONTRIBUTING.en.md). The project's scope is deliberately narrow: "just reading, kept light." Annotation sync, thoughts/comments, official-account articles, and full-text search were cut on purpose and aren't planned to come back — but changes that make the core experience more reliable, faster, or lighter on network usage are very welcome.

## Origin and license

SoweRead is forked from MiuRead (觅阅), which itself originated as a modified version of `finlater/weread.koplugin` v0.1.1, having undergone substantial restructuring, modification, and extension since.

SoweRead is an unofficial community project and is not affiliated with or endorsed by WeRead, Tencent, KOReader, or their maintainers.

This project is distributed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`). See `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES` for details.
