#!/usr/bin/env bash
#
# canon-g3020-ubuntu — single installer for the Canon PIXMA G3020
# printer (cnijfilter2 6.10) + scanner (scangearmp2 4.10) drivers.
#
# Canon only ships 2020-era source packages that do NOT build on a modern
# Ubuntu / gcc 15 toolchain. This script extracts Canon's original sources,
# applies the minimal set of portability patches (see docs/PORTING.md),
# builds both .deb packages, installs them, and configures a working CUPS
# print queue + an ink-level helper. Scanning works out of the box via
# sane-airscan (eSCL/WSD).
#
# Tested on: Ubuntu 26.04 (resolute), amd64, gcc 15.2, debhelper 13.
#
# Usage:
#   ./install.sh                # build + install everything, auto-configure
#   ./install.sh --no-queue     # build + install drivers only (skip CUPS queue)
#   ./install.sh --build-only   # build the .deb packages, do not install
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/src"
TOOLS_DIR="$REPO_DIR/tools"
BUILD_DIR="$REPO_DIR/build"

CNIJ_TAR="$SRC_DIR/cnijfilter2-source-6.10-1.tar.gz"
SCAN_TAR="$SRC_DIR/scangearmp2-source-4.10-1.tar.gz"
CNIJ_DIR="cnijfilter2-source-6.10-1"
SCAN_DIR="scangearmp2-source-4.10-1"

PPD_PATH="/usr/share/ppd/canong3020.ppd"
QUEUE_NAME="Canon_G3020"

DO_QUEUE=1
DO_INSTALL=1

for arg in "$@"; do
    case "$arg" in
        --no-queue)   DO_QUEUE=0 ;;
        --build-only) DO_INSTALL=0; DO_QUEUE=0 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root. Run as your normal user; sudo is used only where needed."
command -v sudo >/dev/null || die "sudo is required."
[ -f "$CNIJ_TAR" ] || die "Missing $CNIJ_TAR"
[ -f "$SCAN_TAR" ] || die "Missing $SCAN_TAR"

# ---------------------------------------------------------------------------
# 1. Build dependencies
# ---------------------------------------------------------------------------
install_deps() {
    log "Installing build & runtime dependencies (sudo apt-get)"
    sudo apt-get update -qq
    sudo apt-get install -y \
        build-essential debhelper fakeroot \
        autoconf automake libtool libtool-bin pkg-config intltool gettext \
        libcups2-dev libxml2-dev \
        libgtk2.0-dev libglib2.0-dev libusb-1.0-0-dev libsane-dev \
        cups sane-utils sane-airscan
    ok "Dependencies installed"
}

# ---------------------------------------------------------------------------
# 2. Portability patches (applied to freshly-extracted Canon sources)
#    See docs/PORTING.md for the reasoning behind each one.
# ---------------------------------------------------------------------------
patch_common() {
    local pkgdir="$1"          # cnijfilter2 or scangearmp2 source tree
    # (a) debhelper compat 4 is rejected by debhelper 13 -> bump to 10
    echo 10 > "$pkgdir/debian/compat"
    # (b) modern debhelper EXECUTES executable config files; Canon ships
    #     debian/docs mode 0775 -> strip the execute bit so it stays a list
    chmod -x "$pkgdir/debian/docs" 2>/dev/null || true
    # (c) dpkg now defaults Rules-Requires-Root to "no"; Canon's rules do
    #     `install -o lp -g lp ...` which needs fakeroot -> request it
    if ! grep -q '^Rules-Requires-Root:' "$pkgdir/debian/control"; then
        sed -i '/^Standards-Version:/a Rules-Requires-Root: binary-targets' "$pkgdir/debian/control"
    fi
}

patch_printer() {
    local d="$BUILD_DIR/$CNIJ_DIR"
    log "Patching printer source (cnijfilter2)"
    # obsolete libcupsys2-dev -> libcups2-dev, and pull in the tools the old
    # autogen.sh assumes are present
    sed -i 's/^Build-Depends:.*/Build-Depends: debhelper (>= 10), libcups2-dev, libxml2-dev, libtool, autoconf, automake, pkg-config/' \
        "$d/debian/control"
    patch_common "$d"
    ok "Printer source patched"
}

patch_scanner() {
    local d="$BUILD_DIR/$SCAN_DIR"
    log "Patching scanner source (scangearmp2)"
    sed -i 's/^Build-Depends:.*/Build-Depends: debhelper (>= 10), libtool, autoconf, automake, pkg-config, intltool, libgtk2.0-dev, libglib2.0-dev, libusb-1.0-0-dev, libsane-dev/' \
        "$d/debian/control"
    patch_common "$d"
    ok "Scanner source patched"
}

# ---------------------------------------------------------------------------
# 3. Build one package with the gcc-15 compatibility compiler wrappers
#    (tools/cc, tools/cxx add -fcommon -std=gnu17 -Wno-error ... so 2020-era
#     C/C++ compiles under gcc 15's C23 defaults, surviving configure.in
#     scripts that overwrite CFLAGS).
# ---------------------------------------------------------------------------
build_pkg() {
    local dir="$1"
    ( cd "$BUILD_DIR/$dir"
      CC="$TOOLS_DIR/cc" CXX="$TOOLS_DIR/cxx" \
          dpkg-buildpackage -b -us -uc -d )
}

extract_and_build() {
    log "Extracting sources into build/"
    rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
    tar xzf "$CNIJ_TAR" -C "$BUILD_DIR"
    tar xzf "$SCAN_TAR" -C "$BUILD_DIR"
    ok "Sources extracted"

    patch_printer
    patch_scanner

    log "Building printer package (this compiles the Canon filters)"
    build_pkg "$CNIJ_DIR"
    ok "Built $(ls "$BUILD_DIR"/cnijfilter2_*_amd64.deb 2>/dev/null | xargs -r basename)"

    log "Building scanner package"
    build_pkg "$SCAN_DIR"
    ok "Built $(ls "$BUILD_DIR"/scangearmp2_*_amd64.deb 2>/dev/null | xargs -r basename)"
}

# ---------------------------------------------------------------------------
# 4. Install the built .deb packages
# ---------------------------------------------------------------------------
install_debs() {
    log "Installing the built .deb packages (sudo)"
    local debs
    debs=$(ls "$BUILD_DIR"/cnijfilter2_*_amd64.deb "$BUILD_DIR"/scangearmp2_*_amd64.deb 2>/dev/null)
    [ -n "$debs" ] || die "No .deb packages found — build failed?"
    # shellcheck disable=SC2086
    sudo apt-get install -y $debs
    sudo ldconfig
    ok "Drivers installed"

    # Ink-level helper
    sudo install -m 755 "$TOOLS_DIR/canon-ink" /usr/local/bin/canon-ink
    ok "Installed 'canon-ink' helper to /usr/local/bin"
}

# ---------------------------------------------------------------------------
# 5. Configure the CUPS print queue with the Canon backend
# ---------------------------------------------------------------------------
setup_queue() {
    log "Configuring the print queue"
    [ -f "$PPD_PATH" ] || { warn "PPD $PPD_PATH not found; skipping queue setup."; return; }

    # Auto-discover the printer via Canon's own network backend.
    local disc uri
    disc="$(/usr/lib/cups/backend/cnijbe2 2>/dev/null | grep -m1 '^network')" || true
    uri="$(printf '%s' "$disc" | awk '{print $2}')"

    if [ -z "$uri" ]; then
        warn "Printer not found on the network automatically."
        warn "Turn the printer on and connect it to Wi-Fi, then either re-run this"
        warn "script or add it manually, e.g.:"
        warn "  sudo lpadmin -p $QUEUE_NAME -E -v socket://<PRINTER_IP>:9100 -P $PPD_PATH"
        return
    fi

    # cups-browsed can auto-create a broken 'implicitclass://' driverless queue
    # that fails with "No suitable destination host found". Disable it so our
    # permanent Canon queue is the single source of truth.
    if systemctl is-active --quiet cups-browsed 2>/dev/null; then
        sudo systemctl disable --now cups-browsed || true
        warn "Disabled cups-browsed (was creating a broken duplicate queue)."
        warn "Re-enable anytime with: sudo systemctl enable --now cups-browsed"
    fi

    sudo lpadmin -p "$QUEUE_NAME" -E -v "$uri" -P "$PPD_PATH" \
        -D "Canon G3020 series (Canon driver)" -L "Network" -o printer-is-shared=false
    sudo cupsenable "$QUEUE_NAME"
    sudo cupsaccept "$QUEUE_NAME"
    sudo lpadmin -d "$QUEUE_NAME"      # make it the system default
    ok "Queue '$QUEUE_NAME' created and set as default ($uri)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_deps
extract_and_build
if [ "$DO_INSTALL" -eq 1 ]; then
    install_debs
    [ "$DO_QUEUE" -eq 1 ] && setup_queue
fi

log "Done."
cat <<EOF

Next steps
----------
  • Print : your default printer is '$QUEUE_NAME'. Print from any app.
  • Ink   : run  canon-ink        (or open http://<printer-ip> in a browser)
  • Scan  : open 'Document Scanner' (simple-scan), or run 'scangearmp2',
            or:  scanimage -L  &&  scanimage -o ~/scan.png

Note: with the Canon backend, small print jobs can take ~30-60s to leave the
queue because the driver does an ink/status handshake after sending. Normal.
EOF
