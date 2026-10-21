# Ubuntu Preseed ISO Generator
Generate an ISO image for automated Ubuntu installations. Two modes:

- **Preseed mode** (default): Ubuntu 20.04 desktop ISO + preseed file, patched
  and repacked into a hands-free installer ISO (debian-installer).
- **Autoinstall mode** (`--autoinstall`): Ubuntu 22.04/24.04/25.10. Builds a
  cloud-init "nocloud" seed ISO (volume label `cidata`) with a subiquity
  autoinstall `user-data` + `meta-data`. Boot any stock 22.04+ installer ISO
  with the seed attached and the install runs unattended. Preseed is legacy
  on 22.04+ (debian-installer was removed there); autoinstall is the
  supported path.

## [Looking for the server version?](https://github.com/covertsh/ubuntu-autoinstall-generator)

### Behavior

Check out the usage information below for arguments. The basic idea is to take an unmodified Ubuntu ISO image, extract it, add some kernel command line parameters and a preseed file, then repack the data into a new ISO. Creating the preseed file itself is outside the scope of this tool.

There is an example preseed file ```example.seed``` in this repository which will install Ubuntu using US English settings and UTC time zone with a user named "User" and password "ubuntu". You could modify that file to create your own custom configuration. Unlike the server version of this script, there is currently no way to provide the preseed configuration on a separate volume during the installation - it must be baked into the ISO image.

This script can use an existing ISO image or download the latest daily 64-bit image from the Ubuntu project. Using a fresh ISO speeds things up because there won't be as many packages to update during the installation.

By default, the source ISO image is checked for integrity and authenticity using GPG. This can be disabled with ```-k```.

### Requirements
Tested on a host running Ubuntu 20.04.1.
- Utilities required (the script checks for these and exits with a clear error if any are missing):
    - ```xorriso```
    - ```sed```
    - ```curl```
    - ```gpg```
    - ```isolinux``` (provides ```/usr/lib/ISOLINUX/isohdpfx.bin```)

Autoinstall mode only needs ```xorriso``` (plus optional ```openssl``` to hash
`--password`, and python3 + PyYAML for full YAML validation of user-data).

### Usage
```
Usage: ubuntu-preseed-iso-generator.sh [-h] [-k] [-v] [-n] [-i] [-t] [-p preseed-file] [-s source-iso] [-d destination-iso]

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
                    SHA256SUMS-<current date> and SHA256SUMS-<current date>.gpg in
                    <script directory> are used to verify the authenticity and
                    integrity of the source ISO file. If they are not present the
                    latest daily SHA256SUMS files are downloaded and saved in
                    <script directory>, along with the Ubuntu signing key in a new
                    keyring in <script directory>
-p, --preseed       Path to the preseed configuration file (required).
-s, --source        Source ISO file. By default the latest daily ISO for
                    Ubuntu 20.04 is downloaded and saved as
                    <script directory>/ubuntu-original-<current date>.iso
                    That file is reused by default if it already exists.
-d, --destination   Destination ISO file. By default
                    <script directory>/ubuntu-preseed-<current date>.iso is created,
                    overwriting any existing file.

Examples:
  ubuntu-preseed-iso-generator.sh -p example.seed
  ubuntu-preseed-iso-generator.sh -p mysetup.seed -s ~/isos/focal-desktop-amd64.iso -d ~/my-auto-install.iso
  ubuntu-preseed-iso-generator.sh -i -n          # answer prompts, then only show the plan
```

### Autoinstall mode (Ubuntu 22.04/24.04/25.10)

```bash
# Generate a user-data from flags and build the seed ISO:
ubuntu-preseed-iso-generator.sh --autoinstall --username jay \
  --password-hash '$6$...' --hostname srv1 \
  --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" --packages "git,curl" \
  --timezone America/Winnipeg

# Use your own cloud-config instead of generating one:
ubuntu-preseed-iso-generator.sh --autoinstall --user-data my-user-data.yaml

# Pick the release (default 24.04 in autoinstall mode):
ubuntu-preseed-iso-generator.sh --autoinstall --release 22.04 --username jay --password s3cret -n
```

In autoinstall mode the script validates your options (username/hostname shape,
a login method is present), renders `user-data`, validates it structurally
(plus a real YAML parse when python3 + PyYAML are available), writes
`meta-data`, and packs both into the seed ISO with volume label `cidata`.
Then boot a stock installer ISO for the same release with the seed ISO
attached as a second CD (QEMU: `-drive file=seed.iso,format=raw`) — the
installer picks it up automatically and installs with zero prompts.

`--password` (plaintext) is hashed with `openssl passwd -6` when openssl is
available; prefer `--password-hash` with a pre-hashed `$6$` crypt string so
the plaintext never appears on the command line.

Before doing anything destructive the script runs pre-flight checks: all required
utilities are present (with install hints when they aren't), the preseed file is
readable and non-empty, source and destination aren't the same file, the
destination directory is writable, and there is enough free disk space for
extraction plus repackaging. Use `-n`/`--dry-run` to see the full plan first.

### Example
```
user@testbox:~$ bash ubuntu-preseed-iso-generator.sh -p example.seed -d ubuntu-preseed-example.iso
[2021-03-13 10:05:10] 👶 Starting up...
[2021-03-13 10:05:10] 📁 Created temporary working directory /tmp/tmp.rrehvj78Bk
[2021-03-13 10:05:10] 🔎 Checking for required utilities...
[2021-03-13 10:05:10] 👍 All required utilities are installed.
[2020-12-23 14:06:07] 🌎 Downloading current daily ISO image for Ubuntu 20.04 Focal Fossa...
[2020-12-23 14:08:01] 👍 Downloaded and saved to /home/user/ubuntu-original-2021-03-13.iso
[2020-12-23 14:08:01] 🌎 Downloading SHA256SUMS & SHA256SUMS.gpg files...
[2020-12-23 14:08:02] 🌎 Downloading and saving Ubuntu signing key...
[2020-12-23 14:08:02] 👍 Downloaded and saved to /home/user/843938DF228D22F7B3742BC0D94AA3F0EFE21092.keyring
[2020-12-23 14:08:02] 🔐 Verifying /home/user/ubuntu-original-2021-03-13.iso integrity and authenticity...
[2020-12-23 14:08:09] 👍 Verification succeeded.
[2020-12-23 14:08:09] 🔧 Extracting ISO image...
[2021-03-13 10:05:23] 👍 Extracted to /tmp/tmp.rrehvj78Bk
[2021-03-13 10:05:23] 🧩 Adding preseed parameters to kernel command line...
[2021-03-13 10:05:23] 👍 Added parameters to UEFI and BIOS kernel command lines.
[2021-03-13 10:05:23] 🧩 Adding preseed configuration file...
[2021-03-13 10:05:23] 👍 Added preseed file
[2021-03-13 10:05:23] 👷 Updating /tmp/tmp.rrehvj78Bk/md5sum.txt with hashes of modified files...
[2021-03-13 10:05:23] 👍 Updated hashes.
[2021-03-13 10:05:23] 📦 Repackaging extracted files into an ISO image...
[2021-03-13 10:05:35] 👍 Repackaged into /home/user/ubuntu-preseed-example.iso
[2021-03-13 10:05:35] ✅ Completed.
[2021-03-13 10:05:35] 🚽 Deleted temporary working directory /tmp/tmp.rrehvj78Bk
```

Now you can boot your target machine using ```ubuntu-preseed-example.iso``` and it will automatically install Ubuntu using the configuration from ```example.seed```.

### Thanks
This script is based on [this](https://betterdev.blog/minimal-safe-bash-script-template/) minimal safe bash template, and steps found in [this](https://askubuntu.com/questions/806820/how-do-i-create-a-completely-unattended-install-of-ubuntu-desktop-16-04-1-lts) Ask Ubuntu answer.


### License
MIT license.
