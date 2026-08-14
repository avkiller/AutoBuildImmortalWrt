#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. 先获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# 2. 根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
# 此处特殊处理个别开发板网口顺序问题
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        # 默认第一个接口为WAN，其余为LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        echo "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
esac

# 3. 配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # 多网口设备配置
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 查找 br-lan 设备 section
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "error：cannot find device 'br-lan'." >>$LOGFILE
    else
        # 删除原有ports
        uci -q delete "network.$section.ports"
        # 添加LAN接口端口
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Updated br-lan ports: $lan_ifnames" >>$LOGFILE
    fi

    # # LAN口设置静态IP
    # uci set network.lan.proto='static'
    # # 多网口设备 支持修改为别的管理后台地址 在Github Action 的UI上自行输入即可 
    # uci set network.lan.netmask='255.255.255.0'
    # # 设置路由器管理后台地址
    # IP_VALUE_FILE="/etc/custom_router_ip.txt"
    # if [ -f "$IP_VALUE_FILE" ]; then
    #     CUSTOM_IP=$(cat "$IP_VALUE_FILE")
    #     # 用户在UI上设置的路由器后台管理地址
    #     uci set network.lan.ipaddr=$CUSTOM_IP
    #     echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
    # else
    #     uci set network.lan.ipaddr='192.168.100.1'
    #     echo "default router ip is 192.168.100.1" >> $LOGFILE
    # fi

    # LAN口设置静态IP
    uci set network.lan.proto='static'
    uci set network.lan.netmask='255.255.255.0'

    # 设置路由器管理后台地址
    IP_VALUE_FILE="/etc/custom_router_ip.txt"
    DEFAULT_IP="192.168.100.1"

    if [ -f "$IP_VALUE_FILE" ]; then
        # 读取并清理IP地址（去除空格、换行符）
        CUSTOM_IP=$(head -n 1 "$IP_VALUE_FILE" | tr -d ' \t\n\r')
        
        # 验证IP地址格式（简单检查）
        if echo "$CUSTOM_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            uci set network.lan.ipaddr="$CUSTOM_IP"
            echo "custom router ip is $CUSTOM_IP" >> "$LOGFILE"
        else
            # IP格式无效，使用默认值并记录警告
            echo "WARNING: Invalid IP format '$CUSTOM_IP', using default $DEFAULT_IP" >> "$LOGFILE"
            uci set network.lan.ipaddr="$DEFAULT_IP"
        fi
    else
        uci set network.lan.ipaddr="$DEFAULT_IP"
        echo "default router ip is $DEFAULT_IP" >> "$LOGFILE"
    fi

    # PPPoE设置
    echo "enable_pppoe value: $enable_pppoe" >>$LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE enabled, configuring..." >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE config done." >>$LOGFILE
    else
        echo "PPPoE not enabled." >>$LOGFILE
    fi

    uci commit network
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置ttyd直接以root账号启动
uci set ttyd.@ttyd[0].command='/bin/login -f root'
uci commit ttyd
# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
# uci set dropbear.@dropbear[0].DirectInterface='lan'
uci commit dropbear

# 添加一个nat 防火墙规则以解决在非动态伪装下部分app无法访问的问题
CONFIG_NAME="app_user_srcnat"
# 检查是否存在名为 'app_user_srcnat' 的 include 段
if ! uci show firewall | grep -q "firewall.${CONFIG_NAME}="; then
    echo "📝 配置段 '${CONFIG_NAME}' 不存在，正在添加..."
    
    # 创建一个新的匿名段
    uci set firewall.@include[-1]="include"
    # 设置参数
    uci set firewall.@include[-1].type="nftables"
    uci set firewall.@include[-1].path="/etc/firewall.user.nft"
    uci set firewall.@include[-1].enabled="1"
    # 重命名为目标名称
    uci rename firewall.@include[-1]="${CONFIG_NAME}"
    
    # 提交更改
    uci commit firewall
    echo "✅ 配置段 '${CONFIG_NAME}' 已成功添加。"
else
    echo "⏭️  配置段 '${CONFIG_NAME}' 已存在，跳过添加。"
fi


# 修改默认的主机名
uci set system.@system[0].hostname='Netgate'
# 清空原有的 ntp_server 列表并写入新值
uci del system.@system[0].ntp_server
uci add_list system.@system[0].ntp_server='ntp.aliyun.com'
uci add_list system.@system[0].ntp_server='ntp.tencent.com'
uci add_list system.@system[0].ntp_server='ntp.ntsc.ac.cn'
uci add_list system.@system[0].ntp_server='time.apple.com'

# 2. 提交更改
uci commit system
# 修改默认的dns并发数
uci set dhcp.@dnsmasq[0].dnsforwardmax='1000'
uci commit dhcp


# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by avkiller"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "fix ttyd show msg: /usb/bin/zsh: not found" >>$LOGFILE
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "fix quickfile nginx config" >>$LOGFILE
fi

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall

# 追加新的 zone + forwarding 配置
cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi
# 1. 确保 BBR 内核模块已加载（如果固件已内置，此步可跳过）
# 注意：如果模块未安装，modprobe 会失败，但不应影响脚本其他部分
modprobe tcp_bbr 2>/dev/null

# 2. 安全写入 /etc/sysctl.conf（带有去重判断，防止重复运行脚本时追加多行）
if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
    cat << 'EOF' >> /etc/sysctl.conf
# BBR Congestion Control
net.ipv4.tcp_congestion_control = bbr
EOF
else
    # 如果已存在该配置，则直接替换为 bbr
    sed -i 's/^net\.ipv4\.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/' /etc/sysctl.conf
fi

# 写入转发的规则
cat << 'EOF' >> /etc/sysctl.conf

# Disable ICMP send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.br-lan.send_redirects = 0
EOF

# 3. 强制当前系统立即生效
sysctl -p /etc/sysctl.conf >/dev/null 2>&1
exit 0
