cat << 'EOF' > /root/cdt.sh
#!/usr/bin/env bash
# ======================================================================================
# CDT-Management 一键 Docker 部署 / 备份 / 无损更新管理脚本 (自动保留3份备份版)
# 适用项目: https://github.com/BeacherZ/cdt-management
# 默认宿主机端口: 12333
# ======================================================================================

set -e

REPO_URL="https://github.com/BeacherZ/cdt-management.git"
APP_NAME="cdt-management"
INSTALL_DIR="/opt/docker/${APP_NAME}"
BACKUP_DIR="/opt/docker/${APP_NAME}-backups"
HOST_PORT="12333"
MAX_BACKUPS=3

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; return 1; }

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 用户运行此脚本 (sudo -i)"
    exit 1
fi

# 暂停并返回主菜单
pause_back() {
    echo ""
    read -rp "按回车键 (Enter) 返回主菜单..." _
}

# 获取已安装版本号
get_installed_version() {
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        echo -e "${RED}未安装${NC}"
        return
    fi

    local ver=""
    local commit=""
    local commit_date=""

    # 1. 尝试从常见版本文件中读取显式版本号
    if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
        ver=$(head -n 1 "${INSTALL_DIR}/VERSION" | tr -d '[:space:]')
    elif [[ -f "${INSTALL_DIR}/version.txt" ]]; then
        ver=$(head -n 1 "${INSTALL_DIR}/version.txt" | tr -d '[:space:]')
    elif [[ -f "${INSTALL_DIR}/package.json" ]]; then
        ver=$(grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "${INSTALL_DIR}/package.json" | cut -d'"' -f4 || true)
    fi

    # 2. 尝试从 Git 仓库获取 Tag / Commit 信息
    if [[ -d "${INSTALL_DIR}/.git" ]] && command -v git &>/dev/null; then
        local git_tag
        git_tag=$(git -C "${INSTALL_DIR}" describe --tags --abbrev=0 2>/dev/null || true)
        [[ -z "$ver" && -n "$git_tag" ]] && ver="$git_tag"

        commit=$(git -C "${INSTALL_DIR}" rev-parse --short HEAD 2>/dev/null || true)
        commit_date=$(git -C "${INSTALL_DIR}" log -1 --format="%cd" --date=short 2>/dev/null || true)
    fi

    # 3. 格式化组合输出
    if [[ -n "$ver" && -n "$commit" ]]; then
        if [[ "$ver" == "$commit" ]]; then
            echo -e "${GREEN}${ver}${NC} (${commit_date})"
        else
            echo -e "${GREEN}${ver}${NC} (Commit: ${YELLOW}${commit}${NC}, ${commit_date})"
        fi
    elif [[ -n "$ver" ]]; then
        echo -e "${GREEN}${ver}${NC}"
    elif [[ -n "$commit" ]]; then
        echo -e "${GREEN}Commit: ${commit}${NC} (${commit_date})"
    else
        echo -e "${YELLOW}已安装 (未知版本)${NC}"
    fi
}

# 自动清理旧备份，仅保留最新的 MAX_BACKUPS (3) 份
clean_old_backups() {
    mkdir -p "${BACKUP_DIR}"
    mapfile -t all_backups < <(ls -1t "${BACKUP_DIR}"/${APP_NAME}_backup_*.tar.gz 2>/dev/null || true)
    local total=${#all_backups[@]}

    if (( total > MAX_BACKUPS )); then
        info "检测到当前共有 ${total} 份备份，正在清理旧备份（仅保留最新 ${MAX_BACKUPS} 份）..."
        for (( i=MAX_BACKUPS; i<total; i++ )); do
            rm -f "${all_backups[$i]}"
            info "已删除旧备份: $(basename "${all_backups[$i]}")"
        done
        ok "旧备份清理完成！当前保留最新 ${MAX_BACKUPS} 份备份。"
    fi
}

# 1. 环境检查与依赖安装
check_env() {
    if ! command -v git &>/dev/null || ! command -v tar &>/dev/null || ! command -v curl &>/dev/null; then
        info "正在安装基础依赖 (git, curl, tar)..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y git curl tar ca-certificates
        elif command -v yum &>/dev/null; then
            yum install -y git curl tar ca-certificates
        elif command -v apk &>/dev/null; then
            apk add --no-cache git curl tar ca-certificates
        fi
    fi

    if ! command -v docker &>/dev/null; then
        info "未检测到 Docker，正在自动安装 Docker..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker || true
        ok "Docker 安装完成"
    fi

    if ! docker compose version &>/dev/null; then
        err "当前 Docker 版本不支持 'docker compose' (V2)，请升级 Docker 或安装 docker-compose-plugin。"
        return 1
    fi
}

# 2. 自动识别并修改端口为 12333（保持容器内部端口不变）
apply_port_config() {
    cd "${INSTALL_DIR}"
    local compose_file=""
    for f in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
        if [[ -f "$f" ]]; then
            compose_file="$f"
            break
        fi
    done

    if [[ -n "$compose_file" ]]; then
        info "检测到配置文件 ${compose_file}，正在将宿主机端口修改为 ${HOST_PORT}..."
        sed -i -E "s/^([[:space:]]*-[[:space:]]*[\"']?)([0-9]+):([0-9]+[\"']?)/\1${HOST_PORT}:\3/g" "$compose_file"
        ok "端口映射已锁定为宿主机 ${HOST_PORT} 端口"
    else
        info "未检测到默认 compose 文件，正在根据 Dockerfile 自动生成 docker-compose.yml..."
        local internal_port="8080"
        if [[ -f "Dockerfile" ]]; then
            local exposed
            exposed=$(grep -iE '^EXPOSE[[:space:]]+[0-9]+' Dockerfile | awk '{print $2}' | head -n1 || true)
            [[ -n "$exposed" ]] && internal_port="$exposed"
        fi
        mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/config" "${INSTALL_DIR}/logs"
        cat <<YML > "${INSTALL_DIR}/docker-compose.yml"
services:
  ${APP_NAME}:
    build: .
    image: ${APP_NAME}:latest
    container_name: ${APP_NAME}
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:${internal_port}"
    volumes:
      - ${INSTALL_DIR}/data:/app/data
      - ${INSTALL_DIR}/config:/app/config
      - ${INSTALL_DIR}/logs:/app/logs
    environment:
      - TZ=Asia/Shanghai
YML
        ok "已生成 docker-compose.yml (端口映射: ${HOST_PORT}:${internal_port})"
    fi
}

# 3. 启动或重建容器（优先拉取镜像，失败则本地构建）
start_containers() {
    cd "${INSTALL_DIR}"
    info "正在启动 ${APP_NAME} 容器..."
    if grep -q "ghcr.io" docker-compose.y*ml compose.y*ml 2>/dev/null; then
        if ! docker compose pull; then
            warn "拉取远程镜像失败，尝试使用本地源码构建..."
            docker compose up -d --build --remove-orphans
        else
            docker compose up -d --remove-orphans
        fi
    else
        docker compose up -d --build --remove-orphans
    fi
}

# 4. 安装部署
install_app() {
    check_env || return 1
    mkdir -p "${BACKUP_DIR}"

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        warn "检测到已安装目录 ${INSTALL_DIR}，正在为您转为【无损更新】流程..."
        update_app
        return
    fi

    info "正在拉取项目源码至 ${INSTALL_DIR} ..."
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    git clone "${REPO_URL}" "${INSTALL_DIR}"

    apply_port_config
    start_containers

    local ip
    ip=$(curl -fsSL -4 ip.sb 2>/dev/null || hostname -I | awk '{print $1}')
    echo ""
    ok "================================================================"
    ok " CDT-Management 安装成功！"
    ok " 当前版本: $(get_installed_version)"
    ok " 访问地址: http://${ip}:${HOST_PORT}"
    ok " 安装目录: ${INSTALL_DIR}"
    ok " 备份目录: ${BACKUP_DIR} (最多保留 ${MAX_BACKUPS} 份)"
    ok "================================================================"
}

# 5. 备份数据（支持手动备份与更新前自动备份 + 自动保留最新3份）
backup_data() {
    local tag="${1:-manual}"
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        err "未找到安装目录 ${INSTALL_DIR}，无法备份！"
        return 1
    fi

    mkdir -p "${BACKUP_DIR}"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${BACKUP_DIR}/${APP_NAME}_backup_${tag}_${timestamp}.tar.gz"

    info "正在打包备份持久化数据与配置文件..."
    tar --exclude="${INSTALL_DIR}/.git" -czf "${backup_file}" -C "$(dirname "${INSTALL_DIR}")" "$(basename "${INSTALL_DIR}")"

    ok "数据备份完成！备份文件路径: ${backup_file}"
    ls -lh "${backup_file}"

    # 每次备份完成后自动清理超出的旧备份
    clean_old_backups
}

# 6. 无损更新（自动备份 -> 保护持久化数据 -> 拉取更新 -> 恢复端口 -> 重建容器）
update_app() {
    check_env || return 1
    if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
        err "未检测到已安装的 ${INSTALL_DIR}，请先执行【1. 安装部署】。"
        return 1
    fi

    local old_ver
    old_ver=$(get_installed_version)
    info "更新前版本: ${old_ver}"

    info "【第 1/4 步】更新前自动备份当前数据..."
    backup_data "pre_update"

    info "【第 2/4 步】保护持久化数据目录并同步最新源码..."
    local tmp_data_dir="/tmp/${APP_NAME}_data_preserve_$$"
    mkdir -p "${tmp_data_dir}"
    cd "${INSTALL_DIR}"
    for item in data config logs db storage *.db *.sqlite *.sqlite3 *.json .env; do
        if [[ -e "$item" && "$item" != "package.json" && "$item" != "package-lock.json" ]]; then
            cp -a "$item" "${tmp_data_dir}/" 2>/dev/null || true
        fi
    done

    git fetch --all --tags
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
    git reset --hard "origin/${branch}"

    cp -af "${tmp_data_dir}/." "${INSTALL_DIR}/" 2>/dev/null || true
    rm -rf "${tmp_data_dir}"

    info "【第 3/4 步】重新应用 ${HOST_PORT} 端口配置..."
    apply_port_config

    info "【第 4/4 步】拉取最新镜像并无缝重建容器（挂载数据保持不变）..."
    start_containers
    docker image prune -f >/dev/null 2>&1 || true

    local new_ver
    new_ver=$(get_installed_version)

    ok "================================================================"
    ok " CDT-Management 已成功更新至最新版本，所有数据完好保留！"
    ok " 版本变更: ${old_ver} -> ${new_ver}"
    ok "================================================================"
}

# 7. 还原数据备份
restore_data() {
    mkdir -p "${BACKUP_DIR}"
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/${APP_NAME}_backup_*.tar.gz 2>/dev/null || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "在 ${BACKUP_DIR} 中未找到任何备份文件。"
        return
    fi

    echo -e "\n${CYAN}可用的备份列表（按时间从新到旧，最多保留 ${MAX_BACKUPS} 份）：${NC}"
    for i in "${!backups[@]}"; do
        echo "  [$((i+1))] $(basename "${backups[$i]}") ($(du -h "${backups[$i]}" | awk '{print $1}'))"
    done

    read -rp "请输入要恢复的备份序号 [1-${#backups[@]}] (输入 0 取消): " choice
    if [[ "$choice" == "0" || -z "$choice" ]]; then
        info "已取消恢复操作。"
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        err "无效的序号！"
        return 1
    fi

    local selected_backup="${backups[$((choice-1))]}"
    warn "即将从 $(basename "${selected_backup}") 恢复数据，当前运行状态将被覆盖！"
    read -rp "确认恢复吗？(y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消。"; return; }

    if [[ -d "${INSTALL_DIR}" ]]; then
        cd "${INSTALL_DIR}" && docker compose down 2>/dev/null || true
    fi

    info "正在解压恢复数据..."
    tar -xzf "${selected_backup}" -C "$(dirname "${INSTALL_DIR}")"
    apply_port_config
    start_containers
    ok "数据已成功恢复并重新启动服务！"
}

# 8. 查看状态与日志（支持 Ctrl+C 退回主菜单而不退出脚本）
view_logs() {
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        err "未找到安装目录 ${INSTALL_DIR}，请先安装！"
        return 1
    fi
    cd "${INSTALL_DIR}"
    docker compose ps
    echo -e "\n${YELLOW}提示：正在显示实时日志，按 Ctrl+C 可停止查看并返回主菜单...${NC}\n"
    trap 'echo -e "\n${CYAN}[INFO] 已停止日志输出${NC}"' INT
    docker compose logs --tail=50 -f || true
    trap - INT
}

# 9. 卸载服务
uninstall_app() {
    warn "即将停止并移除 ${APP_NAME} 容器。"
    read -rp "确认卸载容器吗？(y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && return

    if [[ -d "${INSTALL_DIR}" ]]; then
        cd "${INSTALL_DIR}" && docker compose down --rmi all 2>/dev/null || true
    fi

    read -rp "是否在删除安装目录前先执行一次最终数据备份？(Y/n): " do_bak
    if [[ "${do_bak,,}" != "n" ]]; then
        backup_data "before_uninstall" || true
    fi

    read -rp "是否彻底删除安装目录 ${INSTALL_DIR}（备份目录 ${BACKUP_DIR} 仍会保留）？(y/N): " del_dir
    if [[ "${del_dir,,}" == "y" ]]; then
        rm -rf "${INSTALL_DIR}"
        ok "安装目录已删除。您的历史备份仍安全保留在: ${BACKUP_DIR}"
    else
        ok "容器已移除，数据文件仍保留在: ${INSTALL_DIR}"
    fi
}

# 循环主菜单界面
show_menu() {
    # 启动菜单时自动检查并清理一次多余备份
    clean_old_backups >/dev/null 2>&1 || true

    while true; do
        clear
        local cur_backups
        cur_backups=$(ls -1 "${BACKUP_DIR}"/${APP_NAME}_backup_*.tar.gz 2>/dev/null | wc -l)
        local current_version
        current_version=$(get_installed_version)

        echo -e "${CYAN}==============================================================${NC}"
        echo -e "${GREEN}            CDT-Management Docker 一键管理脚本                 ${NC}"
        echo -e "${CYAN}==============================================================${NC}"
        echo -e " 项目地址: ${REPO_URL}"
        echo -e " 安装路径: ${INSTALL_DIR}"
        echo -e " 当前版本: ${current_version}"
        echo -e " 备份路径: ${BACKUP_DIR} (当前: ${YELLOW}${cur_backups}/${MAX_BACKUPS}${NC} 份)"
        echo -e " 面板端口: ${YELLOW}${HOST_PORT}${NC}"
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}1.${NC} 一键安装部署 (端口 ${HOST_PORT})"
        echo -e "  ${GREEN}2.${NC} 无损更新版本 (自动备份 + 保留全部数据)"
        echo -e "  ${GREEN}3.${NC} 立即备份数据 (超出 ${MAX_BACKUPS} 份自动删旧)"
        echo -e "  ${GREEN}4.${NC} 从备份恢复数据"
        echo -e "  ${GREEN}5.${NC} 查看运行状态与实时日志"
        echo -e "  ${GREEN}6.${NC} 重启服务"
        echo -e "  ${RED}7.${NC} 卸载服务"
        echo -e "  ${GREEN}0.${NC} 退出脚本"
        echo -e "${CYAN}==============================================================${NC}"
        read -rp "请输入数字选项 [0-7]: " opt

        case "$opt" in
            1) install_app || true; pause_back ;;
            2) update_app || true; pause_back ;;
            3) backup_data "manual" || true; pause_back ;;
            4) restore_data || true; pause_back ;;
            5) view_logs || true; pause_back ;;
            6)
                if [[ -d "${INSTALL_DIR}" ]]; then
                    cd "${INSTALL_DIR}" && docker compose restart && ok "服务已重启"
                else
                    err "未找到安装目录 ${INSTALL_DIR}" || true
                fi
                pause_back
                ;;
            7) uninstall_app || true; pause_back ;;
            0) info "已退出管理脚本。"; exit 0 ;;
            *) warn "无效选项，请重新输入"; sleep 1 ;;
        esac
    done
}

# 支持命令行参数直接调用 (便于写入 crontab 定时备份，不进入循环)
case "${1:-}" in
    install)   install_app ;;
    update)    update_app ;;
    backup)    backup_data "cron" ;;
    restore)   restore_data ;;
    uninstall) uninstall_app ;;
    *)         show_menu ;;
esac
EOF
chmod +x /root/cdt.sh && /root/cdt.sh
