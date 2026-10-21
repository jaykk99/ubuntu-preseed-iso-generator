#!/bin/bash
#
# ubuntu-preseed-iso-generator.sh — build fully-automated Ubuntu installation media.
#
# Two modes:
#   1. Preseed mode (default): Ubuntu 20.04 desktop ISO + preseed file, patched
#      and repacked into a hands-free installer ISO (debian-installer, legacy).
#   2. Autoinstall mode (--autoinstall): Ubuntu 22.04/24.04/25.10. Generates a
#      cloud-init "nocloud" seed ISO (volume label "cidata") carrying a
#      subiquity autoinstall user-data + meta-data. Boot any stock 22.04+
#      installer ISO with the seed attached and the install runs unattended.
#      Preseed is legacy on 22.04+ (d-i was removed); autoinstall is the
#      supported path there.
#
# MIT license. See LICENSE.
#
set -Eeuo pipefail

VERSION="2.1.0"

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

# autoinstall mode
autoinstall=0
release=""
autoinstall_hostname="ubuntu"
autoinstall_username=""
autoinstall_password=""
autoinstall_password_hash=""
ssh_keys=()
autoinstall_packages=""
autoinstall_timezone="Etc/UTC"
autoinstall_locale="en_US.UTF-8"
user_data_file=""
meta_data_file=""

# Release -> codename used by cdimage.ubuntu.com daily-live paths.
release_codename() {
        case "$1" in
        20.04) echo "focal" ;;
        22.04) echo "jammy" ;;
        24.04) echo "noble" ;;
        25.10) echo "questing" ;;
        *) return 1 ;;
        esac
}

# Daily desktop ISO URL for a release.
release_iso_url() {
        local codename
        codename="$(release_codename "$1")" || return 1
        echo "https://cdimage.ubuntu.com/${codename}/daily-live/current/${codename}-desktop-amd64.iso"
}

default_source_iso() {
        echo "${script_dir}/ubuntu-original-${release}-${today}.iso"
}

default_destination_iso() {
        if [[ "${autoinstall}" -eq 1 ]]; then
                echo "${script_dir}/ubuntu-autoinstall-seed-${release}-${today}.iso"
        else
                echo "${script_dir}/ubuntu-preseed-${today}.iso"
        fi
}

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
       $script_name --autoinstall [--release 22.04|24.04|25.10] [--hostname H] --username U
                    [--password P | --password-hash H] [--ssh-key KEY]... [--packages a,b,c]
                    [--timezone TZ] [--locale LOC] [--user-data file] [-d destination-iso] [-n]

💁 This script creates fully-automated Ubuntu installation media, in two modes.

PRESEED MODE (default): Ubuntu 20.04 Focal Fossa. Takes a stock Ubuntu ISO,
injects your preseed file plus the kernel command-line parameters needed for
a hands-free install, and repacks everything into a new ISO.

AUTOINSTALL MODE (--autoinstall): Ubuntu 22.04/24.04/25.10. Preseed
(debian-installer) is legacy there, so instead this generates a cloud-init
"nocloud" seed ISO (volume label "cidata") with a subiquity autoinstall
user-data and meta-data. Boot any stock 22.04+ installer ISO with the seed
ISO attached (second CD, or QEMU -drive file=seed.iso,format=raw) and the
install runs unattended. The installer ISO itself is NOT modified.

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
-p, --preseed       Path to the preseed configuration file (preseed mode, required).
-s, --source        Source ISO file. By default the latest daily ISO for
                    the release is downloaded and saved as
                    $script_dir/ubuntu-original-<release>-$today.iso
                    That file is reused by default if it already exists.
                    (Ignored in autoinstall mode: the seed ISO is standalone.)
-d, --destination   Destination ISO file. By default
                    $script_dir/ubuntu-preseed-$today.iso (preseed mode) or
                    $script_dir/ubuntu-autoinstall-seed-<release>-$today.iso
                    (autoinstall mode) is created, overwriting any existing file.

Autoinstall-only options:

    --autoinstall   Switch to autoinstall mode (default release 24.04).
    --release       Ubuntu release: 20.04, 22.04, 24.04 or 25.10.
                    Default 20.04 in preseed mode, 24.04 in autoinstall mode.
                    (Preseed mode with a release other than 20.04 warns: the
                    boot patch targets the 20.04 desktop ISO layout.)
    --hostname      Installed system hostname (default: ubuntu).
    --username      Login username for the installed system (required,
                    unless --user-data is given).
    --password      Login password (plaintext; hashed with openssl -6 when
                    available, otherwise stored as-is — prefer --password-hash).
    --password-hash Pre-hashed password (\$6\$... crypt string), used verbatim.
    --ssh-key       SSH public key for the user (repeatable).
    --packages      Comma-separated extra packages to install.
    --timezone      Timezone for the installed system (default: Etc/UTC).
    --locale        Locale for the installed system (default: en_US.UTF-8).
    --user-data     Use your own cloud-config user-data file instead of
                    generating one (it must contain an "autoinstall:" section;
                    --username/--password/--ssh-key etc. are ignored then).

Examples:
  $script_name -p example.seed
  $script_name -p mysetup.seed -s ~/isos/focal-desktop-amd64.iso -d ~/my-auto-install.iso
  $script_name -i -n          # answer prompts, then only show the plan
  $script_name --autoinstall --username jay --password-hash '\$6\$...' --hostname srv1
  $script_name --autoinstall --release 22.04 --username jay --ssh-key "\$(cat ~/.ssh/id_ed25519.pub)" -n
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
        source_iso=""
        destination_iso=""
        gpg_verify=1
        dry_run=0
        interactive=0
        keep_tmp=0
        autoinstall=0
        release=""
        autoinstall_hostname="ubuntu"
        autoinstall_username=""
        autoinstall_password=""
        autoinstall_password_hash=""
        ssh_keys=()
        autoinstall_packages=""
        autoinstall_timezone="Etc/UTC"
        autoinstall_locale="en_US.UTF-8"
        user_data_file=""
        meta_data_file=""

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
                --autoinstall) autoinstall=1 ;;
                --release)
                        release="${2-}"
                        shift
                        ;;
                --hostname)
                        autoinstall_hostname="${2-}"
                        shift
                        ;;
                --username)
                        autoinstall_username="${2-}"
                        shift
                        ;;
                --password)
                        autoinstall_password="${2-}"
                        shift
                        ;;
                --password-hash)
                        autoinstall_password_hash="${2-}"
                        shift
                        ;;
                --ssh-key)
                        ssh_keys+=("${2-}")
                        shift
                        ;;
                --packages)
                        autoinstall_packages="${2-}"
                        shift
                        ;;
                --timezone)
                        autoinstall_timezone="${2-}"
                        shift
                        ;;
                --locale)
                        autoinstall_locale="${2-}"
                        shift
                        ;;
                --user-data)
                        user_data_file="${2-}"
                        shift
                        ;;
                -?*) die "Unknown option: $1 (see --help)" ;;
                *) break ;;
                esac
                shift
        done

        # An option that needs a value but got none (e.g. "-p" at the end).
        [[ -n "${1-}" ]] && die "Unexpected argument: $1 (see --help)"

        # Release profile: preseed defaults to 20.04, autoinstall to 24.04.
        if [[ -z "${release}" ]]; then
                if [[ "${autoinstall}" -eq 1 ]]; then
                        release="24.04"
                else
                        release="20.04"
                fi
        fi
        release_codename "${release}" >/dev/null \
                || die "Unsupported --release \"${release}\" (choose 20.04, 22.04, 24.04 or 25.10)."
        if [[ "${autoinstall}" -eq 0 && "${release}" != "20.04" ]]; then
                warn "Preseed mode targets the Ubuntu 20.04 desktop ISO layout; --release ${release} is accepted but the boot patch may not apply cleanly."
        fi
        if [[ "${autoinstall}" -eq 1 && "${release}" == "20.04" ]]; then
                die "Autoinstall mode needs Ubuntu 22.04 or newer (20.04 has no subiquity autoinstall on the desktop ISO). Use preseed mode for 20.04."
        fi

        [[ -z "${source_iso}" ]] && source_iso="$(default_source_iso)"
        [[ -z "${destination_iso}" ]] && destination_iso="$(default_destination_iso)"

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
        local default_src
        default_src="$(default_source_iso)"
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
        local default_dst
        default_dst="$(default_destination_iso)"
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
                # A dry run never builds an ISO, so xorriso is not needed for it.
                if [[ "${dry_run}" -eq 1 && "${tool}" == "xorriso" ]]; then
                        continue
                fi
                if ! command -v "${tool}" &>/dev/null; then
                        log "   ❌ ${tool} is not installed. Install it with: ${hints[$tool]}"
                        missing=1
                fi
        done
        if [[ "${autoinstall}" -eq 0 && "${dry_run}" -eq 0 ]]; then
                # Preseed mode repacks a hybrid ISO, so it needs the isolinux
                # MBR (a dry run never repacks, so it does not need it).
                # Autoinstall mode only builds a small data (cidata) ISO.
                if [[ ! -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]]; then
                        log "   ❌ isolinux is not installed (missing /usr/lib/ISOLINUX/isohdpfx.bin). Install it with: sudo apt install isolinux"
                        missing=1
                fi
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
        if [[ "${source_iso}" == "$(default_source_iso)" && ! -s "${source_iso}" ]]; then
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
        [[ "${source_will_download}" -eq 1 ]] && echo "     1. Download daily Ubuntu ${release} ISO"
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
                local codename url
                codename="$(release_codename "${release}")"
                url="$(release_iso_url "${release}")"
                step "Downloading current daily ISO image for Ubuntu ${release} (${codename})..."
                download_file "${url}" "${source_iso}"
                ok "Downloaded and saved to ${source_iso}"
        else
                log "☑️  Using existing ${source_iso} file."
                if [[ "${gpg_verify}" -eq 1 && "${source_iso}" != "$(default_source_iso)" ]]; then
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

        local sums="${script_dir}/SHA256SUMS-${release}-${today}"
        local sums_sig="${sums}.gpg"
        local keyring="${script_dir}/${ubuntu_gpg_key_id}.keyring"
        local codename base_url
        codename="$(release_codename "${release}")"
        base_url="https://cdimage.ubuntu.com/${codename}/daily-live/current"

        if [[ ! -f "${sums}" || ! -f "${sums_sig}" ]]; then
                step "Downloading SHA256SUMS & SHA256SUMS.gpg files..."
                download_file "${base_url}/SHA256SUMS" "${sums}"
                download_file "${base_url}/SHA256SUMS.gpg" "${sums_sig}"
        else
                log "☑️  Using existing SHA256SUMS-${release}-${today} & SHA256SUMS-${release}-${today}.gpg files."
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

# -------------------------------------------------------- autoinstall ----
# Autoinstall mode (--autoinstall): generate a cloud-init "nocloud" seed ISO
# (volume label "cidata") with subiquity autoinstall user-data + meta-data.
# Boot any stock Ubuntu 22.04+ installer ISO with this seed attached and the
# install runs unattended. The installer ISO itself is never modified.

# Resolve the password to store: pre-hashed wins; plaintext is hashed with
# openssl when available; otherwise it is stored as-is with a loud warning
# (cloud-init accepts plaintext, but it lands in the seed ISO verbatim).
resolve_password_hash() {
        if [[ -n "${autoinstall_password_hash}" ]]; then
                printf '%s' "${autoinstall_password_hash}"
                return 0
        fi
        if [[ -z "${autoinstall_password}" ]]; then
                echo ""
                return 0
        fi
        if command -v openssl &>/dev/null; then
                openssl passwd -6 "${autoinstall_password}"
        else
                warn "openssl not found: storing the password in plaintext in user-data. Prefer --password-hash."
                printf '%s' "${autoinstall_password}"
        fi
}

# generate_user_data <output-file>: render the subiquity autoinstall
# cloud-config from the --username/--password/--ssh-key/... options.
# Written with printf (not heredoc interpolation) so $ in password hashes
# and special characters in keys can never break the YAML.
generate_user_data() {
        local out=$1
        local pw_hash
        pw_hash="$(resolve_password_hash)"

        {
                printf '#cloud-config\n'
                printf '# Generated by %s v%s on %s for Ubuntu %s autoinstall.\n' \
                        "${script_name}" "${VERSION}" "${today}" "${release}"
                printf '# Attach as a second CD (volume label "cidata") when booting\n'
                printf '# a stock Ubuntu %s installer ISO for a fully automatic install.\n' "${release}"
                printf 'autoinstall:\n'
                printf '  version: 1\n'
                printf '  locale: %s\n' "${autoinstall_locale}"
                printf '  keyboard:\n'
                printf '    layout: us\n'
                printf '  identity:\n'
                printf '    hostname: %s\n' "${autoinstall_hostname}"
                printf '    username: %s\n' "${autoinstall_username}"
                printf '    password: "%s"\n' "${pw_hash}"
                printf '  timezone: %s\n' "${autoinstall_timezone}"
                printf '  ssh:\n'
                printf '    install-server: true\n'
                if [[ "${#ssh_keys[@]}" -gt 0 ]]; then
                        printf '    allow-pw: false\n'
                        printf '    authorized-keys:\n'
                        local key
                        for key in "${ssh_keys[@]}"; do
                                printf '      - "%s"\n' "${key}"
                        done
                else
                        printf '    allow-pw: true\n'
                fi
                if [[ -n "${autoinstall_packages}" ]]; then
                        printf '  packages:\n'
                        local pkg
                        local IFS=','
                        for pkg in ${autoinstall_packages}; do
                                pkg="$(printf '%s' "${pkg}" | tr -d ' ')"
                                [[ -n "${pkg}" ]] && printf '    - %s\n' "${pkg}"
                        done
                        unset IFS
                fi
                printf '  storage:\n'
                printf '    layout:\n'
                printf '      name: lvm\n'
        } > "${out}"
}

# generate_meta_data <output-file>: the nocloud meta-data companion.
generate_meta_data() {
        local out=$1
        {
                printf 'instance-id: iid-%s-%s\n' "${today}" "${autoinstall_hostname}"
                printf 'local-hostname: %s\n' "${autoinstall_hostname}"
        } > "${out}"
}

# validate_user_data_file <file>: structural checks + a real YAML parse when
# python3 has PyYAML. Dies on any failure.
validate_user_data_file() {
        local f=$1
        [[ -f "${f}" ]] || die "user-data file not found: ${f}"
        [[ -s "${f}" ]] || die "user-data file is empty: ${f}"
        head -n 1 "${f}" | grep -q '^#cloud-config' \
                || die "user-data must start with '#cloud-config' (first line of ${f} does not)."
        grep -q '^autoinstall:' "${f}" \
                || die "user-data has no top-level 'autoinstall:' section — the installer would ignore it."
        grep -q 'version: 1' "${f}" \
                || warn "user-data has no 'version: 1' under autoinstall: (subiquity may reject it)."
        if command -v python3 &>/dev/null && python3 -c 'import yaml' 2>/dev/null; then
                python3 - "${f}" <<'PYEOF' || die "user-data is not valid YAML."
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert isinstance(doc, dict), "top-level YAML must be a mapping"
assert "autoinstall" in doc, "missing autoinstall section"
PYEOF
                log "   ✅ user-data parsed as valid YAML (python3 + PyYAML)."
        else
                log "   ℹ️  PyYAML not available — structural checks only."
        fi
        ok "user-data validation passed."
}

# build_seed_iso <seed-dir>: pack user-data + meta-data into the cidata ISO.
build_seed_iso() {
        local seed_dir=$1
        step "Building nocloud seed ISO..."
        local start=$SECONDS
        xorriso -as mkisofs -r -V cidata -J -joliet-long \
                -o "${destination_iso}" "${seed_dir}" &>/dev/null \
                || die "xorriso failed to build the seed ISO."
        [[ -s "${destination_iso}" ]] || die "Seed ISO build produced an empty file: ${destination_iso}"
        ok "Seed ISO written to ${destination_iso} ($(numfmt --to=iec "$(stat -c%s "${destination_iso}")")) in $(( SECONDS - start ))s"
        log "   💡 Boot your Ubuntu ${release} installer ISO with this seed ISO attached"
        log "      as a second CD (QEMU: -drive file=${destination_iso},format=raw)."
}

preflight_autoinstall() {
        step "Running autoinstall pre-flight checks..."

        if [[ -n "${user_data_file}" ]]; then
                # User-supplied cloud-config: validate it, identity options ignored.
                validate_user_data_file "${user_data_file}"
                if [[ -n "${autoinstall_username}" || -n "${autoinstall_password}" \
                        || -n "${autoinstall_password_hash}" || "${#ssh_keys[@]}" -gt 0 \
                        || -n "${autoinstall_packages}" ]]; then
                        warn "--user-data given: --username/--password/--ssh-key/--packages are ignored."
                fi
        else
                [[ -z "${autoinstall_username}" ]] && die "autoinstall mode needs --username (or supply --user-data)."
                [[ "${autoinstall_username}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
                        || die "username \"${autoinstall_username}\" is not a valid Linux username."
                if [[ -z "${autoinstall_password}" && -z "${autoinstall_password_hash}" \
                        && "${#ssh_keys[@]}" -eq 0 ]]; then
                        die "no login method: give --password, --password-hash, or at least one --ssh-key."
                fi
        fi

        [[ -z "${autoinstall_hostname}" ]] && die "hostname is empty."
        [[ "${autoinstall_hostname}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
                || die "hostname \"${autoinstall_hostname}\" is not a valid hostname."

        # destination (same rules as preseed mode)
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

        # The seed ISO is tiny; only check there is *some* room.
        local free_dst
        free_dst="$(df --output=avail -B1 "${dest_dir}" | tail -1)"
        [[ "${free_dst}" -lt 10485760 ]] && die "Less than 10 MiB free in ${dest_dir} — cannot write the seed ISO."

        ok "Autoinstall pre-flight checks passed."
}

print_autoinstall_plan() {
        local user_data_path=$1 meta_data_path=$2
        echo
        echo "📋 DRY RUN — nothing will be written."
        echo "   Mode         : autoinstall (Ubuntu ${release}, subiquity)"
        echo "   Hostname     : ${autoinstall_hostname}"
        echo "   Username     : ${autoinstall_username:-"(from --user-data)"}"
        echo "   SSH keys     : ${#ssh_keys[@]}"
        echo "   Packages     : ${autoinstall_packages:-"(none)"}"
        echo "   Timezone     : ${autoinstall_timezone}"
        echo "   Destination  : ${destination_iso}$([[ -e "${destination_iso}" ]] && echo " (WILL BE OVERWRITTEN)" || echo " (new file)")"
        echo
        echo "   Generated user-data:"
        echo "   ----------------------------------------------------------------"
        sed 's/^/   /' "${user_data_path}"
        echo "   ----------------------------------------------------------------"
        echo "   Generated meta-data:"
        sed 's/^/   /' "${meta_data_path}"
        echo
        echo "   Steps that would run:"
        echo "     1. Validate user-data (structure + YAML when PyYAML is available)"
        echo "     2. Pack user-data + meta-data into ${destination_iso} (volume label \"cidata\")"
        echo
        echo "   Then boot a stock Ubuntu ${release} installer ISO with the seed ISO"
        echo "   attached as a second CD for a fully automatic install."
        echo
}

prompt_autoinstall() {
        local answer
        read -r -p "🖥️  Hostname [${autoinstall_hostname}]: " answer
        autoinstall_hostname="${answer:-${autoinstall_hostname}}"
        while [[ -z "${autoinstall_username}" ]]; do
                read -r -p "👤 Username (required): " autoinstall_username
                [[ -z "${autoinstall_username}" ]] && echo "   ❌ Username is required."
        done
        if [[ "${#ssh_keys[@]}" -eq 0 ]]; then
                read -r -s -p "🔑 Password (empty = none, prefer SSH key): " autoinstall_password
                echo
                read -r -p "🔐 Path to SSH public key to install (empty = none): " answer
                if [[ -n "${answer}" && -r "${answer}" ]]; then
                        ssh_keys=("$(cat "${answer}")")
                elif [[ -n "${answer}" ]]; then
                        echo "   ❌ Not readable, skipping."
                fi
        fi
        read -r -p "📦 Extra packages (comma-separated, empty = none): " answer
        autoinstall_packages="${answer}"
        read -r -p "🌍 Timezone [${autoinstall_timezone}]: " answer
        autoinstall_timezone="${answer:-${autoinstall_timezone}}"
}

# autoinstall_main: the --autoinstall pipeline (after parse_params).
autoinstall_main() {
        [[ "${interactive}" -eq 1 ]] && prompt_autoinstall

        check_requirements
        preflight_autoinstall

        tmpdir="$(mktemp -d)"
        if [[ -z "${tmpdir}" || ! -d "${tmpdir}" ]]; then
                die "Could not create temporary working directory."
        fi
        local seed_dir="${tmpdir}/seed"
        mkdir -p "${seed_dir}"

        local user_data_path="${seed_dir}/user-data"
        local meta_data_path="${seed_dir}/meta-data"
        if [[ -n "${user_data_file}" ]]; then
                cp "${user_data_file}" "${user_data_path}"
        else
                generate_user_data "${user_data_path}"
        fi
        generate_meta_data "${meta_data_path}"
        validate_user_data_file "${user_data_path}"

        if [[ "${dry_run}" -eq 1 ]]; then
                print_autoinstall_plan "${user_data_path}" "${meta_data_path}"
                log "✅ Dry run complete — no changes made."
                exit 0
        fi

        build_seed_iso "${seed_dir}"

        log "✅ Completed."
        exit 0
}

# ------------------------------------------------------------------ main ----
main() {
        parse_params "$@"

        log "👶 Starting up..."

        if [[ "${autoinstall}" -eq 1 ]]; then
                autoinstall_main
        fi

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
