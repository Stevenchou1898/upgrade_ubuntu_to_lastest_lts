#!/bin/bash

# 日志文件路径
LOG_FILE="/var/log/ubuntu_ultimate_upgrade_$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
export LOG_FILE

LOG_OUTPUT=0

safe_exit() {
    local msg=$1
    if [[ $LOG_OUTPUT -eq 0 ]]; then
        echo -e "${RED}[中止] ${msg}${NC}" | tee -a "$LOG_FILE" > /dev/null
        echo -e "${YELLOW}► 查看完整日志: tail -n 50 ${LOG_FILE}${NC}"
        echo -e "${YELLOW}► 此SSH连接保持活动状态${NC}"
        LOG_OUTPUT=1
    fi
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}[提示] 需要root权限，请输入密码 (仅需一次):${NC}"
        exec sudo -E env "SSH_CLIENT=$SSH_CLIENT" "SSH_TTY=$SSH_TTY" "$0" "$@"
    fi
}

check_network() {
    echo -e "${BLUE}[预检] 检查网络连通性...${NC}" | tee -a "$LOG_FILE" > /dev/null
    if ! ping -c 2 archive.ubuntu.com >/dev/null 2>&1; then
        safe_exit "无法连接 archive.ubuntu.com，请检查网络"
    fi
}

check_upgrade() {
    echo -e "${BLUE}[预检] 正在检查LTS升级可用性...${NC}" | tee -a "$LOG_FILE" > /dev/null

    local current_version latest_info latest_version network_status

    current_version=$(lsb_release -ds)
    latest_info=$(do-release-upgrade -c 2>&1 | tee -a "$LOG_FILE")
    echo -e "${BLUE}[调试] do-release-upgrade 输出:${NC}" >> "$LOG_FILE"
    echo "$latest_info" >> "$LOG_FILE"

    latest_version=$(echo "$latest_info" | grep -oP "New release '\K[0-9\.]+")
    ping -c 2 archive.ubuntu.com >/dev/null 2>&1 && network_status="✅ 正常" || network_status="❌ 无法连接"

    if echo "$latest_info" | grep -q "New release"; then
        echo -e "${GREEN}[预检] 找到新的LTS版本：${latest_version}${NC}" | tee -a "$LOG_FILE" > /dev/null
    else
        safe_exit "$(cat <<EOF
当前没有可用的LTS升级，详细情况如下：

1. 当前系统版本     ➤ ${current_version}
2. 最新可用LTS版本 ➤ ${latest_version:-未知}（可能尚未发布或未识别）
3. 网络连通性       ➤ ${network_status}

EOF
)"
    fi
}

run_upgrade() {
    (
        set -euo pipefail
        trap 'echo -e "${RED}[子进程错误] 命令失败: $BASH_COMMAND${NC}" | tee -a "$LOG_FILE"' ERR

        echo -e "${GREEN}[阶段1] 更新软件列表...${NC}" | tee -a "$LOG_FILE" > /dev/null
        apt-get -qq update \
            -o Acquire::http::No-Cache=True \
            -o Acquire::http::Pipeline-Depth=0 \
            2>&1 | tee -a "$LOG_FILE"

        echo -e "${GREEN}[阶段2] 升级当前软件（仅显示警告及以上）...${NC}" | tee -a "$LOG_FILE" > /dev/null
        DEBIAN_FRONTEND=noninteractive apt-get -qq upgrade -y \
            -o DPkg::options::="--force-confdef" \
            -o DPkg::options::="--force-confold" \
            -o APT::Get::Show-User-Simulation-Note=false \
            2>&1 | tee -a "$LOG_FILE"

        echo -e "${GREEN}[阶段3] 开始LTS升级...${NC}" | tee -a "$LOG_FILE" > /dev/null
        DEBIAN_FRONTEND=noninteractive do-release-upgrade \
            -f DistUpgradeViewNonInteractive \
            -q \
            2>&1 | tee -a "$LOG_FILE"

        echo -e "${GREEN}[阶段4] 清理系统（仅显示警告及以上）...${NC}" | tee -a "$LOG_FILE" > /dev/null
        apt-get -qq autoremove -y \
            2>&1 | tee -a "$LOG_FILE"
    ) || safe_exit "升级过程中出现错误"
}

reboot_prompt() {
    if [[ -f /var/run/reboot-required ]]; then
        echo -e "${YELLOW}[注意] 需要手动重启以完成升级${NC}" | tee -a "$LOG_FILE" > /dev/null
        echo -e "可选择在Ctrl+C后直接本ssh窗口执行: ${GREEN}sudo reboot${NC}" | tee -a "$LOG_FILE" > /dev/null
    fi
}

main() {
    # 颜色定义
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    check_root "$@"
    check_network
    check_upgrade
    run_upgrade
    reboot_prompt

    echo -e "${GREEN}[完成] 所有操作已安全完成${NC}" | tee -a "$LOG_FILE" > /dev/null
    echo -e "日志文件: ${BLUE}${LOG_FILE}${NC}"
}

export -f main check_root check_network check_upgrade run_upgrade reboot_prompt safe_exit

# 启动升级任务并保持实时日志显示
main "$@" >> "$LOG_FILE" 2>&1 &
UPGRADE_PID=$!

# 显示实时日志并保持连接
{
    tail -f "$LOG_FILE"
} &

# 提示并显示升级任务后台启动信息
echo -e "${GREEN}[信息] 升级任务已在后台安全启动 (PID: $UPGRADE_PID)${NC}"
echo -e "► 正在显示实时日志，按 Ctrl+C 可退出查看，不影响升级进程"
echo -e "► 日志路径: ${BLUE}${LOG_FILE}${NC}"
