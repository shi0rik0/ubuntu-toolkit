#!/bin/bash

# PostgreSQL 安全管理脚本（Ubuntu）
# - 安装 PostgreSQL
# - 启用外网访问（scram-sha-256）
# - 创建用户 & 数据库（可自定义库名，支持自动生成强密码）

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

check_sudo() {
    if ! command -v sudo &> /dev/null; then
        error "本脚本需要 sudo 权限，请确保已安装 sudo 并配置好权限。"
    fi
}

get_pg_version() {
    local version=""
    if command -v pg_config &> /dev/null; then
        version=$(pg_config --version | awk '{print $2}' | cut -d '.' -f1)
    elif [ -d /etc/postgresql ]; then
        # 列出 /etc/postgresql/ 下的子目录，取第一个（通常是主版本号如 16）
        version=$(ls /etc/postgresql/ | head -n1 | cut -d '.' -f1)
    else
        version="16"  # 默认主版本，可根据 Ubuntu 默认调整（22.04+ 默认 14/16）
    fi
    # 确保只保留数字（防止意外字符）
    echo "$version" | grep -Eo '^[0-9]+'
}

# 生成 16 位强密码（含大小写字母、数字、符号）
generate_strong_password() {
    local length=16
    if command -v openssl &> /dev/null; then
        openssl rand -base64 48 | tr -d '+/=' | cut -c1-"$length"
    else
        tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length"
    fi
}

# 1. 安装 PostgreSQL
install_postgres() {
    log "正在更新软件包列表..."
    sudo apt update

    log "正在安装 PostgreSQL..."
    sudo apt install -y postgresql postgresql-contrib

    log "启动并启用 PostgreSQL 服务..."
    sudo systemctl enable --now postgresql

    # 可选：为 postgres 超级用户设置一个默认密码（方便后续管理，可删除）
    # echo "ALTER USER postgres WITH PASSWORD 'postgres';" | sudo -u postgres psql -q >/dev/null

    log "PostgreSQL 安装完成！"
}

# 2. 允许外网连接（使用 scram-sha-256）
enable_remote_access() {
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL 服务未运行，请先安装 PostgreSQL。"
    fi

    PG_VERSION=$(get_pg_version)
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    POSTGRESQL_CONF="$PG_CONF_DIR/postgresql.conf"
    PG_HBA_CONF="$PG_CONF_DIR/pg_hba.conf"

    log "检测到 PostgreSQL 版本: $PG_VERSION"

    # 配置监听所有地址
    if ! grep -q "^listen_addresses" "$POSTGRESQL_CONF"; then
        echo "listen_addresses = '*'" | sudo tee -a "$POSTGRESQL_CONF"
    else
        sudo sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$POSTGRESQL_CONF"
    fi

    # 备份 pg_hba.conf
    sudo cp "$PG_HBA_CONF" "$PG_HBA_CONF.bak.$(date +%Y%m%d%H%M%S)"

    # 清理旧的 md5/trust 规则（避免冲突）
    sudo sed -i '/^host.*all.*all.*0\.0\.0\.0\/0.*md5/d' "$PG_HBA_CONF"
    sudo sed -i '/^host.*all.*all.*0\.0\.0\.0\/0.*trust/d' "$PG_HBA_CONF"
    sudo sed -i '/^host.*all.*all.*::0\/0.*md5/d' "$PG_HBA_CONF"
    sudo sed -i '/^host.*all.*all.*::0\/0.*trust/d' "$PG_HBA_CONF"

    # 添加 SCRAM-SHA-256 规则（IPv4 + IPv6）
    echo "host    all             all             0.0.0.0/0               scram-sha-256" | sudo tee -a "$PG_HBA_CONF"
    echo "host    all             all             ::0/0                   scram-sha-256" | sudo tee -a "$PG_HBA_CONF"

    log "已配置 PostgreSQL 使用 scram-sha-256 允许外网连接。"
    warn "请确保防火墙（如 ufw）已放行 5432 端口！"

    log "正在重启 PostgreSQL 服务..."
    sudo systemctl restart postgresql

    log "外网访问配置完成！"
}

# 3. 创建用户和数据库（支持自定义 DB 名 + 自动生成密码）
create_user_db() {
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL 服务未运行，请先安装 PostgreSQL。"
    fi

    read -rp "请输入新用户名: " username
    [[ -z "$username" ]] && error "用户名不能为空。"

    read -rp "请输入数据库名称（留空则使用用户名 '$username'）: " db_name
    if [[ -z "$db_name" ]]; then
        db_name="$username"
        log "数据库名称未指定，将使用: $db_name"
    fi

    read -rsp "请输入密码（留空则自动生成强密码）: " password
    echo  # 换行以便后续输出

    if [[ -z "$password" ]]; then
        password=$(generate_strong_password)
        echo
        log "✅ 自动生成强密码: ${YELLOW}$password${NC}"
        echo
    fi

    # 创建用户（角色）
    sudo -u postgres psql -q -c "CREATE ROLE $username WITH LOGIN PASSWORD '$password';" >/dev/null
    # 创建数据库（用双引号支持大小写，但常规名无需）
    sudo -u postgres psql -q -c "CREATE DATABASE \"$db_name\" OWNER $username;" >/dev/null
    sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO $username;" >/dev/null

    log "用户 '$username' 和数据库 '$db_name' 创建成功！"
    log "密码已使用 SCRAM-SHA-256 安全存储。"
}

# 主菜单
show_menu() {
    clear
    cat <<EOF
==========================================
  PostgreSQL 安全管理脚本 (SCRAM-SHA-256)
==========================================
1) 安装 PostgreSQL
2) 允许外网连接（scram-sha-256）
3) 创建用户和数据库（支持自定义库名）
0) 退出
------------------------------------------
EOF
    read -rp "请选择操作 [0-3]: " choice
}

# 主程序
main() {
    check_sudo

    while true; do
        show_menu
        case $choice in
            1)
                install_postgres
                read -n1 -rsp $'\n按任意键返回菜单...\n'
                ;;
            2)
                enable_remote_access
                read -n1 -rsp $'\n按任意键返回菜单...\n'
                ;;
            3)
                create_user_db
                read -n1 -rsp $'\n按任意键返回菜单...\n'
                ;;
            0)
                echo "再见！"
                exit 0
                ;;
            *)
                warn "无效选项，请输入 0-3 之间的数字。"
                sleep 1
                ;;
        esac
    done
}

# 执行主函数
main
