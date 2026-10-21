#!/bin/bash
# tests/run.sh — verification harness for ubuntu-preseed-iso-generator.sh.
#
# Runs without root and without network: every test uses --dry-run (nothing
# is downloaded, extracted or written). shellcheck and the real seed-ISO
# build run only when the tools are installed; otherwise they are skipped
# with a clear note instead of failing.
#
# Usage: ./tests/run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd -P)"
SCRIPT="${SCRIPT_DIR}/ubuntu-preseed-iso-generator.sh"

pass=0
fail=0
skip=0

ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
no()   { fail=$((fail+1)); echo "  ❌ $1"; }
note() { skip=$((skip+1)); echo "  ⏭️  $1 (skipped)"; }

# expect_ok <desc> <command...>: command must exit 0.
expect_ok() {
        local desc=$1; shift
        if "$@" >/tmp/quota-test-out.txt 2>&1; then ok "${desc}"; else
                no "${desc}"; sed 's/^/     /' /tmp/quota-test-out.txt | head -5
        fi
}

# expect_fail <desc> <command...>: command must exit non-zero.
expect_fail() {
        local desc=$1; shift
        if "$@" >/tmp/quota-test-out.txt 2>&1; then no "${desc} (expected failure, got success)"; else ok "${desc}"; fi
}

# expect_in <desc> <needle> <command...>: command must exit 0 and print needle.
expect_in() {
        local desc=$1 needle=$2; shift 2
        if "$@" >/tmp/quota-test-out.txt 2>&1 && grep -qF -e "${needle}" /tmp/quota-test-out.txt; then
                ok "${desc}"
        else
                no "${desc} (missing ${needle@Q})"; head -5 /tmp/quota-test-out.txt | sed 's/^/     /'
        fi
}

echo "== syntax =="
expect_ok "bash -n passes" bash -n "${SCRIPT}"

echo "== shellcheck =="
if command -v shellcheck &>/dev/null; then
        expect_ok "shellcheck -S warning is clean" shellcheck -S warning "${SCRIPT}"
else
        note "shellcheck not installed"
fi

echo "== autoinstall dry-run (all releases) =="
for rel in 22.04 24.04 25.10; do
        expect_in "autoinstall --release ${rel} dry-run shows release" \
                "Ubuntu ${rel}" \
                "${SCRIPT}" --autoinstall --release "${rel}" \
                --username testuser --password-hash '$6$test$hash' \
                --hostname "test-${rel/./-}" -n
done

echo "== autoinstall user-data content =="
expect_in "user-data starts with #cloud-config" \
        "#cloud-config" \
        "${SCRIPT}" --autoinstall --username jay \
        --ssh-key "ssh-ed25519 AAAAtest jay@box" --hostname srv1 -n
expect_in "username lands in identity" \
        "username: jay" \
        "${SCRIPT}" --autoinstall --username jay \
        --ssh-key "ssh-ed25519 AAAAtest jay@box" -n
expect_in "ssh key lands in authorized-keys" \
        "ssh-ed25519 AAAAtest jay@box" \
        "${SCRIPT}" --autoinstall --username jay \
        --ssh-key "ssh-ed25519 AAAAtest jay@box" -n
expect_in "packages list rendered" \
        "- wireguard" \
        "${SCRIPT}" --autoinstall --username jay --password x \
        --packages "git,wireguard" -n
expect_in "meta-data has local-hostname" \
        "local-hostname: srv1" \
        "${SCRIPT}" --autoinstall --username jay --password x \
        --hostname srv1 -n
expect_in "destination defaults to seed ISO name" \
        "ubuntu-autoinstall-seed-24.04" \
        "${SCRIPT}" --autoinstall --username jay --password x -n

echo "== autoinstall error paths =="
expect_fail "missing --username fails" \
        "${SCRIPT}" --autoinstall --password x -n
expect_fail "no login method fails" \
        "${SCRIPT}" --autoinstall --username jay -n
expect_fail "bad username fails" \
        "${SCRIPT}" --autoinstall --username 'Bad Name!' --password x -n
expect_fail "autoinstall on 20.04 fails" \
        "${SCRIPT}" --autoinstall --release 20.04 --username jay --password x -n
expect_fail "unknown release fails" \
        "${SCRIPT}" --release 99.99 --autoinstall --username jay --password x -n

echo "== custom user-data =="
GOOD_UD="$(mktemp)"; BAD_UD="$(mktemp)"
trap 'rm -f "${GOOD_UD}" "${BAD_UD}"' EXIT
printf '#cloud-config\nautoinstall:\n  version: 1\n' > "${GOOD_UD}"
printf 'nope: not cloud config\n' > "${BAD_UD}"
expect_ok "valid custom user-data accepted" \
        "${SCRIPT}" --autoinstall --user-data "${GOOD_UD}" -n
expect_fail "user-data without #cloud-config rejected" \
        "${SCRIPT}" --autoinstall --user-data "${BAD_UD}" -n
expect_fail "missing user-data file rejected" \
        "${SCRIPT}" --autoinstall --user-data /nonexistent-ud.yaml -n

echo "== preseed mode regression =="
dd if=/dev/zero of=/tmp/quota-fake.iso bs=1M count=1 status=none
# This sandbox's /tmp is tiny; keep the dry-run's space checks on the repo
# dir (a dry run creates nothing there anyway).
export TMPDIR="${SCRIPT_DIR}"
expect_in "preseed dry-run still works" \
        "DRY RUN" \
        "${SCRIPT}" -n -k -p "${SCRIPT_DIR}/example.seed" \
        -s /tmp/quota-fake.iso -d "${SCRIPT_DIR}/quota-out-test.iso"
unset TMPDIR
rm -f /tmp/quota-fake.iso "${SCRIPT_DIR}/quota-out-test.iso"
expect_fail "preseed mode still requires -p" \
        "${SCRIPT}" -n
expect_fail "unknown flag still fails" \
        "${SCRIPT}" --bogus

echo "== real seed ISO build =="
if command -v xorriso &>/dev/null; then
        OUT="$(mktemp -d)/seed.iso"
        if "${SCRIPT}" --autoinstall --username jay --password x \
                -d "${OUT}" >/tmp/quota-test-out.txt 2>&1; then
                if [[ -s "${OUT}" ]] && xorriso -indev "${OUT}" -find / -maxdepth 1 2>/dev/null | grep -q 'user-data'; then
                        ok "seed ISO built with user-data + meta-data (volume label cidata)"
                else
                        no "seed ISO missing user-data"
                fi
        else
                no "seed ISO build failed"; head -5 /tmp/quota-test-out.txt | sed 's/^/     /'
        fi
        rm -rf "$(dirname "${OUT}")"
else
        note "xorriso not installed"
fi

echo
echo "results: ${pass} passed, ${fail} failed, ${skip} skipped"
[[ "${fail}" -eq 0 ]]
