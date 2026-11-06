#!/bin/bash
# Copies the shared libraries that the given ELF files need into a root file
# system. The libraries are resolved recursively from the NEEDED entries and
# the program interpreter (readelf), the files are not executed. Unlike ldd
# this also works for foreign-architecture builds under emulation.
#
# Usage: copy-libs.sh <rootfs> <file with one ELF path per line>
#
# Fails if a library cannot be found.
set -euo pipefail

ROOTFS=$1
LIST=$2
SEARCH=(/usr/lib64 /lib64 /usr/local/lib64 /usr/local/lib)

declare -A found # library name -> path on the build system
queue=()

while read -r f; do
  queue+=("$f")
  interp=$(readelf -l "$f" | sed -n 's/.*Requesting program interpreter: \(.*\)\]$/\1/p')
  if [ -n "$interp" ] && [ -z "${found[$(basename "$interp")]:-}" ]; then
    found[$(basename "$interp")]=$interp
  fi
done < "$LIST"

while [ ${#queue[@]} -gt 0 ]; do
  f=${queue[0]}
  queue=("${queue[@]:1}")
  for lib in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'); do
    [ -n "${found[$lib]:-}" ] && continue
    path=""
    for dir in "${SEARCH[@]}"; do
      if [ -e "$dir/$lib" ]; then
        path="$dir/$lib"
        break
      fi
    done
    if [ -z "$path" ]; then
      echo "copy-libs: $lib (needed by $f) not found" >&2
      exit 1
    fi
    found[$lib]=$path
    queue+=("$path")
  done
done

mkdir -p "$ROOTFS/usr/lib64"
for lib in $(printf '%s\n' "${!found[@]}" | sort); do
  cp -L "${found[$lib]}" "$ROOTFS/usr/lib64/$lib"
  echo "$lib <- ${found[$lib]}"
done
