#!/data/data/com.termux/files/usr/bin/sh
# Install Invidious (CI-built native binary) + companion + PostgreSQL on Termux.
# Single-file installer: config template and service scripts are embedded
# below as heredocs (they are the source of truth; see docs/TERMUX-NOTES.md).
#
# - Downloads the release tarball and verifies its sha256 before installing.
# - Backs up an existing $PREFIX/bin/invidious once to invidious.pkg-backup.
# - Generates config + secrets ONCE; reinstalls never overwrite
#   $PREFIX/share/invidious/config/config.yml.
# - Sets up three termux-services: postgresql, invidious (:3000),
#   invidious-companion (:8282). The companion is compiled on-device with
#   Deno (fast, unlike the Crystal build, which happens in CI).
set -eu

TAG="v2.20261022.0-termux.1"
VER="2.20261022.0"
ASSET="invidious_${VER}_termux_arm64.tar.gz"
SHA256="TO_BE_FILLED_AFTER_CI"
URL="https://github.com/wirawira941/invidious-termux/releases/download/${TAG}/${ASSET}"
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

# ---------------------------------------------------------------- packages
PKGS="postgresql deno git curl libgc libevent libyaml pcre2 libxml2 openssl libpq sqlite libiconv libgmp zlib libc++ liblzma librsvg"
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

# ------------------------------------------------------------------ config
rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
rand_key16() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }

if [ -n "$CONFIG_SAVED" ]; then
    cp -a "$CONFIG_SAVED" "$CONFIG"
    DB_PASSWORD="$(sed -n 's/^  password: //p' "$CONFIG" | head -1)"
    COMPANION_KEY="$(sed -n 's/^invidious_companion_key: //p' "$CONFIG" | head -1 | tr -d '"')"
    echo "config restored unchanged"
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

# Local-only by default. To publish this instance, set host_binding to
# 0.0.0.0, set domain: to your public hostname, and review
# https://docs.invidious.io/installation/#post-install-configuration
host_binding: 127.0.0.1
port: 3000

hmac_key: "$HMAC_KEY"
EOF
    echo "config written to $CONFIG (secrets generated once)"
fi

# --------------------------------------------------------------- postgres
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "initialising PostgreSQL data directory"
    initdb -D "$PGDATA" >/dev/null
fi
if ! pg_isready -q -h 127.0.0.1 -p 5432; then
    if [ -d "$PREFIX/var/service/postgresql" ]; then
        sv-enable postgresql 2>/dev/null || true
        sv up postgresql 2>/dev/null || true
    fi
fi
tries=0
until pg_isready -q -h 127.0.0.1 -p 5432; do
    tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then
        echo "PostgreSQL did not come up; start it manually:" >&2
        echo "  sv up postgresql    (or: pg_ctl -D \"$PGDATA\" start)" >&2
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
if [ ! -x "$COMPANION_DIR/invidious_companion" ]; then
    echo "building invidious-companion on-device with Deno (one-time)"
    rm -rf "$WORK/companion-src"
    git clone -q "$COMPANION_REPO" "$WORK/companion-src"
    ( cd "$WORK/companion-src" \
      && git checkout -q "$COMPANION_COMMIT" \
      && deno task compile )
    mkdir -p "$COMPANION_DIR"
    install -m 0755 "$WORK/companion-src/invidious_companion" "$COMPANION_DIR/invidious_companion"
fi
echo "companion binary: $COMPANION_DIR/invidious_companion"

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
exec "\$PREFIX/share/invidious-companion/invidious_companion"
EOF

chmod +x "$PREFIX/var/service/invidious/run" "$PREFIX/var/service/invidious-companion/run"
sv-enable invidious 2>/dev/null || true
sv-enable invidious-companion 2>/dev/null || true

echo
echo "installed. Web UI: http://127.0.0.1:3000"
echo "  companion: http://127.0.0.1:8282 (private; Invidious talks to it)"
echo "  config:    $CONFIG (never overwritten by reinstalls)"
echo "  services:  sv status invidious invidious-companion postgresql"
echo "First start can take a moment (table creation). If a service does"
echo "not come up, restart Termux once and check: sv status invidious"
