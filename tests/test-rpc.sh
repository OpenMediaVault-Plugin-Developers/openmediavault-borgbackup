#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-borgbackup RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Tests CRUD operations for repos, archives, env vars, and compact schedules,
# then registers real borg repositories (initialised under /tmp) and
# exercises read/command RPCs against them: backups, archive info/delete,
# passphrase masking and changes, keyfile download, export/extract, mount,
# quotas and the generated scheduled scripts.
# No remote server or network access required.
#
# WARNING: Creates temporary borg repositories under /tmp. If at least one
# shared folder exists, two temporary shared folders (bgrpctest_*) are
# created on the same filesystem for export/extract/mount/quota tests; they
# and their contents are deleted again on exit. Existing shared folder data
# is never touched. Writes the borg serve block to root's authorized_keys
# and removes it again.

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

# Results and cleanup commands are kept in files rather than variables, so
# assertions and registrations made inside $(...) subshells are not lost.
RESULTS_FILE=$(mktemp)
CLEANUP_FILE=$(mktemp)

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1" >&2
    printf 'PASS %s\n' "${1//$'\n'/ }" >>"$RESULTS_FILE"
}
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    printf 'FAIL %s\n' "${1//$'\n'/ }" >>"$RESULTS_FILE"
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

# Read one key from a JSON object on stdin.
jget() {
    python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" \
        2>/dev/null || echo ""
}

# Print a JSON document built from a Python expression. Extra arguments are
# available as a[0], a[1], ... so values never need shell/Python quoting.
pyjson() {
    local expr=$1
    shift
    python3 -c "import json, sys; a = sys.argv[1:]; print(json.dumps($expr))" "$@"
}

# Poll a background job started by an execBgProc RPC (its JSON-encoded
# status filename is passed in) until it finishes. Sets BG_OUTPUT to the
# job's full output and BG_ERROR to the error, if any. Returns non-zero if
# the job failed or timed out.
BG_OUTPUT=""
BG_ERROR=""
wait_bg() {
    local filename timeout=${2:-300} pos=0 start=$SECONDS resp meta
    local running pending outfile
    BG_OUTPUT=""
    BG_ERROR=""
    filename=$(echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin))" \
        2>/dev/null) || { BG_ERROR="not a background job: ${1:0:200}"; return 1; }
    outfile=$(mktemp)
    while :; do
        resp=$(omv-rpc -u admin "Exec" "getOutput" \
            "{\"filename\":\"$filename\",\"pos\":$pos}" 2>&1) || {
            BG_OUTPUT=$(cat "$outfile")
            BG_ERROR=$resp
            rm -f "$outfile"
            return 1
        }
        meta=$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
with open(sys.argv[1], 'a') as f:
    f.write(d.get('output') or '')
print(d['pos'], int(bool(d['running'])), int(bool(d.get('pendingOutput'))))
" "$outfile" 2>/dev/null) || {
            BG_ERROR="unexpected getOutput response: ${resp:0:200}"
            rm -f "$outfile"
            return 1
        }
        read -r pos running pending <<<"$meta"
        [ "$running" = "0" ] && [ "$pending" = "0" ] && break
        if (( SECONDS - start > timeout )); then
            BG_ERROR="timed out after ${timeout}s"
            break
        fi
        sleep 1
    done
    BG_OUTPUT=$(cat "$outfile")
    rm -f "$outfile"
    [ -z "$BG_ERROR" ]
}

# Run a background-job RPC to completion and assert it succeeded (and that
# its output matches an optional grep pattern).
assert_bg() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "dispatch failed: $(echo "$out" | tail -3)"
        return 1
    fi
    if ! wait_bg "$out"; then
        _fail "$desc" "$(echo "$BG_ERROR" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! grep -q -- "$pattern" <<<"$BG_OUTPUT"; then
        _fail "$desc" "Pattern '$pattern' not found in: $(tail -c 300 <<<"$BG_OUTPUT")"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Assert a background-job RPC is rejected up front or fails while running.
assert_bg_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ] || echo "$out" | grep -qi "exception"; then
        _pass "$desc"
        return 0
    fi
    if wait_bg "$out"; then
        _fail "$desc" "Expected failure but job succeeded: $(tail -c 200 <<<"$BG_OUTPUT")"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Register a command to run on exit. Commands run in reverse order of
# registration, so register a resource before anything that depends on it.
on_cleanup() {
    printf '%q ' "$@" >>"$CLEANUP_FILE"
    echo >>"$CLEANUP_FILE"
}

# Create a BorgBackup config object, register its deletion for cleanup and
# print its UUID. Returns non-zero (and records a failure) if it fails.
create_obj() {
    local desc=$1 method=$2 delete_method=$3 params=$4 out uuid del_params
    out=$(assert_rpc "$desc" "BorgBackup" "$method" "$params") || return 1
    uuid=$(jget uuid <<<"$out")
    if [ -z "$uuid" ] || [ "$uuid" = "$OMV_NEW_UUID" ]; then
        _fail "$desc — no UUID returned"
        return 1
    fi
    del_params="{\"uuid\":\"$uuid\"}"
    if [ "$delete_method" = "deleteRepo" ]; then
        del_params="{\"uuid\":\"$uuid\",\"deleteFiles\":false}"
    fi
    on_cleanup rpc BorgBackup "$delete_method" "$del_params"
    echo "$uuid"
}

# setArchive params for a new archive config.
# Usage: archive_params NAME REPO_UUID INCLUDE [EMAIL(true|false)]
archive_params() {
    pyjson "{
    'enable': True, 'uuid': a[0], 'name': a[1], 'reporef': a[2],
    'compressiontype': 'lz4', 'compressionratio': 9,
    'onefs': False, 'include': a[3], 'exclude': '',
    'hourly': 0,  'hourlyenable': False, 'hourlymin': 5,
    'daily': 7,   'dailyenable': True,   'dailyhour': 3, 'dailymin': 30,
    'weekly': 0,  'weeklyenable': False, 'weeklyhour': 3, 'weeklymin': 0,
    'monthly': 0, 'monthlyenable': False, 'monthlyhour': 2, 'monthlymin': 30,
    'yearly': 0,  'yearlyenable': False, 'yearlyhour': 2, 'yearlymin': 0,
    'compact': False, 'cthreshold': 10, 'ratelimit': 0,
    'list': True, 'email': a[4] == 'true',
    'prescript': '', 'postscript': '', 'basedir': '',
}" "$OMV_NEW_UUID" "$1" "$2" "$3" "${4:-false}"
}

# setRepo params. Usage: repo_params NAME TYPE SFREF URI PASSPHRASE
#   ENCRYPTION(true|false) SKIPINIT(true|false) [STORQUOTA]
repo_params() {
    pyjson "{
    'uuid': a[0], 'name': a[1], 'type': a[2], 'sharedfolderref': a[3],
    'uri': a[4], 'passphrase': a[5], 'encryption': a[6] == 'true',
    'skipinit': a[7] == 'true', 'storquota': a[8],
}" "$OMV_NEW_UUID" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}"
}

# setCompact params for an enabled schedule with no periods enabled.
compact_params() {
    pyjson "{
    'uuid': a[0], 'enable': True, 'reporef': a[1], 'cthreshold': 10,
    'email': False,
    'dailyenable':   False, 'dailyhour': 4,   'dailymin': 0,
    'weeklyenable':  False, 'weeklyhour': 4,  'weeklymin': 0, 'weeklyday': 1,
    'monthlyenable': False, 'monthlyhour': 4, 'monthlymin': 0, 'monthlyday': 1,
}" "$OMV_NEW_UUID" "$1"
}

# Archive names in a borg repo, one per line.
borg_list() {
    BORG_PASSPHRASE=${2:-} BORG_RELOCATED_REPO_ACCESS_IS_OK=yes \
    BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes \
        borg list --short "$1" </dev/null 2>/dev/null
}

# Remove local borg cache/security state for a repo directory.
forget_borg_repo() {
    local id
    id=$(borg config "$1" id 2>/dev/null </dev/null) || return 0
    [ -n "$id" ] || return 0
    rm -rf "/root/.cache/borg/$id" "/root/.config/borg/security/$id" \
        "$HOME/.cache/borg/$id" "$HOME/.config/borg/security/$id"
}

# Unmount a borg FUSE mount left behind by a failed test and remove its dir.
unmount_dir() {
    if mountpoint -q "$1" 2>/dev/null; then
        borg umount "$1" 2>/dev/null || fusermount -u "$1" 2>/dev/null \
            || fusermount3 -u "$1" 2>/dev/null || umount -l "$1"
    fi
    rmdir "$1" 2>/dev/null || true
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

    # Undo everything registered with on_cleanup, newest first.
    local cmd
    while IFS= read -r cmd; do
        [ -n "$cmd" ] && { eval "$cmd" &>/dev/null || true; }
    done < <(tac "$CLEANUP_FILE")
    rm -f "$CLEANUP_FILE"
    rm -f /var/log/borgbackup/bgrpc*.log /var/log/borgbackup/compact-bgrpc*.log

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
        forget_borg_repo "$REPO_DIR"
        rm -rf "$REPO_DIR" 2>/dev/null || true
    fi

    info "Done."

    # Deploy pending config changes so the OMV web UI "apply changes" banner
    # does not linger after this test run. Runs detached/async so the script
    # returns promptly; --append-dirty clears the dirty-module markers (the
    # banner) once the deploy completes.
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
    rm -f "$RESULTS_FILE"
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

# Direct borg calls must see the same keys, cache and security dirs as
# omv-engined and cron, which run as root with HOME=/root.
export HOME=/root

for cmd in omv-rpc borg python3 tar; do
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

# Names are written unquoted into a file that bash sources, so anything that
# is not a valid shell identifier must be rejected.
for bad_name in '1BAD' 'A-B' 'A;id' 'A$(id)' 'A=B'; do
    assert_rpc_fails "setEnvVar — invalid name rejected ($bad_name)" "BorgBackup" "setEnvVar" \
        "$(pyjson "{'uuid': a[0], 'envname': a[1], 'envvalue': 'v', 'reporef': ''}" \
            "$OMV_NEW_UUID" "$bad_name")"
done

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

    # Editing the client (the GUI never resends the private key) must keep
    # the generated private key while the public key is unchanged ...
    SV_GEN_PUBKEY=$(rpc "BorgBackup" "getServe" "{\"uuid\":\"$SV_GEN_UUID\"}" \
        2>/dev/null | jget publickey)
    sv_edit_params() {
        pyjson "{
    'uuid': a[0], 'name': 'bg_rpc_serve_gen', 'username': 'root',
    'sharedfolderref': a[1], 'publickey': a[2], 'privatekey': '',
    'appendonly': True, 'storquota': '',
}" "$SV_GEN_UUID" "$SV_SFREF" "$1"
    }
    assert_rpc "setServe (edit, same public key)" "BorgBackup" "setServe" \
        "$(sv_edit_params "$SV_GEN_PUBKEY")" >/dev/null
    assert_rpc "downloadServeKey — kept after edit with same public key" \
        "BorgBackup" "downloadServeKey" "{\"uuid\":\"$SV_GEN_UUID\"}" "filepath" >/dev/null

    # ... but drop it once a different public key is pasted in, because it
    # no longer matches anything in authorized_keys.
    SV_OTHER_PUBKEY=$(rpc "BorgBackup" "generateServeKey" '{"comment":"bg-rpc-other"}' \
        2>/dev/null | jget publickey)
    assert_rpc "setServe (edit, new public key)" "BorgBackup" "setServe" \
        "$(sv_edit_params "$SV_OTHER_PUBKEY")" >/dev/null
    assert_rpc_fails "downloadServeKey — stale private key dropped after key change" \
        "BorgBackup" "downloadServeKey" "{\"uuid\":\"$SV_GEN_UUID\"}"

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

# getLog builds a shell command from its params, so they must be validated.
GETLOG_MARKER="/tmp/bgrpctest-getlog-injected"
rm -f "$GETLOG_MARKER"
assert_bg_fails "getLog — shell metacharacters in command rejected" "BorgBackup" "getLog" \
    "$(pyjson "{'uuid': a[0], 'command': 'x; touch ' + a[1] + ';', 'follow': False}" \
        "$BAD_UUID" "$GETLOG_MARKER")"
assert_bg_fails "getLog — non-UUID uuid rejected" "BorgBackup" "getLog" \
    "$(pyjson "{'uuid': 'x; touch ' + a[0] + ';', 'command': 'extract', 'follow': False}" \
        "$GETLOG_MARKER")"
if [ -e "$GETLOG_MARKER" ]; then
    _fail "getLog — injected command was executed"
    rm -f "$GETLOG_MARKER"
else
    _pass "getLog — no injected command executed"
fi
assert_bg "getLog — valid params, no log yet" "BorgBackup" "getLog" \
    "{\"uuid\":\"$BAD_UUID\",\"command\":\"extract\",\"follow\":false}"

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

    # deleteArchive — runs 'borg delete --glob-archives "bgrpctest-<date>*" REPO'.
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
# Integration — createArchive and archive name matching
# ---------------------------------------------------------------------------
section "Integration — createArchive and archive name matching"

SRC_BASE=$(mktemp -d)
on_cleanup rm -rf "$SRC_BASE"
SRC_DIR="$SRC_BASE/src"
mkdir -p "$SRC_DIR/sub"
echo "bgrpctest-content" >"$SRC_DIR/file1.txt"
echo "bgrpctest-sub" >"$SRC_DIR/sub/file2.txt"

# Three configs whose names share a prefix. Operations on one config must
# never touch the archives of the others.
ARCH_A=$(create_obj "setArchive (bgrpcarch)" setArchive deleteArchive \
    "$(archive_params bgrpcarch "$REPO_UUID" "$SRC_DIR")") || true
ARCH_X=$(create_obj "setArchive (bgrpcarchx)" setArchive deleteArchive \
    "$(archive_params bgrpcarchx "$REPO_UUID" "$SRC_DIR")") || true
ARCH_OLD=$(create_obj "setArchive (bgrpcarch-old)" setArchive deleteArchive \
    "$(archive_params bgrpcarch-old "$REPO_UUID" "$SRC_DIR")") || true

if [ -n "$ARCH_A" ] && [ -n "$ARCH_X" ] && [ -n "$ARCH_OLD" ]; then
    assert_bg "createArchive (dry run)" "BorgBackup" "createArchive" \
        "{\"uuid\":\"$ARCH_A\",\"dryrun\":true,\"progress\":false}"
    if [ -z "$(borg_list "$REPO_DIR")" ]; then
        _pass "createArchive (dry run) — no archive created"
    else
        _fail "createArchive (dry run) — an archive was created"
    fi

    for pair in "bgrpcarch:$ARCH_A" "bgrpcarchx:$ARCH_X" "bgrpcarch-old:$ARCH_OLD"; do
        assert_bg "createArchive (${pair%%:*})" "BorgBackup" "createArchive" \
            "{\"uuid\":\"${pair#*:}\",\"dryrun\":false,\"progress\":false}" "This archive:"
    done

    ARCH_NAMES=$(borg_list "$REPO_DIR")
    for n in bgrpcarch bgrpcarchx bgrpcarch-old; do
        if grep -qE "^${n}-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$" <<<"$ARCH_NAMES"; then
            _pass "createArchive — archive named $n-<timestamp> exists"
        else
            _fail "createArchive — no $n-<timestamp> archive" "$ARCH_NAMES"
        fi
    done

    ENUM_COUNT=$(rpc "BorgBackup" "enumerateArchives" "{\"uuid\":\"$REPO_UUID\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "error")
    if [ "$ENUM_COUNT" = "3" ]; then
        _pass "enumerateArchives — 3 archives listed"
    else
        _fail "enumerateArchives — expected 3 archives, got $ENUM_COUNT"
    fi

    if assert_bg "archiveCommand info (bgrpcarch)" "BorgBackup" "archiveCommand" \
        "{\"uuid\":\"$ARCH_A\",\"command\":\"info\"}" "Archive name: bgrpcarch-[0-9]"; then
        if grep -qE "Archive name: (bgrpcarchx|bgrpcarch-old)-" <<<"$BG_OUTPUT"; then
            _fail "archiveCommand info — includes archives of other configs"
        else
            _pass "archiveCommand info — only this config's archives"
        fi
    fi

    assert_rpc "getArchiveLog — contains the run's stats" "BorgBackup" "getArchiveLog" \
        '{"name":"bgrpcarch"}' "This archive:" >/dev/null

    assert_rpc "deleteArchive (bgrpcarch)" "BorgBackup" "deleteArchive" \
        "{\"uuid\":\"$ARCH_A\"}" >/dev/null
    ARCH_NAMES=$(borg_list "$REPO_DIR")
    if grep -qE "^bgrpcarch-[0-9]" <<<"$ARCH_NAMES"; then
        _fail "deleteArchive — bgrpcarch archive still present"
    else
        _pass "deleteArchive — bgrpcarch archives removed"
    fi
    if grep -q "^bgrpcarchx-" <<<"$ARCH_NAMES" && grep -q "^bgrpcarch-old-" <<<"$ARCH_NAMES"; then
        _pass "deleteArchive — archives of bgrpcarchx and bgrpcarch-old kept"
    else
        _fail "deleteArchive — deleted archives of other configs" "$ARCH_NAMES"
    fi
else
    _fail "createArchive — could not create the archive configs"
fi

# ---------------------------------------------------------------------------
# Integration — repoCommand (run to completion, non-destructive)
# ---------------------------------------------------------------------------
section "Integration — repoCommand"

assert_bg "repoCommand info" "BorgBackup" "repoCommand" \
    "{\"uuid\":\"$REPO_UUID\",\"command\":\"info\"}" "Repository ID"
assert_bg "repoCommand list" "BorgBackup" "repoCommand" \
    "{\"uuid\":\"$REPO_UUID\",\"command\":\"list\"}" "bgrpcarchx-"
for check in repo archives all verify compact; do
    assert_bg "repoCommand $check" "BorgBackup" "repoCommand" \
        "{\"uuid\":\"$REPO_UUID\",\"command\":\"$check\"}"
done

# ---------------------------------------------------------------------------
# Integration — encrypted repo: passphrase masking, keyfile, passphrase change
# ---------------------------------------------------------------------------
section "Integration — encrypted repo"

# Passphrases with quotes, backslashes and $() must survive every layer and
# must never show up in task output or logs. The bgrpcSecret markers contain
# no shell metacharacters, so they are found even inside a quoted command.
PASS1="bgrpcSecret1'q\\t\$(id)"
PASS2="bgrpcSecret2 q\\x41'\$HOME"
ENC_BASE=$(mktemp -d)
on_cleanup rm -rf "$ENC_BASE"
ENC_DIR="$ENC_BASE/enc repo"   # space in the path on purpose
on_cleanup forget_borg_repo "$ENC_DIR"
ENC_UUID=$(create_obj "setRepo (init, keyfile encryption, path with space)" \
    setRepo deleteRepo "$(repo_params bgrpcenc remote '' "$ENC_DIR" "$PASS1" true false)") || true

if [ -n "$ENC_UUID" ]; then
    ENC_KEYFILE=$(BORG_PASSPHRASE="$PASS1" borg info --json "$ENC_DIR" </dev/null 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['encryption'].get('keyfile',''))" \
        2>/dev/null || echo "")
    [ -n "$ENC_KEYFILE" ] && on_cleanup rm -f "$ENC_KEYFILE"

    ENC_ARCH=$(create_obj "setArchive (bgrpcenc)" setArchive deleteArchive \
        "$(archive_params bgrpcenc "$ENC_UUID" "$SRC_DIR")") || true
    if [ -n "$ENC_ARCH" ]; then
        assert_bg "createArchive (special-char passphrase)" "BorgBackup" "createArchive" \
            "{\"uuid\":\"$ENC_ARCH\",\"dryrun\":false,\"progress\":false}" "This archive:"
        if grep -q "^Command: .*BORG_PASSPHRASE=" <<<"$BG_OUTPUT" \
           && ! grep -qF "bgrpcSecret1" <<<"$BG_OUTPUT"; then
            _pass "createArchive — passphrase masked in task output"
        else
            _fail "createArchive — passphrase shown in task output (or no Command line)"
        fi
        if grep -qF "bgrpcSecret1" /var/log/borgbackup/bgrpcenc.log 2>/dev/null; then
            _fail "createArchive — passphrase written to /var/log/borgbackup/bgrpcenc.log"
        else
            _pass "createArchive — passphrase not in archive log"
        fi

        assert_bg "archiveCommand info (encrypted repo)" "BorgBackup" "archiveCommand" \
            "{\"uuid\":\"$ENC_ARCH\",\"command\":\"info\"}" "Archive name: bgrpcenc-"
        if grep -qF "bgrpcSecret1" <<<"$BG_OUTPUT"; then
            _fail "archiveCommand — passphrase shown in task output"
        else
            _pass "archiveCommand — passphrase masked in task output"
        fi
    fi

    ENC_COMPACT=$(create_obj "setCompact (encrypted repo)" setCompact deleteCompact \
        "$(compact_params "$ENC_UUID")") || true
    if [ -n "$ENC_COMPACT" ]; then
        assert_bg "runCompact (encrypted repo)" "BorgBackup" "runCompact" \
            "{\"uuid\":\"$ENC_COMPACT\"}"
        if grep -qF "bgrpcSecret1" <<<"$BG_OUTPUT"; then
            _fail "runCompact — passphrase shown in task output"
        else
            _pass "runCompact — passphrase masked in task output"
        fi
    fi

    KEY_OUT=$(assert_rpc "downloadKey" "BorgBackup" "downloadKey" \
        "{\"uuid\":\"$ENC_UUID\"}" "filepath") || true
    KEY_TMP=$(jget filepath <<<"$KEY_OUT")
    if [ -n "$KEY_TMP" ] && grep -q "^BORG_KEY " "$KEY_TMP" 2>/dev/null; then
        _pass "downloadKey — file contains the borg key"
    else
        _fail "downloadKey — no borg key in returned file ($KEY_TMP)"
    fi
    [ -n "$KEY_TMP" ] && rm -f "$KEY_TMP"

    assert_rpc "changePassphrase (path with space, special chars)" "BorgBackup" \
        "changePassphrase" "$(pyjson "{'uuid': a[0], 'passphrase': a[1]}" "$ENC_UUID" "$PASS2")" \
        >/dev/null
    if BORG_PASSPHRASE="$PASS2" borg info "$ENC_DIR" </dev/null &>/dev/null; then
        _pass "changePassphrase — borg accepts the new passphrase"
    else
        _fail "changePassphrase — borg rejects the new passphrase"
    fi
    if BORG_PASSPHRASE="$PASS1" borg info "$ENC_DIR" </dev/null &>/dev/null; then
        _fail "changePassphrase — old passphrase still accepted"
    else
        _pass "changePassphrase — old passphrase rejected"
    fi
    STORED_PASS=$(rpc "BorgBackup" "getRepo" "{\"uuid\":\"$ENC_UUID\"}" 2>/dev/null \
        | jget passphrase)
    if [ "$STORED_PASS" = "$PASS2" ]; then
        _pass "changePassphrase — new passphrase stored"
    else
        _fail "changePassphrase — stored passphrase not updated"
    fi
fi

# ---------------------------------------------------------------------------
# Integration — shared folder operations: export, extract, mount, quota
# ---------------------------------------------------------------------------
section "Integration — shared folder operations"

SF_MNTENT=$(rpc "ShareMgmt" "enumerateSharedFolders" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d[0]['mntentref'] if d else '')" 2>/dev/null || echo "")
SF_RAND=$(python3 -c "import secrets; print(secrets.token_hex(3))")

# Create a temporary shared folder on the same filesystem as an existing one
# and print its UUID. It is deleted (with its content) on exit.
new_sharedfolder() {
    local name=$1 out uuid
    out=$(assert_rpc "ShareMgmt set ($name)" "ShareMgmt" "set" \
        "$(pyjson "{
    'uuid': a[0], 'name': a[1], 'reldirpath': a[1] + '/',
    'comment': 'openmediavault-borgbackup test', 'mntentref': a[2], 'mode': '755',
}" "$OMV_NEW_UUID" "$name" "$SF_MNTENT")") || return 1
    uuid=$(jget uuid <<<"$out")
    if [ -z "$uuid" ] || [ "$uuid" = "$OMV_NEW_UUID" ]; then
        _fail "ShareMgmt set ($name) — no UUID returned"
        return 1
    fi
    on_cleanup rpc ShareMgmt delete "{\"uuid\":\"$uuid\",\"recursive\":true}"
    echo "$uuid"
}

sf_path() {
    rpc "ShareMgmt" "getPath" "{\"uuid\":\"$1\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).rstrip('/'))" 2>/dev/null
}

if [ -z "$SF_MNTENT" ]; then
    info "No shared folder exists — skipping export/extract/mount/quota tests"
else
    SF_DATA=$(new_sharedfolder "bgrpctest_data_$SF_RAND") || true
    SF_DATA_PATH=$( [ -n "$SF_DATA" ] && sf_path "$SF_DATA" )
fi

if [ -n "${SF_DATA_PATH:-}" ] && [ -d "$SF_DATA_PATH" ]; then
    on_cleanup rm -f "/tmp/omv-borg-export-$REPO_UUID.log" "/tmp/omv-borg-extract-$REPO_UUID.log"
    EXPORT_ARCHIVE=$(borg_list "$REPO_DIR" | grep -m1 '^bgrpcarchx-')

    # --- export -------------------------------------------------------------
    assert_bg "exportArchive" "BorgBackup" "exportArchive" \
        "$(pyjson "{'uuid': a[0], 'archive': a[1], 'sharedfolderref': a[2]}" \
            "$REPO_UUID" "$EXPORT_ARCHIVE" "$SF_DATA")"
    if tar tzf "$SF_DATA_PATH/$EXPORT_ARCHIVE.tar.gz" 2>/dev/null | grep -q "src/file1.txt$"; then
        _pass "exportArchive — tar.gz contains the backed-up files"
    else
        _fail "exportArchive — $SF_DATA_PATH/$EXPORT_ARCHIVE.tar.gz missing or incomplete"
    fi
    assert_bg "getLog (export)" "BorgBackup" "getLog" \
        "{\"uuid\":\"$REPO_UUID\",\"command\":\"export\",\"follow\":false}"

    # --- extract ------------------------------------------------------------
    extract_params() {
        pyjson "{'uuid': a[0], 'archive': a[1], 'original': a[2], 'sharedfolderref': a[3]}" \
            "$REPO_UUID" "$EXPORT_ARCHIVE" "$1" "$2"
    }
    assert_bg "extractArchive (to shared folder)" "BorgBackup" "extractArchive" \
        "$(extract_params false "$SF_DATA")"
    if [ "$(cat "$SF_DATA_PATH/${SRC_DIR#/}/file1.txt" 2>/dev/null)" = "bgrpctest-content" ]; then
        _pass "extractArchive — files extracted into the shared folder"
    else
        _fail "extractArchive — $SF_DATA_PATH/${SRC_DIR#/}/file1.txt missing"
    fi

    # Without a shared folder and without "original location" it must refuse
    # rather than extract into /. Remove a source file first so an extraction
    # into / (which restores the original paths) would be detectable.
    rm -f "$SRC_DIR/file1.txt"
    assert_bg_fails "extractArchive — no shared folder and not original location rejected" \
        "BorgBackup" "extractArchive" "$(extract_params false "")"
    if [ -e "$SRC_DIR/file1.txt" ]; then
        _fail "extractArchive — files were extracted into /"
    else
        _pass "extractArchive — nothing extracted into /"
    fi

    assert_bg "extractArchive (original location)" "BorgBackup" "extractArchive" \
        "$(extract_params true "")"
    if [ "$(cat "$SRC_DIR/file1.txt" 2>/dev/null)" = "bgrpctest-content" ]; then
        _pass "extractArchive — original file restored"
    else
        _fail "extractArchive — $SRC_DIR/file1.txt not restored"
    fi
    assert_bg "getLog (extract)" "BorgBackup" "getLog" \
        "{\"uuid\":\"$REPO_UUID\",\"command\":\"extract\",\"follow\":false}"

    # --- mount / unmount ----------------------------------------------------
    # xbgrpctest ends with the main repo's name bgrpctest; mount status and
    # unmount must not confuse the two.
    XR_DIR=$(mktemp -d)
    on_cleanup rm -rf "$XR_DIR"
    on_cleanup forget_borg_repo "$XR_DIR"
    XR_UUID=$(create_obj "setRepo (xbgrpctest)" setRepo deleteRepo \
        "$(repo_params xbgrpctest remote '' "$XR_DIR" '' false false)") || true
    XR_MNT="$SF_DATA_PATH/xbgrpctest"
    on_cleanup unmount_dir "$XR_MNT"

    repo_mounted() {
        rpc "BorgBackup" "getRepoList" "$LIST_PARAMS" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', []) if isinstance(d, dict) else d
print(next((str(r.get('mounted')).lower() for r in rows if r.get('name') == sys.argv[1]),
           'missing'))" "$1" 2>/dev/null || echo "error"
    }

    MOUNT_OUT=""
    MOUNT_EC=0
    if [ -n "$XR_UUID" ]; then
        MOUNT_OUT=$(rpc "BorgBackup" "mountRepo" \
            "{\"uuid\":\"$XR_UUID\",\"sharedfolderref\":\"$SF_DATA\",\"versions\":false}" 2>&1) \
            || MOUNT_EC=$?
    fi
    if [ -z "$XR_UUID" ]; then
        _fail "mountRepo — could not register xbgrpctest"
    elif [ $MOUNT_EC -ne 0 ] && grep -qi "fuse" <<<"$MOUNT_OUT"; then
        info "borg mount not available (no FUSE support) — skipping mount tests"
    elif [ $MOUNT_EC -ne 0 ]; then
        _fail "mountRepo (xbgrpctest)" "$(echo "$MOUNT_OUT" | tail -3)"
    else
        _pass "mountRepo (xbgrpctest)"
        if mountpoint -q "$XR_MNT"; then
            _pass "mountRepo — mounted at $XR_MNT"
        else
            _fail "mountRepo — nothing mounted at $XR_MNT"
        fi
        [ "$(repo_mounted xbgrpctest)" = "true" ] \
            && _pass "getRepoList — xbgrpctest shown as mounted" \
            || _fail "getRepoList — xbgrpctest not shown as mounted"
        [ "$(repo_mounted bgrpctest)" = "false" ] \
            && _pass "getRepoList — bgrpctest not shown as mounted" \
            || _fail "getRepoList — bgrpctest shown as mounted (matched xbgrpctest)"

        assert_rpc_fails "unmountRepo (bgrpctest) — not mounted, rejected" "BorgBackup" \
            "unmountRepo" "{\"uuid\":\"$REPO_UUID\"}"
        if mountpoint -q "$XR_MNT"; then
            _pass "unmountRepo (bgrpctest) — xbgrpctest left mounted"
        else
            _fail "unmountRepo (bgrpctest) — unmounted xbgrpctest instead"
        fi

        assert_rpc "unmountRepo (xbgrpctest)" "BorgBackup" "unmountRepo" \
            "{\"uuid\":\"$XR_UUID\"}" >/dev/null
        if ! mountpoint -q "$XR_MNT" && [ ! -d "$XR_MNT" ]; then
            _pass "unmountRepo — unmounted and mount directory removed"
        else
            _fail "unmountRepo — $XR_MNT still mounted or present"
        fi
    fi

    # --- local repo: quota, deleteRepo with files ---------------------------
    SF_REPO=$(new_sharedfolder "bgrpctest_repo_$SF_RAND") || true
    SF_REPO_PATH=$( [ -n "$SF_REPO" ] && sf_path "$SF_REPO" )
    if [ -n "$SF_REPO_PATH" ] && [ -d "$SF_REPO_PATH" ]; then
        on_cleanup forget_borg_repo "$SF_REPO_PATH"
        LR_UUID=$(create_obj "setRepo (local, storage quota 1G)" setRepo deleteRepo \
            "$(repo_params bgrpclocal local "$SF_REPO" '' '' false false 1G)") || true
    fi
    if [ -n "${LR_UUID:-}" ]; then
        assert_rpc "changeQuota (1G → 2G)" "BorgBackup" "changeQuota" \
            "$(pyjson "{'uuid': a[0], 'newquota': '2G'}" "$LR_UUID")" >/dev/null
        LR_QUOTA=$(borg config "$SF_REPO_PATH" storage_quota </dev/null 2>/dev/null || echo "")
        case "$LR_QUOTA" in
            2000000000|2G) _pass "changeQuota — repo config updated ($LR_QUOTA)" ;;
            *) _fail "changeQuota — repo storage_quota is '$LR_QUOTA'" ;;
        esac
        assert_rpc "changeQuota — new quota stored" "BorgBackup" "getRepo" \
            "{\"uuid\":\"$LR_UUID\"}" '"storquota":"2G"' >/dev/null

        # Removing a repo must also remove the compact schedules and env vars
        # that reference it, so they are not left scheduled/orphaned.
        LR_COMPACT=$(create_obj "setCompact (local repo)" setCompact deleteCompact \
            "$(compact_params "$LR_UUID")") || true
        LR_ENV=$(create_obj "setEnvVar (local repo)" setEnvVar deleteEnvVar \
            "$(pyjson "{'uuid': a[0], 'envname': 'BG_RPC_LOCAL', 'envvalue': 'x', 'reporef': a[1]}" \
                "$OMV_NEW_UUID" "$LR_UUID")") || true

        assert_rpc "deleteRepo (local, deleteFiles=true)" "BorgBackup" "deleteRepo" \
            "{\"uuid\":\"$LR_UUID\",\"deleteFiles\":true}" >/dev/null
        if [ -d "$SF_REPO_PATH" ] && [ ! -e "$SF_REPO_PATH/config" ]; then
            _pass "deleteRepo — repo files removed, shared folder directory kept"
        else
            _fail "deleteRepo — repo files still present or directory missing"
        fi
        [ -n "$LR_COMPACT" ] && assert_rpc_fails "deleteRepo — compact schedule removed" \
            "BorgBackup" "getCompact" "{\"uuid\":\"$LR_COMPACT\"}"
        [ -n "$LR_ENV" ] && assert_rpc_fails "deleteRepo — env var removed" \
            "BorgBackup" "getEnvVar" "{\"uuid\":\"$LR_ENV\"}"
    fi
elif [ -n "$SF_MNTENT" ]; then
    _fail "Could not create a temporary shared folder"
fi

# ---------------------------------------------------------------------------
# Integration — salt deploy: generated scheduled backup scripts
# ---------------------------------------------------------------------------
section "Integration — salt deploy (scheduled scripts)"

if ! command -v omv-salt &>/dev/null; then
    info "omv-salt not available — skipping scheduled script tests"
elif [ -z "${ENC_UUID:-}" ]; then
    _fail "Scheduled script tests — encrypted repo missing"
else
    # bgrpcsalt runs from cron with email on (output piped through tee) on
    # the encrypted repo (special-char passphrase, path with a space).
    SALT_ARCH=$(create_obj "setArchive (bgrpcsalt, email on)" setArchive deleteArchive \
        "$(archive_params bgrpcsalt "$ENC_UUID" "$SRC_DIR" true)") || true
    # Two same-day archives of bgrpcsalt-old: with a plain 'bgrpcsalt-*' prune
    # glob, bgrpcsalt's keep-daily rule would prune one of them.
    SALT_OLD=$(create_obj "setArchive (bgrpcsalt-old)" setArchive deleteArchive \
        "$(archive_params bgrpcsalt-old "$ENC_UUID" "$SRC_DIR")") || true
    if [ -n "$SALT_OLD" ]; then
        for run in 1 2; do
            assert_bg "createArchive (bgrpcsalt-old #$run)" "BorgBackup" "createArchive" \
                "{\"uuid\":\"$SALT_OLD\",\"dryrun\":false,\"progress\":false}" "This archive:"
            sleep 1   # archive names have one-second resolution
        done
    fi

    # Env var values with quotes, $() and backslashes must reach borg as-is.
    QUOTE_VALUE="it's \"q\" \$(id) \`id\` \\t"
    create_obj "setEnvVar (value with quotes and \$())" setEnvVar deleteEnvVar \
        "$(pyjson "{'uuid': a[0], 'envname': 'BG_RPC_QUOTE', 'envvalue': a[1], 'reporef': a[2]}" \
            "$OMV_NEW_UUID" "$QUOTE_VALUE" "$ENC_UUID")" >/dev/null || true
    # Extra create args from an env var must be honoured by GUI runs too.
    create_obj "setEnvVar (BORG_EXTRA_CREATE_ARGS)" setEnvVar deleteEnvVar \
        "$(pyjson "{'uuid': a[0], 'envname': 'BORG_EXTRA_CREATE_ARGS',
                    'envvalue': '--exclude-if-present .bgrpcskip', 'reporef': a[1]}" \
            "$OMV_NEW_UUID" "$REPO_UUID")" >/dev/null || true

    SALT_LOG=$(mktemp)
    if omv-salt deploy run borgbackup &>"$SALT_LOG"; then
        _pass "omv-salt deploy run borgbackup — applied (archives, env vars)"
    else
        _fail "omv-salt deploy run borgbackup — failed" "$(tail -5 "$SALT_LOG")"
    fi
    rm -f "$SALT_LOG"

    SALT_SCRIPT="/var/lib/openmediavault/borgbackup/borgbackup-$SALT_ARCH"
    if grep -q "root  $SALT_SCRIPT$" /etc/cron.d/openmediavault-borgbackup 2>/dev/null; then
        _pass "cron — bgrpcsalt scheduled"
    else
        _fail "cron — bgrpcsalt not scheduled"
    fi

    if [ -x "$SALT_SCRIPT" ]; then
        SALT_RC=0
        bash "$SALT_SCRIPT" &>/dev/null </dev/null || SALT_RC=$?
        if [ $SALT_RC -eq 0 ]; then
            _pass "scheduled script — succeeds with special-char passphrase and path with space"
        else
            _fail "scheduled script — exit $SALT_RC" \
                "$(tail -3 /var/log/borgbackup/bgrpcsalt.log 2>/dev/null)"
        fi
        SALT_NAMES=$(borg_list "$ENC_DIR" "$PASS2")
        if [ "$(grep -cE '^bgrpcsalt-[0-9]' <<<"$SALT_NAMES")" = "1" ]; then
            _pass "scheduled script — bgrpcsalt archive created"
        else
            _fail "scheduled script — bgrpcsalt archive missing" "$SALT_NAMES"
        fi
        if [ "$(grep -c '^bgrpcsalt-old-' <<<"$SALT_NAMES")" = "2" ]; then
            _pass "scheduled script — prune left bgrpcsalt-old archives alone"
        else
            _fail "scheduled script — prune touched bgrpcsalt-old archives" "$SALT_NAMES"
        fi

        # With the repo gone the script must fail, even though its output is
        # piped through tee.
        mv "$ENC_DIR" "$ENC_DIR.moved"
        SALT_RC=0
        bash "$SALT_SCRIPT" &>/dev/null </dev/null || SALT_RC=$?
        mv "$ENC_DIR.moved" "$ENC_DIR"
        if [ $SALT_RC -ne 0 ]; then
            _pass "scheduled script — failing backup exits non-zero ($SALT_RC)"
        else
            _fail "scheduled script — failing backup exited 0"
        fi
        if tail -5 /var/log/borgbackup/bgrpcsalt.log 2>/dev/null \
            | grep -q "Borg finished with errors"; then
            _pass "scheduled script — failure logged as an error"
        else
            _fail "scheduled script — failure not logged as an error"
        fi
    else
        _fail "scheduled script — $SALT_SCRIPT not generated"
    fi

    ENV_FILE="/etc/borgbackup/borg-envvar-$ENC_UUID"
    ENV_GOT=$(bash -c 'set -a; . "$1"; printf "%s" "$BG_RPC_QUOTE"' _ "$ENV_FILE" 2>/dev/null)
    if [ "$ENV_GOT" = "$QUOTE_VALUE" ]; then
        _pass "env var file — value with quotes and \$() read back unchanged"
    else
        _fail "env var file — value changed" "expected [$QUOTE_VALUE] got [$ENV_GOT]"
    fi

    if [ -n "${ARCH_X:-}" ]; then
        mkdir -p "$SRC_DIR/skipme"
        touch "$SRC_DIR/skipme/.bgrpcskip"
        echo "secret" >"$SRC_DIR/skipme/secret.txt"
        assert_bg "createArchive with BORG_EXTRA_CREATE_ARGS" "BorgBackup" "createArchive" \
            "{\"uuid\":\"$ARCH_X\",\"dryrun\":false,\"progress\":false}" "This archive:"
        LATEST_X=$(borg_list "$REPO_DIR" | grep '^bgrpcarchx-' | sort | tail -1)
        X_FILES=$(BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes \
            borg list --short "$REPO_DIR::$LATEST_X" </dev/null 2>/dev/null)
        if grep -q "sub/file2.txt$" <<<"$X_FILES" && ! grep -q "skipme/secret.txt$" <<<"$X_FILES"; then
            _pass "createArchive — BORG_EXTRA_CREATE_ARGS applied (--exclude-if-present)"
        else
            _fail "createArchive — BORG_EXTRA_CREATE_ARGS not applied"
        fi
        rm -rf "$SRC_DIR/skipme"
    fi
fi

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

# An enabled compact schedule and an env var for the repo: both must go away
# with the repo, and no compact script or cron line may be left behind.
MAIN_COMPACT=$(create_obj "setCompact (daily, main repo)" setCompact deleteCompact \
    "$(compact_params "$REPO_UUID" | python3 -c "
import sys, json
p = json.load(sys.stdin)
p['dailyenable'] = True
print(json.dumps(p))")") || true
MAIN_ENV=$(create_obj "setEnvVar (main repo)" setEnvVar deleteEnvVar \
    "$(pyjson "{'uuid': a[0], 'envname': 'BG_RPC_MAIN', 'envvalue': 'x', 'reporef': a[1]}" \
        "$OMV_NEW_UUID" "$REPO_UUID")") || true

assert_rpc "deleteRepo (deleteFiles=false)" "BorgBackup" "deleteRepo" \
    "{\"uuid\":\"$REPO_UUID\",\"deleteFiles\":false}" >/dev/null
REPO_UUID=""

assert_rpc_fails "getRepo after delete" "BorgBackup" "getRepo" \
    "{\"uuid\":\"$SAVED_REPO_UUID\"}"
[ -n "$MAIN_COMPACT" ] && assert_rpc_fails "deleteRepo — compact schedule removed" \
    "BorgBackup" "getCompact" "{\"uuid\":\"$MAIN_COMPACT\"}"
[ -n "$MAIN_ENV" ] && assert_rpc_fails "deleteRepo — env var removed" \
    "BorgBackup" "getEnvVar" "{\"uuid\":\"$MAIN_ENV\"}"
for a in "${ARCH_X:-}" "${ARCH_OLD:-}"; do
    [ -n "$a" ] && assert_rpc_fails "deleteRepo — archive config $a removed" \
        "BorgBackup" "getArchive" "{\"uuid\":\"$a\"}"
done

if command -v omv-salt &>/dev/null && [ -n "$MAIN_COMPACT" ]; then
    omv-salt deploy run borgbackup &>/dev/null || true
    if [ -e "/var/lib/openmediavault/borgbackup/borgcompact-$MAIN_COMPACT" ] \
       || grep -q "borgcompact-$MAIN_COMPACT" /etc/cron.d/openmediavault-borgbackup 2>/dev/null; then
        _fail "deleteRepo — compact script or cron line left behind after deploy"
    else
        _pass "deleteRepo — no compact script or cron line left after deploy"
    fi
    if [ -e "/etc/borgbackup/borg-envvar-$SAVED_REPO_UUID" ]; then
        _fail "deleteRepo — env var file left behind after deploy"
    else
        _pass "deleteRepo — env var file removed after deploy"
    fi
fi

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
PASS=$(grep -c '^PASS ' "$RESULTS_FILE")
FAIL=$(grep -c '^FAIL ' "$RESULTS_FILE")
TOTAL=$((PASS + FAIL))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} (${TOTAL} total)" >&2
if [ "$FAIL" -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    while IFS= read -r t; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done < <(sed -n 's/^FAIL //p' "$RESULTS_FILE")
fi
echo >&2
rm -f "$RESULTS_FILE"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
