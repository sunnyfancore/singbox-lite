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

generated_uuid=''
_resolve_credential generated_uuid UUID uuid uuid
assert_eq '123e4567-e89b-12d3-a456-426614174000' "$generated_uuid" 'UUID generation'

custom_uuid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
resolved_uuid=''
_resolve_credential resolved_uuid UUID uuid uuid "$custom_uuid"
assert_eq "$custom_uuid" "$resolved_uuid" 'custom UUID preservation'

if _resolve_credential resolved_uuid UUID uuid uuid invalid >/dev/null 2>&1; then
    fail 'invalid UUID was accepted'
fi

credential_function=$(declare -f _resolve_credential)
[[ "$credential_function" != *'read -r -s'* ]] || fail 'credential input is still hidden'
reality_function=$(declare -f _resolve_reality_credentials)
[[ "$reality_function" != *'read -r -s'* ]] || fail 'Reality private key input is still hidden'
[[ "$credential_function" == *'read -r -p'* ]] || fail 'credential input does not use a normal visible prompt'

update_function=$(declare -f _update_script)
[[ "$update_function" == *'paths_to_check+=("$active_script_path")'* ]] || fail 'sub-script update order does not match launch order'
[[ "$update_function" == *'for script_path in "${installed_paths[@]}"'* ]] || fail 'all installed sub-script copies are not updated'
[[ "$update_function" == *'! bash -n "$temp_sub_path"'* ]] || fail 'downloaded sub-scripts are not syntax checked'
[[ "$update_function" == *'mkdir -p "$target_parent"'* ]] || fail 'missing sub-script install locations are not created during updates'
[[ "$update_function" == *'cmp -s "$temp_sub_path" "$script_path"'* ]] || fail 'updated sub-script copies are not verified'
[[ "$update_function" == *'if [ "$component_update_failed" = true ]'* ]] || fail 'partial sub-script update failures are still reported as full success'
assert_eq '26' "$SCRIPT_VERSION" 'main script version after menu input buffer repair'

normalized_menu_choice=''
_normalize_numeric_menu_choice normalized_menu_choice $' \t15\r '
assert_eq '15' "$normalized_menu_choice" 'menu choice CR and whitespace normalization'
_normalize_numeric_menu_choice normalized_menu_choice $'\e[200~15\e[201~'
assert_eq '15' "$normalized_menu_choice" 'menu choice bracketed-paste normalization'
_normalize_numeric_menu_choice normalized_menu_choice $'\e[?2004h0\r\177\e[?2004l'
assert_eq '0' "$normalized_menu_choice" 'menu choice generic terminal control normalization'
main_menu_function=$(declare -f _main_menu)
[[ "$main_menu_function" == *'_normalize_numeric_menu_choice choice "$choice"'* ]] || fail 'main menu does not normalize terminal input before dispatch'
[[ "$main_menu_function" == *'_wait_for_enter "按回车键返回主菜单..."'* ]] || fail 'main menu still leaves partial key sequences in the input buffer'
if grep -Eq 'read[[:space:]]+-n[[:space:]]+1|按任意键' "${REPO_ROOT}/singbox.sh"; then
    fail 'single-byte wait prompts still leave input bytes for a later menu read'
fi

update_test_root="${TEST_TMP}/script-update"
update_script_dir="${update_test_root}/bin"
update_config_dir="${update_test_root}/etc"
mkdir -p "$update_script_dir" "$update_config_dir"
cp "${REPO_ROOT}/singbox.sh" "${update_script_dir}/singbox.sh"
(
    SELF_SCRIPT_PATH="${update_script_dir}/singbox.sh"
    SCRIPT_DIR="$update_script_dir"
    SINGBOX_DIR="$update_config_dir"
    SCRIPT_UPDATE_URL="https://example.test/singbox.sh"
    GITHUB_RAW_BASE="https://example.test"

    # 模拟 wget，将更新地址映射到当前仓库中的同名文件。
    # 参数：
    #   $1 - wget 的 -qO 参数。
    #   $2 - 下载目标路径。
    #   $3 - 带可选查询参数的下载地址。
    # 输出：复制成功时返回 0，否则返回 1。
    wget() {
        local destination="$2"
        local source_url="${3%%\?*}"
        local source_name="${source_url##*/}"
        cp "${REPO_ROOT}/${source_name}" "$destination"
    }

    # 更新器测试不需要安装真实 yq。
    # 参数：无。
    # 输出：始终返回成功。
    _install_yq() {
        return 0
    }

    _update_script
) >/dev/null 2>&1
for updated_sub_script in advanced_relay.sh parser.sh xray_manager.sh; do
    cmp -s "${REPO_ROOT}/${updated_sub_script}" "${update_script_dir}/${updated_sub_script}" || fail "active sub-script copy was not updated: ${updated_sub_script}"
    cmp -s "${REPO_ROOT}/${updated_sub_script}" "${update_config_dir}/${updated_sub_script}" || fail "fallback sub-script copy was not updated: ${updated_sub_script}"
done

uninstall_function=$(declare -f _uninstall)
[[ "$uninstall_function" == *'/etc/systemd/system/sing-box.service'* ]] || fail 'uninstall misses the sing-box systemd service'
[[ "$uninstall_function" == *'/etc/systemd/system/sing-box-relay.service'* ]] || fail 'uninstall misses the relay systemd service'
[[ "$uninstall_function" == *'/etc/systemd/system/sing-box-restart.timer'* ]] || fail 'uninstall misses the restart timer'
[[ "$uninstall_function" == *'rm -rf "${SINGBOX_DIR}" /etc/cloudflared'* ]] || fail 'uninstall misses sing-box or cloudflared configuration'
[[ "$uninstall_function" == *'rm -rf /usr/local/etc/xray'* ]] || fail 'uninstall misses Xray configuration'

delete_node_function=$(declare -f _delete_node)
[[ "$delete_node_function" != *'${SINGBOX_DIR}/*.pem'* ]] || fail 'main node deletion still removes all shared certificates'
[[ "$delete_node_function" == *'for owned_tag in "${inbound_tags[@]}"'* ]] || fail 'main node deletion does not scope certificates by tag'

if grep -Fq '${password}@' "${REPO_ROOT}/singbox.sh" || grep -Fq '${pw}@' "${REPO_ROOT}/singbox.sh"; then
    fail 'a main-script share link still embeds an unencoded password'
fi

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

INIT_SYSTEM=direct
# shellcheck source=../advanced_relay.sh
source "${REPO_ROOT}/advanced_relay.sh"
SINGBOX_BIN="${TEST_TMP}/sing-box"

relay_generated_uuid=''
_relay_generate_credential relay_generated_uuid uuid
assert_eq '123e4567-e89b-12d3-a456-426614174000' "$relay_generated_uuid" 'relay UUID generation'

relay_custom_password=''
_relay_resolve_credential relay_custom_password '中转密码' 'rand-hex:16' nonempty 'custom-relay-password'
assert_eq 'custom-relay-password' "$relay_custom_password" 'custom relay password preservation'

if _relay_resolve_credential relay_generated_uuid '中转 UUID' uuid uuid invalid >/dev/null 2>&1; then
    fail 'invalid relay UUID was accepted'
fi

relay_private_key=''
relay_public_key=''
relay_short_id=''
_relay_resolve_reality_credentials relay_private_key relay_public_key relay_short_id <<< $'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\nDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD\n0123456789abcdef'
assert_eq 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC' "$relay_private_key" 'custom relay Reality private key'
assert_eq 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD' "$relay_public_key" 'custom relay Reality public key'
assert_eq '0123456789abcdef' "$relay_short_id" 'custom relay Reality short ID'

_relay_resolve_reality_credentials relay_private_key relay_public_key relay_short_id <<< $'\n\n\n'
assert_eq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$relay_private_key" 'generated relay Reality private key'
assert_eq 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' "$relay_public_key" 'generated relay Reality public key'
assert_eq 'aaaaaaaaaaaaaaaa' "$relay_short_id" 'generated relay Reality short ID'

if _relay_resolve_reality_credentials relay_private_key relay_public_key relay_short_id <<< $'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\n\n0123456789abcdef' >/dev/null 2>&1; then
    fail 'incomplete relay Reality key pair was accepted'
fi

relay_setup_function=$(declare -f _finalize_relay_setup)
[[ "$relay_setup_function" == *'_relay_resolve_credential uuid "  请输入 VLESS UUID"'* ]] || fail 'VLESS relay credentials are not configurable'
[[ "$relay_setup_function" == *'_relay_resolve_credential password "  请输入 Hysteria2 密码"'* ]] || fail 'Hysteria2 relay credentials are not configurable'
[[ "$relay_setup_function" == *'_relay_resolve_credential password "  请输入 TUIC 密码"'* ]] || fail 'TUIC relay credentials are not configurable'
[[ "$relay_setup_function" == *'_relay_resolve_credential password "  请输入 AnyTLS 密码/UUID"'* ]] || fail 'AnyTLS relay credentials are not configurable'
[[ "$relay_setup_function" == *'hysteria2://${encoded_password}@'* ]] || fail 'Hysteria2 relay password is not URL encoded'
[[ "$relay_setup_function" == *'tuic://${uuid}:${encoded_password}@'* ]] || fail 'TUIC relay password is not URL encoded'
[[ "$relay_setup_function" == *'anytls://${encoded_password}@'* ]] || fail 'AnyTLS relay password is not URL encoded'
[[ "$relay_setup_function" == *'"$SINGBOX_BIN" check -c "$MAIN_CONFIG_FILE" -c "$CONFIG_FILE"'* ]] || fail 'relay setup does not validate the combined sing-box configuration'
[[ "$relay_setup_function" == *'if ! _manage_service restart'* ]] || fail 'relay setup does not check service restart failures'
[[ "$relay_setup_function" == *'_relay_rollback_setup "$CONFIG_FILE"'* ]] || fail 'relay setup does not roll back a failed restart'
[[ "$relay_setup_function" == *'"name":$u,"uuid":$u'* ]] || fail 'VLESS-Reality relay name does not match UUID'
[[ "$relay_setup_function" == *'"name":$pw,"password":$pw'* ]] || fail 'AnyTLS relay name does not match its UUID credential'
[[ "$relay_setup_function" == *'_relay_resolve_anytls_padding_scheme padding_scheme_json'* ]] || fail 'AnyTLS relay padding scheme is not configurable'
[[ "$relay_setup_function" == *'.padding_scheme = $padding'* ]] || fail 'AnyTLS relay does not always write padding_scheme'
[[ "$relay_setup_function" != *'"padding_scheme":[]'* ]] || fail 'Any-Reality relay still hardcodes an empty padding scheme'
[[ "$relay_setup_function" == *'"auth_user":[$au]'* ]] || fail 'new relay routes do not match auth_user'
[[ "$relay_setup_function" == *'relay_type="any-reality"'* ]] || fail 'Any-Reality relay entrance is missing'
[[ "$relay_setup_function" == *'复用入口未完成，按回车重新选择入口协议'* ]] || fail 'failed entrance reuse still exits directly to the menu'

shared_route_function=$(declare -f _relay_add_shared_auth_route)
[[ "$shared_route_function" == *'_relay_select_shared_inbound selected_inbound'* ]] || fail 'shared auth routing does not select an existing entrance'
[[ "$shared_route_function" == *'_relay_apply_shared_route_config'* ]] || fail 'shared auth routing does not append a user route'
[[ "$shared_route_function" == *'_relay_apply_external_shared_route_config'* ]] || fail 'shared auth routing does not support entrances from the main configuration'
[[ "$shared_route_function" == *'_relay_check_combined_config'* ]] || fail 'shared auth routing does not validate the combined configuration'

rollback_config="${TEST_TMP}/relay-rollback.json"
rollback_backup="${rollback_config}.bak"
rollback_cert="${TEST_TMP}/relay-rollback.pem"
rollback_key="${TEST_TMP}/relay-rollback.key"
printf '%s\n' 'new-config' > "$rollback_config"
printf '%s\n' 'old-config' > "$rollback_backup"
printf '%s\n' 'certificate' > "$rollback_cert"
printf '%s\n' 'private-key' > "$rollback_key"
_relay_rollback_setup "$rollback_config" "$rollback_backup" "$rollback_cert" "$rollback_key" ''
assert_eq 'old-config' "$(<"$rollback_config")" 'relay configuration rollback'
[ ! -e "$rollback_backup" ] || fail 'relay rollback backup was not consumed'
[ ! -e "$rollback_cert" ] || fail 'relay rollback certificate was not removed'
[ ! -e "$rollback_key" ] || fail 'relay rollback private key was not removed'

clear_relays_function=$(declare -f _clear_all_relays)
[[ "$clear_relays_function" != *'*.pem'* ]] || fail 'relay deletion still removes all shared certificates'
[[ "$clear_relays_function" != *'.proxies = []'* ]] || fail 'relay deletion still clears all shared YAML proxies'
[[ "$clear_relays_function" == *'_relay_remove_owned_certificates'* ]] || fail 'relay deletion does not scope certificates by tag'
[[ "$clear_relays_function" == *'_relay_remove_external_auth_user'* ]] || fail 'relay deletion leaves shared UUID users in the main configuration'

main_reality_function=$(declare -f _add_vless_reality)
[[ "$main_reality_function" == *'"name":$u,"uuid":$u'* ]] || fail 'main VLESS-Reality name does not match UUID'
main_anytls_function=$(declare -f _create_anytls_tls_node)
[[ "$main_anytls_function" == *'"name": $pw, "password": $pw'* ]] || fail 'main AnyTLS name does not match its UUID credential'
[[ "$main_anytls_function" == *'_resolve_anytls_padding_scheme padding_scheme_json'* ]] || fail 'main AnyTLS padding scheme is not configurable'
[[ "$main_anytls_function" == *'.padding_scheme = $padding'* ]] || fail 'main AnyTLS does not always write padding_scheme'
main_anyreality_function=$(declare -f _create_anyreality_node)
[[ "$main_anyreality_function" == *'"name": $pw, "password": $pw'* ]] || fail 'main Any-Reality name does not match its UUID credential'
[[ "$main_anyreality_function" == *'_resolve_anytls_padding_scheme padding_scheme_json'* ]] || fail 'main Any-Reality padding scheme is not configurable'
[[ "$main_anyreality_function" == *'"padding_scheme": $padding'* ]] || fail 'main Any-Reality does not write padding_scheme'
main_anytls_menu_function=$(declare -f _add_anytls)
[[ "$main_anytls_menu_function" == *'tls_padding_scheme_json'* && "$main_anytls_menu_function" == *'reality_padding_scheme_json'* ]] || fail 'combined AnyTLS creation does not keep independent padding schemes'
[[ "$main_anytls_menu_function" == *'请设置 Any-Reality 入站的 padding_scheme'* ]] || fail 'combined AnyTLS creation does not identify the Any-Reality padding prompt'

unset -f jq
command -v jq >/dev/null 2>&1 || fail 'jq is required for auth routing configuration tests'

custom_padding='["stop=2","0=10-20","1=30-40"]'
resolved_padding=''
_resolve_anytls_padding_scheme resolved_padding "$custom_padding"
assert_eq "$custom_padding" "$resolved_padding" 'main AnyTLS padding JSON preset'
unset BATCH_ANYTLS_PADDING_SCHEME
random_main_padding=''
_resolve_anytls_padding_scheme random_main_padding
printf '%s' "$random_main_padding" | jq -e '
    type == "array" and length >= 6 and length <= 9 and
    (.[0] | test("^stop=[5-8]$")) and
    (.[1:] | all(.[]; test("^[0-9]+=[0-9]+-[0-9]+$")))
' >/dev/null || fail 'main AnyTLS blank input does not generate a runtime padding scheme'
relay_padding=''
_relay_resolve_anytls_padding_scheme relay_padding "$custom_padding"
assert_eq "$custom_padding" "$relay_padding" 'relay AnyTLS padding JSON preset'
random_relay_padding=''
_relay_resolve_anytls_padding_scheme random_relay_padding <<< $'\n'
printf '%s' "$random_relay_padding" | jq -e '
    type == "array" and length >= 6 and length <= 9 and
    (.[0] | test("^stop=[5-8]$")) and
    (.[1:] | all(.[]; test("^[0-9]+=[0-9]+-[0-9]+$")))
' >/dev/null || fail 'relay AnyTLS blank input does not generate a runtime padding scheme'
interactive_padding=''
_relay_resolve_anytls_padding_scheme interactive_padding <<< $'stop=2\n0=10-20\n1=30-40\n\n'
assert_eq "$custom_padding" "$interactive_padding" 'relay AnyTLS interactive padding input'
if _resolve_anytls_padding_scheme resolved_padding '["",1]' >/dev/null 2>&1; then
    fail 'invalid AnyTLS padding JSON was accepted'
fi

old_uuid='11111111-1111-4111-8111-111111111111'
new_uuid='22222222-2222-4222-8222-222222222222'
third_uuid='55555555-5555-4555-8555-555555555555'
fourth_uuid='66666666-6666-4666-8666-666666666666'
auth_config="${TEST_TMP}/relay-auth.json"
cat > "$auth_config" <<EOF
{
  "inbounds": [{
    "type": "vless",
    "tag": "vless-reality-in-20001",
    "users": [{"uuid": "$old_uuid", "flow": "xtls-rprx-vision"}],
    "tls": {"enabled": true, "reality": {"enabled": true}}
  }],
  "outbounds": [{"type": "direct", "tag": "relay-out-20001"}],
  "route": {"rules": [{"inbound": "vless-reality-in-20001", "outbound": "relay-out-20001"}]}
}
EOF

new_user=$(jq -n --arg u "$new_uuid" '{name:$u,uuid:$u,flow:"xtls-rprx-vision"}')
new_outbound=$(jq -n '{type:"direct",tag:"relay-out-20001-u2"}')
new_rule=$(jq -n --arg u "$new_uuid" '{inbound:"vless-reality-in-20001",auth_user:[$u],action:"route",outbound:"relay-out-20001-u2"}')
_relay_apply_shared_route_config "$auth_config" 'vless-reality-in-20001' "$new_user" "$new_outbound" "$new_rule"
jq -e --arg u "$old_uuid" '.inbounds[0].users[0] | .name == $u and .uuid == $u' "$auth_config" >/dev/null || fail 'legacy VLESS user was not normalized to name=UUID'
jq -e --arg u "$old_uuid" '.route.rules[] | select(.outbound == "relay-out-20001") | .auth_user == [$u] and .action == "route"' "$auth_config" >/dev/null || fail 'legacy broad route was not converted to auth_user routing'
jq -e --arg u "$new_uuid" '.route.rules[] | select(.outbound == "relay-out-20001-u2") | .auth_user == [$u]' "$auth_config" >/dev/null || fail 'new UUID route was not appended'

for route_spec in "$third_uuid:relay-out-20001-u3" "$fourth_uuid:relay-out-20001-u4"; do
    route_uuid="${route_spec%%:*}"
    route_outbound="${route_spec#*:}"
    new_user=$(jq -n --arg u "$route_uuid" '{name:$u,uuid:$u,flow:"xtls-rprx-vision"}')
    new_outbound=$(jq -n --arg tag "$route_outbound" '{type:"direct",tag:$tag}')
    new_rule=$(jq -n --arg u "$route_uuid" --arg tag "$route_outbound" '{inbound:"vless-reality-in-20001",auth_user:[$u],action:"route",outbound:$tag}')
    _relay_apply_shared_route_config "$auth_config" 'vless-reality-in-20001' "$new_user" "$new_outbound" "$new_rule"
done
jq -e '.inbounds[0].users | length == 4' "$auth_config" >/dev/null || fail 'one entrance does not support four UUID users'
jq -e '.route.rules | length == 4' "$auth_config" >/dev/null || fail 'four UUID users do not have four explicit routes'

_relay_remove_route_config "$auth_config" 'vless-reality-in-20001' 'relay-out-20001-u2' "$new_uuid"
jq -e --arg old "$old_uuid" --arg third "$third_uuid" --arg fourth "$fourth_uuid" '
    [.inbounds[0].users[].uuid] | sort == ([$old,$third,$fourth] | sort)
' "$auth_config" >/dev/null || fail 'deleting one UUID removed or changed another VLESS user'
jq -e '.route.rules | length == 3' "$auth_config" >/dev/null || fail 'deleting one UUID removed another route'

_relay_remove_route_config "$auth_config" 'vless-reality-in-20001' 'relay-out-20001-u3' "$third_uuid"
_relay_remove_route_config "$auth_config" 'vless-reality-in-20001' 'relay-out-20001-u4' "$fourth_uuid"
_relay_remove_route_config "$auth_config" 'vless-reality-in-20001' 'relay-out-20001' "$old_uuid"
jq -e '.inbounds == [] and .outbounds == [] and .route.rules == []' "$auth_config" >/dev/null || fail 'deleting the final UUID did not remove the empty entrance'

old_anytls_uuid='33333333-3333-4333-8333-333333333333'
new_anytls_uuid='44444444-4444-4444-8444-444444444444'
anytls_config="${TEST_TMP}/relay-anytls-auth.json"
cat > "$anytls_config" <<EOF
{
  "inbounds": [{
    "type": "anytls",
    "tag": "anytls-in-20002",
    "users": [{"name": "default", "password": "$old_anytls_uuid"}],
    "tls": {"enabled": true}
  }],
  "outbounds": [{"type": "direct", "tag": "relay-out-20002"}],
  "route": {"rules": [{"inbound": "anytls-in-20002", "outbound": "relay-out-20002"}]}
}
EOF

new_user=$(jq -n --arg u "$new_anytls_uuid" '{name:$u,password:$u}')
new_outbound=$(jq -n '{type:"direct",tag:"relay-out-20002-u2"}')
new_rule=$(jq -n --arg u "$new_anytls_uuid" '{inbound:"anytls-in-20002",auth_user:[$u],action:"route",outbound:"relay-out-20002-u2"}')
_relay_apply_shared_route_config "$anytls_config" 'anytls-in-20002' "$new_user" "$new_outbound" "$new_rule"
jq -e --arg u "$old_anytls_uuid" '.inbounds[0].users[0] == {name:$u,password:$u}' "$anytls_config" >/dev/null || fail 'legacy AnyTLS user was not normalized to name=UUID'
jq -e --arg u "$new_anytls_uuid" '.route.rules[] | select(.outbound == "relay-out-20002-u2") | .auth_user == [$u]' "$anytls_config" >/dev/null || fail 'AnyTLS UUID route was not appended'

RELAY_AUX_DIR="$TEST_TMP"
relay_links_file="${RELAY_AUX_DIR}/relay_links.json"
cat > "$relay_links_file" <<'EOF'
{
  "vless-reality-in-20001": {
    "link": "vless://old-user@example.test:20001?security=reality&pbk=public-key",
    "node_name": "legacy-route"
  }
}
EOF
_relay_migrate_legacy_metadata 'vless-reality-in-20001' 'relay-out-20001'
jq -e '.["relay-out-20001"].inbound_tag == "vless-reality-in-20001" and .["vless-reality-in-20001"] == null' "$relay_links_file" >/dev/null || fail 'legacy relay metadata was not migrated to the outbound index'
route_metadata=$(jq -n '{link:"vless://new-user@example.test:20001",node_name:"new-route",auth_user:"new-user"}')
_relay_store_route_metadata 'vless-reality-in-20001' 'relay-out-20001-u2' "$route_metadata"
resolved_metadata=$(_relay_get_route_metadata 'vless-reality-in-20001' 'relay-out-20001-u2')
assert_eq 'new-user' "$(echo "$resolved_metadata" | jq -r '.auth_user')" 'route metadata lookup by outbound'
_relay_delete_route_metadata 'vless-reality-in-20001' 'relay-out-20001-u2'
jq -e '.["relay-out-20001"] != null and .["relay-out-20001-u2"] == null' "$relay_links_file" >/dev/null || fail 'deleting one route metadata entry removed another route'

external_main_config="${TEST_TMP}/main-vless-reality.json"
external_relay_config="${TEST_TMP}/relay-for-main-vless.json"
external_old_uuid='99999999-9999-4999-8999-999999999999'
external_new_uuid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
cat > "$external_main_config" <<EOF
{
  "inbounds": [{
    "type": "vless",
    "tag": "vless-reality-in-22001",
    "listen_port": 22001,
    "users": [{"uuid": "$external_old_uuid", "flow": "xtls-rprx-vision"}],
    "tls": {"enabled": true, "reality": {"enabled": true, "short_id": ["0123456789abcdef"]}}
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"rules": []}
}
EOF
cat > "$external_relay_config" <<'EOF'
{"inbounds":[],"outbounds":[],"route":{"rules":[]}}
EOF
external_existing_users=$(_relay_get_normalized_auth_users "$external_main_config" 'vless-reality-in-22001')
assert_eq "[\"$external_old_uuid\"]" "$external_existing_users" 'main VLESS normalized auth users'
external_user=$(jq -n --arg u "$external_new_uuid" '{name:$u,uuid:$u,flow:"xtls-rprx-vision"}')
external_outbound=$(jq -n '{type:"direct",tag:"relay-out-22001"}')
external_rule=$(jq -n --arg u "$external_new_uuid" '{inbound:"vless-reality-in-22001",auth_user:[$u],action:"route",outbound:"relay-out-22001"}')
external_base_rule=$(jq -n --arg u "$external_old_uuid" '{inbound:"vless-reality-in-22001",auth_user:[$u],action:"route",outbound:"direct"}')
_relay_apply_external_shared_route_config "$external_main_config" "$external_relay_config" 'vless-reality-in-22001' \
    "$external_existing_users" "$external_user" "$external_outbound" "$external_rule" "$external_base_rule"
jq -e --arg old "$external_old_uuid" --arg new "$external_new_uuid" '
    [.inbounds[0].users[].name] | sort == ([$old,$new] | sort)
' "$external_main_config" >/dev/null || fail 'main VLESS entrance did not retain the original UUID and append the shared UUID'
jq -e --arg old "$external_old_uuid" --arg new "$external_new_uuid" '
    (.route.rules[] | select(.outbound == "direct") | .auth_user == [$old]) and
    (.route.rules[] | select(.outbound == "relay-out-22001") | .auth_user == [$new])
' "$external_relay_config" >/dev/null || fail 'main VLESS auth users were not split between direct and relay routes'

_relay_remove_route_config "$external_relay_config" 'vless-reality-in-22001' 'relay-out-22001' "$external_new_uuid"
_relay_remove_external_auth_user "$external_main_config" 'vless-reality-in-22001' "$external_new_uuid"
_relay_remove_external_base_route "$external_relay_config" 'vless-reality-in-22001'
jq -e --arg old "$external_old_uuid" '
    .inbounds[0].users == [{name:$old,uuid:$old,flow:"xtls-rprx-vision"}]
' "$external_main_config" >/dev/null || fail 'deleting a shared UUID changed the original main VLESS user'
jq -e '.outbounds == [] and .route.rules == []' "$external_relay_config" >/dev/null || fail 'deleting the final shared UUID left relay routing configuration behind'

MAIN_CONFIG_FILE="$external_main_config"
RELAY_CONFIG_FILE="$external_relay_config"
selected_shared_inbound=''
_relay_select_shared_inbound selected_shared_inbound <<< $'1\n' >/dev/null
assert_eq 'vless-reality-in-22001' "$(echo "$selected_shared_inbound" | jq -r '.tag')" 'main VLESS-Reality entrance selection'
assert_eq 'main' "$(echo "$selected_shared_inbound" | jq -r '._source_config')" 'main VLESS-Reality entrance source marker'

shared_select_config="${TEST_TMP}/relay-shared-select.json"
cat > "$shared_select_config" <<'EOF'
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "legacy-reality-in-21001",
      "listen_port": 21001,
      "users": [{"uuid": "77777777-7777-4777-8777-777777777777"}],
      "tls": {"reality": {"enabled": "true"}}
    },
    {
      "type": "anytls",
      "tag": "legacy-anytls-in-21002",
      "listen_port": 21002,
      "users": [{"name": "default", "password": "88888888-8888-4888-8888-888888888888"}]
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in-21003",
      "listen_port": 21003,
      "users": [{"password": "not-reusable"}]
    }
  ]
}
EOF
MAIN_CONFIG_FILE="${TEST_TMP}/missing-main-config.json"
RELAY_CONFIG_FILE="$shared_select_config"
selected_shared_inbound=''
_relay_select_shared_inbound selected_shared_inbound <<< $'1\n' >/dev/null
assert_eq 'legacy-reality-in-21001' "$(echo "$selected_shared_inbound" | jq -r '.tag')" 'legacy Reality entrance selection'
selected_shared_inbound=''
_relay_select_shared_inbound selected_shared_inbound <<< $'2\n' >/dev/null
assert_eq 'legacy-anytls-in-21002' "$(echo "$selected_shared_inbound" | jq -r '.tag')" 'legacy AnyTLS entrance selection'

# 完整复用流程使用固定公网 IP，避免测试访问网络。
# 参数：无。
# 输出：输出文档保留地址作为分享链接主机。
_get_public_ip() {
    printf '%s\n' '192.0.2.10'
}

# 完整复用流程跳过真实 sing-box 配置检查。
# 参数：
#   $1 - 待检查的中转配置路径，本测试不使用。
# 输出：始终返回成功。
_relay_check_combined_config() {
    return 0
}

# 完整复用流程跳过真实服务管理。
# 参数：
#   $1 - 服务动作，本测试不使用。
# 输出：始终返回成功。
_manage_service() {
    return 0
}

# 完整复用流程跳过测试环境中的 YAML 写入。
# 参数：
#   $1 - Clash 节点 JSON，本测试不使用。
# 输出：始终返回成功。
_add_node_to_relay_yaml() {
    return 0
}

# 完整复用流程跳过操作日志写入。
# 参数：
#   $1 - 操作类型，本测试不使用。
#   $2 - 操作详情，本测试不使用。
# 输出：始终返回成功。
_log_operation() {
    return 0
}

MAIN_CONFIG_FILE="$external_main_config"
RELAY_CONFIG_FILE="$external_relay_config"
MAIN_METADATA_FILE="${TEST_TMP}/main-vless-metadata.json"
RELAY_AUX_DIR="$TEST_TMP"
printf '%s\n' '{"vless-reality-in-22001":{"publicKey":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","shortId":"0123456789abcdef"}}' > "$MAIN_METADATA_FILE"
printf '%s\n' '{}' > "${RELAY_AUX_DIR}/relay_links.json"
for shared_uuid in \
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' \
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc' \
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; do
    shared_outbound=$(jq -n '{type:"shadowsocks",tag:"TEMP_TAG",server:"198.51.100.20",server_port:8388,method:"2022-blake3-aes-128-gcm",password:"test-key"}')
    _relay_add_shared_auth_route 'shadowsocks' '198.51.100.20' '8388' "$shared_outbound" \
        <<< $'1\n'"${shared_uuid}"$'\n\n\n' >/dev/null
done
jq -e '.inbounds[0].users | length == 4' "$MAIN_CONFIG_FILE" >/dev/null || fail 'main VLESS entrance does not support one direct UUID and three shared UUIDs'
jq -e '
    ([.route.rules[] | select(.outbound == "direct")] | length) == 1 and
    ([.route.rules[] | select((.outbound // "") | startswith("relay-out-22001"))] | length) == 3 and
    (.outbounds | length) == 3
' "$RELAY_CONFIG_FILE" >/dev/null || fail 'three main VLESS UUIDs did not receive three independent relay routes'
jq -e '
    [to_entries[] | select(.value.source_config == "main" and .value.base_route_owned == true)] | length == 3
' "${RELAY_AUX_DIR}/relay_links.json" >/dev/null || fail 'main VLESS route metadata does not preserve its source and cleanup ownership'

printf 'credential helper tests: OK\n'
