# Termux / Android notes

Engineering notes for the installer: what breaks on Android, how it was
diagnosed, and why the fix looks the way it does. Environment used for all of
this: Samsung SM-A325F, Android 13 (API 33), kernel 4.14.186, Termux arm64,
PostgreSQL 18.6, Deno 2.9.8.

---

## 1. PostgreSQL hangs: `libandroid-shmem` and `/dev/ashmem`

**Symptom.** `initdb` never finishes. `postgres --check` (which `initdb` runs
first) sits in `read()` forever, ignores SIGTERM, and leaves
`$TMPDIR/ashv_key_*` symlinks behind. `initdb` then retries with smaller
`shared_buffers` values and eventually gives up.

**Diagnosis.** `strace -k` on the stuck process shows the chain:

```
libandroid_shmget
  ashmem_create_region() failed for size 4096: Permission denied
  open("/dev/ashmem") = -1 EACCES
PGSharedMemoryCreate
CreateSharedMemoryAndSemaphores
BootstrapModeMain
```

`/dev/ashmem` is denied to `untrusted_app` (SELinux) on Android 10+. The
packaged `libandroid-shmem` is built with `__ANDROID_API__ = 24`, so
`ashmem_create_region()` takes the legacy `open("/dev/ashmem")` path. When that
fails, the library falls back to its `ashv` socket protocol, which deadlocks
inside `shmget` (the packaged 0.7 build predates the upstream "fix deadlock in
shmget" commit).

Note that `shared_memory_type=mmap` does **not** avoid this: PostgreSQL still
creates a minimal SysV segment during startup.

**Fix.** Upstream `libandroid-shmem` has an API-26 path that uses
`ASharedMemory_create()` (exported by `libandroid.so`), which works on this
device. The installer rebuilds it from source:

```sh
git clone --depth 1 https://github.com/termux/libandroid-shmem
make -C libandroid-shmem CC=clang \
     CFLAGS="-fpic -std=c11 -Wall -Wextra -O2 --target=aarch64-linux-android26" \
     libandroid-shmem.so
```

Then it backs up the packaged library once (`libandroid-shmem.so.orig`) and
installs the new one over `$PREFIX/lib/libandroid-shmem.so`. The rebuilt object
links `ASharedMemory_create`/`ASharedMemory_getSize` and no longer contains the
string `/dev/ashmem`:

```
$ nm -D --undefined-only $PREFIX/lib/libandroid-shmem.so | grep Shared
                 U ASharedMemory_create
                 U ASharedMemory_getSize
```

**When it runs.** Before touching the database, the installer compiles a small
probe (`shmget` → `shmat` → `shmdt` → `shmctl`) against `libandroid-shmem`.
Only if the probe fails does it rebuild. If `cc` is missing it installs
`clang` (which pulls `ndk-sysroot`); `make` is installed on demand too.

**Caveats.**

- `pkg upgrade libandroid-shmem` restores the packaged build; re-run the
  installer to re-patch it.
- Devices below API 26 have no `ASharedMemory_create()`; the installer warns
  instead of pretending it can fix it.
- `/dev/ashmem` is not the only affected consumer — anything using the shim
  (X11/MIT-SHM clients, for example) benefits from the rebuild, and nothing
  regresses because the old build simply fails on these devices.

---

## 2. Invidious dies at boot: missing `config/sql/`

**Symptom.**

```
check_table: check_table: CREATE TABLE channels
Unhandled exception: Error opening file with mode 'r': 'config/sql/channels.sql':
No such file or directory (File::NotFoundError)
```

**Cause.** The arm64 release tarball ships `invidious`, `assets/` and
`locales/`, but **not** `config/sql/`. Invidious reads those schema files at
startup to create its tables (`check_tables: true`).

**Fix.** The installer downloads the source tarball of the matching upstream
tag and copies the two directories it needs:

```sh
SRC_URL="https://codeload.github.com/iv-org/invidious/tar.gz/refs/tags/v${VER}"
tar -xzf src.tar.gz "invidious-${VER}/config/sql" \
                    "invidious-${VER}/config/migrate-scripts"
```

They are refreshed on every run (like `assets/` and `locales/`), while
`config.yml` is preserved.

---

## 3. Companion: `deno compile` cannot target Android

**Symptom.**

```
error: Writing deno compile executable to temporary file 'invidious_companion.tmp-...'
Caused by:
    0: Setting up base binary.
    1: Failed downloading 'https://dl.deno.land/release/v2.9.8/denort-aarch64-linux-android.zip'
    2: Not Found.
```

**Cause.** `deno compile` needs a `denort` base binary for the target triple.
Deno publishes them for Linux/macOS/Windows only — there is no Android build,
so compiling on-device cannot work at all.

**Fix.** Keep the pinned source checkout and run it with Deno directly. The
service does the equivalent of the upstream `dev` task, without `--watch`:

```sh
cd "$COMPANION_DIR/app"
exec deno run \
  --allow-import=github.com:443,jsr.io:443,cdn.jsdelivr.net:443,esm.sh:443,deno.land:443 \
  --allow-net --allow-env --allow-sys=hostname --allow-read \
  --allow-write="$CACHE_DIRECTORY/youtubei.js" \
  src/main.ts
```

`CACHE_DIRECTORY` must be inside `$PREFIX` because upstream's default
`/var/tmp` does not exist on Android (the root filesystem is read-only). The
write permission is scoped to that path; the companion creates
`youtubei.js/kv_cache.sqlite3` itself and falls back to an in-memory store if
it cannot write.

---

## 4. Service name: `postgres`, not `postgresql`

The Termux `postgresql` package ships its runit service as
`$PREFIX/var/service/postgres`. Older layouts used `postgresql`. The installer
checks for both and enables whichever exists, falling back to `pg_ctl` if there
is no service directory at all.

---

## 5. Recovering from an interrupted `initdb`

An aborted `initdb` leaves a directory that looks initialised (`PG_VERSION`
exists) but has no `global/pg_control` and a 0-byte `postgresql.conf`. A naive
`[ ! -s "$PGDATA/PG_VERSION" ]` guard skips re-initialisation, and every later
start fails.

The installer treats a missing `global/pg_control` as "incomplete", moves the
directory to `$PGDATA.incomplete-<timestamp>` (kept for inspection) and runs
`initdb` again.

---

## 6. Ports, binding, and honest status reporting

- The upstream default port is 3000, which is frequently occupied on a phone
  (this device had a Rails app on 3000 and 3001). `INVIDIOUS_PORT` overrides it
  and rewrites the existing config in place.
- `host_binding` defaults to loopback in the generated config. Set
  `INVIDIOUS_BIND=0.0.0.0` to serve the LAN/intranet; the installer then prints
  the detected `inet` address.
- After enabling the services the installer polls
  `http://127.0.0.1:$PORT/api/v1/stats` for up to ~30 s and reports whether the
  UI answers. Without this, a crash-looping service (for example on a busy
  port) still ends with a cheerful "installed" message.
- `sv-enable` calls `sv up` immediately, which races `runsvdir`'s scan of a
  newly created service directory and prints
  `warning: ... unable to open supervise/ok`. Harmless; the warning is
  suppressed.

---

## Debugging recipes used here

```sh
# follow a hung postgres into the shim
strace -f -k -s 120 -o /tmp/trace initdb -D /tmp/pgprobe --no-sync

# `timeout` needs -k: the deadlocked process ignores SIGTERM
timeout -k 2 20 postgres --check ...

# LD_PRELOAD must keep libtermux-exec, or exec() of Termux binaries from a
# child process fails with EACCES
LD_PRELOAD="$PREFIX/lib/libtermux-exec.so /path/to/libandroid-shmem.so"

# stale fallback sockets from crashed runs (safe to delete)
rm -f "$TMPDIR"/ashv_key_*
```

---

## Verification transcript

```
$ sv status invidious invidious-companion postgres
run: invidious: (pid 13327) 70s
run: invidious-companion: (pid 32092) 458s
run: postgres: (pid 31099) 719s; run: log: (pid 16984) 4314s

$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.43.114:3002/feed/popular
200

$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8282/healthz
200

$ psql -h 127.0.0.1 -U $(whoami) -d invidious -tAc \
    "select count(*) from information_schema.tables where table_schema='public'"
8

$ curl -s 'http://127.0.0.1:3002/api/v1/search?q=termux' | head -c 80
[{"type":"channel","author":"termux",...
```

---

## Build: the arm64 binary (GitHub Actions)

The sections above cover the installer and the device. The `invidious`
binary itself is cross-compiled in CI (`.github/workflows/build-termux.yml`),
mirroring how Termux builds its own Crystal package
(termux-packages `packages/crystal/build.sh`):

- Host Crystal 1.22.1 (official linux-x86_64 tarball) compiles
  `src/invidious.cr` with `--release --cross-compile
  --target aarch64-linux-android -Dwithout_iconv
  --link-flags "-lxml2 -llzma"` into `invidious.o`. The clone keeps `.git`:
  Invidious reads CURRENT_COMMIT/VERSION from git at build time.
- The object is linked with NDK r28c clang against a sysroot of Termux
  .debs (libgc, libevent, libyaml, pcre2, libxml2, openssl, libpq,
  **libsqlite**, libiconv, libgmp, zlib, libc++, liblzma), RUNPATH baked
  to `$PREFIX/lib`. NDK r28c has no GNU libstdc++, hence `-lc++`.
- Three CI failures shaped this recipe (2026-10-25):
  1. The sysroot must fetch `libsqlite`, not `sqlite` — the `sqlite`
     package is the CLI only; the library lives in `libsqlite`
     (`unable to find library -lsqlite3`).
  2. The link target must be API 28, not 24: Crystal's stdlib references
     `getrandom` (bionic API 28) and `__system_property_read_callback`
     (API 26), which the API 24 libc stubs do not provide.
  3. The ELF gate checks `main` in the regular symbol table, not the
     dynamic one — a PIE executable does not export `main`; the entry
     point is what the loader uses.
- ELF gate: Type DYN, Machine AArch64, interpreter
  `/system/bin/linker64`, no `ld-linux` in the dynamic section.
- The workflow packages `config/sql/` and `config/migrate-scripts/` into
  the tarball for future releases; for the current release the installer
  refreshes them from the upstream source tag instead (section 2).
- Upstream compiles its own OpenSSL 3.6.5 over a memory-leak interaction
  with Crystal (invidious#1438); this port links Termux's openssl. If the
  service grows in memory over days, `sv restart invidious` mitigates.
