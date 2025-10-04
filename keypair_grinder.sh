#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
PATTERN="${PATTERN:-aa:1}"             # Override with env var, e.g., PATTERN="A:2"
NUM_THREADS="${NUM_THREADS:-0}"       # 0 = use CLI default (all cores)
SLEEP_BETWEEN_LOOPS="${SLEEP_BETWEEN_LOOPS:-0}"   # seconds to pause between loops
NO_BIP39="${NO_BIP39:---no-bip39-passphrase}"     # keep default; remove if you want a passphrase
DATABASE_URL="${DATABASE_URL:-}"

# Locate repo directory and local keygen binary
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "${SCRIPT_DIR}/target/release/solana-keygen" ]; then
  LOCAL_KEYGEN_BIN="${SCRIPT_DIR}/target/release/solana-keygen"
elif [ -x "${SCRIPT_DIR}/target/debug/solana-keygen" ]; then
  LOCAL_KEYGEN_BIN="${SCRIPT_DIR}/target/debug/solana-keygen"
else
  if command -v cargo >/dev/null 2>&1; then
    (cd "${SCRIPT_DIR}" && cargo build --release >/dev/null 2>&1)
    LOCAL_KEYGEN_BIN="${SCRIPT_DIR}/target/release/solana-keygen"
  else
    echo "Local solana-keygen not found and cargo is not installed to build it."
    exit 1
  fi
fi

# Sanity checks
command -v psql >/dev/null 2>&1 || { echo "psql not found in PATH"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH"; exit 1; }

echo "Starting vanity grind loop for pattern: ${PATTERN}"
echo "Inserting into table: sol_keypairs(public_key varchar primary key, private_key bytea)"
echo "Press Ctrl-C to stop."

while :; do
  # Use a temp dir so each iteration is clean
  tmpdir="$(mktemp -d -t solkeygrind.XXXXXX)"

  # Run the grind. We direct stdout/stderr to a log in case you want to inspect.
    # grind does not accept an explicit outfile; it writes keypair(s) into CWD.
  logf="${tmpdir}/grind.log"
    # Build command, omitting --num-threads when set to 0 so the CLI uses its default
    cmd=("${LOCAL_KEYGEN_BIN}" grind --ends-with "${PATTERN}" ${NO_BIP39})
    if [ "${NUM_THREADS}" != "0" ] && [ -n "${NUM_THREADS}" ]; then
      cmd+=(--num-threads "${NUM_THREADS}")
    fi

    if ! (cd "${tmpdir}" && "${cmd[@]}" >"${logf}" 2>&1); then
    echo "grind failed; log:"
    sed -n '1,200p' "${logf}" || true
    rm -rf "${tmpdir}"
    sleep "${SLEEP_BETWEEN_LOOPS}"
    continue
  fi

    # Collect generated keypair files (grind writes one file per match into tmpdir)
    shopt -s nullglob
    json_files=("${tmpdir}"/*.json)
    shopt -u nullglob
    if [ ${#json_files[@]} -eq 0 ]; then
      echo "grind reported success but no keypair files were found"
      sed -n '1,200p' "${logf}" || true
      rm -rf "${tmpdir}"
      sleep "${SLEEP_BETWEEN_LOOPS}"
      continue
    fi

    any_fail=0
    for outfile in "${json_files[@]}"; do
      # Derive the public key from the written keypair file (most robust way)
      if ! pubkey="$("${LOCAL_KEYGEN_BIN}" pubkey "${outfile}")"; then
        echo "Failed to derive public key from ${outfile}"
        any_fail=1
        continue
      fi

      # Convert the keypair JSON array (64 bytes) into a hex string for bytea insertion
      # The file contains a JSON array of integers (the raw 64-byte ed25519 secret key).
      if ! hex_secret="$(python3 - "$outfile" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, "r") as f:
    arr = json.load(f)
# Normalize potential negative values just in case
arr = [(x + 256) % 256 for x in arr]
# Pack to bytes and print hex (no 0x, no spaces)
sys.stdout.write(bytes(arr).hex())
PY
      )"; then
        echo "Failed to convert keypair JSON into hex for ${outfile}"
        any_fail=1
        continue
      fi

      # Insert into Postgres. Use hex format for bytea: '\xDEADBEEF...'
      # ON CONFLICT DO NOTHING avoids crashing if the pubkey already exists.
      sql="
        INSERT INTO sol_keypairs (public_key, private_key)
        VALUES ('${pubkey}', '\x${hex_secret}')
        ON CONFLICT (public_key) DO NOTHING;
      "

      if ! psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -c "${sql}"; then
        echo "psql insert failed for ${pubkey}"
        # Keep the temp dir for debugging on failure
        echo "Keypair kept at: ${outfile}"
        echo "Log kept at: ${logf}"
        any_fail=1
      else
        echo "Inserted ${pubkey}"
      fi
    done

    if [ "${any_fail}" -eq 0 ]; then
      rm -rf "${tmpdir}"
    else
      echo "One or more inserts failed; leaving artifacts in ${tmpdir}"
    fi

  # Optional small sleep to avoid tight-loop thrash
  sleep "${SLEEP_BETWEEN_LOOPS}"
done
