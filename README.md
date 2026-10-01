# Ubuntu Preseed ISO Generator

Build a **fully automated Ubuntu 20.04 (Focal Fossa) desktop install ISO**.
`build.sh` takes a stock Ubuntu 20.04 desktop ISO you supply, bakes in
`preseed.cfg`, patches the UEFI and BIOS boot entries to run the installer
unattended, and repacks a bootable hybrid ISO. Boot a machine from the output
ISO and Ubuntu installs itself with zero prompts, then powers off.

> The older `ubuntu-preseed-iso-generator.sh` from upstream is kept for
> reference. `build.sh` is the maintained entry point: it never downloads an
> ISO and validates every input before touching anything.

## Requirements

- A Linux host (tested logic on Debian/Ubuntu-style systems)
- `xorriso` and the isolinux MBR template:
  ```bash
  sudo apt install xorriso isolinux
  ```
- An Ubuntu 20.04 desktop ISO, e.g. `ubuntu-20.04.6-desktop-amd64.iso`
  (download from https://releases.ubuntu.com/20.04/ — the script never
  downloads one for you)
- ~4 GB free disk space for the extracted ISO tree

## Quick start

```bash
# 1. (Optional) set your own login password in preseed.cfg
openssl passwd -6   # paste the output into passwd/user-password-crypted

# 2. Build
./build.sh -s ~/iso/ubuntu-20.04.6-desktop-amd64.iso

# 3. Flash and boot
#    Output: ./ubuntu-20.04-preseed-<date>.iso
```

The machine boots the ISO, installs Ubuntu unattended, and powers off.
Log in as `ubuntu` (or whatever you configured).

## Usage

```
./build.sh -s SOURCE_ISO [-p PRESEED] [-d DEST_ISO] [-h] [-v]

  -s, --source PATH       Ubuntu 20.04 desktop ISO (required; never modified)
  -p, --preseed PATH      Preseed file to bake in (default: ./preseed.cfg)
  -d, --destination PATH  Output ISO (default: ./ubuntu-20.04-preseed-<date>.iso)
  -v, --verbose           Print every command (set -x)
  -h, --help              Show help
```

### What the script does, step by step

1. **Validates inputs** — source ISO exists and is actually an ISO 9660
   image, preseed file exists and every line matches the
   `owner key type [value]` format, destination dir is writable and differs
   from the source, `xorriso` and the isolinux MBR template are installed.
2. **Extracts** the source ISO to a temp dir with `xorriso -osirrox`.
3. **Patches boot entries** — `boot/grub/grub.cfg` and
   `boot/grub/loopback.cfg` (UEFI) get
   `file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper
   automatic-ubiquity quiet splash noprompt noshell`; `isolinux/txt.cfg`
   (BIOS) is rewritten with the same parameters.
4. **Embeds** your preseed file as `/preseed/custom.seed` in the ISO.
5. **Removes `md5sum.txt`** — the stock checksums no longer match the
   modified files, and a stale file breaks the installer's integrity check.
6. **Repacks** a hybrid (UEFI + BIOS bootable) ISO with `xorriso -as mkisofs`
   and cleans up the temp dir.

### Changing the install

Edit `preseed.cfg` and rebuild. The knobs you'll most likely want:

| Setting | Key in preseed.cfg | Default |
|---|---|---|
| Username / full name | `passwd/username`, `passwd/user-fullname` | `ubuntu` / `Ubuntu User` |
| Password (crypted!) | `passwd/user-password-crypted` | `ubuntu` ⚠️ change this |
| Timezone | `time/zone` | `America/Winnipeg` |
| Keyboard | `keyboard-configuration/layoutcode` | `us` |
| Hostname | `netcfg/get_hostname` | `ubuntu` |
| Target disk | `partman-auto/disk` | `/dev/sda` (wiped!) |
| Extra packages | `pkgsel/include` | `openssh-server vim curl git net-tools` |
| Power off vs reboot when done | `ubiquity/poweroff` / `ubiquity/reboot` | power off |

⚠️ **Passwords:** generate a crypted hash with `openssl passwd -6` and
replace the value of `passwd/user-password-crypted`. Never ship an ISO with
the default password anywhere real.

⚠️ **Partitioning wipes `/dev/sda`.** Point `partman-auto/disk` at the right
device for your hardware before building.

## Validation

- `bash -n build.sh` — syntax check, clean.
- `debconf-set-selections -c preseed.cfg` — preseed format check, clean.
- `build.sh` itself sanity-checks the preseed line format before building.
- End-to-end build logic tested against a stubbed `xorriso` with a fixture
  Ubuntu ISO layout: boot entries patched, preseed embedded, stale
  `md5sum.txt` removed, output ISO produced (both absolute and relative
  destination paths), and every error path (missing source, non-ISO input,
  malformed preseed, missing xorriso, unknown option) exits with a clear
  message. A real `xorriso` run on an actual Ubuntu ISO is still recommended
  before production use.

## License

MIT — see `LICENSE`.
