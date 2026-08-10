#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${TEST_DIR}/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

cat > "${TEST_TMP}/sing-box" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
    generate:uuid)
        printf '%s\n' '123e4567-e89b-12d3-a456-426614174000'
        ;;
    generate:rand)
        length="${4:?missing random length}"
        case "${3:-}" in
            --hex)
                printf '%*s' "$((length * 2))" '' | tr ' ' a
                printf '\n'
                ;;
            --base64)
                head -c "$length" /dev/zero | base64 | tr -d '\n'
                printf '\n'
                ;;
            *) exit 1 ;;
        esac
        ;;
    generate:reality-keypair)
        printf '%s\n' \
            'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
            'PublicKey: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${TEST_TMP}/sing-box"

# shellcheck source=../singbox.sh
source "${REPO_ROOT}/singbox.sh"

SINGBOX_BIN="${TEST_TMP}/sing-box"
BATCH_MODE=true
export SINGBOX_BIN BATCH_MODE

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [ "$expected" = "$actual" ] || fail "${message}: expected '${expected}', got '${actual}'"
}

generated_uuid=$(_resolve_credential UUID uuid uuid)
assert_eq '123e4567-e89b-12d3-a456-426614174000' "$generated_uuid" 'UUID generation'

custom_uuid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
resolved_uuid=$(_resolve_credential UUID uuid uuid "$custom_uuid")
assert_eq "$custom_uuid" "$resolved_uuid" 'custom UUID preservation'

if _resolve_credential UUID uuid uuid invalid >/dev/null 2>&1; then
    fail 'invalid UUID was accepted'
fi

credential_function=$(declare -f _resolve_credential)
[[ "$credential_function" != *'read -r -s'* ]] || fail 'credential input is still hidden'
reality_function=$(declare -f _resolve_reality_credentials)
[[ "$reality_function" != *'read -r -s'* ]] || fail 'Reality private key input is still hidden'

key16=$(_generate_credential 'rand-base64:16')
key32=$(_generate_credential 'rand-base64:32')
_validate_credential 'base64-bytes:16' "$key16"
_validate_credential 'base64-bytes:32' "$key32"
if _validate_credential 'base64-bytes:32' "$key16" >/dev/null 2>&1; then
    fail '16-byte Shadowsocks key was accepted as 32-byte key'
fi

unset BATCH_REALITY_PRIVATE_KEY BATCH_REALITY_PUBLIC_KEY BATCH_REALITY_SHORT_ID
_resolve_reality_credentials
assert_eq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$REALITY_PRIVATE_KEY" 'generated Reality private key'
assert_eq 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' "$REALITY_PUBLIC_KEY" 'generated Reality public key'
assert_eq 'aaaaaaaaaaaaaaaa' "$REALITY_SHORT_ID" 'generated Reality short ID'
assert_eq 'false' "$REALITY_INPUT_PROVIDED" 'generated Reality input marker'

BATCH_REALITY_PRIVATE_KEY='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
BATCH_REALITY_PUBLIC_KEY='DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD'
BATCH_REALITY_SHORT_ID='0123456789abcdef'
_resolve_reality_credentials 2>/dev/null
assert_eq "$BATCH_REALITY_PRIVATE_KEY" "$REALITY_PRIVATE_KEY" 'custom Reality private key'
assert_eq "$BATCH_REALITY_PUBLIC_KEY" "$REALITY_PUBLIC_KEY" 'custom Reality public key'
assert_eq "$BATCH_REALITY_SHORT_ID" "$REALITY_SHORT_ID" 'custom Reality short ID'
assert_eq 'true' "$REALITY_INPUT_PROVIDED" 'custom Reality input marker'

BATCH_REALITY_PUBLIC_KEY=''
if _resolve_reality_credentials >/dev/null 2>&1; then
    fail 'incomplete Reality key pair was accepted'
fi

jq() { printf '{}\n'; }
_atomic_modify_json() { return 0; }
_add_node_to_yaml() { return 0; }
_show_node_link() {
    CAPTURED_SS_METHOD="$6"
    CAPTURED_SS_PASSWORD="$7"
}

BATCH_IP='192.0.2.1'
BATCH_PORT='10443'
BATCH_SNI='www.example.com'
export BATCH_IP BATCH_PORT BATCH_SNI

expected_ss_methods=(
    ''
    'aes-128-gcm'
    'aes-192-gcm'
    'aes-256-gcm'
    'chacha20-ietf-poly1305'
    'xchacha20-ietf-poly1305'
    '2022-blake3-aes-128-gcm'
    '2022-blake3-aes-256-gcm'
    '2022-blake3-chacha20-poly1305'
    '2022-blake3-aes-256-gcm'
    '2022-blake3-aes-256-gcm'
    'none'
)

for choice in {1..11}; do
    BATCH_SS_VARIANT="$choice"
    CAPTURED_SS_METHOD=''
    CAPTURED_SS_PASSWORD='unset'
    export BATCH_SS_VARIANT
    _add_shadowsocks_menu >/dev/null 2>&1 || fail "Shadowsocks choice ${choice} failed"
    assert_eq "${expected_ss_methods[$choice]}" "$CAPTURED_SS_METHOD" "Shadowsocks choice ${choice} mapping"
    if [ "$choice" -eq 11 ]; then
        assert_eq '' "$CAPTURED_SS_PASSWORD" 'none method password'
    else
        [ -n "$CAPTURED_SS_PASSWORD" ] || fail "Shadowsocks choice ${choice} generated an empty password"
    fi
done

printf 'credential helper tests: OK\n'
