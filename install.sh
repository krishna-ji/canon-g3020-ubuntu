#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_DIR/build"
PRINTER_SRC="$REPO_DIR/src/cnijfilter2-source-6.10-1"
SCANNER_SRC="$REPO_DIR/src/scangearmp2-source-4.10-1"
PPD_PATH=/usr/share/ppd/canong3020.ppd
QUEUE_NAME=Canon_G3020

DO_INSTALL=1
DO_QUEUE=1
INSTALL_DEPS=1

usage() {
    cat <<'EOF'
Usage: ./install.sh [--build-only | --no-queue] [--skip-deps]

Build and install the bundled Canon G3020 printer and scanner drivers on
amd64 Ubuntu. Run as a normal user; system changes use sudo.

  --build-only  Write .deb files under build/ without installing the drivers.
  --no-queue    Install the drivers without configuring a CUPS queue.
  --skip-deps   Use already installed dependencies; skip apt dependency setup.
  -h, --help    Show this help.
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --build-only) DO_INSTALL=0; DO_QUEUE=0 ;;
        --no-queue)   DO_QUEUE=0 ;;
        --skip-deps)  INSTALL_DEPS=0 ;;
        -h|--help)    usage; exit 0 ;;
        *)            printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

(( EUID != 0 )) || die 'Run as a normal user; the installer invokes sudo where needed.'
command -v dpkg >/dev/null || die 'This installer requires Ubuntu with dpkg.'
arch="$(dpkg --print-architecture)"
[[ "$arch" == amd64 ]] || die "This installer supports amd64 Ubuntu (found $arch)."
for source_dir in "$PRINTER_SRC" "$SCANNER_SRC"; do
    [[ -x "$source_dir/debian/rules" ]] || die "Missing or incomplete driver source: $source_dir"
done
if (( INSTALL_DEPS || DO_INSTALL )); then
    command -v sudo >/dev/null || die 'sudo is required for system changes.'
fi

install_deps() {
    log 'Installing build dependencies from Ubuntu'
    sudo apt-get update
    sudo apt-get install -y build-essential
    sudo apt-get build-dep -y "$PRINTER_SRC" "$SCANNER_SRC"

    if (( DO_INSTALL )); then
        log 'Installing CUPS and scanner utilities'
        sudo apt-get install -y cups cups-ipp-utils sane-utils sane-airscan
    fi
}

build_pkg() {
    local source_dir="$1" pkg="$2" role="$3"
    local version
    cp -a -- "$source_dir" "$work_dir/"
    log "Building $pkg"
    (
        cd -- "$work_dir/${source_dir##*/}"
        dpkg-buildpackage -b -us -uc
    )
    version="$(dpkg-parsechangelog -l "$source_dir/debian/changelog" -S Version)"
    local suffix="${version#*:}_${arch}.deb"
    local archive="${pkg}_${suffix}"
    [[ -f "$work_dir/$archive" ]] || die "Build did not produce $archive"
    local output="canon-g3020-${role}_${suffix}"
    mv -- "$work_dir/$archive" "$work_dir/$output"
    debs+=("$output")
}

setup_queue() {
    log 'Configuring the Canon G3020 print queue'
    [[ -f "$PPD_PATH" ]] || die "Installed printer PPD is missing: $PPD_PATH"

    local discovered uri
    local -a uris
    discovered="$(/usr/lib/cups/backend/cnijbe2 2>/dev/null)" || true
    mapfile -t uris < <(awk '$1 == "network" && $2 ~ /^cnijbe2:\/\// && /"Canon G3020 series"/ {print $2}' <<< "$discovered" | sort -u)
    if (( ${#uris[@]} != 1 )); then
        if (( ${#uris[@]} == 0 )); then
            warn 'No Canon G3020 was discovered. Check that the printer is on and connected to the same network.'
        else
            warn 'Multiple Canon G3020 printers were discovered. Select a printer in CUPS.'
        fi
        warn "To add a queue by IP: sudo lpadmin -p $QUEUE_NAME -E -v 'socket://PRINTER_IP:9100' -P '$PPD_PATH'"
        return
    fi

    uri="${uris[0]}"
    sudo lpadmin -p "$QUEUE_NAME" -E -v "$uri" -P "$PPD_PATH" \
        -D 'Canon G3020 series (Canon driver)' -o printer-is-shared=false
    sudo lpadmin -d "$QUEUE_NAME"
    log "Default print queue: $QUEUE_NAME ($uri)"
}

if (( INSTALL_DEPS )); then
    install_deps
fi
for tool in dpkg-buildpackage dpkg-parsechangelog; do
    command -v "$tool" >/dev/null || die "Missing $tool; rerun without --skip-deps."
done
if [[ "${TMPDIR:-/tmp}" =~ [[:space:]] ]]; then
    # Legacy Autotools/Debian recipes require a build directory without spaces.
    work_dir="$(mktemp -d /tmp/canon-g3020.XXXXXXXX)"
else
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/canon-g3020.XXXXXXXX")"
fi
trap 'rm -rf -- "$work_dir"' EXIT

debs=()
build_pkg "$PRINTER_SRC" cnijfilter2 printer
build_pkg "$SCANNER_SRC" scangearmp2 scanner
mkdir -p -- "$BUILD_DIR"
for i in "${!debs[@]}"; do
    mv -f -- "$work_dir/${debs[i]}" "$BUILD_DIR/"
    debs[i]="$BUILD_DIR/${debs[i]}"
done
log 'Packages built:'
printf '  %s\n' "${debs[@]}"

if (( DO_INSTALL )); then
    log 'Installing the Canon driver packages and ink-level helper'
    sudo apt-get install -y --reinstall "${debs[@]}"
    sudo ldconfig
    sudo install -m 755 -- "$REPO_DIR/tools/canon-ink" /usr/local/bin/canon-ink
    if (( DO_QUEUE )); then
        setup_queue
    fi
    log 'Drivers installed. Run scangearmp2 to scan or canon-ink PRINTER_IP to check ink.'
fi
