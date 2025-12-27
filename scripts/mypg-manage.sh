#!/bin/bash

# PostgreSQL 安全管理脚本（Ubuntu）
# 支持 SCRAM-SHA-256、强密码生成、配置路径显示、用户权限表格

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
        error "本脚本需要 sudo 权限。"
    fi
}

# ✅ 修复：只返回主版本号（如 16，而非 16.11）
get_pg_version() {
    local version=""
    if command -v pg_config &> /dev/null; then
        version=$(pg_config --version | awk '{print $2}' | cut -d '.' -f1)
    elif [ -d /etc/postgresql ]; then
        version=$(ls /etc/postgresql/ | head -n1 | cut -d '.' -f1)
    else
        version="16"
    fi
    echo "$version" | grep -Eo '^[0-9]+'
}

# 🔍 显示配置文件路径
show_config_paths() {
    if ! systemctl is-active --quiet postgresql; then
        warn "PostgreSQL 服务未运行，但仍尝试从默认路径检测..."
    fi

    PG_VERSION=$(get_pg_version)
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    POSTGRESQL_CONF="$PG_CONF_DIR/postgresql.conf"
    PG_HBA_CONF="$PG_CONF_DIR/pg_hba.conf"

    log "PostgreSQL 主版本: $PG_VERSION"
    echo
    echo -e "postgresql.conf: ${YELLOW}$POSTGRESQL_CONF${NC}"
    echo -e "pg_hba.conf:     ${YELLOW}$PG_HBA_CONF${NC}"
    echo

    if [ -f "$POSTGRESQL_CONF" ] && [ -f "$PG_HBA_CONF" ]; then
        log "配置文件路径有效。"
    else
        warn "警告：一个或多个配置文件不存在（可能未安装或路径异常）。"
    fi
}

# 🔐 生成 16 位强密码
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
    log "PostgreSQL 安装完成！"
}

# 2. 允许外网连接（scram-sha-256）
enable_remote_access() {
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL 服务未运行，请先安装。"
    fi

    PG_VERSION=$(get_pg_version)
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    POSTGRESQL_CONF="$PG_CONF_DIR/postgresql.conf"
    PG_HBA_CONF="$PG_CONF_DIR/pg_hba.conf"

    log "检测到 PostgreSQL 主版本: $PG_VERSION"

    if [ ! -d "$PG_CONF_DIR" ]; then
        error "PostgreSQL 配置目录不存在: $PG_CONF_DIR，请确认安装是否成功。"
    fi

    if ! grep -q "^listen_addresses" "$POSTGRESQL_CONF"; then
        echo "listen_addresses = '*'" | sudo tee -a "$POSTGRESQL_CONF"
    else
        sudo sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$POSTGRESQL_CONF"
    fi

    sudo cp "$PG_HBA_CONF" "$PG_HBA_CONF.bak.$(date +%Y%m%d%H%M%S)"

    sudo sed -i '/^host.*all.*all.*0\.0\.0\.0\/0.*md5/d' "$PG_HBA_CONF"
    sudo sed -i '/^host.*all.*all.*0\.0\.0\.0\/0.*trust/d' "$PG_HBA_CONF"
    sudo sed -i '/^host.*all.*all.*::0\/0.*md5/d' "$PG_HBA_CONF"
    sudo sed -i '/^host.*all.*all.*::0\/0.*trust/d' "$PG_HBA_CONF"

    echo "host    all             all             0.0.0.0/0               scram-sha-256" | sudo tee -a "$PG_HBA_CONF"
    echo "host    all             all             ::0/0                   scram-sha-256" | sudo tee -a "$PG_HBA_CONF"

    log "已配置 scram-sha-256 外网访问。"
    warn "请确保防火墙（如 ufw）已放行 5432 端口！"

    sudo systemctl restart postgresql
    log "配置完成！"
}

# 3. 创建用户和数据库
create_user_db() {
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL 服务未运行。"
    fi

    read -rp "请输入新用户名: " username
    [[ -z "$username" ]] && error "用户名不能为空。"

    read -rp "请输入数据库名称（留空则使用用户名 '$username'）: " db_name
    if [[ -z "$db_name" ]]; then
        db_name="$username"
        log "数据库名称未指定，将使用: $db_name"
    fi

    read -rsp "请输入密码（留空则自动生成强密码）: " password
    echo

    if [[ -z "$password" ]]; then
        password=$(generate_strong_password)
        echo
        log "✅ 自动生成强密码: ${YELLOW}$password${NC}"
        echo
    fi

    sudo -u postgres psql -q -c "CREATE ROLE $username WITH LOGIN PASSWORD '$password';" >/dev/null
    sudo -u postgres psql -q -c "CREATE DATABASE \"$db_name\" OWNER $username;" >/dev/null
    sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO $username;" >/dev/null

    log "用户 '$username' 和数据库 '$db_name' 创建成功！"
}

# 5. 列出所有可登录用户及其可访问的数据库（紧凑表格）
list_users_and_dbs() {
    if ! systemctl is-active --quiet postgresql; then
        error "PostgreSQL 服务未运行，无法查询用户信息。"
    fi

    log "正在查询所有可登录用户及其可访问的数据库...\n"

    sudo -u postgres psql -q -c "
    SELECT
        r.rolname AS username,
        string_agg(d.datname, ', ' ORDER BY d.datname) AS accessible_databases
    FROM
        pg_roles r
    CROSS JOIN
        pg_database d
    WHERE
        r.rolcanlogin = true
        AND d.datname NOT IN ('template0', 'template1')
        AND has_database_privilege(r.rolname, d.datname, 'CONNECT')
    GROUP BY
        r.rolname
    ORDER BY
        r.rolname;
    "
}

# 主菜单（0-5）
show_menu() {
    clear
    cat <<EOF
==========================================
  PostgreSQL 安全管理脚本 (SCRAM-SHA-256)
==========================================
1) 安装 PostgreSQL
2) 允许外网连接（scram-sha-256）
3) 创建用户和数据库
4) 显示配置文件路径
5) 列出用户及其可访问的数据库
0) 退出
------------------------------------------
EOF
    read -rp "请选择操作 [0-5]: " choice
}

# 主程序
main() {
    check_sudo

    while true; do
        show_menu
        case $choice in
            1) install_postgres; read -n1 -rsp $'\n按任意键继续...\n' ;;
            2) enable_remote_access; read -n1 -rsp $'\n按任意键继续...\n' ;;
            3) create_user_db; read -n1 -rsp $'\n按任意键继续...\n' ;;
            4) show_config_paths; read -n1 -rsp $'\n按任意键返回菜单...\n' ;;
            5) list_users_and_dbs; read -n1 -rsp $'\n按任意键返回菜单...\n' ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-5 之间的数字。"; sleep 1 ;;
        esac
    done
}

main