#!/bin/sh
# xpon-apply.sh {auth|network|mac|leds|iptv|ponmode <hex>|all}
#
# 读 UCI -> omcicfgCmd/oamcfgCmd 下发 -> 重启 OMCI -> reload network
# 与 SDK airoha_network/uci.c 的 airoha_gpon_active / config_init_xpon 对齐：
#   GPON SN  : set sn + set passwdAscii|passwdHex
#   GPON LOID: set sn <def_sn> + set loid + set loidPasswd
#   /tmp/load_process 存在则只发 `omci set reconfig`，否则重启 omci/ponmgr_cfg

OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
PONMGR=/userfs/bin/ponmgr_cfg
OMCID=/userfs/bin/omci

uci_get() { uci -q get "$1"; }

apply_auth() {
	local mode auth sn_type loid loidpw defsn sn apwd hexpwd
	mode=$(uci_get network.xpon_auth.pon_mode); [ -z "$mode" ] && mode=GPON
	auth=$(uci_get network.xpon_auth.auth_type_g); [ -z "$auth" ] && auth=sn
	sn=$(uci_get network.xpon_auth.sn)
	loid=$(uci_get network.xpon_auth.loid)
	loidpw=$(uci_get network.xpon_auth.loid_password)
	defsn=$(uci_get network.xpon_auth.def_sn)
	sn_type=$(uci_get network.xpon_auth.xpon_sn_auth_type); [ -z "$sn_type" ] && sn_type=ascii
	apwd=$(uci_get network.xpon_auth.sn_ascii_password)
	hexpwd=$(uci_get network.xpon_auth.sn_hex_password)

	# omcicfgCmd 对参数有长度校验（如 SN 必须 12 字节、loid ≤24 字节），
	# 空值/非法长度一律跳过并记日志——避免误覆盖出厂 SN（NoNumber 8 字节会被拒）。
	set_sn() { # $1=sn
		[ -n "$1" ] || return 0
		if [ "${#1}" -eq 12 ]; then
			$OMCI set sn "$1" >/dev/null 2>&1
		else
			logger -t xpon "skip set sn '$1'（需 12 字节，保持出厂 SN）"
		fi
	}

	if [ "$mode" = "GPON" ]; then
		if [ "$auth" = "loid" ]; then
			set_sn "${defsn:-$sn}"
			[ -n "$loid" ] && $OMCI set loid "$loid" >/dev/null 2>&1
			[ -n "$loidpw" ] && $OMCI set loidPasswd "$loidpw" >/dev/null 2>&1
		else
			set_sn "$sn"
			[ -n "$apwd" ] && $OMCI set passwdAscii "$apwd" >/dev/null 2>&1
			[ -n "$hexpwd" ] && $OMCI set passwdHex "$hexpwd" >/dev/null 2>&1
		fi
		# 厂商信息（netifd 引擎不管，这里补）
		[ -n "$(uci_get xpon.auth.vendor_id)" ] && $OMCI set vendor_id "$(uci_get xpon.auth.vendor_id)" >/dev/null 2>&1
		[ -n "$(uci_get xpon.auth.equipment_id)" ] && $OMCI set equipment_id "$(uci_get xpon.auth.equipment_id)" >/dev/null 2>&1
		[ -n "$(uci_get xpon.auth.onu_version)" ] && $OMCI set onu_version "$(uci_get xpon.auth.onu_version)" >/dev/null 2>&1
		[ -n "$(uci_get xpon.auth.omcc_version)" ] && $OMCI set omcc_version "$(uci_get xpon.auth.omcc_version)" >/dev/null 2>&1
	elif [ "$mode" = "EPON" ]; then
		[ -n "$loid" ] && $OAM set loidauth loid0 "$loid" >/dev/null 2>&1
		[ -n "$loidpw" ] && $OAM set loidauth password0 "$loidpw" >/dev/null 2>&1
	fi

	# 让共享内存生效（对齐 SDK：已加载只 reconfig，未加载则重启拉起）
	if [ -e /tmp/load_process ]; then
		$OMCID set reconfig >/dev/null 2>&1
	else
		killall omci >/dev/null 2>&1
		killall ponmgr_cfg >/dev/null 2>&1
		sleep 1
		$PONMGR &
		$OMCID &
		touch /tmp/load_process
	fi
}

apply_network() {
	uci commit network
	/etc/init.d/network reload
}

apply_mac() {
	# S00xponconfig 已用 /tmp/dsd.env 的 wan_mac 设置 pon MAC；
	# 这里允许用 xpon.auth.pon_mac 显式覆盖（留空=维持默认）
	local pmac
	pmac=$(uci_get xpon.auth.pon_mac)
	[ -n "$pmac" ] && ifconfig pon hw ether "$pmac" 2>/dev/null
}

apply_leds() {
	local led
	# sts_green 常亮修复（LED 逆向：缺 aliases 导致默认闪绿，见 XG2010G-LUCI-APPS.md §8）
	if [ "$(uci_get xpon.led.fix_sts_green)" = "1" ] && [ -d /sys/class/leds/sts_green ]; then
		echo none > /sys/class/leds/sts_green/trigger 2>/dev/null
		echo 255 > /sys/class/leds/sts_green/brightness 2>/dev/null
	fi
	# 上网灯：pppoe-wan netdev 触发器（可选）
	led=$(uci_get xpon.led.internet_led)
	[ -n "$led" ] && [ -d "/sys/class/leds/$led" ] && {
		echo netdev > "/sys/class/leds/$led/trigger" 2>/dev/null
		echo pppoe-wan > "/sys/class/leds/$led/device_name" 2>/dev/null
		echo 1 > "/sys/class/leds/$led/link" 2>/dev/null
		echo 1 > "/sys/class/leds/$led/tx" 2>/dev/null
		echo 1 > "/sys/class/leds/$led/rx" 2>/dev/null
	}
}

# 切换 HGU / SFU × GPON / XGPON / XGSPON 模式（写 U-Boot env，重启后生效）
# 原理：PON 模式来自 onu_type bootarg 字节（SDK dump_pon_type_mode_info）：
#       bits[1:0]=ONU 类型 1=SFU 2=HGU；bits[7:4]=PON 模式 1=GPON 6=XGPON 7=XGSPON。
#       出厂 71=SFU+XGSPON；本机当前 61=SFU+XGPON；联通 HGU 请用 62=HGU+XGPON。
# 只改 env 不重启（由页面选择是否 reboot）。
apply_ponmode() {
	local val="$1"
	[ -n "$val" ] || { echo "usage: xpon-apply.sh ponmode <2-digit-hex>" >&2; return 1; }
	case "$val" in
		[0-9a-fA-F][0-9a-fA-F]) : ;;
		*) echo "invalid onu_type: $val（需 2 位十六进制）" >&2; return 1 ;;
	esac
	command -v fw_setenv >/dev/null 2>&1 || {
		echo "fw_setenv 不可用（缺 uboot-envtools 或 fw_env.config）" >&2
		return 1
	}

	# 1) 更新 bootargs 里的 onu_type=（保留其余参数，如 tclinux_info/ethaddr）
	local ba newba
	ba=$(fw_printenv bootargs 2>/dev/null)
	if [ -n "$ba" ]; then
		newba=$(printf '%s' "$ba" | sed "s/onu_type=[0-9a-fA-F]*/onu_type=$val/")
		[ -n "$newba" ] && fw_setenv bootargs "$newba"
	fi
	# 2) 独立 onu_type 变量（bootcmd 若从变量拼 bootargs 也能生效）
	fw_setenv onu_type "$val"
	logger -t xpon "onu_type -> $val (bootargs updated: ${newba:+yes})"
}

apply_iptv() {
	[ -x /usr/bin/xpon-iptv.sh ] || return 0
	/usr/bin/xpon-iptv.sh >/dev/null 2>&1
}

case "${1:-all}" in
	auth)    apply_auth ;;
	network) apply_network ;;
	mac)     apply_mac ;;
	leds)    apply_leds ;;
	iptv)    apply_iptv ;;
	ponmode) apply_ponmode "$2" ;;
	all)
		apply_auth
		apply_mac
		apply_network
		apply_leds
		;;
	*) echo "usage: $0 {auth|network|mac|leds|iptv|ponmode <hex>|all}" >&2; exit 1 ;;
esac

exit 0
