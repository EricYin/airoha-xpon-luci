#!/bin/sh
# Replay settings only after netifd has started the OMCI/OAM engine. Patched
# S00 restores network.xpon_auth first; S11 provides the old-firmware fallback.
# This helper handles runtime/shared-memory-only attributes.

OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
tries=0
mac_applied=0
# S00 主路径或 S11 兼容路径已把实际引擎镜像到 network。
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
if [ "$mode" = "EPON" ]; then
	# apply auth 会先重启 epon_oam，再对新进程重放并回读全部 OAM 身份。
	if ! /usr/bin/xpon-apply.sh auth; then
		logger -t xpon "replay: EPON OAM 重启后身份（含 CTC ONUSN）重放失败，详见 /tmp/xpon-auth-native.log"
		exit 1
	fi
else
	if ! /usr/bin/xpon-auth-native.sh; then
		logger -t xpon "replay: 设备参数严格下发或回读失败，详见 /tmp/xpon-auth-native.log"
		exit 1
	fi
	# GPON 严格脚本负责逐项写入与回读，apply auth 触发 OMCI reconfig。
	/usr/bin/xpon-apply.sh auth || exit 1
fi
/usr/bin/xpon-apply.sh mac
/usr/bin/xpon-apply.sh iptv
/usr/bin/xpon-mvlan.sh
/usr/bin/pon-multicast apply-all
/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1 &
logger -t xpon "replay: 认证引擎就绪后身份与设备信息已重放"
