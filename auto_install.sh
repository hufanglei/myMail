#!/bin/bash

# 检查参数个数是否正确
if [ $# -ne 5 ]; then
    echo "Usage: $0 <DOMAIN> <MAIL_DOMAIN> <MAIL_ADMIN> <MAIL_ADMIN_PASSWORD> <MYSQL_ROOT_PASSWORD>"
    exit 1
fi

# 获取传递进来的参数
DOMAIN="$1"
MAIL_DOMAIN="$2"
MAIL_ADMIN="$3"
MAIL_ADMIN_PASSWORD="$4"
MYSQL_ROOT_PASSWORD="$5"

VERSION="1.7.1"
LOG_FILE="/opt/auto-install.log"

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本。" | tee -a $LOG_FILE
    exit 1
fi

# 打印日志函数
log() {
    echo "$1" | tee -a $LOG_FILE
}

# 设置主机名
hostnamectl set-hostname "${DOMAIN}"
if [ $? -eq 0 ]; then
    log "主机名已设置为: $(hostnamectl status | grep 'Static hostname' | awk '{print $3}')"
else
    log "设置主机名失败。"
    exit 1
fi

# 修改 /etc/hosts 文件，将 FQDN 主机名列为第一项
echo "127.0.0.1   ${MAIL_DOMAIN} ${DOMAIN} localhost localhost.localdomain" > /etc/hosts
if [ $? -eq 0 ]; then
    log "/etc/hosts 文件已更新，并将 FQDN 主机名列为第一项。"
else
    log "更新 /etc/hosts 文件失败。"
    exit 1
fi

# 验证 FQDN 主机名
FQDN=$(hostname -f)
if [ $? -eq 0 ]; then
    log "完全限定域名 (FQDN) 主机名为: ${FQDN}"
else
    log "获取 FQDN 主机名失败。"
    exit 1
fi

# 禁用 SELinux
setenforce 0
if [ $? -eq 0 ]; then
    log "SELinux 已立即禁用。"
else
    log "禁用 SELinux 失败。"
    exit 1
fi
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
if [ $? -eq 0 ]; then
    log "SELinux 配置文件已更新，禁用 SELinux。"
else
    log "更新 SELinux 配置文件失败。"
    exit 1
fi

# 获取外网 IP 地址
external_ip=$(curl -s ifconfig.me)
if [ $? -eq 0 ]; then
    log "本机的外网 IP 地址是: $external_ip"
else
    log "获取外网 IP 地址失败。"
    exit 1
fi

# 安装必要的依赖
yum install -y wget tar expect
if [ $? -eq 0 ]; then
    log "必要的依赖已安装。"
else
    log "安装依赖失败。"
    exit 1
fi


cd iRedMail-${VERSION}

# 创建 Expect 脚本
cat <<EOL > /opt/iredmail_install.expect
#!/usr/bin/expect -f

set timeout -1
log_user 1
set MYSQL_ROOT_PASSWORD "${MYSQL_ROOT_PASSWORD}"
set DOMAIN "${DOMAIN}"
set MAIL_ADMIN_PASSWORD "${MAIL_ADMIN_PASSWORD}"

# 启动日志记录
log_file /opt/iredmail_install.log

# 启动安装程序
spawn sudo bash /opt/iRedMail-1.7.1/iRedMail.sh

# 检查 spawn 是否成功
if {![info exists spawn_id] || \$spawn_id == ""} {
    send_user "Error: spawn failed.\n"
    exit 1
}

# 等待欢迎信息并确认
expect {
    "Welcome and thanks for your use" { send "\r" }
    timeout { send_user "Error: timeout waiting for welcome message.\n"; exit 1 }
}
sleep 5

# 设置邮件存储目录
expect {
    "Please specify a directory" { send "/var/vmail\r" }
    timeout { send_user "Error: timeout waiting for directory prompt.\n"; exit 1 }
}
sleep 5

# 选择 Web 服务器
expect {
    "Choose a web server" { send "2\r" }
    timeout { send_user "Error: timeout waiting for web server prompt.\n"; exit 1 }
}
sleep 3

# 选择 MariaDB 作为数据库
expect {
    "Choose preferred backend" { send "\r" }
    timeout { send_user "Error: timeout waiting for backend prompt.\n"; exit 1 }
}
sleep 5

# 输入 MySQL 管理员密码
expect {
    "Password for MySQL administrator" { send "\${MYSQL_ROOT_PASSWORD}\r" }
    timeout { send_user "Error: timeout waiting for MySQL password prompt.\n"; exit 1 }
}
sleep 5

# 设置邮件域名
expect {
    "Your first mail domain name" { send "\${DOMAIN}\r" }
    timeout { send_user "Error: timeout waiting for mail domain prompt.\n"; exit 1 }
}
sleep 5

# 设置邮件管理员密码
expect {
    "Password for the mail domain administrator" { send "\${MAIL_ADMIN_PASSWORD}\r" }
    timeout { send_user "Error: timeout waiting for mail admin password prompt.\n"; exit 1 }
}
sleep 5

# 确认邮件管理员密码
expect {
    "Re-enter password" { send "\${MAIL_ADMIN_PASSWORD}\r" }
    timeout { send_user "Error: timeout waiting for re-enter password prompt.\n"; exit 1 }
}
sleep 5



expect eof
EOL

chmod +x /opt/iredmail_install.expect

# 运行 Expect 脚本并捕获所有输出
/opt/iredmail_install.expect >> $LOG_FILE 2>&1

if [ $? -eq 0 ]; then
    log "iRedMail 安装完成。"
else
    log "iRedMail 安装失败。请查看 /opt/iredmail_install.log 以获取详细信息。"
    exit 1
fi

# 配置防火墙
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-service=imap
firewall-cmd --permanent --add-service=pop3
firewall-cmd --permanent --add-port=25/tcp
firewall-cmd --reload

if [ $? -eq 0 ]; then
    log "防火墙配置完成。"
else
    log "防火墙配置失败。"
    exit 1
fi

log "********************************************************************"
log "* URLs of installed web applications:"
log "*"
log "* - Roundcube webmail: https://${DOMAIN}/mail/"
log "* - netdata (monitor): https://${DOMAIN}/netdata/"
log "*"
log "* - Web admin panel (iRedAdmin): https://${DOMAIN}/iredadmin/"
log "*"
log "* You can login to above links with below credential:"
log "*"
log "* - Username: ${ADMIN}"
log "* - Password: ${MAIL_ADMIN_PASSWORD}"
log "*"
log "********************************************************************"
log "* Congratulations, mail server setup completed successfully. Please"
log "* read below file for more information:"
log "*"
log "*   - /opt/iRedMail-${VERSION}/iRedMail.tips"
log "*"
log "* And it's sent to your mail account ${MAIL_ADMIN}."
log "********************************************************************"
log "* WARNING: Please reboot your system to enable all mail services."
log "********************************************************************"