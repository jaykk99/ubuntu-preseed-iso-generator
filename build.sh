#!/bin/bash
#
# build.sh — Bake a preseed.cfg into an Ubuntu 20.04 desktop ISO for a
# fully automated installation.
#
#   ./build.sh -s /path/to/ubuntu-20.04.x-desktop-amd64.iso \
#              [-p preseed.cfg] [-d ubuntu-preseed.iso]
#
# The source ISO is NEVER downloaded or modified — it must be supplied by you.
# The script extracts the ISO with xorriso, points the kernel command line
# (UEFI + BIOS) at the embedded preseed file, and repacks a bootable hybrid
# ISO.
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
TODAY=$(date +"%Y-%m-%d")
# Path to the hybrid-boot MBR template. Overridable for testing only:
#   ISOHDPFX_BIN=/tmp/fake.bin ./build.sh -s foo.iso
ISOHDPFX_BIN="${ISOHDPFX_BIN:-/usr/lib/ISOLINUX/isohdpfx.bin}"

log()  { echo >&2 "[$(date +"%Y-%m-%d %H:%M:%S")] $*"; }
die()  { log "ERROR: $1"; exit "${2:-1}"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") -s SOURCE_ISO [-p PRESEED] [-d DEST_ISO] [-h] [-v]

Build a fully-automated Ubuntu 20.04 desktop install ISO.

Required:
  -s, --source PATH       Ubuntu 20.04 desktop ISO to preseed (never downloaded,
                          never modified in place).

Optional:
  -p, --preseed PATH      Preseed file to bake in. Default: ${SCRIPT_DIR}/preseed.cfg
  -d, --destination PATH  Output ISO. Default: ./ubuntu-20.04-preseed-${TODAY}.iso
  -v, --verbose           Show every command (set -x).
  -h, --help              Show this help and exit.

Requirements (Debian/Ubuntu host):
  sudo apt install xorriso isolinux

Example:
  ./build.sh -s ~/iso/ubuntu-20.04.6-desktop-amd64.iso
EOF
    exit 0
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
source_iso=""
preseed_file="${SCRIPT_DIR}/preseed.cfg"
destination_iso="./ubuntu-20.04-preseed-${TODAY}.iso"

while [[ $# -gt 0 ]]; do
    case "${1-}" in
        -h|--help)    usage ;;
        -v|--verbose) set -x; shift ;;
        -s|--source)      source_iso="${2-}";      shift 2 ;;
        -p|--preseed)     preseed_file="${2-}";    shift 2 ;;
        -d|--destination) destination_iso="${2-}"; shift 2 ;;
        -?*) die "Unknown option: $1 (see -h)" ;;
        *)   die "Unexpected argument: $1 (see -h)" ;;
    esac
done

# --------------------------------------------------------------------------
# Input validation (fail fast, with clear errors)
# --------------------------------------------------------------------------

[[ -z "$source_iso" ]] && die "Source ISO is required: ./build.sh -s /path/to/ubuntu-20.04-desktop-amd64.iso"

[[ -r "$source_iso" ]] \
    || die "Source ISO not found or not readable: $source_iso"

# Sanity check: it should actually be an ISO 9660 image, not a stray .txt etc.
if command -v file >/dev/null 2>&1; then
    file -b "$source_iso" | grep -qi "ISO 9660" \
        || die "Does not look like an ISO image: $source_iso"
fi

[[ -r "$preseed_file" ]] \
    || die "Preseed file not found or not readable: $preseed_file"

# Basic preseed format check: every non-blank, non-comment line must have
# at least "<owner> <key> <type>" (value may be empty).
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    # join backslash continuations so multi-line commands count as one line
    full="$line"
    while [[ "$full" == *\\ ]]; do
        IFS= read -r cont || break
        full="${full%\\} ${cont#"${cont%%[![:space:]]*}"}"
    done
    words=$(wc -w <<<"$full")
    (( words >= 3 )) || die "Malformed preseed line (needs 'owner key type [value]'): $line"
done < "$preseed_file"
log "Preseed file looks valid: $preseed_file"

dest_dir=$(dirname "$destination_iso")
[[ -d "$dest_dir" && -w "$dest_dir" ]] \
    || die "Destination directory does not exist or is not writable: $dest_dir"

# Refuse to overwrite the source ISO with the output.
[[ "$(realpath -m "$source_iso")" == "$(realpath -m "$destination_iso")" ]] \
    && die "Destination must differ from the source ISO."
# Work with absolute paths from here on (the repack step runs inside tmpdir).
source_iso=$(realpath -m "$source_iso")
destination_iso=$(realpath -m "$destination_iso")

if [[ -e "$destination_iso" ]]; then
    log "WARNING: destination exists and will be overwritten: $destination_iso"
fi

# --------------------------------------------------------------------------
# Tool checks
# --------------------------------------------------------------------------
command -v xorriso >/dev/null 2>&1 \
    || die "xorriso is not installed. On Debian/Ubuntu: sudo apt install xorriso"
command -v md5sum >/dev/null 2>&1 \
    || die "md5sum is not installed (package: coreutils)."

[[ -r "$ISOHDPFX_BIN" ]] \
    || die "Hybrid-boot MBR template not found at $ISOHDPFX_BIN. On Debian/Ubuntu: sudo apt install isolinux"

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
tmpdir=$(mktemp -d)
cleanup() {
    rm -rf "$tmpdir"
    log "Deleted temporary working directory $tmpdir"
}
trap cleanup EXIT

log "Extracting $source_iso ..."
xorriso -osirrox on -indev "$source_iso" -extract / "$tmpdir" >/dev/null \
    || die "xorriso failed to extract the source ISO."
chmod -R u+w "$tmpdir"
rm -rf "$tmpdir/"'[BOOT]'

# Patch kernel command lines to point at our embedded preseed file.
PRESEED_ARGS="file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity quiet splash noprompt noshell"

# UEFI
for cfg in "$tmpdir/boot/grub/grub.cfg" "$tmpdir/boot/grub/loopback.cfg"; do
    if [[ -f "$cfg" ]]; then
        sed -i -e "s| maybe-ubiquity||g" \
               -e "s| quiet splash||g" \
               -e "s|file=/cdrom/preseed/ubuntu.seed|$PRESEED_ARGS|g" "$cfg"
        grep -q "custom.seed" "$cfg" \
            || die "Could not patch preseed kernel args into $cfg (unexpected ISO layout)."
    else
        log "WARNING: $cfg not found — skipping (UEFI boot entry may not preseed)."
    fi
done

# BIOS (legacy isolinux menu)
mkdir -p "$tmpdir/isolinux"
cat > "$tmpdir/isolinux/txt.cfg" <<EOF
default live-install
label live-install
  menu label ^Install Ubuntu (automated)
  kernel /casper/vmlinuz
  append  $PRESEED_ARGS initrd=/casper/initrd ---
EOF

# Drop the embedded preseed file into the ISO
mkdir -p "$tmpdir/preseed"
cp "$preseed_file" "$tmpdir/preseed/custom.seed"
log "Embedded preseed file as /preseed/custom.seed"

# The stock md5sum.txt no longer matches (we changed files); a stale one
# breaks the installer's integrity check, so remove it.
if [[ -f "$tmpdir/md5sum.txt" ]]; then
    rm -f "$tmpdir/md5sum.txt"
    log "Removed stale md5sum.txt (files were modified)."
fi

log "Repacking into $destination_iso ..."
(
    cd "$tmpdir"
    xorriso -as mkisofs \
        -r -V "ubuntu-20.04-preseed" -J \
        -b isolinux/isolinux.bin -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 \
        -isohybrid-mbr "$ISOHDPFX_BIN" -boot-info-table \
        -input-charset utf-8 \
        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$destination_iso" . >/dev/null \
        || die "xorriso failed to repack the ISO."
)
cd "$OLDPWD" 2>/dev/null || true

[[ -s "$destination_iso" ]] \
    || die "Build failed: $destination_iso was not created."

log "Done: $destination_iso"
log "Boot a machine from it — Ubuntu 20.04 desktop will install fully unattended."
