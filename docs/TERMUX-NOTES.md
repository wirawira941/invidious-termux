# TERMUX-NOTES — Invidious port design

- Upstream: https://github.com/iv-org/invidious — pinned release
  **v2.20261022.0** (Crystal, `shard.yml` requires crystal >= 1.14.1, < 2.0.0).
  Companion: https://github.com/iv-org/invidious-companion — pinned commit
  **fcb0456** (master, 2026-10-25; the repo has no version tags).
- Why CI builds the binary: the user chose CI over an on-device build
  (2026-10-25). The on-device route was also feasible — Termux main ships
  crystal 1.22.1, deno 2.9.8, postgresql 18.6 — but `crystal build --release`
  on Invidious is RAM-hungry, and CI keeps the phone out of it.
- The cross-compile recipe mirrors **Termux's own crystal package**
  (termux-packages `packages/crystal/build.sh`), which is the proven way
  to target Android with Crystal:
  - host crystal 1.22.1 (official linux-x86_64 tarball) on the runner;
    Termux builds shards 0.18.0 into its crystal package the same way
    (host shards + cross-compile), which is why `shards` needs no
    separate handling for the on-device fallback either.
  - `crystal build src/invidious.cr --release --cross-compile
    --target aarch64-linux-android -Dwithout_iconv
    --link-flags "-lxml2 -llzma"` → `invidious.o`
    (`-Dwithout_iconv` and the link flags follow upstream's Dockerfile
    and Termux's crystal build).
  - The clone keeps `.git`: Invidious reads CURRENT_COMMIT/VERSION from
    git at build time (upstream's Dockerfile copies `.git` for the
    same reason).
  - Link with NDK r28c clang `--target=aarch64-linux-android24` against
    a sysroot of Termux .debs downloaded from packages.termux.dev
    (libgc, libevent, libyaml, pcre2, libxml2, openssl, libpq, sqlite,
    libiconv, libgmp, zlib, libc++, liblzma), RUNPATH baked to
    `$PREFIX/lib`. NDK r28c has no GNU libstdc++, hence `-lc++`
    (Termux's `libc++` package provides `libc++.so` at runtime).
  - ELF gate fails the release unless: Type DYN, Machine AArch64,
    interpreter `/system/bin/linker64`, no `ld-linux` anywhere in the
    dynamic section, and a dynamic `main` symbol exists.
- Runtime layout on device (installer):
  - binary `$PREFIX/bin/invidious`; app tree `$PREFIX/share/invidious`
    (assets/, locales/, config/) — Invidious resolves these relative to
    its working directory, so the service script `cd`s there.
  - PostgreSQL: Termux package; data `$PREFIX/var/lib/postgresql`;
    role/db both `invidious`; password generated once into the config,
    and the installer re-syncs the role password from the config on
    every run so reinstalls stay consistent.
  - Companion: cloned at the pinned commit and compiled ON DEVICE with
    `deno task compile` (output binary `invidious_companion`). A git
    clone is required — the compile task reads version info from git.
    The compiled binary is a Deno self-contained executable for the
    device platform; no Crystal-scale resources needed.
  - Companion config comes from env in its service script:
    `SERVER_SECRET_KEY` (exactly 16 chars, identical to
    `invidious_companion_key` in the Invidious config), `PORT=8282`,
    `HOST=127.0.0.1`, `CACHE_DIRECTORY=$PREFIX/var/tmp/invidious-companion`.
    Upstream's default cache path `/var/tmp/youtubei.js` does not exist
    on Android, and the compiled binary's baked-in `--allow-write` list
    names `/var/tmp` — whether the Termux Deno build maps that path is
    a device-verdict question; if the player cache write fails, fall
    back to running the companion uncompiled via `deno run` with
    explicit allow flags (same task flags as `dev`, minus `--watch`).
  - All service scripts re-assert `LD_PRELOAD=$PREFIX/lib/libtermux-exec.so`
    (guarded, no duplicates): service contexts don't guarantee it, and
    child execs fail with EACCES without it (Forgejo lesson).
  - Config binds 127.0.0.1 by default (`host_binding`, `port: 3000`);
    publishing is a config change on the user's side, see README.
- Known caveats:
  - Upstream compiles its own OpenSSL 3.6.5 because of a memory-leak
    interaction with Crystal (invidious#1438). This port links Termux's
    openssl; if the service grows in memory over days, `sv restart
    invidious` is the mitigation until upstream/Termux align.
  - PostgreSQL 18.6 (Termux) vs upstream compose's PG 14: schema is
    upstream SQL + `check_tables: true` auto-creation; device smoke
    test is the verdict.
  - YouTube-side breakage (poToken/player changes) is an upstream
    cadence issue: bump the companion commit first, then Invidious.
- Device verdict that closes this port: installer run completes,
  `sv status` shows all three services up, http://127.0.0.1:3000 loads,
  and a video actually plays through the companion.
