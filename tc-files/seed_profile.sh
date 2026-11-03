#!/bin/sh
# Re-seed /.profile so interactive SSH logins get the static toolbox on PATH.
#
# The TC root filesystem is reset from firmware at every boot, so this runs each
# boot via /mnt/Flash/boot.sh. It is intentionally idempotent BY CONSTRUCTION:
# it rewrites /.profile by copying the existing file while dropping any prior
# toolbox block, then appends exactly one fresh block. This guarantees a single
# clean block no matter how many times it runs or what stale state it starts
# from (orphan source lines, duplicate blocks, etc.).
#
# Uses only POSIX shell builtins (the TC has no grep/head/awk we can rely on
# before PATH is augmented). Guarded by "|| true" so any failure can never
# abort Samba startup (boot.sh runs under "set -eu").
{ chmod u+w /.profile 2>/dev/null
  tmp="/.profile.tcseed.$$"
  : > "$tmp"
  # Copy /.profile to a temp file, dropping any pre-existing toolbox block lines.
  while IFS= read -r line; do
      case "$line" in
          *"TC static toolbox"*|*"/mnt/Flash/setenv.sh"*) ;;   # drop old block
          *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
  done < /.profile 2>/dev/null
  # Append exactly one fresh toolbox block.
  printf '\n# TC static toolbox (re-seeded by boot.sh)\n. /mnt/Flash/setenv.sh\n' >> "$tmp"
  # Replace /.profile (rename on same fs; fall back to cp across devices).
  if mv "$tmp" /.profile 2>/dev/null; then
      :
  else
      cp "$tmp" /.profile 2>/dev/null && rm -f "$tmp"
  fi
  chmod u-w /.profile 2>/dev/null
} || true
