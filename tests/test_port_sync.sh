#!/bin/bash
# Automated unit & integration test suite for port-sync.sh
# Uses isolated mock BIN_DIR (natpmpc, curl) with zero live network/service side effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PORT_SYNC="${REPO_ROOT}/port-sync.sh"

PASS_COUNT=0
FAIL_COUNT=0

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}[FAIL]${NC} $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo -e "       Details: $2" >&2
    fi
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg (got '$actual')"
    else
        fail "$msg" "expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
        pass "$msg"
    else
        fail "$msg" "missing substring '$needle'"
    fi
}

# Strip ANSI escape sequences for ct127-health.py log compatibility testing
strip_ansi() {
    sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g'
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/port-sync-test-XXXXXX")"
BIN_DIR="${TEST_ROOT}/bin"
STATE_DIR="${TEST_ROOT}/state"
WORK_TMP="${TEST_ROOT}/tmp"
mkdir -p "$BIN_DIR" "$STATE_DIR" "$WORK_TMP"

cleanup_test_root() {
    rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

# ---------------------------------------------------------------------------
# Install mock curl & natpmpc into BIN_DIR
# ---------------------------------------------------------------------------
cat >"${BIN_DIR}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

STATE_DIR="${MOCK_STATE_DIR:?MOCK_STATE_DIR required}"
echo "$*" >>"${STATE_DIR}/curl_calls.log"

url="${!#}"
method="GET"
post_data=""

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -X)
            method="${args[$((i + 1))]:-GET}"
            ;;
        -d|--data|--data-raw)
            if [[ -n "$post_data" ]]; then
                post_data="${post_data}&${args[$((i + 1))]:-}"
            else
                post_data="${args[$((i + 1))]:-}"
            fi
            ;;
    esac
done

case "$url" in
    */api/v2/auth/login)
        printf 'Ok.'
        ;;
    */api/v2/app/version)
        printf 'v5.0.4'
        ;;
    */api/v2/app/preferences)
        port="$(cat "${STATE_DIR}/qbt_port" 2>/dev/null || echo "31938")"
        printf '{"listen_port":%s,"random_port":false,"upnp":false}' "$port"
        ;;
    */api/v2/sync/maindata)
        if [[ -f "${STATE_DIR}/expose_maindata_port" ]]; then
            port="$(cat "${STATE_DIR}/qbt_port" 2>/dev/null || echo "31938")"
            printf '{"rid":1,"server_state":{"connection_status":"connected","listen_port":%s}}' "$port"
        else
            printf '{"rid":1,"server_state":{"connection_status":"connected"}}'
        fi
        ;;
    */api/v2/app/setPreferences)
        count="$(cat "${STATE_DIR}/set_prefs_count" 2>/dev/null || echo "0")"
        echo $((count + 1)) >"${STATE_DIR}/set_prefs_count"
        new_port="$(printf '%s\n' "$post_data" | grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
        if [[ -n "$new_port" ]]; then
            echo "$new_port" >"${STATE_DIR}/qbt_pending_port"
            mode="$(cat "${STATE_DIR}/qbt_mode" 2>/dev/null || echo "hot")"
            if [[ "$mode" == "hot" ]]; then
                echo "$new_port" >"${STATE_DIR}/qbt_port"
            fi
        fi
        printf ''
        ;;
    *)
        echo "Mock curl: unexpected URL $url" >&2
        exit 22
        ;;
esac
EOF
chmod +x "${BIN_DIR}/curl"

cat >"${BIN_DIR}/natpmpc" <<'EOF'
#!/bin/bash
set -euo pipefail

STATE_DIR="${MOCK_STATE_DIR:?MOCK_STATE_DIR required}"
echo "$*" >>"${STATE_DIR}/natpmpc_calls.log"

pub_hint=""
proto=""
lifetime=""

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-a" ]]; then
        pub_hint="${args[$((i + 1))]:-1}"
        proto="${args[$((i + 3))]:-udp}"
        lifetime="${args[$((i + 4))]:-60}"
        break
    fi
done

proto_upper="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
granted_lt="$(cat "${STATE_DIR}/granted_lifetime" 2>/dev/null || echo "60")"
scenario="$(cat "${STATE_DIR}/natpmp_scenario" 2>/dev/null || echo "normal")"

if [[ "$lifetime" == "0" ]]; then
    touch "${STATE_DIR}/released_${proto}"
    echo "Mapped public port 0 protocol ${proto_upper} to local port 0 liftime 0"
    exit 0
fi

case "$scenario" in
    normal)
        port="$(cat "${STATE_DIR}/natpmp_port" 2>/dev/null || echo "31938")"
        echo "Mapped public port ${port} protocol ${proto_upper} to local port 0 liftime ${granted_lt}"
        ;;
    transient_udp_fail_once)
        if [[ "$proto" == "udp" ]]; then
            udp_calls="$(cat "${STATE_DIR}/udp_attempts" 2>/dev/null || echo "0")"
            udp_calls=$((udp_calls + 1))
            echo "$udp_calls" >"${STATE_DIR}/udp_attempts"
            if (( udp_calls == 1 )); then
                echo "readnatpmpresponseorretry() failed : the gateway does not support nat-pmp" >&2
                exit 1
            fi
        fi
        port="$(cat "${STATE_DIR}/natpmp_port" 2>/dev/null || echo "31938")"
        echo "Mapped public port ${port} protocol ${proto_upper} to local port 0 liftime ${granted_lt}"
        ;;
    split_heal_after_release)
        if [[ -f "${STATE_DIR}/released_udp" && -f "${STATE_DIR}/released_tcp" ]]; then
            echo "Mapped public port 49001 protocol ${proto_upper} to local port 0 liftime ${granted_lt}"
        else
            if [[ "$proto" == "udp" ]]; then
                echo "Mapped public port 31938 protocol UDP to local port 0 liftime ${granted_lt}"
            else
                # Even if hinted with 31938, gateway keeps returning 38015 until both leases are released
                echo "Mapped public port 38015 protocol TCP to local port 0 liftime ${granted_lt}"
            fi
        fi
        ;;
    partial_udp_dead)
        if [[ "$proto" == "udp" ]]; then
            echo "readnatpmpresponseorretry() failed : network timeout" >&2
            exit 1
        fi
        tcp_port="$(cat "${STATE_DIR}/natpmp_tcp_only_port" 2>/dev/null || echo "51111")"
        echo "Mapped public port ${tcp_port} protocol TCP to local port 0 liftime ${granted_lt}"
        ;;
    *)
        echo "Unknown mock natpmpc scenario: $scenario" >&2
        exit 1
        ;;
esac
EOF
chmod +x "${BIN_DIR}/natpmpc"

reset_state() {
    rm -f "${STATE_DIR}"/*
    echo "31938" >"${STATE_DIR}/qbt_port"
    echo "hot" >"${STATE_DIR}/qbt_mode"
    echo "31938" >"${STATE_DIR}/natpmp_port"
    echo "normal" >"${STATE_DIR}/natpmp_scenario"
    echo "60" >"${STATE_DIR}/granted_lifetime"
    echo "0" >"${STATE_DIR}/set_prefs_count"
    echo "0" >"${STATE_DIR}/restart_count"
}

RESTART_HELPER="${BIN_DIR}/mock-qbt-restart"
cat >"$RESTART_HELPER" <<'EOF'
#!/bin/bash
set -euo pipefail
STATE_DIR="${MOCK_STATE_DIR:?MOCK_STATE_DIR required}"
count="$(cat "${STATE_DIR}/restart_count" 2>/dev/null || echo "0")"
echo $((count + 1)) >"${STATE_DIR}/restart_count"
if [[ -f "${STATE_DIR}/qbt_pending_port" ]]; then
    cp "${STATE_DIR}/qbt_pending_port" "${STATE_DIR}/qbt_port"
fi
EOF
chmod +x "$RESTART_HELPER"

export PATH="${BIN_DIR}:${PATH}"
export MOCK_STATE_DIR="$STATE_DIR"

echo -e "${CYAN}=== Running qbittorrent-wireguard-pmp Test Suite ===${NC}"

# ---------------------------------------------------------------------------
# Test 1: bash -n syntax check & zero-CRLF check across repository files
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 1: Syntax & LF Line-Ending Verification ---${NC}"
for sh_file in "${REPO_ROOT}/port-sync.sh" "${REPO_ROOT}/install.sh" "${REPO_ROOT}/service-manager.sh" "${REPO_ROOT}/tests/test_port_sync.sh"; do
    base="$(basename "$sh_file")"
    if bash -n "$sh_file"; then
        pass "bash -n syntax check passed for ${base}"
    else
        fail "bash -n syntax check failed for ${base}"
    fi

    if LC_ALL=C grep -q $'\r' "$sh_file"; then
        fail "Zero-CRLF check failed for ${base} (contains CR byte)"
    else
        pass "Zero-CRLF check passed for ${base}"
    fi
done

if LC_ALL=C grep -q $'\r' "${REPO_ROOT}/qbittorrent-wireguard-sync.service"; then
    fail "Zero-CRLF check failed for qbittorrent-wireguard-sync.service"
else
    pass "Zero-CRLF check passed for qbittorrent-wireguard-sync.service"
fi

# ---------------------------------------------------------------------------
# Test 2: Normal sync when NAT-PMP UDP == TCP == qBittorrent listen_port
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 2: Normal Sync (Ports Already Match) ---${NC}"
reset_state
LOG_PATH="${TEST_ROOT}/test2.log"

out2="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    QBITTORRENT_RESTART_COMMAND="$RESTART_HELPER" \
    bash "$PORT_SYNC" 2>&1
)"

assert_eq "0" "$(cat "${STATE_DIR}/set_prefs_count")" "No setPreferences call when ports match"
assert_eq "0" "$(cat "${STATE_DIR}/restart_count")" "No qBittorrent restart when ports match"
clean_out2="$(printf '%s\n' "$out2" | strip_ansi)"
if printf '%s\n' "$clean_out2" | grep -Eq 'NAT-PMP mapped public port:[[:space:]]*31938[[:space:]]*$'; then
    pass "Emits ct127-health.py compatible 'NAT-PMP mapped public port: 31938' log line"
else
    fail "Missing ct127-health.py compatible log line" "$clean_out2"
fi

# ---------------------------------------------------------------------------
# Test 3: Port change (31938 -> 45123) Zero-Downtime Hot Update
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 3: Port Change (31938 -> 45123) Zero-Downtime Hot Update ---${NC}"
reset_state
echo "31938" >"${STATE_DIR}/qbt_port"
echo "45123" >"${STATE_DIR}/natpmp_port"
LOG_PATH="${TEST_ROOT}/test3.log"

t3_start="$(date +%s)"
out3="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    QBITTORRENT_RESTART_COMMAND="$RESTART_HELPER" \
    QBITTORRENT_RESTART_WAIT="15" \
    bash "$PORT_SYNC" 2>&1
)"
t3_end="$(date +%s)"
t3_elapsed=$((t3_end - t3_start))

assert_eq "45123" "$(cat "${STATE_DIR}/qbt_port")" "Mock qBittorrent listen_port hot-updated to 45123"
assert_eq "1" "$(cat "${STATE_DIR}/set_prefs_count")" "Exactly 1 setPreferences API call made"
assert_eq "0" "$(cat "${STATE_DIR}/restart_count")" "ZERO invocations of QBITTORRENT_RESTART_COMMAND during hot update"
assert_contains "$out3" "Hot-applied qBittorrent listen_port=45123 via WebUI API (zero restart)" "Logged zero-restart hot-apply confirmation"
if (( t3_elapsed <= 2 )); then
    pass "Hot port update completed in <=2s (elapsed=${t3_elapsed}s)"
else
    fail "Hot port update took too long" "elapsed=${t3_elapsed}s"
fi

# ---------------------------------------------------------------------------
# Test 4: Emergency Fallback Restart when qBittorrent Ignores Hot setPreferences
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 4: Emergency Fallback Restart on Hot-Apply Failure ---${NC}"
reset_state
echo "31938" >"${STATE_DIR}/qbt_port"
echo "45123" >"${STATE_DIR}/natpmp_port"
echo "ignore_hot" >"${STATE_DIR}/qbt_mode"
LOG_PATH="${TEST_ROOT}/test4.log"

out4="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    QBITTORRENT_RESTART_COMMAND="$RESTART_HELPER" \
    QBITTORRENT_RESTART_WAIT="0" \
    QBITTORRENT_HOT_VERIFY_DELAY="0.05" \
    QBITTORRENT_VERIFY_DELAY="0.05" \
    bash "$PORT_SYNC" 2>&1
)"

assert_eq "1" "$(cat "${STATE_DIR}/restart_count")" "Fallback QBITTORRENT_RESTART_COMMAND invoked once when hot-apply failed"
assert_eq "45123" "$(cat "${STATE_DIR}/qbt_port")" "qBittorrent port updated to 45123 after fallback restart"
assert_contains "$out4" "invoking fallback QBITTORRENT_RESTART_COMMAND" "Logged emergency fallback restart warning"

# ---------------------------------------------------------------------------
# Test 5: Transient UDP natpmpc Failure on Attempt 1 (Recovers on Attempt 2)
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 5: Transient UDP natpmpc Failure Retry Recovery ---${NC}"
reset_state
echo "31938" >"${STATE_DIR}/qbt_port"
echo "31938" >"${STATE_DIR}/natpmp_port"
echo "transient_udp_fail_once" >"${STATE_DIR}/natpmp_scenario"
LOG_PATH="${TEST_ROOT}/test5.log"

out5="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    NATPMP_RETRIES="3" \
    NATPMP_RETRY_DELAY="0.05" \
    QBITTORRENT_RESTART_COMMAND="$RESTART_HELPER" \
    bash "$PORT_SYNC" 2>&1
)"

assert_eq "2" "$(cat "${STATE_DIR}/udp_attempts")" "UDP natpmpc retried and succeeded on attempt 2"
assert_eq "0" "$(cat "${STATE_DIR}/set_prefs_count")" "Recovered clean symmetric port 31938 without spurious port flip"
assert_eq "0" "$(cat "${STATE_DIR}/restart_count")" "Zero restarts on transient UDP packet loss"

# ---------------------------------------------------------------------------
# Test 6: UDP/TCP Port Split (udp=31938, tcp=38015) Automatic Self-Healing
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 6: UDP/TCP Port Split Self-Healing (Release & Symmetric Re-Request) ---${NC}"
reset_state
echo "31938" >"${STATE_DIR}/qbt_port"
echo "split_heal_after_release" >"${STATE_DIR}/natpmp_scenario"
LOG_PATH="${TEST_ROOT}/test6.log"

out6="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    NATPMP_LIFETIME="120" \
    QBITTORRENT_RESTART_COMMAND="$RESTART_HELPER" \
    bash "$PORT_SYNC" 2>&1
)"

assert_contains "$out6" "UDP/TCP mapped ports differ (udp=31938 tcp=38015); attempting NAT-PMP resync" "Logged UDP/TCP split resync warning"
if [[ -f "${STATE_DIR}/released_udp" && -f "${STATE_DIR}/released_tcp" ]]; then
    pass "Released both UDP and TCP mappings with lifetime 0"
else
    fail "Did not release both UDP and TCP mappings during split self-healing"
fi
assert_contains "$(cat "${STATE_DIR}/natpmpc_calls.log")" "-g 10.2.0.1 -a 31938 0 tcp 120" "Attempted hinted TCP resync before full release"
assert_eq "49001" "$(cat "${STATE_DIR}/qbt_port")" "Healed to symmetric port 49001 and hot-updated qBittorrent"
assert_eq "0" "$(cat "${STATE_DIR}/restart_count")" "Zero qBittorrent restarts during split self-healing"

# ---------------------------------------------------------------------------
# Test 7: Partial Single-Protocol Failure Guard (1-Cycle Hold, 2-Cycle Adopt)
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 7: Partial Single-Protocol Failure Guard ---${NC}"
reset_state
LOG_PATH="${TEST_ROOT}/test7.log"

partial_results="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    NATPMP_RETRIES="2" \
    NATPMP_RETRY_DELAY="0.02" \
    bash -c '
        source "'"$PORT_SYNC"'"
        # Cycle 1: Normal symmetric port 31938
        p1=$(get_protonvpn_port 2>/dev/null)
        _load_natpmp_state
        # Switch mock to partial failure (UDP dead, TCP=51111)
        echo "partial_udp_dead" >"'"${STATE_DIR}"'/natpmp_scenario"
        echo "51111" >"'"${STATE_DIR}"'/natpmp_tcp_only_port"
        # Cycle 2 (1st degraded cycle): must keep 31938
        p2=$(get_protonvpn_port 2>/dev/null)
        _load_natpmp_state
        # Cycle 3 (2nd consecutive degraded cycle): must adopt 51111
        p3=$(get_protonvpn_port 2>/dev/null)
        _load_natpmp_state
        printf "%s,%s,%s,%s" "$p1" "$p2" "$p3" "$LAST_GRANTED_LIFETIME"
    '
)"

assert_eq "31938,31938,51111,60" "$partial_results" "Held last known port for 1 degraded cycle, adopted on 2nd cycle, and persisted LAST_GRANTED_LIFETIME=60"

# ---------------------------------------------------------------------------
# Test 8: Adaptive Cadence Math & Daemon Slow-Cycle Immediate Lease Refresh
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 8: Granted-Lifetime Cadence & Slow-Cycle Immediate Lease Refresh ---${NC}"
cadence_results="$(
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    bash -c '
        source "'"$PORT_SYNC"'"
        CHECK_INTERVAL=25; LAST_GRANTED_LIFETIME=60;  c1=$(compute_target_interval)
        CHECK_INTERVAL=25; LAST_GRANTED_LIFETIME=120; c2=$(compute_target_interval)
        CHECK_INTERVAL=25; LAST_GRANTED_LIFETIME=30;  c3=$(compute_target_interval)
        CHECK_INTERVAL=18; LAST_GRANTED_LIFETIME=60;  c4=$(compute_target_interval)
        printf "%s,%s,%s,%s" "$c1" "$c2" "$c3" "$c4"
    '
)"
assert_eq "24,25,15,18" "$cadence_results" "compute_target_interval enforces min(CHECK_INTERVAL, max(15, granted*2/5))"

# Simulate a 23s slow daemon loop iteration using a mock date for +%s
reset_state
REAL_DATE="$(command -v date)"
cat >"${BIN_DIR}/date" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "+%s" ]]; then
    ts_file="${STATE_DIR}/mock_epoch_seq"
    idx="\$(cat "\$ts_file" 2>/dev/null || echo "0")"
    idx=\$((idx + 1))
    echo "\$idx" >"\$ts_file"
    case "\$idx" in
        1) echo 1700000000 ;; # init_start
        2) echo 1700000001 ;; # init_end
        3) echo 1700000002 ;; # loop_start
        4) echo 1700000025 ;; # loop_end (elapsed = 23s >= 20s!)
        *) echo \$((1700000025 + idx)) ;;
    esac
else
    exec "$REAL_DATE" "\$@"
fi
EOF
chmod +x "${BIN_DIR}/date"

LOG_PATH="${TEST_ROOT}/test8.log"
out8="$(
    LOG_FILE="$LOG_PATH" \
    PORT_SYNC_TMPDIR="$WORK_TMP" \
    NATPMP_GATEWAY="10.2.0.1" \
    DEBUG="1" \
    DAEMON_MAX_LOOPS="1" \
    bash "$PORT_SYNC" --daemon 2>&1
)"
rm -f "${BIN_DIR}/date"

assert_contains "$out8" "Cycle took 23s (>=20s); refreshing NAT-PMP lease immediately before sleeping" "Slow cycle (>=20s) triggered immediate pre-sleep NAT-PMP lease refresh"
assert_contains "$out8" "granted_lifetime=60s target_interval=24s sleep=24s" "Daemon computed adaptive 24s target interval and post-refresh sleep"
# Initial sync (2 calls: udp+tcp) + Loop #1 (2 calls: udp+tcp) + Post-slow-op refresh (2 calls: udp+tcp) = 6 natpmpc calls
natpmpc_total_calls="$(wc -l <"${STATE_DIR}/natpmpc_calls.log" | tr -d '[:space:]')"
assert_eq "6" "$natpmpc_total_calls" "Executed initial + loop + immediate post-slow-op NAT-PMP refreshes (6 natpmpc calls)"

# ---------------------------------------------------------------------------
# Test 9: Log File Size Cap Rotation (LOG_FILE -> LOG_FILE.1)
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Test 9: Log Rotation Guard ---${NC}"
reset_state
ROT_LOG="${TEST_ROOT}/rot.log"
head -c 512 /dev/zero | tr '\0' 'X' >"$ROT_LOG"

LOG_FILE="$ROT_LOG" \
LOG_MAX_BYTES="200" \
PORT_SYNC_TMPDIR="$WORK_TMP" \
NATPMP_GATEWAY="10.2.0.1" \
bash "$PORT_SYNC" >/dev/null 2>&1

if [[ -f "${ROT_LOG}.1" ]]; then
    rot_size="$(wc -c <"${ROT_LOG}.1" | tr -d '[:space:]')"
    assert_eq "512" "$rot_size" "Oversized LOG_FILE rotated cleanly to LOG_FILE.1"
else
    fail "Oversized LOG_FILE was not rotated to LOG_FILE.1"
fi

echo -e "\n============================================"
echo -e "Passed: ${GREEN}${PASS_COUNT}${NC} | Failed: ${RED}${FAIL_COUNT}${NC}"
echo -e "============================================"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
