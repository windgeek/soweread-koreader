# MiuRead Implementation Plan (Phase 1)

Prerequisite reading: `ARCHITECTURE_ANALYSIS.md`. This plan follows directly from its §10 gap list. Nothing here has been implemented yet — this is for review before any code is written, per your instructions.

## Design principles (restated as constraints on every new module below)

1. **Read first, download later.** Opening a book fetches at most the current chapter.
2. **Fewer requests beats faster requests.** No new code path is allowed to raise concurrency above 1 for WeRead-bound requests, ever, even opportunistically.
3. **Cache ≠ Download.** The new chapter cache is small, evictable, and slides with reading position. Deliberate downloads remain a separate, unchanged, user-initiated concept.
4. **Reuse existing, hardened infrastructure wherever the code already does the right thing** (auth, cookies, EPUB build/validate/install, checkpointing, rate-limit backoff, download pause/cancel/resume, per-chapter API calls). Do not rewrite anything in `ARCHITECTURE_ANALYSIS.md` §5–§7 that already behaves correctly — wrap and reuse it.
5. **Reading always preempts background work** — this principle already exists for downloads (`main.lua:9477-9480`) and must be extended, not reinvented, for prefetch/cache.

---

## Target architecture (delta only — everything not mentioned is unchanged)

```
                         ┌─────────────────────────────┐
                         │      RequestScheduler        │  (NEW)
                         │  priority queue, 1 in-flight  │
                         │  AUTH>READ>METADATA>SYNC>     │
                         │  PREFETCH>DOWNLOAD            │
                         └───────────────┬───────────────┘
                                          │ all WeRead-bound calls route through here
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
            existing Http:request   existing download job   existing 13 Async
            (auth, TOC, chapter,    (unchanged internals,    workers (covers,
            metadata, sync calls)   just now scheduled       shelf, search, …)
                    │               as DOWNLOAD priority)            │
                    └─────────────────────┴─────────────────────────┘
                                          │
                              existing http.lua rate-limit
                              detection + backoff (reused as-is)

Tap book
   │
   ▼
_home_open_book / _shelf_select  (main.lua — MODIFIED)
   │
   ├── local file already exists ──────────────► open exactly as today (unchanged)
   │
   └── no local file ──► ChapterProvider:open_current(book)   (NEW)
                             │  READ-priority request via RequestScheduler:
                             │  1. TOC (reuses Reader:catalog)
                             │  2. current chapter only, standalone-EPUB shape
                             │     (reuses Downloader:_save / Epub.build / EpubInstaller,
                             │      NOT the whole-book pipeline)
                             ▼
                        ChapterCache:put(book_id, chapter)      (NEW)
                        writes into its own path namespace,
                        own tiny index — NOT store.lua `variants`
                             │
                             ▼
                        open the resulting mini-EPUB via the SAME
                        _open_file_direct → switchDocument/showReader
                        call already used today

While reading:
   PrefetchManager (NEW) watches page position via existing onPageUpdate hook
   → at ~70-80% through current chapter, if RequestScheduler is idle and
     network state machine is not BACKOFF/RATE_LIMITED/OFFLINE/SUSPENDED:
     issue exactly ONE PREFETCH-priority fetch for next chapter into ChapterCache
   → never recurses, never fetches N+2

On chapter turn:
   ChapterProvider checks ChapterCache first (no network call if hit)
   → cache hit: switchDocument to the (rebuilt, still small) window EPUB
   → cache miss: same as "open_current" above, READ priority (jumps the queue
     ahead of any in-flight PREFETCH)
   → ChapterCache evicts anything outside [prev, current, next]
```

---

## New files

### `miuread/network/request_scheduler.lua`
**What**: a thin priority queue sitting in front of `Http:request`. Not a new transport — it decides *when* a queued call is allowed to fire, then delegates to the existing `Http`/`Reader`/`Api` call. Enforces global `max_concurrency = 1` for WeRead-bound calls (closing the gap in ARCHITECTURE_ANALYSIS.md §6: today's 13 `Async` workers + download job + interactive-network task are not mutually coordinated).
**Why new, not reused**: nothing like this exists. The closest thing, `Http:_reserve_shared_pacing` (`http.lua:279-318`), is a minimum-interval gate, not a priority scheduler, and is opt-in per call site today.
**Reuses**: `http.lua`'s shared-pacing file-lock primitive as its cross-process coordination mechanism (same file-based approach the codebase already trusts for the rate-limit cooldown), rather than inventing a new IPC mechanism.
**Priorities**: `AUTH=1, READ=2, METADATA=3, SYNC=4, PREFETCH=5, DOWNLOAD=6` (lower fires first; a lower-priority request already in flight is *not* preempted mid-flight — same non-preemptive discipline the download loop already uses between chapters).

### `miuread/network/backoff.lua`
**What**: extracts the rate-limit detection + backoff schedule currently inlined in `http.lua` (`RATE_LIMIT_DELAYS`, `body_rate_limit`, shared-cooldown read/write) into a standalone, reusable module, so `ChapterCache`/`PrefetchManager` can consult "are we currently in backoff" without depending on `Http` internals.
**Why**: `ARCHITECTURE_ANALYSIS.md` §6 confirms this logic is already good — this is a refactor-for-reuse, not new logic. The actual delay values (15/30/60/90s) and detection strings stay unchanged unless you want them more conservative (see "Open questions" below).
**Risk note**: this is the one file where "minimal invasive" is in tension with "clean architecture" — `http.lua` is 796 lines and already deeply tested in production. Extracting logic risks subtle behavior changes. Recommend: `backoff.lua` wraps/delegates to `http.lua`'s existing functions rather than duplicating them, so `http.lua` keeps working exactly as today for every existing caller, and only new callers (ChapterCache, PrefetchManager) go through the new thin wrapper.

### `miuread/network/network_state.lua`
**What**: the explicit state machine from `ARCHITECTURE_ANALYSIS.md` §10.5 — `IDLE / READING / PREFETCHING / DOWNLOADING / OFFLINE / BACKOFF / RATE_LIMITED / SUSPENDED`. Single source of truth, replacing the scattered booleans this redesign's new code would otherwise need to invent its own copies of.
**Scope discipline**: this plan does **not** propose ripping out and replacing `Sync.state` or `download_task.lua`'s existing flags (that's a much bigger, riskier change for marginal benefit given those subsystems already work). `network_state.lua` is authoritative only for the *new* subsystems (ChapterCache/PrefetchManager/RequestScheduler); it observes suspend/resume/network-connectivity events the same way `download_task.lua` already does, via the same hooks.

### `miuread/reader/chapter_provider.lua`
**What**: the "open exactly what I need to read right now" entry point. `ChapterProvider:open_current(book)`, `ChapterProvider:open_chapter(book, uid)`. Internally:
- Calls `Reader:catalog` for TOC if not already cached (reuses `reader.lua:814-824` unchanged).
- Builds a minimal EPUB via the **existing** `Downloader:_save` standalone-chapter code path (`downloader.lua`, `opt.chapter_uid` shape from `download_plan.lua:42-45`), but invoked directly for one chapter rather than via the full download-menu UI, and **without** `opt.previous_chapters` (so `EpubInstaller`'s superset/regression guard, `epub_installer.lua:252-256,275-279`, does not apply — confirmed opt-in per `ARCHITECTURE_ANALYSIS.md` §8).
- Hands the result to `ChapterCache:put`.
- Opens via the same `_open_file_direct`/`switchDocument` call `main.lua` already uses (`main.lua:15172-15181`) — no new KOReader integration code.
**Why new**: this exact "just the current chapter, right now, blocking the UI minimally" call shape doesn't exist — today the only entry points are the full download-menu flow (`choose_download_mode`) which always frames itself as a deliberate, dialog-confirmed action.

### `miuread/reader/prefetch_manager.lua`
**What**: owns the "≈70-80% through chapter → prefetch next" trigger. Hooks the existing `Plugin:onPageUpdate` (`main.lua:19400-19410`) the same way `Sync:on_page` already does, computes percentage-through-chapter, and if the network state machine allows it, submits exactly one `PREFETCH`-priority request via `RequestScheduler` for the next chapter only. Explicitly refuses to submit a second prefetch until the first completes and the user has advanced into that chapter (prevents any recursive/cascading fetch by construction — there is deliberately no "if prefetch succeeds, prefetch the one after" code path).
**Suspend/resume discipline**: mirrors `DownloadTask:on_suspend/on_resume` (`download_task.lua:228-240`) — on suspend, cancel any in-flight or scheduled prefetch outright (unlike downloads, a prefetch is cheap to redo and has no checkpoint worth preserving mid-flight); on resume, wait for the same "network back + short delay + not rate-limited" sequence `main.lua`'s `onResume` already implements for downloads (`main.lua:12454-12474`), then at most re-evaluate whether the *current* chapter still needs it — never resume a queue of anything, because no queue of prefetches is ever allowed to exist in the first place (single-slot by design).

### `miuread/cache/chapter_cache.lua`
**What**: the "cache ≠ download" distinction from `ARCHITECTURE_ANALYSIS.md` §9/§10. Tracks, per book, a small sliding window of cached chapter files (default: prev=1, current=1, next=1, all configurable) in **its own path namespace and its own tiny index**, deliberately kept out of `store.lua`'s `variants` map (per the migration-history caution in §9 — that map has a documented history of regretted fine-grained state).
**Storage layout**:
```
<data_dir>/cache/books/<book_id>/
    window.json          -- {book_id, chapters: [{uid, index, file, built_at}], catalog_signature}
    chapter-<uid>.epub    -- the actual small EPUB(s) built by ChapterProvider
```
This intentionally does **not** reuse `store:book_dir()`/`.miuread-partial-*` (that's the deliberate-download checkpoint area, already governed by different invariants) and does **not** reuse `books_root()`/`epub_root()` (the user-visible documents folder for deliberate downloads) — keeping this fully separate is what makes "cache vs download are two concepts" actually true in the filesystem, not just in naming.
**Eviction**: on window slide, delete any chapter file outside `[prev,current,next]` immediately (simple, synchronous, no background sweep needed at this scale — 1-3 small files per book). No LRU/age policy needed for Phase 1 given the tiny working set; can be added later if multi-book concurrent caching turns out to need it.
**API**: `ChapterCache:get(book_id, uid)` → file path or nil (fast, no network); `ChapterCache:put(book_id, uid, built_epub_path)`; `ChapterCache:evict_outside_window(book_id, keep_uids)`.

### `miuread/download/download_manager.lua` (thin wrapper, not a rewrite)
**What**: per your §22 target structure, this is a thin facade over the *existing* `download_task.lua`/`downloader.lua` that simply routes their requests through the new `RequestScheduler` at `DOWNLOAD` priority instead of calling `Http` directly. This is the minimal change needed to make "reading always preempts everything, including full-book downloads" globally true instead of true-only-within-the-download-subsystem (which is already the case today per §5, so this is closing the loop, not fixing a bug).
**Explicitly not changed**: chapter selection (`download_plan.lua`), checkpointing (`download_database.lua`), pause/cancel/resume UI, EPUB build/validate/install, retry/backoff internals. All of `ARCHITECTURE_ANALYSIS.md` §5's "already good" list stays as-is.

### `miuread/sync/progress_sync.lua` (thin wrapper, not a rewrite)
**What**: routes `sync.lua`'s existing report calls through `RequestScheduler` at `SYNC` priority (lowest priority above prefetch/download), so an in-flight progress upload never blocks a `READ`-priority chapter fetch. Everything else — the 60s interval daemon, the debounced control-file writes, the suspend/close final-flush behavior — is unchanged; `ARCHITECTURE_ANALYSIS.md` §7 already found this mostly sound, aside from the one real gap noted below.
**One real fix bundled here**: §7 found that a suspend/close final-flush can silently lose its data if offline, with no retry (`sync.lua:3283-3284`, by design today — "discarded and never carried forward"). Given you explicitly asked for offline progress to be queued and retried post-reconnect (your §16), this file adds a **local pending-flush record** (one small JSON file, last-known-unsynced elapsed+position) that `Sync:on_resume`/network-reconnect checks once and retries at `SYNC` priority, then discards. This is the only place in this plan that changes existing sync *behavior* rather than just its request routing — flagged explicitly for your review since it's a deliberate deviation from current behavior.

---

## Modified files

| File | Change | Reason |
|---|---|---|
| `main.lua:1891-1896`, `main.lua:6178-6184` (`_shelf_select`, `_home_open_book`) | When no local file exists, call `ChapterProvider:open_current(book)` (showing "正在加载当前章节…") instead of unconditionally showing the download popup. The full download popup remains reachable (e.g. long-press → book menu) for users who explicitly want a full/range download. | This is the actual fix for your core complaint — the tap-to-read path stops being all-or-nothing. |
| `main.lua:19400-19410` (`onPageUpdate`) | Add a call to `PrefetchManager:on_page(page)` alongside the existing `self.sync:on_page(page)` call. | Wires the 70-80%-through-chapter trigger without touching the existing progress-sync wiring. |
| `main.lua:19768-19846` / `19847-19954` (`onSuspend`/`onResume`) | Add `prefetch_manager:on_suspend()` / `:on_resume()` calls alongside the existing `download_task:on_suspend/on_resume` calls. | Extends the already-correct suspend/resume discipline to the new subsystem instead of leaving it unmanaged. |
| `miuread/http.lua` | No behavioral change. Optionally: expose the rate-limit/backoff internals it already has as named exports so `backoff.lua` can wrap them cleanly (may already be sufficiently exposed via `Http.is_rate_limit_error` etc. — verify during implementation before adding anything). | Enables reuse without duplication. |
| `miuread/api.lua` | No behavioral change to existing calls. New chapter/TOC calls issued by `ChapterProvider` go through `RequestScheduler` instead of calling `Http`/`Reader` directly — this is new call sites, not edits to existing ones. | Keeps every existing caller's behavior identical; only new code adopts the new scheduler. |
| `miuread/config.lua` | Add one new table (see below), following the file's existing flat-constant style. | Centralizes the tunables you asked for instead of scattering them. |
| `miuread/store.lua` | No schema change to `variants`/`chapters`. Optionally add a narrow accessor for `ChapterCache` to read `book.catalog`/chapter UIDs it already needs (read-only), if `ChapterCache` can't get what it needs from `Reader:catalog` alone. | Avoids the "regretted fine-grained state in library records" trap noted in §9 — new cache state stays entirely in `chapter_cache.lua`'s own files. |

---

## Config additions (`miuread/config.lua`)

Following the file's existing idiom (flat table, grouped by comment, e.g. the `DOWNLOAD_NETWORK_*` block already there):

```lua
NETWORK = {
    min_request_interval = 2.5,   -- seconds, baseline pacing for READ/PREFETCH/METADATA
    jitter = 0.5,                 -- +/- random jitter added to min_request_interval
    max_concurrency = 1,          -- hard cap, not user-configurable in UI, exists so it's
                                   -- not a magic number buried in request_scheduler.lua
},

PREFETCH = {
    trigger_percent = 0.75,       -- start next-chapter prefetch at 75% through current chapter
    window_prev = 1,
    window_current = 1,
    window_next = 1,
},

RATE_LIMIT_BACKOFF = {
    -- NOTE: http.lua's existing RATE_LIMIT_DELAYS = {15,30,60,90} already does this.
    -- Only add this table if you want Phase 1 to start MORE conservative than the
    -- existing production values (your prompt's example was 30/60/120/300).
    -- Recommendation: keep http.lua's existing schedule unless real-device testing
    -- shows 15s-first-retry is still too aggressive. Changing this affects every
    -- existing caller of Http:request, not just the new subsystems -- treat as a
    -- separate, deliberate decision, not a drive-by tweak.
},
```

The `RATE_LIMIT_BACKOFF` block is intentionally left as a decision point rather than a default — see "Open questions" below.

---

## Phasing (matches your §17 split)

**Phase 1** (this plan): `RequestScheduler`, `backoff.lua` (wrapper), `network_state.lua`, `ChapterProvider`, `PrefetchManager`, `ChapterCache`, the `_shelf_select`/`_home_open_book` tap-to-read change, suspend/resume wiring for the new subsystems, `download_manager.lua`/`progress_sync.lua` thin wrappers, config additions, mocked-API test suite.

**Phase 2** (explicitly deferred, not touched by this plan): annotations/highlights/bookmarks/comments/full-text search — i.e. `annotations.lua`, `annotation_sync.lua`, `local_annotation_database.lua`, `thoughts.lua`, `thought_database.lua` and everything under them are untouched.

---

## Testing plan

Per your §23, build a mocked WeRead API server/stub before touching a real account. Concretely:

- A Lua test harness that substitutes `Http:request` (or a mock `RequestScheduler` sink) with a scriptable fake returning canned responses/status codes, so `ChapterProvider`/`PrefetchManager`/`RequestScheduler` can be tested without any network access.
- **Case coverage** (directly from your list):
  1. Read 10 chapters consecutively via cache-hit/miss path → assert no requests for chapter N+2 or beyond are ever issued (this is the single most important regression test given the whole point of this redesign).
  2. Server returns rate-limit signal → assert next tick issues zero requests, and `network_state.lua` reports `RATE_LIMITED`.
  3. Simulate suspend for a long duration, then resume → assert no burst of queued requests; assert at most one request (for the current chapter, if not cached) is issued.
  4. Start a background full-book download, then open/read a different chapter → assert the `READ`-priority request is serviced before the in-flight `DOWNLOAD`-priority one resumes (non-preemptive: the current in-flight download chapter finishes, but the *next* one waits).
  5. 429/403/timeout/server-error/cancel-mid-download — reuse existing `downloader.lua`/`http.lua` behavior; add coverage only for the new call sites (`ChapterProvider`, `PrefetchManager`) reacting correctly to the same signals via `backoff.lua`.
  6. Repeated/duplicate taps on the same book while `ChapterProvider:open_current` is already in flight → assert idempotent (no duplicate request), matching the existing single-slot-async pattern used elsewhere in the codebase.
  7. Cache hit vs. cache miss on chapter turn → assert hit path makes zero network calls.

---

## Open questions for you before implementation starts

1. **Backoff schedule**: keep `http.lua`'s existing `15/30/60/90s` (already implemented, already production-tested), or replace with your example `30/60/120/300s`? This is a one-line change (`RATE_LIMIT_DELAYS` in `http.lua:113`) but affects every existing caller, so I'd rather you pick deliberately than have me guess.
2. **Cache window size**: default to exactly prev=1/current=1/next=1 (your explicit spec in §4), or make it configurable in the UI from day one? Recommend hardcoded-but-in-config for Phase 1, exposed in UI only if you want it.
3. **Prefetch trigger point**: 70% or 80% (you gave both in different sections)? Recommend 75% as a middle default, tunable via `config.lua`.
4. **The offline-progress-retry addition** in `progress_sync.lua` above is the one place this plan changes existing behavior rather than purely reusing it — confirm you want that, or prefer to leave `sync.lua`'s current "discard on suspend-flush failure" behavior alone for Phase 1 and revisit later.
5. **Suspend PID-death gap** noted in `ARCHITECTURE_ANALYSIS.md` §7 — worth a dedicated investigation/fix in Phase 1, or acceptable to leave as-is (matching current download-subsystem behavior) since it's pre-existing and not something this redesign introduces?

I'll wait for your review/answers before writing any code.
