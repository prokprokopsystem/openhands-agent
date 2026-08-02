#!/usr/bin/bash
# Verify an SSH private/public keypair by SHA256 fingerprints without printing keys.
set -euo pipefail
PATH=/usr/bin:/bin
export PATH

[ "$#" -eq 2 ] || { printf '[FAIL] Usage: %s <private-key> <public-key>\n' "$0" >&2; exit 2; }
private_key="$1"
public_key="$2"

[ -f "${private_key}" ] && [ ! -L "${private_key}" ] \
    || { printf '[FAIL] Private key is missing or symlinked\n' >&2; exit 1; }
[ -f "${public_key}" ] && [ ! -L "${public_key}" ] \
    || { printf '[FAIL] Public key is missing or symlinked\n' >&2; exit 1; }

private_fingerprint="$(
    ssh-keygen -y -f "${private_key}" \
        | ssh-keygen -lf - -E sha256 2>/dev/null \
        | awk 'NR == 1 {print $2}'
)"
public_fingerprint="$(
    ssh-keygen -lf "${public_key}" -E sha256 2>/dev/null \
        | awk 'NR == 1 {print $2}'
)"

[ -n "${private_fingerprint}" ] && [ -n "${public_fingerprint}" ] \
    && [ "${private_fingerprint}" = "${public_fingerprint}" ] \
    || { printf '[FAIL] SSH keypair fingerprint mismatch\n' >&2; exit 1; }

printf '[OK] SSH keypair fingerprints match\n'
