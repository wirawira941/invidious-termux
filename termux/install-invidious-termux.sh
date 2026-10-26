#!/data/data/com.termux/files/usr/bin/sh
# Install Invidious (CI-built native binary) + companion + PostgreSQL on Termux.
# Single-file installer: config template and service scripts are embedded
# below as heredocs (they are the source of truth; see docs/TERMUX-NOTES.md).
#
# - Downloads the release tarball and verifies its sha256 before installing.
# - Backs up an existing $PREFIX/bin/invidious once to invidious.pkg-backup.
# - Generates config + secrets ONCE; reinstalls never overwrite
#   $PREFIX/share/invidious/config/config.yml.
# - Sets up three termux-services: postgres, invidious (port 3000 by default,
#   override with INVIDIOUS_PORT), invidious-companion (:8282). The companion
#   is pinned to a commit and run from source with Deno (Android has no
#   denort for `deno compile`).
# - Reinstalls keep the existing config, secrets, database and companion tree.
set -eu

TAG="v2.20261022.0-termux.1"
VER="2.20261022.0"
ASSET="invidious_${VER}_termux_arm64.tar.gz"
SHA256="89f4ceed10933536afaba10d522f8af94f36fb75a479aba4ee2b83e6d9c5badc"
URL="https://github.com/wirawira941/invidious-termux/releases/download/${TAG}/${ASSET}"
# The release tarball ships only assets/locales, not config/sql: Invidious
# reads the schema files at boot to create its tables, so pull them from the
# matching upstream source tag.
SRC_URL="https://codeload.github.com/iv-org/invidious/tar.gz/refs/tags/v${VER}"
COMPANION_COMMIT="fcb0456ad5bdf8fdbb44257423a1f8246e38e925"
COMPANION_REPO="https://github.com/iv-org/invidious-companion.git"

if [ -z "${PREFIX:-}" ]; then
    echo "install-invidious-termux: \$PREFIX is empty -- run this inside Termux itself, not inside proot/chroot." >&2
    exit 1
fi

APP_DIR="$PREFIX/share/invidious"
COMPANION_DIR="$PREFIX/share/invidious-companion"
CONFIG="$APP_DIR/config/config.yml"
PGDATA="$PREFIX/var/lib/postgresql"
# Port 3000 is the upstream default; override with INVIDIOUS_PORT when it is
# already taken on the device. The server listens on loopback by default;
# INVIDIOUS_BIND=0.0.0.0 exposes it to the LAN/intranet.
INVIDIOUS_PORT_OVERRIDE="${INVIDIOUS_PORT:-}"
INVIDIOUS_PORT="${INVIDIOUS_PORT:-3000}"
INVIDIOUS_BIND_OVERRIDE="${INVIDIOUS_BIND:-}"
INVIDIOUS_BIND="${INVIDIOUS_BIND:-127.0.0.1}"

# ---------------------------------------------------------------- packages
PKGS="postgresql deno git curl libgc libevent libyaml pcre2 libxml2 openssl libpq libsqlite libiconv libgmp zlib libc++ liblzma librsvg"
for pkg in $PKGS; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "installing Termux package: $pkg"
        pkg install -y "$pkg"
    fi
done
if ! command -v sv >/dev/null 2>&1; then
    pkg install -y termux-services
    echo "NOTE: termux-services activates after a Termux restart."
    echo "Restart Termux once, then re-run this installer."
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------- shared memory (SysV shm)
# The packaged libandroid-shmem is built for API 24, so it opens /dev/ashmem,
# which Android 10+ denies to apps (SELinux). PostgreSQL always creates a small
# SysV segment, so without a working shim initdb/postgres hang in the library's
# socket fallback. Rebuilding against API 26+ switches it to
# ASharedMemory_create(), which works on current Android.
fix_android_shmem() {
    lib="$PREFIX/lib/libandroid-shmem.so"
    [ -e "$lib" ] || return 0

    if ! command -v cc >/dev/null 2>&1; then
        echo "installing clang (needed to rebuild libandroid-shmem)"
        pkg install -y clang
    fi

    cat > "$WORK/shmprobe.c" <<'PROBE'
#include <sys/ipc.h>
#include <sys/shm.h>
int main(void) {
    int id = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    if (id < 0) return 1;
    void *p = shmat(id, NULL, 0);
    if (p == (void *)-1) return 2;
    shmdt(p);
    shmctl(id, IPC_RMID, NULL);
    return 0;
}
PROBE
    if cc -o "$WORK/shmprobe" "$WORK/shmprobe.c" -landroid-shmem 2>/dev/null &&
       "$WORK/shmprobe" >/dev/null 2>&1; then
        return 0
    fi

    sdk="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
    case "$sdk" in ''|*[!0-9]*) sdk=0 ;; esac
    if [ "$sdk" -lt 26 ]; then
        echo "WARNING: Android API $sdk lacks ASharedMemory_create();" >&2
        echo "         PostgreSQL may not start on this device." >&2
        return 0
    fi
    case "$(uname -m)" in
        aarch64|arm64) triple="aarch64-linux-android" ;;
        arm*)          triple="arm-linux-androideabi" ;;
        x86_64)        triple="x86_64-linux-android" ;;
        i?86)          triple="i686-linux-android" ;;
        *) echo "WARNING: unsupported architecture $(uname -m) for shim rebuild" >&2; return 0 ;;
    esac

    echo "rebuilding libandroid-shmem for API 26+ (packaged build cannot use /dev/ashmem)"
    command -v make >/dev/null 2>&1 || pkg install -y make
    rm -rf "$WORK/libandroid-shmem"
    git clone -q --depth 1 https://github.com/termux/libandroid-shmem "$WORK/libandroid-shmem"
    make -C "$WORK/libandroid-shmem" CC=clang \
        CFLAGS="-fpic -std=c11 -Wall -Wextra -O2 --target=${triple}26" \
        libandroid-shmem.so >/dev/null
    [ -e "$lib.orig" ] || cp -a "$lib" "$lib.orig"
    install -m 0755 "$WORK/libandroid-shmem/libandroid-shmem.so" "$lib.new"
    mv -f "$lib.new" "$lib"
    echo "patched libandroid-shmem installed (original kept as $lib.orig)"
}
fix_android_shmem

# ------------------------------------------------------------------ binary
echo "downloading $ASSET ($TAG)"
curl -fL -o "$WORK/$ASSET" "$URL"
echo "${SHA256}  ${WORK}/${ASSET}" | sha256sum -c -
tar --no-same-owner -xzf "$WORK/$ASSET" -C "$WORK"

CONFIG_SAVED=""
if [ -f "$CONFIG" ]; then
    CONFIG_SAVED="$WORK/config.yml.saved"
    cp -a "$CONFIG" "$CONFIG_SAVED"
    echo "existing config found -- it will be preserved"
fi

if [ -x "$PREFIX/bin/invidious" ] && [ ! -e "$PREFIX/bin/invidious.pkg-backup" ]; then
    cp -a "$PREFIX/bin/invidious" "$PREFIX/bin/invidious.pkg-backup"
    echo "existing invidious binary backed up to $PREFIX/bin/invidious.pkg-backup"
fi

install -m 0755 "$WORK/invidious" "$PREFIX/bin/invidious"
mkdir -p "$APP_DIR/config"
rm -rf "$APP_DIR/assets" "$APP_DIR/locales"
cp -r "$WORK/assets" "$APP_DIR/assets"
cp -r "$WORK/locales" "$APP_DIR/locales"
cp "$WORK/config/config.example.yml" "$APP_DIR/config/config.example.yml"

echo "fetching Invidious schema (config/sql) for v$VER"
curl -fL -o "$WORK/invidious-src.tar.gz" "$SRC_URL"
tar -xzf "$WORK/invidious-src.tar.gz" -C "$WORK" \
    "invidious-$VER/config/sql" "invidious-$VER/config/migrate-scripts"
rm -rf "$APP_DIR/config/sql" "$APP_DIR/config/migrate-scripts"
cp -r "$WORK/invidious-$VER/config/sql" "$APP_DIR/config/sql"
cp -r "$WORK/invidious-$VER/config/migrate-scripts" "$APP_DIR/config/migrate-scripts"

# ------------------------------------------------------------------ config
rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
rand_key16() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

if [ -n "$CONFIG_SAVED" ]; then
    cp -a "$CONFIG_SAVED" "$CONFIG"
    DB_PASSWORD="$(sed -n 's/^  password: //p' "$CONFIG" | head -1)"
    COMPANION_KEY="$(sed -n 's/^invidious_companion_key: //p' "$CONFIG" | head -1 | tr -d '"')"
    if [ -n "${INVIDIOUS_PORT_OVERRIDE:-}" ]; then
        sed -i "s/^port: .*/port: $INVIDIOUS_PORT/" "$CONFIG"
        echo "config restored; port set to $INVIDIOUS_PORT"
    fi
    if [ -n "${INVIDIOUS_BIND_OVERRIDE:-}" ]; then
        sed -i "s/^host_binding: .*/host_binding: $INVIDIOUS_BIND/" "$CONFIG"
        echo "config restored; binding set to $INVIDIOUS_BIND"
    fi
    if [ -z "${INVIDIOUS_PORT_OVERRIDE:-}" ] && [ -z "${INVIDIOUS_BIND_OVERRIDE:-}" ]; then
        echo "config restored unchanged"
    fi
else
    DB_PASSWORD="$(rand_hex 12)"
    COMPANION_KEY="$(rand_key16)"
    HMAC_KEY="$(rand_hex 16)"
    cat > "$CONFIG" <<EOF
# Invidious configuration for the Termux port.
# Generated once by install-invidious-termux.sh; reinstalls never overwrite it.
# Full option reference: config.example.yml next to this file.

db:
  dbname: invidious
  user: invidious
  password: $DB_PASSWORD
  host: 127.0.0.1
  port: 5432

check_tables: true

# Companion handles all video stream retrieval from YouTube.
# The key must be exactly 16 characters and match SERVER_SECRET_KEY
# in the companion service script.
invidious_companion:
  - private_url: "http://127.0.0.1:8282/companion"
invidious_companion_key: "$COMPANION_KEY"

# Local-only by default. To reach it from other machines on the LAN, run the
# installer with INVIDIOUS_BIND=0.0.0.0 (and set domain: to a hostname if you
# publish it beyond the LAN); see
# https://docs.invidious.io/installation/#post-install-configuration
host_binding: $INVIDIOUS_BIND
port: $INVIDIOUS_PORT

hmac_key: "$HMAC_KEY"
EOF
    echo "config written to $CONFIG (secrets generated once)"
fi

# --------------------------------------------------------------- postgres
# A half-initialised directory (e.g. an initdb that was interrupted) keeps a
# PG_VERSION but no global/pg_control; initdb and postgres both refuse it.
# Move it aside and start clean instead of failing forever.
if [ ! -s "$PGDATA/PG_VERSION" ] || [ ! -s "$PGDATA/global/pg_control" ]; then
    if [ -d "$PGDATA" ] && [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
        old="$PGDATA.incomplete-$(date +%Y%m%d%H%M%S)"
        echo "incomplete PostgreSQL data directory moved to $old"
        mv "$PGDATA" "$old"
    fi
    echo "initialising PostgreSQL data directory"
    if ! initdb -D "$PGDATA" >/dev/null; then
        echo "initdb failed -- see the messages above" >&2
        exit 1
    fi
fi
# Termux ships the service as "postgres" (postgresql package); older layouts
# used "postgresql". Detect whichever exists instead of assuming one name.
PG_SVC=""
for cand in postgres postgresql; do
    if [ -d "$PREFIX/var/service/$cand" ]; then
        PG_SVC="$cand"
        break
    fi
done
if ! pg_isready -q -h 127.0.0.1 -p 5432; then
    if [ -n "$PG_SVC" ]; then
        sv-enable "$PG_SVC" 2>/dev/null || true
        sv up "$PG_SVC" 2>/dev/null || true
    else
        # No runit service (e.g. termux-services restarted): start directly.
        pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" start 2>/dev/null || true
    fi
fi
tries=0
until pg_isready -q -h 127.0.0.1 -p 5432; do
    tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then
        echo "PostgreSQL did not come up; start it manually:" >&2
        echo "  sv up ${PG_SVC:-postgres}    (or: pg_ctl -D \"$PGDATA\" start)" >&2
        exit 1
    fi
    sleep 1
done

ME="$(whoami)"
psql -h 127.0.0.1 -U "$ME" -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='invidious'" | grep -q 1 \
    || psql -h 127.0.0.1 -U "$ME" -d postgres -c "CREATE ROLE invidious LOGIN"
psql -h 127.0.0.1 -U "$ME" -d postgres -c \
    "ALTER ROLE invidious PASSWORD '$DB_PASSWORD'"
psql -h 127.0.0.1 -U "$ME" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='invidious'" | grep -q 1 \
    || createdb -h 127.0.0.1 -U "$ME" -O invidious invidious
echo "PostgreSQL ready (db: invidious, role: invidious)"

# --------------------------------------------------------------- companion
# `deno compile` cannot target Android (Deno publishes no denort binary for
# android triples), so keep the pinned source tree and run it with `deno run`.
COMPANION_APP="$COMPANION_DIR/app"
if [ ! -f "$COMPANION_APP/src/main.ts" ]; then
    echo "installing invidious-companion source (one-time)"
    rm -rf "$COMPANION_APP"
    mkdir -p "$COMPANION_DIR"
    git clone -q "$COMPANION_REPO" "$COMPANION_APP"
    git -C "$COMPANION_APP" checkout -q "$COMPANION_COMMIT"
fi
echo "companion source: $COMPANION_APP"

# ---------------------------------------------------------------- services
mkdir -p "$PREFIX/var/service/invidious" "$PREFIX/var/service/invidious-companion"

cat > "$PREFIX/var/service/invidious/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
# termux-services run script for Invidious (written by the installer).
exec 2>&1
# Keep termux-exec active for the whole process tree: service contexts
# (termux-boot, runit) do not guarantee LD_PRELOAD is set, and child
# process execs fail with EACCES without it.
LIB="$PREFIX/lib/libtermux-exec.so"
if [ -e "$LIB" ]; then
  case " ${LD_PRELOAD:-} " in
    *" $LIB "*) ;;
    *) LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD }$LIB"; export LD_PRELOAD ;;
  esac
fi
# Invidious resolves config/, assets/ and locales/ relative to its
# working directory.
cd "$PREFIX/share/invidious" || exit 1
exec "$PREFIX/bin/invidious"
EOF

cat > "$PREFIX/var/service/invidious-companion/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# termux-services run script for invidious-companion (written by the installer).
exec 2>&1
LIB="\$PREFIX/lib/libtermux-exec.so"
if [ -e "\$LIB" ]; then
  case " \${LD_PRELOAD:-} " in
    *" \$LIB "*) ;;
    *) LD_PRELOAD="\${LD_PRELOAD:+\$LD_PRELOAD }\$LIB"; export LD_PRELOAD ;;
  esac
fi
# Must match invidious_companion_key in the Invidious config (16 chars).
SERVER_SECRET_KEY="$COMPANION_KEY"
export SERVER_SECRET_KEY
export PORT=8282
export HOST=127.0.0.1
# The upstream cache path is /var/tmp, which does not exist on Android;
# keep the player cache inside the Termux prefix.
export CACHE_DIRECTORY="\$PREFIX/var/tmp/invidious-companion"
mkdir -p "\$CACHE_DIRECTORY"
cd "$COMPANION_APP" || exit 1
exec deno run \\
  --allow-import=github.com:443,jsr.io:443,cdn.jsdelivr.net:443,esm.sh:443,deno.land:443 \\
  --allow-net --allow-env --allow-sys=hostname --allow-read \\
  --allow-write="\$CACHE_DIRECTORY/youtubei.js" \\
  src/main.ts
EOF

chmod +x "$PREFIX/var/service/invidious/run" "$PREFIX/var/service/invidious-companion/run"
# sv-enable -> `sv up` races runsvdir's scan of new service directories and
# prints a spurious "unable to open supervise/ok" warning; runsvdir starts
# them a few seconds later either way.
{ sv-enable invidious; } 2>/dev/null || true
{ sv-enable invidious-companion; } 2>/dev/null || true

WEB_PORT="$(sed -n 's/^port: //p' "$CONFIG" | head -1)"
WEB_PORT="${WEB_PORT:-$INVIDIOUS_PORT}"

# runsvdir rescans its service directory every few seconds, and the first
# start also creates the database tables; wait a bit so the summary below
# reflects reality instead of always claiming success.
up=0
i=0
while [ "$i" -lt 15 ]; do
    if curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$WEB_PORT/api/v1/stats" 2>/dev/null; then
        up=1
        break
    fi
    i=$((i + 1))
    sleep 2
done

echo
echo "installed. Web UI: http://127.0.0.1:$WEB_PORT"
WEB_BIND="$(sed -n 's/^host_binding: //p' "$CONFIG" | head -1)"
if [ "$WEB_BIND" = "0.0.0.0" ]; then
    LAN_IP="$(ifconfig 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1)"
    [ -n "$LAN_IP" ] && echo "  intranet:  http://$LAN_IP:$WEB_PORT"
fi
echo "  companion: http://127.0.0.1:8282 (private; Invidious talks to it)"
echo "  config:    $CONFIG (never overwritten by reinstalls)"
echo "  services:  sv status invidious invidious-companion postgres"
if [ "$up" = 1 ]; then
    echo "  status:    answering on port $WEB_PORT"
else
    echo "  status:    not answering yet -- check: sv status invidious"
    echo "             if port $WEB_PORT is in use by something else, re-run with"
    echo "             INVIDIOUS_PORT=<free port> (the config is updated in place)"
fi
