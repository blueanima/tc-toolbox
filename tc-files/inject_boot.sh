#!/bin/sh
# Run ON the Time Capsule. Idempotently insert the static-toolbox re-seed into
# /mnt/Flash/boot.sh, placing it immediately BEFORE the
# "exec /mnt/Flash/service manager" line so it runs at every boot.
#
# Why: the TC root filesystem is reset from firmware at each boot, so /.profile
# (where we add the toolbox to PATH) is wiped. boot.sh runs at boot via
# /etc/rc.local -> /mnt/Flash/rc.local, so re-seeding /.profile from boot.sh is
# the only way to make the toolbox auto-appear on login after a reboot.
#
# IMPORTANT: this script uses NO grep/sed/awk. At boot the PATH is minimal and
# may not include those tools, so everything is done with POSIX shell builtins.
# The marker check is a plain "while read" scan (grep-free) so idempotency holds
# even when grep is unavailable.
set -u
bf=/mnt/Flash/boot.sh
marker="/mnt/Flash/seed_profile.sh"

if [ ! -f "$bf" ]; then
    echo "FATAL: $bf not found"; exit 1
fi

# Idempotency: already injected?
found=0
while IFS= read -r line; do
    case "$line" in *"$marker"*) found=1; break ;; esac
done < "$bf"
[ "$found" = 1 ] && { echo "already injected; nothing to do"; exit 0; }

chmod u+w "$bf" 2>/dev/null
tmp="$bf.inject.$$"
while IFS= read -r line; do
    case "$line" in
        *"exec /mnt/Flash/service manager"*)
            printf '%s\n' '# Re-seed /.profile so interactive SSH logins get the static toolbox on PATH.'
            printf '%s\n' '# Guarded by || true inside seed_profile.sh; must run before exec service manager.'
            printf '%s\n' '/mnt/Flash/seed_profile.sh'
            ;;
    esac
    printf '%s\n' "$line"
done < "$bf" > "$tmp"
mv "$tmp" "$bf"
chmod u-w "$bf" 2>/dev/null
echo "injected /mnt/Flash/seed_profile.sh before 'exec /mnt/Flash/service manager'"
