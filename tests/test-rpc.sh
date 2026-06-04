#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-borgbackup RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Tests CRUD operations for repos, archives, env vars, and compact schedules,
# then registers a real local borg repository (initialised under /tmp) and
# exercises read/command RPCs against it.
# No remote server or network access required.
#
# WARNING: Creates a temporary borg repository under /tmp. The cleanup trap
# removes it on exit. All repo DB entries are deleted with deleteFiles=false
# so no shared folder data is touched.

set -uo pipefail

# ---------------------------------------------------------------------------
# Colours / counters  (display goes to stderr; $() captures only JSON)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1" >&2
    ((PASS++)) || true
}
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------
rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    echo "$out"
    return 0
}

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
REPO_UUID=""
ARCHIVE_UUID=""
COMPACT_UUID=""
REPO_DIR=""

LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

BAD_UUID="00000000-0000-0000-0000-000000000000"

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    # Delete archive from DB (runs borg delete --glob-archives, safe no-op if
    # the repo dir is still present but has no matching archives).
    if [ -n "$ARCHIVE_UUID" ]; then
        info "Deleting archive $ARCHIVE_UUID from DB"
        rpc "BorgBackup" "deleteArchive" "{\"uuid\":\"$ARCHIVE_UUID\"}" &>/dev/null || true
    fi

    # Delete compact schedule from DB
    if [ -n "$COMPACT_UUID" ]; then
        info "Deleting compact $COMPACT_UUID from DB"
        rpc "BorgBackup" "deleteCompact" "{\"uuid\":\"$COMPACT_UUID\"}" &>/dev/null || true
    fi

    # Delete repo from DB — no file deletion (deleteFiles=false)
    if [ -n "$REPO_UUID" ]; then
        info "Deleting repo $REPO_UUID from DB"
        rpc "BorgBackup" "deleteRepo" \
            "{\"uuid\":\"$REPO_UUID\",\"deleteFiles\":false}" &>/dev/null || true
    fi

    # Remove temp borg repo directory
    if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
        info "Removing temp borg repo: $REPO_DIR"
        rm -rf "$REPO_DIR" 2>/dev/null || true
    fi

    info "Done."

    # Deploy pending config changes so the OMV web UI "apply changes" banner
    # does not linger after this test run. Runs detached/async so the script
    # returns promptly; --append-dirty clears the dirty-module markers (the
    # banner) once the deploy completes.
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
section "Pre-flight"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Must be run as root.${NC}" >&2
    exit 1
fi

for cmd in omv-rpc borg python3; do
    if command -v "$cmd" &>/dev/null; then
        _pass "command available: $cmd"
    else
        _fail "command available: $cmd" "$cmd not found in PATH"
    fi
done

if ! omv-rpc -u admin "Config" "isDirty" '{}' &>/dev/null; then
    echo -e "\n${RED}omv-rpc not functional — aborting.${NC}" >&2
    exit 1
fi
_pass "omv-rpc functional"

BORG_VER=$(borg --version 2>/dev/null || echo "unknown")
info "borg version: $BORG_VER"

# ---------------------------------------------------------------------------
# Informational RPCs (empty-state smoke test)
# ---------------------------------------------------------------------------
section "Informational RPCs"

assert_rpc "getRepoList" "BorgBackup" "getRepoList" "$LIST_PARAMS" >/dev/null
assert_rpc "getArchiveList" "BorgBackup" "getArchiveList" "$LIST_PARAMS" >/dev/null
assert_rpc "getEnvVarList" "BorgBackup" "getEnvVarList" "$LIST_PARAMS" >/dev/null
assert_rpc "getCompactList" "BorgBackup" "getCompactList" "$LIST_PARAMS" >/dev/null

assert_rpc "enumerateRepoCandidates (creation=false)" "BorgBackup" \
    "enumerateRepoCandidates" '{"creation":false}' >/dev/null

assert_rpc "enumerateRepoCandidates (creation=true)" "BorgBackup" \
    "enumerateRepoCandidates" '{"creation":true}' '"Repo creation"' >/dev/null

# ---------------------------------------------------------------------------
# CRUD — EnvVar (pure DB, no borg required)
# ---------------------------------------------------------------------------
section "CRUD — EnvVar"

EV_RESULT=$(assert_rpc "setEnvVar (create, reporef=creation)" "BorgBackup" "setEnvVar" \
    "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'envname': 'BG_RPC_TEST_VAR',
    'envvalue': 'bgrpctest_value',
    'reporef': 'creation',
}))") ") || true
EV_UUID=$(echo "$EV_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$EV_UUID" ] && [ "$EV_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setEnvVar — UUID assigned ($EV_UUID)"
    assert_rpc "getEnvVar" "BorgBackup" "getEnvVar" \
        "{\"uuid\":\"$EV_UUID\"}" "BG_RPC_TEST_VAR" >/dev/null
    assert_rpc "getEnvVarList includes test var" "BorgBackup" "getEnvVarList" \
        "$LIST_PARAMS" "BG_RPC_TEST_VAR" >/dev/null
    assert_rpc "deleteEnvVar" "BorgBackup" "deleteEnvVar" \
        "{\"uuid\":\"$EV_UUID\"}" >/dev/null
    assert_rpc_fails "getEnvVar after delete" "BorgBackup" "getEnvVar" \
        "{\"uuid\":\"$EV_UUID\"}"
else
    _fail "setEnvVar — no UUID returned"
fi

# Verify spaces in envname are converted to underscores
EV2_RESULT=$(assert_rpc "setEnvVar (spaces in name)" "BorgBackup" "setEnvVar" \
    "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'envname': 'BG RPC SPACE TEST',
    'envvalue': 'val',
    'reporef': '',
}))") ") || true
EV2_UUID=$(echo "$EV2_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
if [ -n "$EV2_UUID" ] && [ "$EV2_UUID" != "$OMV_NEW_UUID" ]; then
    EV2_NAME=$(echo "$EV2_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('envname',''))" 2>/dev/null || echo "")
    if [ "$EV2_NAME" = "BG_RPC_SPACE_TEST" ]; then
        _pass "setEnvVar — spaces converted to underscores"
    else
        _fail "setEnvVar — space-to-underscore conversion failed (got: $EV2_NAME)"
    fi
    rpc "BorgBackup" "deleteEnvVar" "{\"uuid\":\"$EV2_UUID\"}" &>/dev/null || true
else
    _fail "setEnvVar (spaces) — no UUID returned"
fi

# ---------------------------------------------------------------------------
# CRUD — Serve (pure DB; no real ssh deploy is triggered by the RPC)
# ---------------------------------------------------------------------------
section "CRUD — Serve"

# Generate a keypair via the RPC and reuse the public key for the client.
SV_KEY=$(assert_rpc "generateServeKey" "BorgBackup" "generateServeKey" \
    '{"comment":"bg-rpc-test"}' "ssh-ed25519") || true
SV_PUBKEY=$(echo "$SV_KEY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('publickey',''))" 2>/dev/null || echo "")
SV_PRIVKEY=$(echo "$SV_KEY" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('privatekey',''))" 2>/dev/null || echo "")
SV_SFREF=$(python3 -c "import uuid; print(uuid.uuid4())")

if [ -n "$SV_PUBKEY" ]; then
    _pass "generateServeKey — public key returned"
    SV_RESULT=$(assert_rpc "setServe (create, user=root)" "BorgBackup" "setServe" \
        "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'bg_rpc_serve',
    'username': 'root',
    'sharedfolderref': '$SV_SFREF',
    'publickey': '''$SV_PUBKEY''',
    'privatekey': '''$SV_PRIVKEY''',
    'appendonly': True,
    'storquota': '',
}))") ") || true
    SV_UUID=$(echo "$SV_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
    if [ -n "$SV_UUID" ] && [ "$SV_UUID" != "$OMV_NEW_UUID" ]; then
        _pass "setServe — UUID assigned ($SV_UUID)"
        # getServe must not leak the stored private key.
        if rpc "BorgBackup" "getServe" "{\"uuid\":\"$SV_UUID\"}" \
            | grep -q '"privatekey"'; then
            _fail "getServe — private key leaked in response"
        else
            _pass "getServe — private key not exposed"
        fi
        assert_rpc "getServeList includes test client" "BorgBackup" "getServeList" \
            "$LIST_PARAMS" "bg_rpc_serve" >/dev/null
        # A generated key is downloadable.
        assert_rpc "downloadServeKey" "BorgBackup" "downloadServeKey" \
            "{\"uuid\":\"$SV_UUID\"}" "filepath" >/dev/null
        assert_rpc "deleteServe" "BorgBackup" "deleteServe" \
            "{\"uuid\":\"$SV_UUID\"}" >/dev/null
        assert_rpc_fails "getServe after delete" "BorgBackup" "getServe" \
            "{\"uuid\":\"$SV_UUID\"}"
    else
        _fail "setServe — no UUID returned"
    fi

    # The login user must exist on the system.
    assert_rpc_fails "setServe — nonexistent user rejected" "BorgBackup" "setServe" \
        "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'bg_rpc_serve_baduser',
    'username': 'bg_rpc_no_such_user',
    'sharedfolderref': '$SV_SFREF',
    'publickey': '''$SV_PUBKEY''',
    'privatekey': '',
    'appendonly': True,
    'storquota': '',
}))")"
else
    _fail "generateServeKey — no public key returned"
fi

# Auto-generate path: an empty public key makes setServe create a key pair.
SV_GEN=$(assert_rpc "setServe (auto-generate key)" "BorgBackup" "setServe" \
    "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'bg_rpc_serve_gen',
    'username': 'root',
    'sharedfolderref': '$SV_SFREF',
    'publickey': '',
    'privatekey': '',
    'appendonly': True,
    'storquota': '',
}))") " "ssh-ed25519") || true
SV_GEN_UUID=$(echo "$SV_GEN" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
if [ -n "$SV_GEN_UUID" ] && [ "$SV_GEN_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setServe — auto-generated public key returned"
    # A stored private key must now be downloadable.
    assert_rpc "downloadServeKey (generated)" "BorgBackup" "downloadServeKey" \
        "{\"uuid\":\"$SV_GEN_UUID\"}" "filepath" >/dev/null
    rpc "BorgBackup" "deleteServe" "{\"uuid\":\"$SV_GEN_UUID\"}" &>/dev/null || true
else
    _fail "setServe (auto-generate) — no UUID returned"
fi

# ---------------------------------------------------------------------------
# Integration — salt deploy (renders + applies the borgbackup state, including
# the serve authorized_keys section that now lives in default.sls)
# ---------------------------------------------------------------------------
section "Integration — salt deploy (serve authorized_keys)"

if ! command -v omv-salt &>/dev/null; then
    info "omv-salt not available — skipping salt deploy test"
else
    SALT_LOG=$(mktemp)
    # Find a real shared folder to act as the restrict-to-path target. Without
    # one the serve forced-command line cannot be rendered, so we fall back to
    # a plain deploy-success check.
    SV_REAL_SF=$(rpc "ShareMgmt" "enumerateSharedFolders" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d[0]['uuid'] if d else '')
except Exception:
    print('')" 2>/dev/null || echo "")

    if [ -n "$SV_REAL_SF" ]; then
        info "Using shared folder $SV_REAL_SF as the serve target"
        SV_DEP=$(rpc "BorgBackup" "setServe" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'bg_rpc_serve_deploy',
    'username': 'root',
    'sharedfolderref': '$SV_REAL_SF',
    'publickey': '',
    'privatekey': '',
    'appendonly': True,
    'storquota': '',
}))")" 2>/dev/null || echo "")
        SV_DEP_UUID=$(echo "$SV_DEP" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

        info "Running 'omv-salt deploy run borgbackup' (write authorized_keys) ..."
        if omv-salt deploy run borgbackup &>"$SALT_LOG"; then
            _pass "omv-salt deploy run borgbackup — applied (with serve client)"
        else
            _fail "omv-salt deploy run borgbackup — failed" "$(tail -5 "$SALT_LOG")"
        fi
        # The forced-command line must now be in root's authorized_keys.
        if grep -q 'openmediavault-borgbackup serve' /root/.ssh/authorized_keys 2>/dev/null \
           && grep -q "borg serve --restrict-to-path" /root/.ssh/authorized_keys 2>/dev/null; then
            _pass "authorized_keys — forced-command line written for root"
        else
            _fail "authorized_keys — forced-command line not found for root"
        fi

        # Delete the client and redeploy; the marked block must be stripped.
        rpc "BorgBackup" "deleteServe" "{\"uuid\":\"$SV_DEP_UUID\"}" &>/dev/null || true
        omv-salt deploy run borgbackup &>"$SALT_LOG" || true
        if grep -q 'openmediavault-borgbackup serve' /root/.ssh/authorized_keys 2>/dev/null; then
            _fail "authorized_keys — serve block not removed after client deletion"
        else
            _pass "authorized_keys — serve block removed after client deletion"
        fi
    else
        info "No shared folder available — running deploy without a serve client"
        if omv-salt deploy run borgbackup &>"$SALT_LOG"; then
            _pass "omv-salt deploy run borgbackup — applied successfully"
        else
            _fail "omv-salt deploy run borgbackup — failed" "$(tail -5 "$SALT_LOG")"
        fi
    fi
    rm -f "$SALT_LOG"
fi

# ---------------------------------------------------------------------------
# Validation — negative tests (no real repo needed)
# ---------------------------------------------------------------------------
section "Validation — negative tests"

assert_rpc_fails "getRepo — unknown UUID" "BorgBackup" "getRepo" \
    "{\"uuid\":\"$BAD_UUID\"}"
assert_rpc_fails "deleteRepo — unknown UUID" "BorgBackup" "deleteRepo" \
    "{\"uuid\":\"$BAD_UUID\",\"deleteFiles\":false}"
assert_rpc_fails "getArchive — unknown UUID" "BorgBackup" "getArchive" \
    "{\"uuid\":\"$BAD_UUID\"}"
assert_rpc_fails "deleteArchive — unknown UUID" "BorgBackup" "deleteArchive" \
    "{\"uuid\":\"$BAD_UUID\"}"
assert_rpc_fails "getEnvVar — unknown UUID" "BorgBackup" "getEnvVar" \
    "{\"uuid\":\"$BAD_UUID\"}"
assert_rpc_fails "deleteEnvVar — unknown UUID" "BorgBackup" "deleteEnvVar" \
    "{\"uuid\":\"$BAD_UUID\"}"
assert_rpc_fails "getCompact — unknown UUID" "BorgBackup" "getCompact" \
    "{\"uuid\":\"$BAD_UUID\"}"
assert_rpc_fails "deleteCompact — unknown UUID" "BorgBackup" "deleteCompact" \
    "{\"uuid\":\"$BAD_UUID\"}"

# ---------------------------------------------------------------------------
# Integration — initialise a local borg repo and register it via RPC
# ---------------------------------------------------------------------------
section "Integration — borg repo setup"

REPO_DIR=$(mktemp -d)
info "Initialising borg repo at $REPO_DIR ..."
if BORG_PASSPHRASE='' BORG_EXIT_CODES=modern \
   borg init --encryption=none "$REPO_DIR" &>/dev/null; then
    _pass "borg init — repo created at $REPO_DIR"
else
    _fail "borg init — failed; cannot continue integration tests"
    exit 1
fi

# Register via setRepo using type=remote + uri so we avoid needing a shared
# folder object.  skipinit=true runs 'borg list --short' instead of 'borg init'.
REPO_RESULT=$(assert_rpc "setRepo (skipinit=true, type=remote/local path)" \
    "BorgBackup" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'bgrpctest',
    'type': 'remote',
    'sharedfolderref': '',
    'uri': '$REPO_DIR',
    'passphrase': '',
    'encryption': False,
    'skipinit': True,
    'storquota': '',
}))")") || { _fail "setRepo — RPC failed; cannot continue"; exit 1; }

REPO_UUID=$(echo "$REPO_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$REPO_UUID" ] || [ "$REPO_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "setRepo — no real UUID returned"
    exit 1
fi
_pass "setRepo — UUID assigned ($REPO_UUID)"

# getRepo — verify stored fields
assert_rpc "getRepo" "BorgBackup" "getRepo" \
    "{\"uuid\":\"$REPO_UUID\"}" "\"name\":\"bgrpctest\"" >/dev/null

# getRepoList — repo must appear
assert_rpc "getRepoList includes bgrpctest" "BorgBackup" "getRepoList" \
    "$LIST_PARAMS" "bgrpctest" >/dev/null

# enumerateRepoCandidates — bgrpctest must appear
assert_rpc "enumerateRepoCandidates includes bgrpctest" "BorgBackup" \
    "enumerateRepoCandidates" '{"creation":false}' "bgrpctest" >/dev/null

# enumerateArchives — fresh repo returns an empty array
ENUM_OUT=$(rpc "BorgBackup" "enumerateArchives" "{\"uuid\":\"$REPO_UUID\"}" 2>/dev/null \
    || echo "error")
ENUM_COUNT=$(echo "$ENUM_OUT" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 'not-a-list')" \
    2>/dev/null || echo "error")
if [ "$ENUM_COUNT" = "0" ]; then
    _pass "enumerateArchives — fresh repo returns empty list"
elif [ "$ENUM_COUNT" = "not-a-list" ] || [ "$ENUM_COUNT" = "error" ]; then
    _fail "enumerateArchives — unexpected response: ${ENUM_OUT:0:100}"
else
    _fail "enumerateArchives — expected 0 archives, got $ENUM_COUNT"
fi

# ---------------------------------------------------------------------------
# Integration — Archive CRUD
# ---------------------------------------------------------------------------
section "Integration — Archive CRUD"

ARCHIVE_RESULT=$(assert_rpc "setArchive (create)" "BorgBackup" "setArchive" \
    "$(python3 -c "
import json; print(json.dumps({
    'enable': True,
    'uuid': '$OMV_NEW_UUID',
    'name': 'bgrpctest',
    'reporef': '$REPO_UUID',
    'compressiontype': 'lz4',
    'compressionratio': 9,
    'onefs': False,
    'include': '/tmp',
    'exclude': '',
    'hourly': 0,    'hourlyenable': False, 'hourlymin': 5,
    'daily': 7,     'dailyenable': True,   'dailyhour': 3, 'dailymin': 30,
    'weekly': 4,    'weeklyenable': False,  'weeklyhour': 3, 'weeklymin': 0,
    'monthly': 3,   'monthlyenable': False, 'monthlyhour': 2, 'monthlymin': 30,
    'yearly': 0,    'yearlyenable': False,  'yearlyhour': 2, 'yearlymin': 0,
    'compact': False, 'cthreshold': 10, 'ratelimit': 0,
    'list': True, 'email': False,
    'prescript': '', 'postscript': '', 'basedir': '',
}))") ") || true

ARCHIVE_UUID=$(echo "$ARCHIVE_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$ARCHIVE_UUID" ] || [ "$ARCHIVE_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "setArchive — no real UUID returned"
else
    _pass "setArchive — UUID assigned ($ARCHIVE_UUID)"

    assert_rpc "getArchive" "BorgBackup" "getArchive" \
        "{\"uuid\":\"$ARCHIVE_UUID\"}" "\"name\":\"bgrpctest\"" >/dev/null

    assert_rpc "getArchiveList includes bgrpctest" "BorgBackup" "getArchiveList" \
        "$LIST_PARAMS" "bgrpctest" >/dev/null

    # getArchiveLog — no log file yet; should return a "not found" message, not an error
    ARCH_LOG=$(rpc "BorgBackup" "getArchiveLog" "{\"name\":\"bgrpctest\"}" 2>/dev/null || echo "")
    if [ -n "$ARCH_LOG" ]; then
        _pass "getArchiveLog — returns response (no log exists yet)"
    else
        _fail "getArchiveLog — empty or errored response"
    fi

    # deleteArchive — runs 'borg delete --glob-archives "bgrpctest*" REPO'.
    # The fresh repo has no matching archives so borg exits 0 (safe no-op).
    SAVED_ARCHIVE_UUID="$ARCHIVE_UUID"
    assert_rpc "deleteArchive" "BorgBackup" "deleteArchive" \
        "{\"uuid\":\"$ARCHIVE_UUID\"}" >/dev/null
    ARCHIVE_UUID=""

    assert_rpc_fails "getArchive after delete" "BorgBackup" "getArchive" \
        "{\"uuid\":\"$SAVED_ARCHIVE_UUID\"}"
fi

# Duplicate-name rejection: create a second archive then try to create one
# with the same name.
ARCH2_RESULT=$(rpc "BorgBackup" "setArchive" "$(python3 -c "
import json; print(json.dumps({
    'enable': True, 'uuid': '$OMV_NEW_UUID', 'name': 'bgrpctest_dup',
    'reporef': '$REPO_UUID',
    'compressiontype': 'none', 'compressionratio': 9,
    'onefs': False, 'include': '/tmp', 'exclude': '',
    'hourly': 0,  'hourlyenable': False, 'hourlymin': 5,
    'daily': 7,   'dailyenable': True,   'dailyhour': 3, 'dailymin': 30,
    'weekly': 4,  'weeklyenable': False,  'weeklyhour': 3, 'weeklymin': 0,
    'monthly': 3, 'monthlyenable': False, 'monthlyhour': 2, 'monthlymin': 30,
    'yearly': 0,  'yearlyenable': False,  'yearlyhour': 2, 'yearlymin': 0,
    'compact': False, 'cthreshold': 10, 'ratelimit': 0,
    'list': True, 'email': False,
    'prescript': '', 'postscript': '', 'basedir': '',
}))")" 2>/dev/null || echo "{}")
ARCH2_UUID=$(echo "$ARCH2_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$ARCH2_UUID" ] && [ "$ARCH2_UUID" != "$OMV_NEW_UUID" ]; then
    assert_rpc_fails "setArchive — duplicate name rejected" "BorgBackup" "setArchive" \
        "$(python3 -c "
import json; print(json.dumps({
    'enable': True, 'uuid': '$OMV_NEW_UUID', 'name': 'bgrpctest_dup',
    'reporef': '$REPO_UUID',
    'compressiontype': 'none', 'compressionratio': 9,
    'onefs': False, 'include': '/tmp', 'exclude': '',
    'hourly': 0,  'hourlyenable': False, 'hourlymin': 5,
    'daily': 7,   'dailyenable': True,   'dailyhour': 3, 'dailymin': 30,
    'weekly': 4,  'weeklyenable': False,  'weeklyhour': 3, 'weeklymin': 0,
    'monthly': 3, 'monthlyenable': False, 'monthlyhour': 2, 'monthlymin': 30,
    'yearly': 0,  'yearlyenable': False,  'yearlyhour': 2, 'yearlymin': 0,
    'compact': False, 'cthreshold': 10, 'ratelimit': 0,
    'list': True, 'email': False,
    'prescript': '', 'postscript': '', 'basedir': '',
}))")"
    rpc "BorgBackup" "deleteArchive" "{\"uuid\":\"$ARCH2_UUID\"}" &>/dev/null || true
else
    _fail "setArchive (dup test) — could not create base archive for duplicate check"
fi

# ---------------------------------------------------------------------------
# Integration — Compact schedule CRUD
# ---------------------------------------------------------------------------
section "Integration — Compact schedule CRUD"

COMPACT_RESULT=$(assert_rpc "setCompact (create)" "BorgBackup" "setCompact" \
    "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'enable': True,
    'reporef': '$REPO_UUID',
    'cthreshold': 10,
    'email': False,
    'dailyenable':   True,  'dailyhour': 4,   'dailymin': 0,
    'weeklyenable':  False, 'weeklyhour': 4,  'weeklymin': 0, 'weeklyday': 1,
    'monthlyenable': False, 'monthlyhour': 4, 'monthlymin': 0, 'monthlyday': 1,
}))") ") || true

COMPACT_UUID=$(echo "$COMPACT_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$COMPACT_UUID" ] || [ "$COMPACT_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "setCompact — no real UUID returned"
else
    _pass "setCompact — UUID assigned ($COMPACT_UUID)"

    assert_rpc "getCompact" "BorgBackup" "getCompact" \
        "{\"uuid\":\"$COMPACT_UUID\"}" "\"cthreshold\":10" >/dev/null

    # getCompactList — entry must appear; 'reponame' is bgrpctest (joined from repo)
    assert_rpc "getCompactList includes bgrpctest" "BorgBackup" "getCompactList" \
        "$LIST_PARAMS" "bgrpctest" >/dev/null

    SAVED_COMPACT_UUID="$COMPACT_UUID"
    assert_rpc "deleteCompact" "BorgBackup" "deleteCompact" \
        "{\"uuid\":\"$COMPACT_UUID\"}" >/dev/null
    COMPACT_UUID=""

    assert_rpc_fails "getCompact after delete" "BorgBackup" "getCompact" \
        "{\"uuid\":\"$SAVED_COMPACT_UUID\"}"
fi

# ---------------------------------------------------------------------------
# Integration — repoCommand (background, non-destructive)
# ---------------------------------------------------------------------------
section "Integration — repoCommand"

assert_rpc "repoCommand info — background job dispatched" "BorgBackup" "repoCommand" \
    "{\"uuid\":\"$REPO_UUID\",\"command\":\"info\"}" >/dev/null

assert_rpc "repoCommand list — background job dispatched" "BorgBackup" "repoCommand" \
    "{\"uuid\":\"$REPO_UUID\",\"command\":\"list\"}" >/dev/null

assert_rpc "repoCommand repo (check --repository-only) — dispatched" \
    "BorgBackup" "repoCommand" \
    "{\"uuid\":\"$REPO_UUID\",\"command\":\"repo\"}" >/dev/null

# ---------------------------------------------------------------------------
# Integration — setRepo duplicate-name rejection
# ---------------------------------------------------------------------------
section "Integration — setRepo duplicate-name rejection"

REPO2_DIR=$(mktemp -d)
BORG_PASSPHRASE='' BORG_EXIT_CODES=modern \
    borg init --encryption=none "$REPO2_DIR" &>/dev/null || true

assert_rpc_fails "setRepo — duplicate name rejected" "BorgBackup" "setRepo" \
    "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'bgrpctest',
    'type': 'remote',
    'sharedfolderref': '',
    'uri': '$REPO2_DIR',
    'passphrase': '',
    'encryption': False,
    'skipinit': True,
    'storquota': '',
}))")"
rm -rf "$REPO2_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Integration — deleteRepo (DB entry only, no file deletion)
# ---------------------------------------------------------------------------
section "Integration — deleteRepo"

SAVED_REPO_UUID="$REPO_UUID"
assert_rpc "deleteRepo (deleteFiles=false)" "BorgBackup" "deleteRepo" \
    "{\"uuid\":\"$REPO_UUID\",\"deleteFiles\":false}" >/dev/null
REPO_UUID=""

assert_rpc_fails "getRepo after delete" "BorgBackup" "getRepo" \
    "{\"uuid\":\"$SAVED_REPO_UUID\"}"

# Verify repo no longer appears in candidate list
CANDIDATES=$(rpc "BorgBackup" "enumerateRepoCandidates" '{"creation":false}' \
    2>/dev/null || echo "[]")
FOUND=$(echo "$CANDIDATES" | python3 -c "
import sys, json
cands = json.load(sys.stdin)
print(any(c.get('name') == 'bgrpctest' for c in cands))
" 2>/dev/null || echo "True")
if [ "$FOUND" = "False" ]; then
    _pass "enumerateRepoCandidates — bgrpctest gone after deleteRepo"
else
    _fail "enumerateRepoCandidates — bgrpctest still listed after deleteRepo"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS + FAIL))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} (${TOTAL} total)" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done
fi
echo >&2

[ $FAIL -eq 0 ] && exit 0 || exit 1
