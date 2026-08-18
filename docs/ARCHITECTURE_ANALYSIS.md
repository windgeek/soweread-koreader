# MiuRead Architecture Analysis (Phase 1)

Scope: `miuread.koplugin/` as of the current `main` branch (4.5.0). This document is pure analysis — no code was changed to produce it. All claims are cited `file:line`; anything the underlying code didn't make clear is flagged explicitly rather than guessed.

## 0. Executive summary — the most important finding

The problem statement assumes MiuRead is aggressively, autonomously downloading content in the background. **That is largely not true of the current code.** Concretely:

- Every chapter/book download is gated behind an explicit user action (a menu tap, a confirmed dialog). There is **no code path where opening or reading a book silently starts a multi-chapter download** (§4, §5).
- Download concurrency is already hard-capped at **one job system-wide**, and chapters within a job are fetched **strictly sequentially**, never in parallel (§5).
- `http.lua` already has real 429/403/"请求过快" detection, a fixed backoff schedule (`15s → 30s → 60s → 90s`, `http.lua:113`), a shared cross-process cooldown file, and a network-failure circuit breaker for downloads (§6).
- Downloads already checkpoint per-chapter to SQLite, already support pause/cancel/resume, and already yield to reader interaction ("Reading interaction always wins over background generation", `main.lua:9477-9480`) (§5).
- Suspend already soft-pauses the download job via a file marker; resume already waits ~3.5s and re-checks state before continuing rather than immediately resuming (§7).

**The actual root cause of the bad UX you're describing is narrower and more specific than "runaway background downloading":**

> Opening a book is an **all-or-nothing** decision. `main.lua` checks only "does a fully-built, complete EPUB file already exist on disk for this book?" (`main.lua:1891-1896`, `main.lua:6178-6184`). If not, the *only* thing on offer is "下载并阅读" (download & read) — which routes into the same full/range/single-chapter **download-and-build-a-complete-EPUB** pipeline used for deliberate offline downloads. There is no notion of "fetch just enough to read right now." (§4, §8)

So the redesign's job is not "add rate limiting to stop an existing runaway downloader" — most of that infrastructure already exists and is worth reusing almost as-is. The job is: **add a genuinely new, minimal "quick open" path that fetches only the current chapter (reusing the download pipeline's existing single-chapter/standalone-EPUB machinery), plus a new small prefetch/cache layer that is architecturally distinct from "download whole book."** That distinction does not exist in the code today (§10) and is the main net-new piece of engineering.

A secondary, real gap worth fixing regardless: the plugin runs **13 independent background `Async` workers** (covers, shelf, home metadata, search, etc., `main.lua:559-590`) that are not coordinated through the shared request-pacing mechanism (only annotation calls opt into `shared_pacing=true` today, `api.lua:184-212`). Nothing currently stops two of these, or one of these plus the download job, from hitting WeRead concurrently. This is the one place the current code is closer to the failure mode you're worried about (§6).

---

## 1. Module map

| Area | Files |
|---|---|
| Entry point / UI orchestration | `main.lua` (20,173 lines — this is where nearly all event wiring, menu callbacks, and the shelf→reader glue live) |
| Auth / session | `miuread/auth.lua`, `miuread/cookies.lua`, `miuread/legacy/cookie.lua` |
| WeRead HTTP transport | `miuread/http.lua` (modern, shared, rate-limit-aware), `miuread/legacy/client.lua` (older, no rate-limit handling, only used by the legacy read-report compatibility path) |
| WeRead API surface | `miuread/api.lua` (agent-gateway + web-cookie endpoints), `miuread/reader.lua` (chapter content, TOC, session bootstrap, progress reporting), `miuread/network_metadata.lua` (non-WeRead metadata enrichment) |
| Download subsystem | `miuread/download_task.lua` (subprocess lifecycle, pause/resume/cancel), `miuread/downloader.lua` (the actual fetch loop + checkpointing), `miuread/download_plan.lua` (chapter selection: single/range/full), `miuread/download_progress.lua` (UI), `miuread/download_database.lua` (SQLite checkpoint store), `miuread/download_result.lua` |
| EPUB build & install | `miuread/epub.lua` (zip/EPUB writer), `miuread/epub_installer.lua` (validate + atomic install/staging), `miuread/book_integrity.lua` (partial-book detection & repair), `miuread/footnotes.lua`, `miuread/internal_links.lua`, `miuread/resource_refs.lua` |
| Reader integration | `main.lua` (`_open_file_direct`, `open_file` — the actual KOReader `ReaderUI`/`switchDocument` calls), `miuread/precise_position.lua`, `miuread/reader_transition_guard.lua` |
| Cache / storage | `miuread/store.lua` (2182 lines — the central Lua-settings-backed metadata/TOC/variant store), `miuread/sqlite_store.lua` (generic KV store), `miuread/local_library.lua`, `miuread/local_metadata.lua`, `miuread/data_migration.lua`, `miuread/cache_cleanup_task.lua` |
| Sync / progress | `miuread/sync.lua` (3481 lines), `miuread/read_report_service.lua`, `miuread/legacy/read_report_worker.lua` |
| Async plumbing | `miuread/async.lua` (generic fork+poll), `miuread/wr_co.lua` |
| Annotations (Phase 2, out of scope) | `miuread/annotations.lua`, `miuread/annotation_sync.lua`, `miuread/local_annotation_database.lua`, `miuread/thoughts.lua`, `miuread/thought_database.lua` |

---

## 2. Current book-open flow

```
User taps a book card (home view or shelf view)
        │
        ▼
Plugin:_home_open_book(book, anchor)   [main.lua:6161]
  (legacy ShelfView path: Plugin:_shelf_select(b) [main.lua:1887], same logic)
        │
        ▼
record = self:_preferred_record(book_id)   [main.lua:13579]
  looks at store:book(id).variants / chapter variants,
  returns whichever has record.file set (prefers last_read_path)
        │
        ├── record.file exists on disk ───────────────► _open_file_direct(record.file) [main.lua:15119]
        │                                                       │
        │                                                       ▼
        │                                    ui:switchDocument(path)  OR
        │                                    ReaderUI:showReader(path)   [main.lua:15172-15181]
        │                                    (standard KOReader APIs, plain file path, no custom provider)
        │
        └── no local file ───────────────────► _show_home_book_open_popup(book, anchor) [main.lua:6140]
                                                        │  primary button: "下载并阅读"
                                                        ▼
                                                choose_download(...) → choose_download_mode(...)
                                                [main.lua:14872, 13974]
                                                        │
                                                        ▼
                                    DownloadTask:start()  →  ONE subprocess, ONE job [download_task.lua:1128]
                                          │
                                          ▼
                                    Downloader:book(id)  [downloader.lua:1071]
                                      1. catalog fetch (TOC)         — Reader:catalog  [reader.lua:814-824]
                                      2. FOR EACH selected chapter, SEQUENTIALLY:
                                           Reader:chapter(...)        — 2-4 HTTP shards [reader.lua:855-969]
                                           optional chapter image tar [reader.lua:913-916]
                                      3. repair_internal_links(all chapters)   [downloader.lua:726-788]
                                      4. ResourceRefs.prune(all chapters)      [downloader.lua:888]
                                      5. Epub.build(path, book, ALL chapters)  [epub.lua:205-299]
                                         — single-pass zip write, all chapters at once, no incremental append
                                      6. EpubInstaller.validate + install     [epub_installer.lua:221-372]
                                          │
                                          ▼
                                whole-book download does NOT auto-open (open_after=false at every
                                whole-book call site — main.lua:6153,7361,7462,13893,14623).
                                User must tap the book again; now step 1's disk check succeeds.
```

**Key fact for the redesign:** the "download" branch is not a bug bolted onto reading — it *is* the only content-acquisition path that exists today, for one chapter or the whole book alike. There is no separate, smaller "just get me chapter 10" code path independent of this pipeline. (There *is* a single-chapter/"standalone" mode of this same pipeline — see §8 — which is the reuse opportunity.)

---

## 3. Why tapping a book enters the download flow

Root cause, precisely: `main.lua:1891-1896` / `main.lua:6178-6184`:

```lua
local record = self:_preferred_record(id)
if record and record.file and U.file_exists(record.file) then
    self:_open_file_direct(record.file)
else
    self:_show_home_book_open_popup(book, anchor)   -- "下载并阅读"
end
```

This is a **binary, local-file-existence check**. There is no intermediate state such as "TOC is cached, chapter 1 could be fetched in under a second" — the code doesn't even know it doesn't need the whole book; it just knows no complete file exists, so it offers the only tool it has, which builds a complete file.

---

## 4. Auto-continuation / silent-download trigger audit

This was the most safety-critical question to answer precisely, so here is the full list of everything that starts or continues a download **without a fresh, current-action user tap**, and why each is safe:

| Mechanism | File:line | Why it's not "silent new download" |
|---|---|---|
| Queue auto-continuation | `_start_next_queued_download` `main.lua:14835` | Only dequeues jobs the user explicitly queued via `_queue_download` (`main.lua:14786`); queue capacity is hard-capped at 1 waiting job (`main.lua:14807-14814`, confirmed via dialog if replacing) |
| Auth-recovery auto-resume | `Plugin:on_auth_success` `main.lua:1373-1395` | Resumes only a download that failed specifically due to expired login, that the user had already explicitly started |
| Process reattachment after restart | `Plugin:_recover_download_state` `main.lua:14292`, `DownloadTask:attach` `download_task.lua:751` | Re-observes an already-running subprocess; never launches a new one |
| Repair flows | `_repair_partial_download` `main.lua:17077`, `_repair_downloaded_book` `main.lua:17137` | Always show a `ConfirmBox` ("开始修复") before calling `download()`, unless `confirmed==true` was already passed from a prior explicit tap |

**No chapter-ahead prefetching exists anywhere in the codebase.** A keyword search for `prefetch|preload|read_ahead|proactive` across `miuread/*.lua` returns zero matches outside UI button labels. Reading a downloaded EPUB is 100% local — KOReader's own document engine renders it; there is no per-page-turn network call of any kind.

---

## 5. Download subsystem internals (what to keep, mostly unchanged)

- **Concurrency**: exactly one download subprocess system-wide (`DownloadTask:start`/`:attach` refuse if `self.job` is set, `download_task.lua:827,752`). Inside a job, chapters are fetched with a plain sequential `for` loop (`downloader.lua:1631`), never in parallel. This already matches your `max_concurrency = 1` requirement — it is not configurable today (no such knob exists), but it also never violates it.
- **Checkpointing**: per-chapter progress lives in a SQLite manifest (`download.sqlite3`, `download_database.lua:8`) under `store:book_dir(id)/.miuread-partial-<option_key>/`. A resumed run reuses any already-`complete` chapter rather than refetching (`downloader.lua:1441-1538`). This is genuinely solid infrastructure and should not be rebuilt.
- **Pause/cancel/resume**: `DownloadTask:pause/resume` (`download_task.lua:177,190`) write reason-tagged flags to a shared marker file; `respect_reader_priority()` (`downloader.lua:1074-1115`) is checked *between* chapters (not mid-request) and busy-waits while paused. This is already exercised automatically whenever the reader/home UI is interacting (`main.lua:9477-9480`, "Reading interaction always wins over background generation") — i.e. **the "current reading always preempts background work" principle you're asking for is already implemented for the download subsystem.** It just doesn't exist yet for a lazy-chapter-cache subsystem, because that subsystem doesn't exist yet.
- **Network-failure circuit breaker**: 3 consecutive chapter-level network failures → `wait_for_network_recovery()` (`downloader.lua:1408`), polling every 6–15s (`config.lua:91-93`) until connectivity returns, then resumes from checkpoint. Distinct from rate-limit handling (see §6).
- **Process-kill resilience**: if the OS kills the subprocess outright, `DownloadTask:_restart_interrupted()` (`download_task.lua:537`) respawns from checkpoint, up to `DOWNLOAD_AUTO_RESTARTS=2` (`config.lua:84`).
- **What does NOT exist**: any concept of downloading only a *window* of chapters around the current reading position that can *shrink or shift* over time. The one selection mode close to this, chapter ranges (`download_plan.lua:39-71`), is explicitly *monotonically growing* — `existing_bounds`/`Plan.select` always widens `[first,last]` to a superset of any prior range (`download_plan.lua:50-52`), and `EpubInstaller.validate`'s `contains_all` check (`epub_installer.lua:252-256,275-279`) will *reject* a new build that drops chapters a prior version had, whenever a caller passes `opt.previous_chapters`. This is a deliberate regression guard for deliberate downloads and is correct behavior for that use case — but it means the existing "range" variant kind **cannot be reused unmodified as a sliding 3-chapter cache window** (§10 covers the implication for the new design).

---

## 6. Network/API layer — what exists, what's missing

**Transport**: `Http:request` (`http.lua:576`) is the practical convergence point for nearly all WeRead calls except the legacy compatibility-report path (`legacy/client.lua`, which has *no* rate-limit handling at all — only a bare `socket.sleep(0.3)` between requests, `legacy/client.lua:830-832`). There is no single mandatory choke point; `Reader`, `Api`, `mp.lua`, `network_metadata.lua`, `auth.lua`, `updater.lua` all call `self.http:*` directly.

**Rate-limit detection — already good, worth reusing almost as-is**:
- HTTP 429/499 recognized (`http.lua:606`), plus response-body sniffing for WeRead's own error codes/strings (`-10102`, `-2014`, "hit api rate limit", "too many requests", "rate limit", "请求频率超限", "请求频率受限" — `http.lua:94-111`).
- Backoff schedule: `RATE_LIMIT_DELAYS = {15, 30, 60, 90}` seconds (`http.lua:113`), honors server `Retry-After` header (`http.lua:624-625,636-637`), capped at 5 attempts.
- **Shared, cross-process cooldown**: once retries are exhausted, a cooldown is written to a shared JSON file (`_set_shared_rate_limit`, `http.lua:347`, default 300s, clamped 30–1800s) that *every other process* (a different chapter fetch, a restarted subprocess, another `Async` worker) consults at the top of every request (`http.lua:587-597`) before doing anything. This is very close to your "global RequestScheduler" ask — it's just currently scoped to rate-limit cooldown only, not general pacing/priority.
- Ordinary transient errors (408/425/500/502/503/504) get a *separate*, short retry ladder (`0.35 × 2^attempt`, capped 2.5s, max 2 retries) — the code already deliberately keeps rate-limit backoff and generic-error backoff separate, with an explicit comment that retrying 429/499 in the generic loop "only amplifies the request burst" (`http.lua:51-53`). Good existing judgment, keep it.

**Pacing — good primitive, under-applied**:
- `Http:_reserve_shared_pacing` (`http.lua:279-318`) enforces a minimum interval between requests **only when a caller passes `shared_pacing=true`**. Today only annotation read/write calls opt in (`api.lua:184-212`, e.g. `min_interval=4.25, pacing_jitter=0.35`). Chapter content, TOC, and book metadata calls do **not** opt in — they rely only on a per-process `min_weread_interval=0.35s` (`http.lua:126`), which does nothing to prevent two *different* processes/subprocesses from hitting WeRead at the same moment.
- This is the real concurrency gap: **13 independent `Async` instances** (`main.lua:559-590`, one each for covers, shelf, search, home metadata, etc.) plus the download subprocess plus the "interactive network" task (catalog fetch, single-slot, `main.lua:875-881`) are all capable of making WeRead requests, and nothing today prevents them from overlapping in time. In practice this is probably rare (a human triggers at most a couple of these per interaction), but it is not structurally prevented, and it's the one place closest to your stated failure mode ("请求过快").

**Auth/cookies — mature, do not touch without strong reason**: `cookies.lua` has a careful persistent-vs-transient boundary with protected-core cookie names (`cookies.lua:19-23,33-36`); `http.lua` and `reader.lua` both guard against cross-process staleness via a `login_session_id` stamp, discarding writes from a subprocess if the account changed underneath it (`http.lua:434,448`, `reader.lua:720-770`). Treat this as stable infrastructure; consume `Http.is_auth_error`/`is_rate_limit_error`/`is_forbidden_error` (`http.lua:789-794`) rather than reimplementing detection.

**Full chapter/content/TOC API call inventory** (for completeness — see the download-subsystem agent's table for the full list; the ones relevant to lazy-loading are):
- TOC: `POST /web/book/chapterInfos` — `reader.lua:814-824` (`Reader:catalog`)
- Chapter content (EPUB path): `POST /web/book/chapter/e_0,e_1,e_2,e_3` — `reader.lua:873-969` (`Reader:_epub_once`)
- Chapter content (TXT fallback): `POST /web/book/chapter/t_0,t_1` — `reader.lua:855-870`
- Chapter images: `chapter.tar` URL — `reader.lua:913-916`
- Session bootstrap (precondition for the above): `reader.lua:778-808` (`Reader:state`/`load_reader_context`)
- Progress report: `POST /web/book/read` — `reader.lua:1149-1154`

---

## 7. Suspend / Resume behavior

- **`onSuspend`** (`main.lua:19768-19846`): cancels the single "interactive network" task (`main.lua:19776`); soft-pauses the download job via a file marker (`DownloadTask:on_suspend`, `download_task.lua:228-233`) — this does **not** kill the subprocess or abort an in-flight HTTP request; the pause is only checked *between* chapters (`downloader.lua:1074-1109`). `Sync:on_suspend()` (`sync.lua:3263-3286`) does one best-effort final progress flush, exempt from any busy-wait, with **no retry** if it fails while offline (explicit comment: "Failed time is discarded and is never carried into the next session", `sync.lua:3283-3284`).
- **`onResume`** (`main.lua:19847-19954`): does **not** resume immediately. Schedules `download_task:on_resume()` **3.5s later** (`_schedule_download_resume_after_wake`, `main.lua:12454-12474`), re-checking and re-deferring if the device still looks suspended. `on_resume` clears only the `suspend` pause reason, explicitly preserving any manual/network/auth pause (`download_task.lua:236-238`) — i.e. it does not blindly un-pause everything. If the device slept ≥300s, `main.lua:19936-19952` waits for network (up to 75s poll) before re-verifying remote progress. **This is already very close to what you asked for in §10** (wake → wait for network → wait a bit → check state → resume only what's needed) — it just needs to be generalized to cover the new prefetch/cache subsystem, which doesn't exist yet.
- **Gap found**: if the OS actually kills the download subprocess during real hardware suspend (not just KOReader's suspend event), `onResume` only manipulates the pause-marker file — no code path was found that detects a dead PID and respawns the job. Recovery in that case appears to depend on the next explicit user action re-triggering `_recover_download_state`. Worth confirming with the original author or via testing; flagged here as unverified rather than assumed broken.
- **State tracking is scattered, not a formal state machine**: `Sync.state` is a free-form string set at ~30 call sites in `sync.lua`; the daemon subprocess (`read_report_service.lua`) tracks an overlapping but separate string state; there are at least three different "are we suspended" booleans (`main.lua`'s `_miuread_suspended` and `HOME_SESSION.suspended`, `sync.lua`'s `self.suspended`) that are synchronized manually rather than through one source of truth. This matches your ask for an explicit state machine (§20) — today there isn't one.

---

## 8. Can KOReader open content incrementally? (the central architectural question)

**No true incremental/streaming document exists today, and building one (Option C) would be new engineering with no reuse from the current code.** But there is a much better-than-expected middle ground already partially built.

**What's confirmed:**
- `Epub.build` (`epub.lua:205-299`) always writes a complete archive in one linear pass (`stream_zip`, `epub.lua:107-177`); there is no zip-append capability. Every rebuild — even adding one chapter — regenerates the whole file from scratch.
- KOReader is handed a plain file path via standard, unmodified APIs: `ui:switchDocument(path)` or `ReaderUI:showReader(path)` (`main.lua:15172-15181`). No custom `DocumentRegistry` provider is registered anywhere in the plugin (`local_metadata.lua:319-359` only *consumes* `DocumentRegistry:openDocument` for short-lived cover/metadata extraction, then closes the document).
- `switchDocument` is a teardown-and-rebuild operation, not a live patch — a comment in `main.lua:19089` describes both `reloadDocument()`/`switchDocument()` as setting `tearing_down=true`. When a newer version of the *currently open* book is built, it is staged as a `*.miuread-pending-*.epub` file (`downloader.lua:965-980`) and only installed after the reader closes that document (`main.lua:14667-14743`) — the live file is never touched mid-session.

**What's promising for reuse:**
- The download pipeline **already supports building a single-chapter, fully standalone EPUB** (`opt.chapter_uid`, `download_plan.lua:42-45`, `standalone = opt.chapter_uid ~= nil`, `downloader.lua:802`) and a **chapter-range EPUB** (`opt.range_start_index/range_end_index`, `download_plan.lua:46-61`). These are not toy features — they're a real, exercised part of the product (`chapter_menu`, `main.lua:15100-15117`). This means "build me a tiny EPUB containing just 1–3 chapters, quickly" is not new code — it's an existing, tested call shape into `Downloader:_save`/`Epub.build`/`EpubInstaller`.
- `EpubInstaller.validate`'s superset/regression check (`contains_all`, `epub_installer.lua:252-256`) is **opt-in per call** — it only runs when the caller passes `opt.previous_chapters` (`epub_installer.lua:275-279`). Deliberate range downloads pass this; a new lazy-cache path simply doesn't have to. So the low-level build/validate/install primitives can be reused for a *sliding* window without fighting the existing grow-only invariant, as long as the new code path uses its own option set and doesn't inherit `previous_chapters` from the download-plan code.
- `book_integrity.lua` already treats partial books as first-class, persistently tracked state (`M.inspect`, `book_integrity.lua:234-293`; `M.partial_repairs`, lines 203-232) — the concept of "this book only has some chapters, and that's fine" already exists in the data model, just not exposed as a fast-open path.
- `precise_position.lua` already reconciles a **local, partial** chapter map against the **full remote catalog** by chapter UID (`M.position_from_maps`, `precise_position.lua:97-143`) rather than by raw file-local page number. This is exactly the indirection needed so that bookmarks/highlights/reading position survive a document being rebuilt/swapped as the cache window slides.

**Real blockers to be aware of, not fatal but need explicit handling:**
- **Footnotes**: `Footnotes.fetch_missing_anchors` (`footnotes.lua:453-572`) will reach out over the network to *other* chapters when a footnote anchor isn't found locally, iterating the full catalog. In a small cache window, this could trigger extra fetches beyond the window if a footnote target lands in a not-yet-cached chapter. Needs an explicit policy (e.g., skip/defer unresolved footnotes rather than fetch outside the window) rather than being left to do whatever it currently does for full downloads.
- **Internal links**: `InternalLinks.build_index`/`rewrite_files_strict` (`internal_links.lua:235-256,575-640`) build a cross-file anchor index over the *whole batch being built*. For a 1–3 chapter window this is cheap and fine as long as it's scoped to the window (it already operates per-batch, not necessarily per-whole-book) — but it should be verified to degrade gracefully (rather than error) when a link's target chapter isn't in the current batch.

**Recommendation**: neither pure Option A (true incremental zip-append — real new engineering, `stream_zip` would need a rewrite) nor pure Option C (custom KOReader document provider — zero precedent in this codebase, highest-risk, least reuse) is the right fit. The pragmatic path is a **hybrid of A/B built on existing primitives**: keep building small, complete, standalone/range-style EPUBs (reusing `Epub.build`/`EpubInstaller` as-is) for a *sliding* 1–3-chapter window, and use the existing `switchDocument` call to move between windows at chapter-turn boundaries — a rebuild-and-swap, not a live patch, but scoped small enough (1–3 chapters, not the whole book) to be fast and to satisfy "read within seconds." This is detailed in `IMPLEMENTATION_PLAN.md`.

---

## 9. Storage/cache layer

- **Metadata/TOC/variant pointers**: one Lua-settings file (`DataStorage:getSettingsDir().."/miuread.lua"`, `store.lua:136-137`), read/written via `Store:get/set`. Not JSON, not SQLite.
- **Chapter content**: persists **only** inside a built EPUB zip. During an active download, raw per-chapter XHTML exists temporarily under `.miuread-partial-<option_key>/chapters/<uid>/` (`downloader.lua:398-479`) purely as a *resume checkpoint* — this directory is deleted on success (`U.remove_tree(cache.root)`, `downloader.lua:1817`) and is explicitly whitelisted for cleanup as disposable "download residue" (`cache_cleanup_task.lua:113-117`). **There is no persistent, standalone per-chapter cache today.**
- **No fast "is chapter N cached" query exists.** Only book-level (`Library:is_downloaded`, `library.lua:308-311`) and single-chapter-*variant* (`Store:chapter_variant`, `store.lua:1451`) lookups, both meaning "was this deliberately downloaded as a product," not "is this near my current reading position and quick to open."
- **"Cache" and "download" are the same concept in the code today.** This is the single biggest structural gap relative to what you're asking for: your requirement that these be "两个概念" (two concepts) is not yet true anywhere in the codebase and is the main new abstraction this redesign needs to introduce.
- **A pattern worth reusing for the new cache design**: each built EPUB embeds its own `OEBPS/miuread.json` (book id, chapter/TOC array, `core_map_hash`) as a self-contained source of truth, and `Store:restore_embedded_chapter_map` (`store.lua:1712-1768`) can rebuild the fast-access Lua-settings index from it if that index is ever lost. I.e., the existing design principle is "keep the durable artifact self-describing; treat the fast index as disposable/rebuildable." The new chapter-cache metadata should follow the same principle rather than being woven deeply into the main `variants` bookkeeping used by deliberate downloads.
- **Caution from history**: `data_migration.lua` and the schema-version history in `store.lua` (schema 1→112) show the team has repeatedly regretted embedding fine-grained per-file state (e.g., an early "access/ownership/lock" model) directly into library records, and later ripped it out entirely (`store.lua:624-687`, schema 43 comment: "removes local reading-rights validation completely"). **Lesson for this redesign: keep new cache-window state in its own small, droppable structure, not merged into the main `variants` map.**
- **Cleanup**: `cache_cleanup_task.lua` is on-demand only (invoked from a settings/cleanup UI with explicit paths and a policy mode); there is no automatic LRU/age-based eviction today. The new cache tier will need its own (simple) eviction policy — likely just "keep prev/current/next, delete anything else for this book" — driven by the prefetch manager itself rather than a generic background sweep.

---

## 10. Summary of gaps to fill (net-new engineering)

Everything below does **not** exist today and is what the redesign actually needs to build, as opposed to infrastructure that can be reused:

1. **Quick-open / lazy chapter path**: a way to open a book by fetching only its current chapter (reusing the existing standalone-EPUB build primitives), bypassing the "download whole book" popup entirely for the common case.
2. **ChapterCache**: a small, distinct-from-"download" concept — tracks a sliding window (prev/current/next, or configurable) of cached chapters per book, stored and evicted independently of the `variants`/deliberate-download bookkeeping in `store.lua`.
3. **PrefetchManager**: decides when it's safe to fetch the next chapter (≈70–80% through current chapter, no other network activity, not rate-limited, online, not suspended) and issues exactly one fetch, never recursively.
4. **RequestScheduler**: a real priority-aware scheduler (AUTH > READ > METADATA > SYNC > PREFETCH > DOWNLOAD) that all 13+ `Async` workers plus the download job plus the new prefetch/cache path route through, so cross-worker concurrency is actually bounded to 1 in practice, not just by convention. This generalizes the shared-pacing mechanism already in `http.lua` (currently opt-in, annotation-only) to be the default for every WeRead-bound call.
5. **Explicit network state machine** (IDLE/READING/PREFETCHING/DOWNLOADING/OFFLINE/BACKOFF/RATE_LIMITED/SUSPENDED) replacing the scattered string/boolean state in `sync.lua`/`main.lua`/`read_report_service.lua`, at least for the pieces this redesign touches.
6. **Generalized suspend/resume discipline** for the new prefetch/cache subsystem, mirroring what `download_task.lua` already does for downloads (soft-pause via marker, resume after a short delay + network re-check, never blindly resuming a large backlog).

Everything else — auth, cookies, checkpointed downloads, EPUB build/validate/install, rate-limit detection and backoff, the download pause/cancel/resume UI, progress-sync cadence and final-flush-on-close — is mature and should be reused with at most small, additive changes (e.g., extending the shared-pacing opt-in to more call sites; adding a `network` config table; making the existing `RATE_LIMIT_DELAYS` more conservative/configurable if desired).

See `IMPLEMENTATION_PLAN.md` for the concrete, file-by-file plan.
