# invidious-termux

A single-file installer that runs [Invidious](https://github.com/iv-org/invidious)
with its companion service and PostgreSQL natively on Android/Termux (arm64),
plus the fixes that are actually required to make it work on a modern Android
device.

```
termux/install-invidious-termux.sh   # installer (config + services embedded)
docs/TERMUX-NOTES.md                 # why each workaround exists, with diagnosis
```

## What you get

- `$PREFIX/bin/invidious` — prebuilt native arm64 binary
- `$PREFIX/share/invidious/{assets,locales,config}` — app tree, generated
  `config.yml` with random secrets, and the SQL schema it needs at boot
- `invidious-companion` running from a pinned source checkout under Deno
- PostgreSQL initialised and a dedicated `invidious` role/database
- Three `termux-services`: `postgres`, `invidious`, `invidious-companion`

Re-running the installer is safe: it keeps the existing config, secrets,
database and companion checkout, and only refreshes the binary/assets/schema.

## Requirements

- Termux from F-Droid (or the GitHub build), **arm64**, Android 8.0+ (API 26+)
- `termux-services` installed (the script offers to install it and asks for a
  Termux restart)
- ~1 GB free, network access during install
- PostgreSQL, Deno, git, curl — installed automatically if missing

## Install

```sh
curl -fLO https://raw.githubusercontent.com/wirawira941/invidious-termux/main/termux/install-invidious-termux.sh
sh install-invidious-termux.sh
```

The first run takes a few minutes (binary download, PostgreSQL init, Deno
module cache). It prints the URL when the web UI actually answers.

### Ports and binding

```sh
# default: http://127.0.0.1:3000 (loopback only)
INVIDIOUS_PORT=3002 INVIDIOUS_BIND=0.0.0.0 sh install-invidious-termux.sh
```

- `INVIDIOUS_PORT` — upstream default is 3000; override it if something else
  already uses that port (the config is rewritten in place, secrets preserved).
- `INVIDIOUS_BIND` — `127.0.0.1` by default. Use `0.0.0.0` to reach the
  instance from other machines on the LAN/intranet. Companion (:8282) and
  PostgreSQL (:5432) stay on loopback; Invidious talks to them locally.

The summary reports the intranet URL when bound to `0.0.0.0`, and says whether
the UI is answering instead of assuming it is.

## What this fixes

These are the differences from a stock Termux install; details and the
diagnosis behind each one are in [docs/TERMUX-NOTES.md](docs/TERMUX-NOTES.md).

| Problem | Effect | Fix |
| --- | --- | --- |
| `libandroid-shmem` built for API 24 uses `/dev/ashmem`, denied to apps since Android 10 | `initdb`/`postgres` hang forever in the shim's socket fallback | rebuild the shim for API 26+ so it uses `ASharedMemory_create()`; original kept as `libandroid-shmem.so.orig` |
| Release tarball has no `config/sql/` | Invidious dies at boot with `File::NotFoundError: config/sql/channels.sql` | fetch the schema from the matching `iv-org/invidious` tag |
| `deno compile` publishes no `denort` for android triples | companion build fails with `404 .../denort-aarch64-linux-android.zip` | keep the pinned source tree and run it with `deno run` |
| Termux service is named `postgres`, not `postgresql` | `sv-enable postgresql` fails | detect either service name |
| Interrupted `initdb` leaves a `PG_VERSION` without `global/pg_control` | every later run skips init and fails to start | move the directory aside and re-init |
| Port 3000 often already taken; config only binds loopback | silent crash-loop on `Address already in use`; unreachable from LAN | `INVIDIOUS_PORT` / `INVIDIOUS_BIND`, plus a real post-start check |

## Verified on

Samsung SM-A325F, Android 13 (API 33), kernel 4.14.186, Termux arm64:

```
run: invidious            (port 3002)
run: invidious-companion  (port 8282)
run: postgres             (port 5432)
UI 200 · companion /healthz 200 · 8 tables · search returns results
```

## Notes

- `pkg upgrade libandroid-shmem` restores the packaged (broken on Android 10+)
  build. The next installer run detects the failing shim and rebuilds it.
- Invidious needs a `domain:` only when served under a hostname; IP access
  works without it.
- The generated `config.yml` contains secrets and is never overwritten — keep
  it out of version control.

## Credits

- [Invidious](https://github.com/iv-org/invidious) and
  [invidious-companion](https://github.com/iv-org/invidious-companion) — AGPL-3.0
- arm64 build and original Termux port: [wirawira941/invidious-termux](https://github.com/wirawira941/invidious-termux)
- [termux/libandroid-shmem](https://github.com/termux/libandroid-shmem)
