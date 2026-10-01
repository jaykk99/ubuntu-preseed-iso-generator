#!/bin/bash
#
# ubuntu-preseed-iso-generator.sh — build fully-automated Ubuntu 20.04
# (Focal Fossa) desktop installation media from a stock ISO + preseed file.
#
# MIT license. See LICENSE.
#
set -Eeuo pipefail

VERSION="2.0.0"

script_name="$(basename "${BASH_SOURCE[0]}")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
today="$(date +"%Y-%m-%d")"

ubuntu_gpg_key_id="843938DF228D22F7B3742BC0D94AA3F0EFE21092"

# ---------------------------------------------------------------- options ----
preseed_file=""
source_iso=""
destination_iso=""
gpg_verify=1
dry_run=0
interactive=0
keep_tmp=0
tmpdir=""

# --------------------------------------------------------------- helpers ----
log()  { echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"; }
step() { log "▶️  $1"; }
ok()   { log "👍 $1"; }
warn() { log "⚠️  $1"; }

die() {
        local msg=$1
        local code=${2:-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
        log "💥 $msg"
        exit "$code"
}

# Remove temp dir unless --keep-tmp was given.
cleanup() {
        trap - SIGINT SIGTERM ERR EXIT
        if [[ -n "${tmpdir}" && -d "${tmpdir}" ]]; then
                if [[ "${keep_tmp}" -eq 1 ]]; then
                        log "🧪 Keeping temporary working directory $tmpdir (--keep-tmp)"
                else
                        rm -rf "$tmpdir"
                        log "🚽 Deleted temporary working directory $tmpdir"
                fi
        fi
}
trap cleanup SIGINT SIGTERM ERR EXIT

usage() {
        cat <<EOF
Usage: $script_name [-h] [-k] [-v] [-n] [-i] [-t] [-p preseed-file] [-s source-iso] [-d destination-iso]

💁 This script creates fully-automated Ubuntu 20.04 Focal Fossa installation media.
It takes a stock Ubuntu ISO, injects your preseed file plus the kernel command-line
parameters needed for a hands-free install, and repacks everything into a new ISO.

Available options:

-h, --help          Print this help and exit
    --version       Print the script version and exit
-v, --verbose       Print script debug info
-n, --dry-run       Run every check and print what would happen, without
                    downloading, extracting or writing anything
-i, --interactive   Prompt for the preseed file, source ISO and destination,
                    validating each answer
-t, --keep-tmp      Keep the temporary working directory after the run
                    (useful for debugging)
-k, --no-verify     Disable GPG verification of the source ISO file. By default
                    SHA256SUMS-$today and SHA256SUMS-$today.gpg in
                    $script_dir are used to verify the authenticity and
                    integrity of the source ISO. If they are not present the
                    latest daily SHA256SUMS files are downloaded and saved in
                    $script_dir, along with the Ubuntu signing key in a new
                    keyring in $script_dir
-p, --preseed       Path to the preseed configuration file (required).
-s, --source        Source ISO file. By default the latest daily ISO for
                    Ubuntu 20.04 is downloaded and saved as
                    $script_dir/ubuntu-original-$today.iso
                    That file is reused by default if it already exists.
-d, --destination   Destination ISO file. By default
                    $script_dir/ubuntu-preseed-$today.iso is created,
                    overwriting any existing file.

Examples:
  $script_name -p example.seed
  $script_name -p mysetup.seed -s ~/isos/focal-desktop-amd64.iso -d ~/my-auto-install.iso
  $script_name -i -n          # answer prompts, then only show the plan
EOF
        exit 0
}

version() {
        echo "$script_name version $VERSION"
        exit 0
}

parse_params() {
        # default values of variables set from params
        preseed_file=""
        source_iso="${script_dir}/ubuntu-original-${today}.iso"
        destination_iso="${script_dir}/ubuntu-preseed-${today}.iso"
        gpg_verify=1
        dry_run=0
        interactive=0
        keep_tmp=0

        while :; do
                case "${1-}" in
                -h | --help) usage ;;
                --version) version ;;
                -v | --verbose) set -x ;;
                -n | --dry-run) dry_run=1 ;;
                -i | --interactive) interactive=1 ;;
                -t | --keep-tmp) keep_tmp=1 ;;
                -k | --no-verify) gpg_verify=0 ;;
                -p | --preseed)
                        preseed_file="${2-}"
                        shift
                        ;;
                -s | --source)
                        source_iso="${2-}"
                        shift
                        ;;
                -d | --destination)
                        destination_iso="${2-}"
                        shift
                        ;;
                -?*) die "Unknown option: $1 (see --help)" ;;
                *) break ;;
                esac
                shift
        done

        # An option that needs a value but got none (e.g. "-p" at the end).
        [[ -n "${1-}" ]] && die "Unexpected argument: $1 (see --help)"

        source_iso="$(realpath -m "${source_iso}")"
        destination_iso="$(realpath -m "${destination_iso}")"

        return 0
}

# ---------------------------------------------------------- interactive -----
prompt_preseed() {
        while :; do
                read -r -p "📄 Path to preseed file: " preseed_file
                [[ -z "${preseed_file}" ]] && { echo "Aborted."; exit 1; }
                if [[ -s "${preseed_file}" && -r "${preseed_file}" ]]; then
                        break
                fi
                echo "   ❌ Not a readable, non-empty file. Try again (empty aborts)."
        done
}

prompt_source() {
        local default_src="${script_dir}/ubuntu-original-${today}.iso"
        while :; do
                read -r -p "💿 Source ISO [${default_src}]: " answer
                source_iso="${answer:-$default_src}"
                source_iso="$(realpath -m "${source_iso}")"
                if [[ -s "${source_iso}" ]]; then
                        break
                elif [[ "${source_iso}" == "${default_src}" ]]; then
                        echo "   ℹ️  Will download the latest daily ISO."
                        break
                fi
                echo "   ❌ File not found. Enter an existing ISO, or press Enter to download the daily ISO."
        done
}

prompt_destination() {
        local default_dst="${script_dir}/ubuntu-preseed-${today}.iso"
        read -r -p "💾 Destination ISO [${default_dst}]: " answer
        destination_iso="$(realpath -m "${answer:-$default_dst}")"
}

prompt_verify() {
        local answer
        read -r -p "🔐 Verify source ISO with GPG? [Y/n]: " answer
        case "${answer}" in
        [nN]*) gpg_verify=0 ;;
        *)     gpg_verify=1 ;;
        esac
}

run_interactive() {
        echo "🧙 Interactive setup (empty preseed path aborts)"
        prompt_preseed
        prompt_source
        prompt_destination
        prompt_verify
        echo
}

# ---------------------------------------------------------- requirements ----
check_requirements() {
        step "Checking for required utilities..."
        local missing=0
        # tool -> install hint
        declare -A hints=(
                [xorriso]="sudo apt install xorriso"
                [sed]="sudo apt install sed"
                [curl]="sudo apt install curl"
                [gpg]="sudo apt install gnupg"
                [sha256sum]="sudo apt install coreutils"
                [md5sum]="sudo apt install coreutils"
                [mktemp]="sudo apt install coreutils"
                [realpath]="sudo apt install coreutils"
                [stat]="sudo apt install coreutils"
                [df]="sudo apt install coreutils"
                [grep]="sudo apt install grep"
                [chmod]="sudo apt install coreutils"
        )
        local tool
        for tool in "${!hints[@]}"; do
                if ! command -v "${tool}" &>/dev/null; then
                        log "   ❌ ${tool} is not installed. Install it with: ${hints[$tool]}"
                        missing=1
                fi
        done
        if [[ ! -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]]; then
                log "   ❌ isolinux is not installed (missing /usr/lib/ISOLINUX/isohdpfx.bin). Install it with: sudo apt install isolinux"
                missing=1
        fi
        [[ "${missing}" -eq 1 ]] && die "One or more required utilities are missing."
        ok "All required utilities are installed."
}

# ------------------------------------------------------------- pre-flight ---
source_will_download=0

preflight() {
        step "Running pre-flight checks..."

        # preseed file
        [[ -z "${preseed_file}" ]] && die "preseed file was not specified. Use -p/--preseed or -i/--interactive."
        [[ ! -f "${preseed_file}" ]] && die "preseed file could not be found: ${preseed_file}"
        [[ ! -r "${preseed_file}" ]] && die "preseed file is not readable: ${preseed_file}"
        [[ ! -s "${preseed_file}" ]] && die "preseed file is empty: ${preseed_file}"

        # source ISO
        if [[ "${source_iso}" == "${script_dir}/ubuntu-original-${today}.iso" && ! -s "${source_iso}" ]]; then
                source_will_download=1
        else
                [[ ! -f "${source_iso}" ]] && die "Source ISO file could not be found: ${source_iso}"
                [[ ! -s "${source_iso}" ]] && die "Source ISO file is empty: ${source_iso}"
        fi

        # destination
        [[ "${source_iso}" == "${destination_iso}" ]] && die "Source and destination ISO are the same file: ${source_iso}"
        local dest_dir
        dest_dir="$(dirname "${destination_iso}")"
        if [[ ! -d "${dest_dir}" ]]; then
                if [[ "${dry_run}" -eq 1 ]]; then
                        warn "Destination directory does not exist yet: ${dest_dir} (would be created)"
                else
                        mkdir -p "${dest_dir}" || die "Could not create destination directory: ${dest_dir}"
                        log "📁 Created destination directory ${dest_dir}"
                fi
        fi
        [[ -e "${destination_iso}" && ! -w "${destination_iso}" ]] && die "Destination ISO exists but is not writable: ${destination_iso}"
        [[ ! -w "${dest_dir}" ]] && die "Destination directory is not writable: ${dest_dir}"

        # script dir must be writable when we need to download checksums/keys there
        if [[ "${gpg_verify}" -eq 1 || "${source_will_download}" -eq 1 ]]; then
                [[ ! -w "${script_dir}" ]] && die "Script directory is not writable, but downloads need to be saved there: ${script_dir}"
        fi

        # disk space: extraction needs ~1x source size in temp, repack needs ~1x at destination
        local tmp_base="${TMPDIR:-/tmp}"
        local iso_size=0
        [[ "${source_will_download}" -eq 0 ]] && iso_size="$(stat -c%s "${source_iso}")"
        if [[ "${iso_size}" -gt 0 ]]; then
                local need_tmp=$(( iso_size * 2 + 1073741824 ))   # 2x + 1 GiB headroom
                local need_dst=$(( iso_size + 536870912 ))        # 1x + 512 MiB headroom
                local free_tmp free_dst
                free_tmp="$(df --output=avail -B1 "${tmp_base}" | tail -1)"
                free_dst="$(df --output=avail -B1 "${dest_dir}" | tail -1)"
                [[ "${free_tmp}" -lt "${need_tmp}" ]] && die "Not enough free space in ${tmp_base}: need ~$(( need_tmp / 1073741824 )) GiB, have $(( free_tmp / 1073741824 )) GiB."
                [[ "${free_dst}" -lt "${need_dst}" ]] && die "Not enough free space in ${dest_dir}: need ~$(( need_dst / 1073741824 )) GiB, have $(( free_dst / 1073741824 )) GiB."
                log "   💽 Disk space OK (source $(numfmt --to=iec "${iso_size}"), temp+dest headroom verified)"
        else
                warn "Source ISO will be downloaded (~4-6 GB); make sure you have ~15 GB free."
        fi

        ok "Pre-flight checks passed."
}

print_plan() {
        echo
        echo "📋 DRY RUN — nothing will be downloaded, extracted or written."
        echo "   Preseed file : ${preseed_file} ($(numfmt --to=iec "$(stat -c%s "${preseed_file}")"))"
        if [[ "${source_will_download}" -eq 1 ]]; then
                echo "   Source ISO   : ${source_iso} (will be downloaded)"
        else
                echo "   Source ISO   : ${source_iso} ($(numfmt --to=iec "$(stat -c%s "${source_iso}")"), exists)"
        fi
        echo "   Destination  : ${destination_iso}$([[ -e "${destination_iso}" ]] && echo " (WILL BE OVERWRITTEN)" || echo " (new file)")"
        echo "   GPG verify   : $([[ "${gpg_verify}" -eq 1 ]] && echo "yes" || echo "no")"
        echo "   Temp dir base: ${TMPDIR:-/tmp}"
        echo
        echo "   Steps that would run:"
        [[ "${source_will_download}" -eq 1 ]] && echo "     1. Download daily Ubuntu 20.04 ISO"
        [[ "${gpg_verify}" -eq 1 ]] && echo "     2. Download SHA256SUMS + Ubuntu signing key, verify ISO"
        echo "     3. Extract ISO to a temp dir"
        echo "     4. Patch UEFI (grub.cfg, loopback.cfg) + BIOS (isolinux/txt.cfg) boot entries"
        echo "     5. Copy preseed file to preseed/custom.seed"
        echo "     6. Refresh md5sum.txt for the modified files"
        echo "     7. Repack into ${destination_iso}"
        echo
}

# --------------------------------------------------------------- download ---
download_file() {
        # download_file <url> <destination> — atomic: writes to .part, moves on success
        local url=$1 dest=$2 part="${2}.part"
        rm -f "${part}"
        if ! curl -fNsSL --retry 3 --retry-delay 5 "${url}" -o "${part}"; then
                rm -f "${part}"
                die "Download failed: ${url}"
        fi
        [[ -s "${part}" ]] || { rm -f "${part}"; die "Downloaded file is empty: ${url}"; }
        mv "${part}" "${dest}"
}

ensure_source_iso() {
        if [[ "${source_will_download}" -eq 1 ]]; then
                step "Downloading current daily ISO image for Ubuntu 20.04 Focal Fossa..."
                download_file "https://cdimage.ubuntu.com/focal/daily-live/current/focal-desktop-amd64.iso" "${source_iso}"
                ok "Downloaded and saved to ${source_iso}"
        else
                log "☑️  Using existing ${source_iso} file."
                if [[ "${gpg_verify}" -eq 1 && "${source_iso}" != "${script_dir}/ubuntu-original-${today}.iso" ]]; then
                        warn "Automatic GPG verification is enabled. If the source ISO is not the latest daily image, verification will fail!"
                fi
        fi
}

# --------------------------------------------------------------- verify -----
verify_iso() {
        if [[ "${gpg_verify}" -ne 1 ]]; then
                log "🤞 Skipping verification of source ISO."
                return 0
        fi

        local sums="${script_dir}/SHA256SUMS-${today}"
        local sums_sig="${sums}.gpg"
        local keyring="${script_dir}/${ubuntu_gpg_key_id}.keyring"

        if [[ ! -f "${sums}" || ! -f "${sums_sig}" ]]; then
                step "Downloading SHA256SUMS & SHA256SUMS.gpg files..."
                download_file "https://cdimage.ubuntu.com/focal/daily-live/current/SHA256SUMS" "${sums}"
                download_file "https://cdimage.ubuntu.com/focal/daily-live/current/SHA256SUMS.gpg" "${sums_sig}"
        else
                log "☑️  Using existing SHA256SUMS-${today} & SHA256SUMS-${today}.gpg files."
        fi

        if [[ ! -f "${keyring}" ]]; then
                step "Downloading and saving Ubuntu signing key..."
                if ! gpg -q --no-default-keyring --keyring "${keyring}" --keyserver "hkp://keyserver.ubuntu.com" --recv-keys "${ubuntu_gpg_key_id}"; then
                        rm -f "${keyring}"
                        die "Could not download the Ubuntu signing key from keyserver.ubuntu.com."
                fi
                ok "Downloaded and saved to ${keyring}"
        else
                log "☑️  Using existing Ubuntu signing key saved in ${keyring}"
        fi

        step "Verifying ${source_iso} integrity and authenticity..."
        local gpg_out
        if ! gpg_out="$(gpg -q --keyring "${keyring}" --verify "${sums_sig}" "${sums}" 2>&1)"; then
                rm -f "${keyring}~"
                die "Verification of SHA256SUMS signature failed. gpg said: ${gpg_out}"
        fi
        rm -f "${keyring}~"

        local digest
        digest="$(sha256sum "${source_iso}" | cut -f1 -d ' ')"
        if grep -Fq "${digest}" "${sums}"; then
                ok "Verification succeeded."
        else
                die "Verification of ISO digest failed: ${source_iso} is not listed in ${sums}."
        fi
}

# --------------------------------------------------------------- extract ----
extract_iso() {
        step "Extracting ISO image..."
        local start=$SECONDS
        xorriso -osirrox on -indev "${source_iso}" -extract / "${tmpdir}" &>/dev/null \
                || die "xorriso failed to extract ${source_iso}. Is it a valid ISO image?"
        chmod -R u+w "${tmpdir}"
        rm -rf "${tmpdir}/"'[BOOT]'
        ok "Extracted to ${tmpdir} in $(( SECONDS - start ))s"

        # Sanity-check the extracted layout before patching anything.
        local expected=( "boot/grub/grub.cfg" "boot/grub/loopback.cfg" "isolinux" "casper" )
        local f
        for f in "${expected[@]}"; do
                [[ -e "${tmpdir}/${f}" ]] || die "Extracted ISO is missing ${f}. Is this really an Ubuntu 20.04 desktop ISO?"
        done
}

# ----------------------------------------------------------------- patch ----
patch_bootloader() {
        step "Adding preseed parameters to kernel command line..."

        # UEFI entries — verify the expected pattern exists before replacing it,
        # so a changed ISO layout fails loudly instead of booting unpatched.
        local grub_cfg="${tmpdir}/boot/grub/grub.cfg"
        local loopback_cfg="${tmpdir}/boot/grub/loopback.cfg"
        grep -q "file=/cdrom/preseed/ubuntu.seed" "${grub_cfg}" \
                || warn "Expected pattern not found in boot/grub/grub.cfg — UEFI menu entry may not be patched (ISO layout changed?)."
        grep -q "file=/cdrom/preseed/ubuntu.seed" "${loopback_cfg}" \
                || warn "Expected pattern not found in boot/grub/loopback.cfg — loopback entry may not be patched (ISO layout changed?)."

        sed -i -e 's,file=/cdrom/preseed/ubuntu.seed maybe-ubiquity quiet splash,file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity quiet splash noprompt noshell,g' "${grub_cfg}"
        sed -i -e 's,file=/cdrom/preseed/ubuntu.seed maybe-ubiquity iso-scan/filename=${iso_path} quiet splash,file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity quiet splash noprompt noshell,g' "${loopback_cfg}"

        grep -q "preseed/custom.seed" "${grub_cfg}" \
                || die "Patching boot/grub/grub.cfg failed — no custom.seed reference present afterwards."
        grep -q "preseed/custom.seed" "${loopback_cfg}" \
                || die "Patching boot/grub/loopback.cfg failed — no custom.seed reference present afterwards."

        # BIOS entry
        cat <<'EOF' > "${tmpdir}/isolinux/txt.cfg"
default live-install
label live-install
  menu label ^Install Ubuntu
  kernel /casper/vmlinuz
  append  file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity initrd=/casper/initrd quiet splash noprompt noshell ---
EOF
        ok "Added parameters to UEFI and BIOS kernel command lines."
}

add_preseed() {
        step "Adding preseed configuration file..."
        mkdir -p "${tmpdir}/preseed"
        cp "${preseed_file}" "${tmpdir}/preseed/custom.seed"
        ok "Added preseed file"
}

update_checksums() {
        step "Updating ${tmpdir}/md5sum.txt with hashes of modified files..."
        # Using the full list of hashes causes long delays at boot.
        # For now, just include a couple of the files we changed.
        local md5
        md5="$(md5sum "${tmpdir}/boot/grub/grub.cfg" | cut -f1 -d ' ')"
        echo "${md5}  ./boot/grub/grub.cfg" > "${tmpdir}/md5sum.txt"
        md5="$(md5sum "${tmpdir}/boot/grub/loopback.cfg" | cut -f1 -d ' ')"
        echo "${md5}  ./boot/grub/loopback.cfg" >> "${tmpdir}/md5sum.txt"
        ok "Updated hashes."
}

repackage_iso() {
        step "Repackaging extracted files into an ISO image..."
        local start=$SECONDS
        (
                cd "${tmpdir}"
                xorriso -as mkisofs -r -V "ubuntu-preseed-${today}" -J \
                        -b isolinux/isolinux.bin -c isolinux/boot.cat \
                        -no-emul-boot -boot-load-size 4 -boot-info-table \
                        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
                        -input-charset utf-8 \
                        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
                        -isohybrid-gpt-basdat \
                        -o "${destination_iso}" . &>/dev/null
        ) || die "xorriso failed to repack the ISO image."
        [[ -s "${destination_iso}" ]] || die "Repackaging produced an empty file: ${destination_iso}"
        ok "Repackaged into ${destination_iso} ($(numfmt --to=iec "$(stat -c%s "${destination_iso}")")) in $(( SECONDS - start ))s"
}

# ------------------------------------------------------------------ main ----
main() {
        parse_params "$@"

        log "👶 Starting up..."

        [[ "${interactive}" -eq 1 ]] && run_interactive

        check_requirements
        preflight

        if [[ "${dry_run}" -eq 1 ]]; then
                print_plan
                log "✅ Dry run complete — no changes made."
                exit 0
        fi

        tmpdir="$(mktemp -d)"
        if [[ -z "${tmpdir}" || ! -d "${tmpdir}" ]]; then
                die "Could not create temporary working directory."
        fi
        log "📁 Created temporary working directory ${tmpdir}"

        ensure_source_iso
        verify_iso
        extract_iso
        patch_bootloader
        add_preseed
        update_checksums
        repackage_iso

        log "✅ Completed."
        exit 0
}

main "$@"
