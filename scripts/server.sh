#!/bin/bash

set -e

# Check sudo
if [ $(id -u) -ne 0 ];then
    echo "Please run this script with sudo"
    exit 1
fi

# Envs
## Caddy
CADDY_DIR=/usr/local/opt/caddy
CADDY_CONFIG_DIR=/usr/local/etc/caddy
CADDY_WWW_DIR=/var/www/
CADDY_BIN=$CADDY_DIR/caddy
## Rclone
RCLONE_DIR=/usr/local/opt/rclone
RCLONE_CONFIG_DIR=/usr/local/etc/rclone
RCLONE_BIN=$RCLONE_DIR/rclone
## FRP
FRP_DIR=/usr/local/opt/frp
FRP_CONFIG_DIR=/usr/local/etc/frp
FRPS_BIN=$FRP_DIR/frps
FRPC_BIN=$FRP_DIR/frpc

install_caddy() {
# Download caddy
mkdir -p $CADDY_DIR
curl -Lo $CADDY_BIN "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fdnspod&p=github.com%2Fmholt%2Fcaddy-webdav"
chmod +x $CADDY_BIN
setcap cap_net_bind_service=+ep $CADDY_BIN

# Create configs
mkdir -p $CADDY_CONFIG_DIR/sites-available
mkdir -p $CADDY_CONFIG_DIR/sites-enabled

if [ ! -d $CADDY_WWW_DIR/default ];then
mkdir -p $CADDY_WWW_DIR/default
cat > $CADDY_WWW_DIR/default/index.html << EOF
Hello World!
EOF
fi
chown -R www-data:www-data $CADDY_WWW_DIR

cat > $CADDY_CONFIG_DIR/envs << EOF
CADDYPATH=$CADDY_CONFIG_DIR/ssl
EOF
cat > $CADDY_CONFIG_DIR/Caddyfile << EOF
import sites-enabled/*
EOF
cat > $CADDY_CONFIG_DIR/sites-available/default << EOF
:80 {
    root * /var/www/default
    file_server
}
EOF

ln -s ../sites-available/default $CADDY_CONFIG_DIR/sites-enabled/default

# Create systemd service
cat > /etc/systemd/system/caddy.service << EOF
[Unit]
Description=Caddy HTTP/2 web server
Documentation=https://caddyserver.com/docs
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

StartLimitIntervalSec=14400
StartLimitBurst=10

[Service]
Restart=on-abnormal

User=www-data
Group=www-data

EnvironmentFile=$CADDY_CONFIG_DIR/envs

ExecStart=$CADDY_BIN run -config $CADDY_CONFIG_DIR/Caddyfile 2>&1
ExecReload=$CADDY_BIN reload -config $CADDY_CONFIG_DIR/Caddyfile

LimitNOFILE=8192

PrivateTmp=true
PrivateDevices=false
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

# Start caddy
systemctl daemon-reload
systemctl start caddy.service
systemctl enable caddy.service

echo "caddy $($CADDY_BIN version | cut -d " " -f 1) installed"
}

uninstall_caddy() {
if [ "$(ps -ea | grep caddy)" != "" ];then
    systemctl daemon-reload
    systemctl stop caddy.service
fi
rm -f /etc/systemd/system/caddy.service
rm -rf /usr/local/etc/caddy
rm -rf /usr/local/opt/caddy

echo "caddy uninstalled"
}

install_rclone() {
mkdir -p $RCLONE_DIR
mkdir -p $RCLONE_CONFIG_DIR
mkdir -p $RCLONE_CONFIG_DIR/serve

curl -fsSL http://public.bigrats.net/scripts/rclone/webauth.sh > $RCLONE_DIR/webauth && chmod +x $RCLONE_DIR/webauth

cat > /usr/local/bin/rclone << EOF
#!/bin/bash
set -e
if [ "\$1" = "webauth" ];then
    $RCLONE_DIR/webauth "\${@:2}"
    exit 0
fi
RCLONE=$RCLONE_BIN
if [ \$(id -u) -eq 0 ];then
    RCLONE="$RCLONE_BIN --config $RCLONE_CONFIG_DIR/rclone.conf"
fi
\$RCLONE "\${@:1}"
EOF

cat > $RCLONE_CONFIG_DIR/serve/sample.conf << EOF
rclone_mode=webdav
rclone_addr=0.0.0.0:8080
rclone_auth="rclone webauth http://127.0.0.1:7000"
EOF

cat > /etc/systemd/system/rcloned@.service << EOF
[Unit]
Description=Rclone remote serving service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
User=nobody
Type=simple
EnvironmentFile=$RCLONE_CONFIG_DIR/serve/%i.conf
ExecStart=/usr/local/bin/rclone serve \${rclone_mode} --addr "\${rclone_addr}" --auth-proxy "\${rclone_auth}"
Restart=on-failure

PrivateTmp=true
PrivateDevices=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

chmod +x /usr/local/bin/rclone
curl https://rclone.org/install.sh | sed "s/\/usr\/bin\/rclone/$(echo $RCLONE_BIN | sed 's/\//\\\//g')/g" | bash

}

uninstall_rclone() {
if [ "$(ps -ea | grep rclone)" != "" ];then
    kill $(ps -e | grep rclone | cut -d ' ' -f 1)
fi
rm -f /usr/local/bin/rclone
rm -f /usr/local/share/man/man1/rclone.1
rm -rf $RCLONE_DIR
rm -rf $RCLONE_CONFIG_DIR
mandb

echo "rclone uninstalled"
}

install_frp() {
mkdir -p $FRP_DIR
curl -Lo $FRPS_BIN "https://github.com/jqjiang819/frp/releases/latest/download/frps_linux_amd64"
curl -Lo $FRPC_BIN "https://github.com/jqjiang819/frp/releases/latest/download/frpc_linux_amd64"
chmod +x $FRPS_BIN $FRPC_BIN
ln -s $FRPS_BIN /usr/local/bin/frps
ln -s $FRPC_BIN /usr/local/bin/frpc

mkdir -p $FRP_CONFIG_DIR
[ ! -e $FRP_CONFIG_DIR/frps.ini ] && curl -Lo $FRP_CONFIG_DIR/frps.ini "https://github.com/jqjiang819/frp/raw/rats/conf/frps.ini"

cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=Frp Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
User=nobody
Type=simple
ExecStart=$FRPS_BIN -c $FRP_CONFIG_DIR/frps.ini
Restart=on-failure

PrivateTmp=true
PrivateDevices=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/frpc.service << EOF
[Unit]
Description=Frp Client Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
User=nobody
Type=idle
ExecStart=$FRPC_BIN -c $FRP_CONFIG_DIR/frpc.ini
ExecReload=$FRPC_BIN reload -c $FRP_CONFIG_DIR/frpc.ini
Restart=on-failure

PrivateTmp=true
PrivateDevices=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/frpc@.service << EOF
[Unit]
Description=Frp Client Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
User=nobody
Type=idle
ExecStart=$FRPC_BIN -c $FRP_CONFIG_DIR/frpc_%i.ini
ExecReload=$FRPC_BIN reload -c $FRP_CONFIG_DIR/frpc_%i.ini
Restart=on-failure

PrivateTmp=true
PrivateDevices=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start frps.service
systemctl enable frps.service

echo "frps $($FRPS_BIN -v) and frpc $($FRPC_BIN -v) installed"
}

uninstall_frp() {
systemctl daemon-reload
if [ "$(ps -ea | grep frps)" != "" ];then
    systemctl disable frps.service
    systemctl stop frps.service
fi
if [ "$(ps -ea | grep frpc)" != "" ];then
    systemctl disable frpc.service
    systemctl stop frpc.service
    for f in $FRP_CONFIG_DIR/frpc_*.ini;do
        svr=$(echo $f | awk -F'[/._]' '{print $(NF-1)}')
        systemctl disable frpc@$svr.service
        systemctl stop frpc@$svr.service
    done
fi

rm -f /etc/systemd/system/frps.service
rm -f /etc/systemd/system/frpc.service
rm -f /etc/systemd/system/frpc@.service
rm -f /usr/local/bin/frps
rm -f /usr/local/bin/frpc
rm -rf $FRP_CONFIG_DIR
rm -rf $FRP_DIR

echo "frp uninstalled"
}

install_bbr() {
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
sysctl -p

echo "bbr installed"
}

uninstall_bbr() {
echo "not supported"
}


if [ "$1" = "install" ];then
    install_$2
elif [ "$1" = "uninstall" ];then
    uninstall_$2
elif [ "$1" = "backup" ];then
    rm -rf /tmp/backup
    mkdir -p /tmp/backup
    pushd /tmp/backup > /dev/null
    for s in ${@:3};do
        cp -r /usr/local/etc/$s ./
        echo "$s copied"
    done
    tar -czf backup.tar.gz ./*
    popd > /dev/null
    mv /tmp/backup/backup.tar.gz $2
    rm -rf /tmp/backup
    echo "backup complete"
elif [ "$1" = "restore" ];then
    rm -rf /tmp/backup
    mkdir -p /tmp/backup
    tar -xzf $2 -C /tmp/backup
    pushd /tmp/backup > /dev/null
    for s in $(ls);do
        rm -rf /usr/local/etc/$s
        mv $s /usr/local/etc/
        echo "$s restored"
    done
    popd > /dev/null
    rm -rf /tmp/backup
    echo "restore complete"
else
    echo "unsupported command:" $1
fi
