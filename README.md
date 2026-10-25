# invidious-termux

Run [Invidious](https://github.com/iv-org/invidious) — the alternative
YouTube front-end — **natively on Termux** (Android arm64), no proot.

Invidious is written in Crystal, so the heavy compile happens in GitHub
Actions, cross-compiled for Android with the same recipe Termux itself
uses to build Crystal. Your phone only installs the finished binary.

## What runs on the phone

| Service | Port | Source |
|---|---|---|
| `invidious` | 3000 (127.0.0.1) | CI-built release binary from this repo |
| `invidious-companion` | 8282 (127.0.0.1) | compiled on-device with Deno (`deno task compile`) |
| `postgresql` | 5432 (127.0.0.1) | Termux package |

All three run under termux-services (`sv status invidious` etc.).
The companion is **required**: current Invidious versions delegate all
video stream retrieval to it. It stays private on localhost; only
Invidious talks to it, authenticated by a shared 16-character key.

## Install

In Termux:

```sh
pkg install curl
curl -fLO https://raw.githubusercontent.com/wirawira941/invidious-termux/main/termux/install-invidious-termux.sh
sh install-invidious-termux.sh
```

The installer verifies the release sha256, installs the Termux packages,
sets up PostgreSQL (data dir, role, database), generates
`$PREFIX/share/invidious/config/config.yml` with fresh secrets **once**
(reinstalls never overwrite it), compiles the companion, and enables the
services. First start takes a moment while Invidious creates its tables.

Then open <http://127.0.0.1:3000>.

If termux-services was just installed, restart Termux once and re-run
the installer — the `sv` command only appears after a restart.

## Publishing it (optional)

The default config binds to 127.0.0.1 only. To serve it on your own
domain, edit the config: set `host_binding: 0.0.0.0`, set `domain:` to
your hostname, put a reverse proxy / tunnel in front, and read the
upstream [post-install notes](https://docs.invidious.io/installation/#post-install-configuration)
first (the companion routing options live there too).

## Updating

Re-run the installer: it fetches the pinned release, replaces the
binary, and keeps your config, database and companion key untouched.
To move to a newer Invidious, a maintainer dispatches the CI workflow
with the new upstream tag and bumps the pin in the installer.

## Notes

Build design, the Crystal cross-compile recipe, the ELF gate and the
known caveats (upstream OpenSSL memory-leak interaction, companion
cache path) are documented in `docs/TERMUX-NOTES.md`.

## License

Invidious is AGPL-3.0-only; this port's scripts and notes are released
under the same terms.
