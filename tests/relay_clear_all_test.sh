#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${TEST_DIR}/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

# 报告测试失败并终止当前测试进程。
# 参数：
#   $1 - 失败原因。
# 输出：将失败原因写入标准错误并以状态码 1 退出。
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# 断言 JSON 文件满足指定 jq 表达式。
# 参数：
#   $1 - JSON 文件路径。
#   $2 - jq 布尔表达式。
#   $3 - 断言失败时的说明。
# 输出：表达式不满足时终止测试。
assert_json() {
    local file="$1"
    local filter="$2"
    local message="$3"
    jq -e "$filter" "$file" >/dev/null || fail "$message"
}

# 创建仅支持配置检查的 sing-box mock，避免测试依赖系统服务。
# 参数：无。
# 输出：在测试临时目录生成 mock 可执行文件。
create_singbox_mock() {
    cat > "${TEST_TMP}/sing-box" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    check) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${TEST_TMP}/sing-box"
}

# 写入包含中转路由和端口转发路由的测试配置。
# 参数：无。
# 输出：更新测试用 relay.json 和 relay_links.json。
write_mixed_config() {
    jq -n '{
        inbounds: [
            {tag:"relay-in-1", type:"vless", users:[{uuid:"u1",name:"u1"}]},
            {tag:"pf-in-1000", type:"direct", listen_port:1000}
        ],
        outbounds: [
            {tag:"relay-out-1", type:"direct", server:"198.51.100.10"},
            {tag:"pf-out-1000", type:"direct", server:"198.51.100.20"}
        ],
        route: {rules: [
            {inbound:"relay-in-1", auth_user:["u1"], outbound:"relay-out-1"},
            {inbound:"pf-in-1000", outbound:"pf-out-1000"}
        ]}
    }' > "$RELAY_CONFIG_FILE"
    jq -n '{"relay-out-1": {inbound_tag:"relay-in-1", outbound_tag:"relay-out-1", auth_user:"u1", source_config:"relay"}}' > "$RELAY_AUX_DIR/relay_links.json"
}

# 写入复用主节点入口的中转测试配置。
# 参数：无。
# 输出：更新主配置、relay.json 和 relay_links.json。
write_main_shared_config() {
    jq -n '{inbounds:[{tag:"main-in-1",type:"vless",users:[{uuid:"original",name:"original"},{uuid:"added",name:"added"}]}]}' > "$MAIN_CONFIG_FILE"
    jq -n '{
        inbounds: [],
        outbounds: [{tag:"relay-out-main",type:"direct",server:"198.51.100.30"}],
        route: {rules: [
            {inbound:"main-in-1",outbound:"direct"},
            {inbound:"main-in-1",auth_user:["added"],outbound:"relay-out-main"}
        ]}
    }' > "$RELAY_CONFIG_FILE"
    jq -n '{"relay-out-main": {inbound_tag:"main-in-1", outbound_tag:"relay-out-main", auth_user:"added", source_config:"main", base_route_owned:true}}' > "$RELAY_AUX_DIR/relay_links.json"
}

# 验证批量清理只移除中转内容并保留端口转发内容。
# 参数：无。
# 输出：断言失败时终止测试。
test_clear_preserves_port_forwarding() {
    write_mixed_config
    _clear_all_relays
    assert_json "$RELAY_CONFIG_FILE" '
        ([.inbounds[] | select(.tag == "pf-in-1000")] | length) == 1 and
        ([.outbounds[] | select(.tag == "pf-out-1000")] | length) == 1 and
        ([.route.rules[] | select(.outbound == "pf-out-1000")] | length) == 1 and
        ([.inbounds[] | select(.tag == "relay-in-1")] | length) == 0 and
        ([.outbounds[] | select(.tag == "relay-out-1")] | length) == 0 and
        ([.route.rules[] | select(.outbound == "relay-out-1")] | length) == 0
    ' '批量清理错误地删除或保留了转发配置'
    assert_json "$RELAY_AUX_DIR/relay_links.json" '. == {}' '批量清理未清空中转元数据'
}

# 验证删除菜单接受 A 后输入 y，并执行批量清理。
# 参数：无。
# 输出：断言批量清理完成，否则终止测试。
test_delete_menu_accepts_short_confirmation() {
    write_mixed_config
    _delete_relay <<< $'A\ny\n' >/dev/null 2>&1
    assert_json "$RELAY_CONFIG_FILE" '([.route.rules[] | select(.outbound == "relay-out-1")] | length) == 0' 'A/y 批量删除未移除中转路由'
}

# 验证复用主节点入口时同步删除附加用户和直连基线规则。
# 参数：无。
# 输出：断言失败时终止测试。
test_clear_removes_shared_main_user() {
    write_main_shared_config
    _clear_all_relays
    assert_json "$MAIN_CONFIG_FILE" '
        ([.inbounds[0].users[] | select(.name == "original")] | length) == 1 and
        ([.inbounds[0].users[] | select(.name == "added")] | length) == 0
    ' '批量清理未移除主节点附加用户'
    assert_json "$RELAY_CONFIG_FILE" '(.route.rules | length) == 0 and (.outbounds | length) == 0' '批量清理未移除主节点复用的中转规则'
}

# 覆盖服务管理和外部系统副作用，使测试只验证配置清理逻辑。
# 参数：无。
# 输出：安装测试替身函数。
install_test_stubs() {
    _manage_service() { return 0; }
    _save_nftables_rules() { return 0; }
    _nft_apply_redirect_rule() { return 0; }
    _relay_remove_owned_certificates() { return 0; }
    _remove_node_from_relay_yaml() { return 0; }
    _relay_check_combined_config() { return 0; }
}

# 初始化测试环境并运行全部批量删除回归断言。
# 参数：无。
# 输出：所有断言通过时输出测试成功标记。
main() {
    INIT_SYSTEM=direct
    source "${REPO_ROOT}/advanced_relay.sh"
    SINGBOX_BIN="${TEST_TMP}/sing-box"
    RELAY_AUX_DIR="$TEST_TMP/relay"
    RELAY_CONFIG_FILE="$RELAY_AUX_DIR/relay.json"
    MAIN_CONFIG_FILE="$TEST_TMP/config.json"
    RELAY_CLASH_YAML="$TEST_TMP/clash.yaml"
    mkdir -p "$RELAY_AUX_DIR"
    create_singbox_mock
    install_test_stubs

    test_clear_preserves_port_forwarding
    test_delete_menu_accepts_short_confirmation
    test_clear_removes_shared_main_user
    printf 'relay clear-all tests: OK\n'
}

main "$@"
