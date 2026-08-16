#!/bin/sh
# Replay settings only after netifd has started the OMCI engine. S11 restores
# network.xpon_auth first; this helper handles shared-memory-only attributes.

OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
tries=0
mac_applied=0
# S11 restore-auth 已按本次 cmdline/env 把实际引擎镜像到 network。
mode=$(uci -q get network.xpon_auth.pon_mode)

while [ "$tries" -lt 90 ]; do
	# GPON 系列的 PON MAC 只是 pon 业务接口地址，不必等待 OMCI。
	# 接口一出现就先应用一次；OMCI 就绪后严格重放还会再次回读确认。
	if [ "$mode" != "EPON" ] && [ "$mac_applied" = 0 ] && [ -e /sys/class/net/pon/address ]; then
		/usr/bin/xpon-apply.sh mac >/dev/null 2>&1 && mac_applied=1
	fi
	if [ "$mode" = "EPON" ]; then
		pidof epon_oam >/dev/null 2>&1 && "$OAM" get loid0 >/dev/null 2>&1 && break
	else
		pidof omci >/dev/null 2>&1 && "$OMCI" get sn >/dev/null 2>&1 && break
	fi
	tries=$((tries + 1))
	sleep 1
done

if [ "$tries" -ge 90 ]; then
	[ "$mode" = "EPON" ] || [ "$mac_applied" = 1 ] || /usr/bin/xpon-apply.sh mac >/dev/null 2>&1
	logger -t xpon "replay: OMCI 90 秒内未就绪，跳过本次重放"
	exit 1
fi

# Let ponmgr/OMCI/OAM finish their own shared-memory initialization first.
sleep 2
if ! /usr/bin/xpon-auth-native.sh; then
	logger -t xpon "replay: 设备参数严格下发或回读失败，详见 /tmp/xpon-auth-native.log"
	exit 1
fi
# 严格脚本负责逐项写入与回读；旧应用函数只负责触发 OMCI reconfig，
# 或在 EPON 下重启 OAM 引擎使新认证参数参与下一次注册。
/usr/bin/xpon-apply.sh auth
/usr/bin/xpon-apply.sh mac
/usr/bin/xpon-apply.sh iptv
/usr/bin/xpon-mvlan.sh
/usr/bin/pon-multicast apply-all
/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1 &
logger -t xpon "replay: OMCI 就绪后认证与设备信息已重放"
