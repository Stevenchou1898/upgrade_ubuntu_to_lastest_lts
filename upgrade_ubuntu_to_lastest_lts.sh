#!/bin/bash
#
# upgrade_ubuntu_to_lastest_lts.sh —— 把 Ubuntu 升级到最新的 LTS 版本
#
# 两种运行方式：
#   监督模式（默认）：后台升级 + 前台实时日志，不自动重启，适合人盯着跑。
#       sudo ./upgrade_ubuntu_to_lastest_lts.sh
#   全自动无人值守：自动多跳升级直到最新 LTS，自动重启续跑，跑完自动清理。
#       sudo ./upgrade_ubuntu_to_lastest_lts.sh --auto
#
# ⚠️ 首次务必先预演（不真正升级/重启）：
#       sudo ./upgrade_ubuntu_to_lastest_lts.sh --auto --dry-run
#    并强烈建议先在虚拟机 / 快照上验证，再用于真实服务器。
#
set -uo pipefail

# ============================ 常量 ============================
SCRIPT_VERSION="2.0"
LOG_DIR="/var/log"
LOG_PREFIX="ubuntu_ultimate_upgrade"
LOG_FILE=""                                        # 运行时确定（带时间戳）
LOCK_FILE="/run/lock/ubuntu_ultimate_upgrade.lock"
STATE_FILE="/var/lib/ubuntu_ultimate_upgrade.state"
UNIT_NAME="ubuntu-auto-lts-upgrade.service"
SYSTEMD_UNIT="/etc/systemd/system/${UNIT_NAME}"
INSTALL_PATH="/usr/local/sbin/ubuntu-auto-lts-upgrade.sh"
DONE_MARK="/run/ubuntu-auto-lts-upgrade.done"
FINISH_MARK="__UPGRADE_FINISHED__"
CANCEL_REBOOT_FILE="/tmp/cancel-auto-reboot"
KEEP_LOGS=10                                       # 日志轮转：仅保留最近 N 个
MIN_FREE_KB=5242880                                # 根分区最少空闲（约 5GB）
MAX_HOPS=5                                         # 多跳上限，防止无限重启

# ============================ 运行参数（默认值）============================
MODE="supervised"          # supervised | auto
DRY_RUN=0
DO_REBOOT=1
REBOOT_DELAY=60
TARGET_RELEASE=""          # 例：24.04；留空表示升到“最新可用 LTS”
FROM_BOOT=0
DO_UNINSTALL=0
LOG_NOTICE_DONE=0
AVAIL_RELEASE=""
ORIG_ARGS=("$@")

# ---- 颜色（顶层定义；无终端时自动关闭）----
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ---- 强制英文环境，保证 do-release-upgrade 输出可被稳定解析 ----
export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive

# ============================ 基础工具 ============================
log_line() { echo -e "$1" | tee -a "$LOG_FILE"; }

die() {
    local msg="$1"
    if [[ $LOG_NOTICE_DONE -eq 0 ]]; then
        echo -e "${RED}[中止] ${msg}${NC}" | tee -a "$LOG_FILE"
        [[ -n "$LOG_FILE" ]] && echo -e "${YELLOW}► 查看完整日志: tail -n 80 ${LOG_FILE}${NC}"
        LOG_NOTICE_DONE=1
    fi
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  sudo ./upgrade_ubuntu_to_lastest_lts.sh          监督模式（默认）：后台升级 + 实时日志，不自动重启
  sudo ./upgrade_ubuntu_to_lastest_lts.sh --auto   全自动无人值守：多跳升级到最新 LTS，自动重启续跑，跑完自清理

参数：
  --auto              无人值守模式（自动多跳 + 自动重启 + systemd 开机续跑）
  --dry-run           预演：走完全部判断与日志，但不真正升级/重启/装单元（首次务必先跑）
  --target=XX.YY      升级到指定 LTS 为止（默认升到最新可用 LTS），如 --target=24.04
  --no-reboot         配合 --auto：升一跳后不自动重启
  --reboot-delay=N    自动重启前倒计时秒数（默认 60；期间 touch /tmp/cancel-auto-reboot 可取消）
  --uninstall         移除全自动模式的 systemd 单元与状态，停止续跑
  --from-boot         内部使用：由 systemd 在开机时调用
  -h, --help          显示本帮助

安全提示：
  * 版本升级不可逆；失败时最可靠的恢复方式是回滚到升级前的快照/备份。
  * 首次请执行：sudo ./upgrade_ubuntu_to_lastest_lts.sh --auto --dry-run
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)            MODE="auto" ;;
            --dry-run)         DRY_RUN=1 ;;
            --no-reboot)       DO_REBOOT=0 ;;
            --from-boot)       FROM_BOOT=1 ;;
            --uninstall)       DO_UNINSTALL=1 ;;
            --target=*)        TARGET_RELEASE="${1#*=}" ;;
            --target)          shift; TARGET_RELEASE="${1:-}" ;;
            --reboot-delay=*)  REBOOT_DELAY="${1#*=}" ;;
            --reboot-delay)    shift; REBOOT_DELAY="${1:-60}" ;;
            -h|--help)         usage; exit 0 ;;
            *)                 echo -e "未知参数：$1" >&2; usage; exit 2 ;;
        esac
        shift
    done
    [[ "$REBOOT_DELAY" =~ ^[0-9]+$ ]] || { echo "--reboot-delay 需为数字" >&2; exit 2; }
    if [[ -n "$TARGET_RELEASE" && ! "$TARGET_RELEASE" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
        echo "--target 格式应为 XX.YY，例如 24.04" >&2; exit 2
    fi
}

# ---- root：有终端则用 sudo 重入；无终端（systemd/cron）则必须已是 root ----
ensure_root() {
    [[ $EUID -eq 0 ]] && return 0
    if [[ -t 0 && -t 1 ]]; then
        echo -e "${YELLOW}[提示] 需要 root 权限，请输入密码（仅需一次）：${NC}" >&2
        exec sudo -E env "SSH_CLIENT=${SSH_CLIENT:-}" "SSH_TTY=${SSH_TTY:-}" "$0" "${ORIG_ARGS[@]}"
    else
        echo -e "${RED}[中止] 需要 root，且当前无可交互终端。无人值守请以 root 运行（systemd/cron）。${NC}" >&2
        exit 1
    fi
}

setup_log() {
    LOG_FILE="${LOG_DIR}/${LOG_PREFIX}_$(date +%Y%m%d-%H%M%S).log"
    : >"$LOG_FILE" || { echo -e "${RED}[错误] 无法写日志文件 ${LOG_FILE}${NC}" >&2; exit 1; }
    chmod 600 "$LOG_FILE"
    export LOG_FILE
}

# ---- 日志轮转：只保留最近 KEEP_LOGS 个 ----
prune_logs() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    local logs old
    mapfile -t logs < <(ls -1t "${LOG_DIR}/${LOG_PREFIX}_"*.log 2>/dev/null)
    if (( ${#logs[@]} > KEEP_LOGS )); then
        for old in "${logs[@]:KEEP_LOGS}"; do rm -f "$old"; done
        log_line "${BLUE}[维护] 已清理旧日志，仅保留最近 ${KEEP_LOGS} 个${NC}"
    fi
}

# ============================ 预检 ============================
check_deps() {
    log_line "${BLUE}[预检] 检查必需命令...${NC}"
    local missing=() c
    for c in apt-get do-release-upgrade lsb_release flock setsid tail grep df sort realpath systemctl; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        die "缺少必需命令：${missing[*]}
可先安装：apt-get install -y ubuntu-release-upgrader-core lsb-release util-linux coreutils"
    fi
}

check_network() {
    log_line "${BLUE}[预检] 检查网络连通性...${NC}"
    if command -v getent >/dev/null 2>&1 && getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        return 0
    fi
    if command -v ping >/dev/null 2>&1 && ping -c 2 -W 3 archive.ubuntu.com >/dev/null 2>&1; then
        return 0
    fi
    die "无法解析或连接 archive.ubuntu.com，请检查网络 / DNS"
}

check_disk() {
    log_line "${BLUE}[预检] 检查根分区磁盘空间...${NC}"
    local avail_kb
    avail_kb="$(df -Pk --output=avail / 2>/dev/null | tail -n 1)"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]] && (( avail_kb < MIN_FREE_KB )); then
        die "根分区空闲空间不足：当前约 $((avail_kb / 1024))MB，升级需要至少 ~$((MIN_FREE_KB / 1024 / 1024))GB。请清理后重试。"
    fi
}

# ============================ 版本 / 升级探测 ============================
current_release() { lsb_release -rs 2>/dev/null || echo "unknown"; }

# 探测是否有可用升级；结果写入全局 AVAIL_RELEASE（无则留空）。只读操作。
probe_upgrade() {
    AVAIL_RELEASE=""
    local out
    out="$(do-release-upgrade -c 2>&1 | tee -a "$LOG_FILE")"
    if echo "$out" | grep -q "New release"; then
        AVAIL_RELEASE="$(echo "$out" | grep -oP "New release '\K[0-9\.]+")"
    fi
}

# 是否已到达 --target（未指定 target 时恒为否）
reached_target() {
    local cur="$1" smaller
    [[ -z "$TARGET_RELEASE" ]] && return 1
    smaller="$(printf '%s\n%s\n' "$TARGET_RELEASE" "$cur" | sort -V | head -n1)"
    [[ "$smaller" == "$TARGET_RELEASE" ]]
}

# ============================ 提醒 / 失败提示 ============================
backup_reminder() {
    log_line "${YELLOW}==================== 升级前提醒 ====================${NC}"
    log_line "${YELLOW}  强烈建议先做快照 / 备份（虚拟机快照、云盘快照、或关键数据备份）。${NC}"
    log_line "${YELLOW}  版本升级不可逆；失败时最可靠的恢复方式是回滚到快照。${NC}"
    log_line "${YELLOW}==================================================${NC}"
}

failure_hints() {
    log_line "${RED}[失败] 升级过程出现错误。恢复建议：${NC}"
    log_line "  1) 查看升级日志：/var/log/dist-upgrade/main.log 以及 ${LOG_FILE}"
    log_line "  2) 若有快照 / 备份，最稳妥是回滚到升级前的快照。"
    log_line "  3) 修复问题（空间 / 依赖 / 软件源）后可重新运行本脚本（幂等）。"
    log_line "  4) 未确认成功前不要重启；本脚本失败时不会自动重启。"
}

# ============================ 升级本体（命令保持原样）============================
run_upgrade() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo -e "${YELLOW}[DRY-RUN] 跳过实际升级命令（apt update / upgrade、do-release-upgrade、autoremove）${NC}" >>"$LOG_FILE"
        return 0
    fi
    (
        set -euo pipefail
        trap 'echo -e "${RED}[子进程错误] 命令失败: ${BASH_COMMAND}${NC}" >>"$LOG_FILE"' ERR

        echo -e "${GREEN}[阶段1] 更新软件列表...${NC}" >>"$LOG_FILE"
        apt-get -qq update \
            -o Acquire::http::No-Cache=True \
            -o Acquire::http::Pipeline-Depth=0 \
            >>"$LOG_FILE" 2>&1

        echo -e "${GREEN}[阶段2] 升级当前软件（保留原有配置文件）...${NC}" >>"$LOG_FILE"
        apt-get -qq upgrade -y \
            -o DPkg::options::="--force-confdef" \
            -o DPkg::options::="--force-confold" \
            -o APT::Get::Show-User-Simulation-Note=false \
            >>"$LOG_FILE" 2>&1

        echo -e "${GREEN}[阶段3] 开始 LTS 升级...${NC}" >>"$LOG_FILE"
        do-release-upgrade -f DistUpgradeViewNonInteractive -q >>"$LOG_FILE" 2>&1

        echo -e "${GREEN}[阶段4] 清理系统...${NC}" >>"$LOG_FILE"
        apt-get -qq autoremove -y >>"$LOG_FILE" 2>&1

        if [[ -f /var/run/reboot-required ]]; then
            echo -e "${YELLOW}[注意] 需要重启以生效：sudo reboot${NC}" >>"$LOG_FILE"
        fi
    )
    return $?
}

# ============================ 自动重启 ============================
maybe_reboot() {
    if [[ "$MODE" != "auto" ]]; then
        log_line "${BLUE}[信息] 监督模式不自动重启；如需生效请手动执行：sudo reboot${NC}"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_line "${YELLOW}[DRY-RUN] 跳过重启（真实模式将在 ${REBOOT_DELAY}s 倒计时后重启）${NC}"
        return 0
    fi
    if [[ $DO_REBOOT -ne 1 ]]; then
        log_line "${YELLOW}[信息] --no-reboot：不自动重启。请手动 sudo reboot 后由 systemd 续跑下一跳。${NC}"
        return 0
    fi
    log_line "${YELLOW}[自动] 升级命令完成，将在 ${REBOOT_DELAY}s 后重启以继续/完成升级。${NC}"
    log_line "${YELLOW}[自动] 如需取消重启：touch ${CANCEL_REBOOT_FILE}${NC}"
    rm -f "$CANCEL_REBOOT_FILE"
    local i
    for (( i = REBOOT_DELAY; i > 0; i-- )); do
        if [[ -e "$CANCEL_REBOOT_FILE" ]]; then
            log_line "${YELLOW}[自动] 检测到取消文件，已取消本次重启。${NC}"
            rm -f "$CANCEL_REBOOT_FILE"
            return 0
        fi
        sleep 1
    done
    log_line "${GREEN}[自动] 正在重启...${NC}"
    systemctl reboot 2>/dev/null || reboot
}

# ============================ systemd 单元自管理 ============================
install_unit() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log_line "${YELLOW}[DRY-RUN] 跳过安装 systemd 单元 ${UNIT_NAME}${NC}"
        return 0
    fi
    command -v systemctl >/dev/null 2>&1 || { log_line "${YELLOW}[警告] 无 systemd，跳过单元安装（多跳续跑需 systemd）${NC}"; return 0; }

    # 把脚本安装到稳定路径（避免用户移动原文件导致单元失效）；避免自我覆盖
    if [[ "$(realpath "$0")" != "$(realpath "$INSTALL_PATH" 2>/dev/null || echo "$INSTALL_PATH")" ]]; then
        install -D -m 0755 "$0" "$INSTALL_PATH" || die "无法把脚本安装到 ${INSTALL_PATH}"
    fi

    cat >"$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=Auto upgrade Ubuntu to latest LTS (multi-hop)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!${DONE_MARK}

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --auto --from-boot
TimeoutStartSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1
    rm -f "$DONE_MARK"
    log_line "${GREEN}[自动] 已安装并启用 ${UNIT_NAME}（开机自动续跑下一跳）${NC}"
}

remove_unit() {
    [[ $DRY_RUN -eq 1 ]] && { log_line "${YELLOW}[DRY-RUN] 跳过移除 systemd 单元${NC}"; return 0; }
    command -v systemctl >/dev/null 2>&1 || return 0
    if [[ -f "$SYSTEMD_UNIT" ]]; then
        systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload
        log_line "${GREEN}[自动] 已移除 ${UNIT_NAME}（停止自动续跑）${NC}"
    fi
    : >"$DONE_MARK" 2>/dev/null || true
}

# ============================ 全自动模式 ============================
run_auto() {
    exec 9>"$LOCK_FILE" || die "无法创建锁文件 ${LOCK_FILE}"
    flock -n 9 || die "已有一个升级正在运行（锁：${LOCK_FILE}）"

    local cur prev_from="" hops=0 k v rc
    cur="$(current_release)"
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r k v; do
            case "$k" in
                prev_from) prev_from="$v" ;;
                hops)      hops="$v" ;;
            esac
        done <"$STATE_FILE"
    fi
    [[ "$hops" =~ ^[0-9]+$ ]] || hops=0

    if [[ $FROM_BOOT -eq 1 ]]; then
        log_line "${BLUE}[自动] 由 systemd 在开机后续跑（第 $((hops)) 跳已记录）${NC}"
    fi
    log_line "${BLUE}[自动] 当前版本：${cur}；已进行跳数：${hops}/${MAX_HOPS}${NC}"

    # 护栏 1：上一跳从同一版本出发却没推进 —— 停止，避免无限重启
    if [[ -n "$prev_from" && "$prev_from" == "$cur" ]]; then
        remove_unit
        log_line "${RED}[自动] 检测到升级未推进（仍为 ${cur}），已停止自动续跑以防重启循环。${NC}"
        failure_hints
        exit 1
    fi
    # 护栏 2：跳数上限
    if (( hops >= MAX_HOPS )); then
        remove_unit
        log_line "${RED}[自动] 已达最大跳数 ${MAX_HOPS}，停止自动续跑。${NC}"
        exit 1
    fi

    probe_upgrade
    if [[ -z "$AVAIL_RELEASE" ]] || reached_target "$cur"; then
        log_line "${GREEN}[自动] 已到达目标/最新 LTS：${cur}。全部完成 ✅${NC}"
        remove_unit
        [[ $DRY_RUN -eq 0 ]] && printf 'done=1\nprev_from=\nhops=%s\n' "$hops" >"$STATE_FILE"
        exit 0
    fi

    log_line "${GREEN}[自动] 计划升级：${cur} → ${AVAIL_RELEASE}${NC}"
    install_unit                                        # 保证重启后能续跑下一跳
    [[ $DRY_RUN -eq 0 ]] && printf 'prev_from=%s\nhops=%s\n' "$cur" "$((hops + 1))" >"$STATE_FILE"

    backup_reminder
    run_upgrade
    rc=$?
    if (( rc == 0 )); then
        log_line "${GREEN}[自动] 本跳升级命令执行完成（rc=0）。${NC}"
        maybe_reboot
        # 若因 dry-run / --no-reboot / 取消而未重启：
        if [[ $DRY_RUN -eq 1 ]]; then
            log_line "${YELLOW}[DRY-RUN] 预演结束，未做任何真实更改。去掉 --dry-run 即真正执行。${NC}"
        elif [[ $DO_REBOOT -ne 1 ]]; then
            log_line "${YELLOW}[自动] 未重启。要续跑请手动 sudo reboot（systemd 会自动继续）。${NC}"
        fi
    else
        remove_unit
        failure_hints
        exit 1
    fi
}

# ============================ 监督模式 ============================
run_supervised() {
    export LOG_FILE LOCK_FILE FINISH_MARK DRY_RUN RED GREEN YELLOW BLUE NC
    export -f run_upgrade

    log_line "${GREEN}[信息] 预检通过，开始在后台执行升级...${NC}"
    setsid bash -c '
        exec 9>"$LOCK_FILE" || { echo "[中止] 无法创建锁文件" >>"$LOG_FILE"; echo "$FINISH_MARK rc=1" >>"$LOG_FILE"; exit 1; }
        if ! flock -n 9; then
            echo "[中止] 已有一个升级正在运行（锁：$LOCK_FILE）" >>"$LOG_FILE"
            echo "$FINISH_MARK rc=1" >>"$LOG_FILE"
            exit 1
        fi
        trap "" INT TERM HUP
        run_upgrade
        rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "[完成] 升级命令执行完成（监督模式不自动重启）" >>"$LOG_FILE"
        else
            echo "[失败] 升级过程出现错误（rc=$rc）" >>"$LOG_FILE"
        fi
        echo "$FINISH_MARK rc=${rc}" >>"$LOG_FILE"
    ' >/dev/null 2>&1 &

    echo -e "${GREEN}[信息] 升级已在后台安全启动，正在显示实时日志...${NC}"
    echo -e "${YELLOW}► 按 Ctrl+C 只退出日志查看，不影响后台升级。${NC}"
    echo -e "${BLUE}► 日志路径: ${LOG_FILE}${NC}"

    tail -n 0 -f "$LOG_FILE" &
    local tail_pid=$!
    trap 'kill "$tail_pid" 2>/dev/null; echo; echo -e "${YELLOW}[提示] 已退出日志查看；升级仍在后台继续。${NC}"; exit 0' INT TERM

    while ! grep -q "$FINISH_MARK" "$LOG_FILE" 2>/dev/null; do
        sleep 2
    done
    sleep 1
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null

    if grep -q "${FINISH_MARK} rc=0" "$LOG_FILE"; then
        echo -e "${GREEN}[完成] 升级流程已结束；如需生效请手动 sudo reboot。日志：${LOG_FILE}${NC}"
    else
        echo -e "${RED}[失败] 升级过程出现错误，请查看日志：${LOG_FILE}${NC}"
        exit 1
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"

    if [[ $DO_UNINSTALL -eq 1 ]]; then
        ensure_root
        setup_log
        remove_unit
        [[ $DRY_RUN -eq 0 ]] && rm -f "$STATE_FILE"
        log_line "${GREEN}[完成] 已卸载全自动模式（移除 systemd 单元与状态）。${NC}"
        exit 0
    fi

    ensure_root
    setup_log
    prune_logs

    if [[ $DRY_RUN -eq 1 ]]; then
        log_line "${YELLOW}[DRY-RUN] 预演模式：不会真正升级 / 重启 / 安装 systemd 单元。${NC}"
    fi
    if [[ "$MODE" == "auto" ]]; then
        log_line "${BLUE}[模式] 全自动无人值守（--auto）；目标：${TARGET_RELEASE:-最新可用 LTS}${NC}"
    else
        log_line "${BLUE}[模式] 监督模式（默认）${NC}"
    fi

    check_deps
    check_network
    check_disk

    if [[ "$MODE" == "auto" ]]; then
        run_auto
    else
        run_supervised
    fi
}

main "$@"
