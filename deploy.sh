#!/bin/sh
# Deploy the static NetBSD/evbarm utilities to the Time Capsule.
#
# - Copies the prebuilt binaries from ./bin to /Volumes/dk2/.tc_tools/bin.
# - Installs the PATH hook (/mnt/Flash/setenv.sh) and the boot re-seed script
#   (/mnt/Flash/seed_profile.sh).
# - Uses scp -O (legacy SCP protocol) because the TC's sshd lacks the SFTP
#   subsystem that modern OpenSSH scp defaults to.
#
# Usage:
#   TC_HOST=root@192.168.31.44 [AUTO_BOOT=1] ./deploy.sh
#
# AUTO_BOOT=1 additionally injects the re-seed call into /mnt/Flash/boot.sh so
# the toolbox is auto-loaded on every boot (the TC root fs resets from firmware
# at each boot). Safe to re-run: the injection is idempotent.
set -e
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
TC="${TC_HOST:-root@192.168.31.44}"
SRC="$SCRIPT_DIR/bin"
DEST=/Volumes/dk2/.tc_tools/bin

echo "==> target: $TC"
echo "==> ensure remote dir"
ssh -o StrictHostKeyChecking=no "$TC" "mkdir -p $DEST"

echo "==> scp binaries (legacy SCP, -O)"
scp -O -o StrictHostKeyChecking=no "$SRC"/* "$TC:$DEST/"
ssh -o StrictHostKeyChecking=no "$TC" "chmod 755 $DEST/*"

echo "==> install env hook files"
scp -O -o StrictHostKeyChecking=no "$SCRIPT_DIR/tc-files/setenv.sh"       "$TC:/mnt/Flash/setenv.sh"
scp -O -o StrictHostKeyChecking=no "$SCRIPT_DIR/tc-files/seed_profile.sh" "$TC:/mnt/Flash/seed_profile.sh"
ssh -o StrictHostKeyChecking=no "$TC" "chmod 755 /mnt/Flash/setenv.sh /mnt/Flash/seed_profile.sh"

if [ "${AUTO_BOOT:-0}" = "1" ]; then
    echo "==> AUTO_BOOT: inject re-seed into /mnt/Flash/boot.sh (idempotent)"
    scp -O -o StrictHostKeyChecking=no "$SCRIPT_DIR/tc-files/inject_boot.sh" "$TC:/mnt/Flash/inject_boot.sh"
    ssh -o StrictHostKeyChecking=no "$TC" "sh /mnt/Flash/inject_boot.sh; rm -f /mnt/Flash/inject_boot.sh"
fi

echo "==> verify on TC"
ssh -o StrictHostKeyChecking=no "$TC" 'export PATH=/Volumes/dk2/.tc_tools/bin:/mnt/Flash/bin:$PATH; for c in ls grep awk sed find tar gzip nc wc head tail sort cut tr uniq diff patch du od rsync; do printf "%-8s " "$c"; if command -v "$c" >/dev/null 2>&1; then echo "present ($(command -v "$c"))"; else echo MISSING; fi; done'
echo "==> done"
