# Sourced by build-app.sh / install-app.sh / sign.sh — not executable.
#
# Resolves the code-signing identity into SIGN_ID. TCC keys permission
# grants on this identity, so it must be STABLE across rebuilds (see the
# comments in the sourcing scripts). Resolution order:
#
#   1. LOCAL_DICTATION_SIGN_ID env var (a cert SHA-1 or name, or "-" for
#      ad-hoc — note ad-hoc drops every TCC grant on each rebuild).
#   2. The keychain's first "Apple Development" certificate.
#
# Machines differ per developer, so nothing is hardcoded here.

if [ -n "${LOCAL_DICTATION_SIGN_ID:-}" ]; then
  SIGN_ID="$LOCAL_DICTATION_SIGN_ID"
else
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
  if [ -z "$SIGN_ID" ]; then
    echo "No 'Apple Development' certificate found in the keychain." >&2
    echo "Create one in Xcode (Settings > Accounts > Manage Certificates)," >&2
    echo "or set LOCAL_DICTATION_SIGN_ID to a cert SHA-1/name explicitly." >&2
    exit 1
  fi
fi
