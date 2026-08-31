#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${TEST_DIR}/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

# 报告测试失败并终止测试进程。
# 参数：
#   $1 - 失败原因。
# 输出：将失败原因写入标准错误并以状态码 1 退出。
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# 断言 JSON 文件满足 jq 表达式。
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
    printf '%s\n' '#!/usr/bin/env bash' 'case "${1:-}" in check) exit 0 ;; *) exit 0 ;; esac' > "${TEST_TMP}/sing-box"
    chmod +x "${TEST_TMP}/sing-box"
}

# 写入包含 sing-box 旧 DNS server 格式的配置。
# 参数：无。
# 输出：更新 CONFIG_FILE 测试文件。
write_legacy_config() {
    jq -n '{
        dns: {
            servers: [
                {tag:"dns-local", address:"local", detour:"direct"},
                {tag:"dns-https", address:"https://dns.google/dns-query"},
                {tag:"dns-plain", address:"1.1.1.1", strategy:"ipv4_only"},
                {tag:"dns-dhcp", address:"dhcp://en0"},
                {tag:"dns-resolved", address:"tcp://resolver.example", address_resolver:"dns-local"}
            ],
            rules: [{outbound:"any", server:"dns-local"}],
            strategy:"prefer_ipv4"
        },
        route: {rules: []}
    }' > "$CONFIG_FILE"
}

# 验证旧 DNS server 已转换为 1.14.0 新格式且保留必要字段。
# 参数：无。
# 输出：断言失败时终止测试。
assert_migrated_config() {
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-local" and .type == "local" and (.address == null))' 'local DNS server was not migrated'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-https" and .type == "https" and .server == "dns.google" and .path == "/dns-query" and .domain_resolver == "dns-bootstrap")' 'HTTPS DNS server was not migrated'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-plain" and .type == "udp" and .server == "1.1.1.1" and (.strategy == null))' 'plain DNS server was not migrated'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-dhcp" and .type == "dhcp" and .interface == "en0")' 'DHCP DNS server was not migrated'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-resolved" and .type == "tcp" and .server == "resolver.example" and .domain_resolver == "dns-local")' 'DNS resolver fields were not migrated'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-bootstrap" and .type == "local")' 'bootstrap DNS server was not added'
}

# 验证 DNS 菜单写入的新格式可被保存和校验。
# 参数：无。
# 输出：断言失败时终止测试。
assert_dns_menu_output() {
    _apply_dns_config 'https://dns.alidns.com/dns-query' 'prefer_ipv6'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-local" and .type == "https" and .server == "dns.alidns.com" and .path == "/dns-query" and .domain_resolver == "dns-bootstrap")' 'DNS menu did not write new HTTPS format'
    assert_json "$CONFIG_FILE" 'any(.dns.servers[]?; .tag == "dns-bootstrap" and .type == "local")' 'DNS menu did not add bootstrap DNS server'
    assert_json "$CONFIG_FILE" '.dns.strategy == "prefer_ipv6"' 'DNS menu did not preserve strategy'
}

# 运行 DNS 迁移与菜单写入测试。
# 参数：无。
# 输出：所有断言通过时打印成功信息。
main() {
    # shellcheck source=../singbox.sh
    source "${REPO_ROOT}/singbox.sh"
    CONFIG_FILE="${TEST_TMP}/config.json"
    CLASH_YAML_FILE="${TEST_TMP}/clash.yaml"
    SINGBOX_BIN="${TEST_TMP}/sing-box"
    INIT_SYSTEM="direct"
    export CONFIG_FILE CLASH_YAML_FILE SINGBOX_BIN INIT_SYSTEM
    # 覆盖服务管理函数，避免测试触碰宿主机服务。
    _manage_service() { :; }
    create_singbox_mock
    write_legacy_config

    _check_and_fix_dns
    assert_migrated_config
    assert_dns_menu_output
    printf 'sing-box DNS migration tests passed.\n'
}

main "$@"
