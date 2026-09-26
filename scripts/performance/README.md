# Performance checks

Run from the repository root with the macOS Swift Command Line Tools:

```sh
scripts/performance/run-checks.sh
```

This runs normalization parity/benchmarks, index cancellation, publication and persistence checks, app discovery, harmless pipe-pattern reproductions, the production subprocess runner, the synthetic index benchmark, and the all-source implementation fixture suite. It targets macOS 13 on the host architecture. On this Mac the host is arm64.

For the two original checks separately:

```sh
scripts/performance/run-space-table.sh
scripts/performance/run-app-discovery.sh
```

Both checks create and remove their own temporary fixtures. They do not scan installed applications or user storage, launch PureMac, or require Full Disk Access. The discovery check compiles the production fetcher with a sizing spy; it deliberately does not link the real FileSizeCalculator.

All checks use generated fixtures. The pipe test intentionally terminates its own stalled fixture children after two seconds; it never invokes a real cleaning, Docker, brew, or signing command. If the internal drive is nearly full, choose an existing temporary directory on another volume, for example `TMPDIR="$PWD/_work/performance/tmp/" scripts/performance/run-checks.sh` after creating that directory. The runner removes only its own uniquely named temporary child directory.

The original 30-finding audit and its follow-up are retained in private maintainer documentation.

To compare against a saved scanner source file:

```sh
scripts/performance/run-space-table.sh /absolute/path/to/previous/SpaceTableScanner.swift
```

The scanner benchmark compiles with `-O`, warms metadata once, then reports five full indexing times. It checks exact directory totals across branching, eight-level nested trees with 2,304 payload files and 218 directories, including hidden files and empty folders. It also verifies symlink exclusion, Photos-library exclusion, size ordering, and that returned paths stay in the requested root namespace.

## September 7, 2026 results

On this Mac, using Swift 6.3.2 and temporary local storage:

| Implementation | Five warm runs (seconds) | Median |
| --- | --- | --- |
| Before | 1.054, 1.150, 1.090, 1.056, 1.361 | 1.090 s |
| After | 0.618, 0.612, 0.597, 0.789, 0.691 | 0.618 s |

The median decreased by approximately 43%. These are sequential synthetic, warm-cache measurements, not whole-volume benchmarks or UI latency measurements. Both versions passed the same fixture assertions.

Changes:

- Space Table retains parent-before-child enumeration order and reverses it to accumulate sizes. This replaces the O(n log n) depth sort and its repeated URL construction with an O(n) accumulation pass. Root-prefix ordering is also computed once instead of once per file. Final per-directory display sorting remains intact.
- App discovery rejects protected bundle IDs and already-seen bundle IDs before loading icons or walking bundle contents. The discovery check confirms protected apps invoke sizing zero times, and accepted apps retain their metadata, sizes, and identifier fallback.

The production scanner and app-discovery source groups compiled successfully with their real dependencies using `swiftc`. Full Xcode app build, XCTest suite, and macOS 13 runtime verification remain outstanding: this environment has Command Line Tools but no Xcode installation. No app was installed or launched.

The extended pass also type-checked **all application Swift sources** with `swiftc -typecheck -parse-as-library -target arm64-apple-macosx13.0`, using the existing no-Sparkle fallback. It passed with pre-existing actor-isolation warnings. This does not validate Sparkle linkage, resources, signing, or a rendered macOS app.

Additional measured results:

- Index notifications: **1,017 → 16** on the 502-directory fixture; all entries persisted and restored.
- Index cancellation: both already-canceled and in-flight callers now throw `CancellationError`; observed return latency **36–66ms** on the fixture, not a universal maximum.
- ASCII normalization: first comparison **31.55 → 3.83ms** for 10,012 identifiers; repeat **68.62 → 4.89ms**. Mixed Unicode had no consistent speedup and retains the original Foundation path.
- The final external-volume scanner run passed all correctness checks with a **0.796s** warm median. Do not compare this directly to the initial internal-volume baseline: storage location, available disk space, and load changed.

## Full implementation fixtures

`scripts/performance/run-implementation.sh` also runs independently. It compiles and links all production sources with a fixture entry point, disables AppState startup work, and injects external operations. Temporary dummy app bundles test grouped cleanup and failure behavior without running real signing, lipo or cleanup commands. A native `NSHostingView` bitmap smoke check runs without opening an application window.

Coverage includes matcher parity, canceled scans, generation-scoped size reuse, category concurrency/root ownership, process permits, incremental persistence/failure preservation, controlled Space Table lifecycle races, metadata-first loading/identity, bulk selections, row-cache reuse/filter ties, icon coalescing, disk cadence, animation policy and grouped app transactions. See the implementation record (historical evidence retained privately).

Xcode, hosted XCTest, Sparkle linkage, signing/resources, full-app interaction and Energy Log remain separate unverified checks. A direct Swift target of macOS 13 is not execution on macOS 13.

## Native verification follow-up

The September 8 verification report (historical evidence retained privately) documents the real-Sparkle native runner and actual signing/thinning fixtures. `run-preview-ordering.sh` checks late shallow previews after full index completion for both expansion and navigation; it is included in `run-checks.sh`.

## Space Table browsing latency

Run `scripts/performance/run-space-table-latency.sh` for blocked-background
expansion, latest-click preemption, partial child sizing, streamed completion,
and cancellation checks. It is included in `run-checks.sh`. See
the real-folder measurements (historical evidence retained privately)
for the measured improvements and remaining full-tree cost.
