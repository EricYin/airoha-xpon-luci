#!/bin/sh
# 严格调用设备原生命令；任一步失败立即退出，禁止静默失败。
OMCI=/userfs/bin/omcicfgCmd
PONMGR=/userfs/bin/ponmgr
LOG=/tmp/xpon-auth-native.log
: > "$LOG"

run() {
	echo "+ $*" >> "$LOG"
	"$@" >> "$LOG" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || { echo "失败：exit_code=$rc" >> "$LOG"; exit "$rc"; }
}
get() { uci -q get "xpon.device.$1"; }
verify() {
	attr=$1
	want=$2
	[ -n "$want" ] || return 0
	have=$($OMCI get "$attr" 2>>"$LOG" | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1)
	cmp_have=$have
	cmp_want=$want
	case "$attr" in
		vendorId|sn|omccVersion) cmp_have=$(printf '%s' "$have" | tr 'a-f' 'A-F'); cmp_want=$(printf '%s' "$want" | tr 'a-f' 'A-F') ;;
	esac
	if [ "$cmp_have" != "$cmp_want" ]; then
		echo "回读校验失败：$attr want='$want' have='$have'" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：$attr='$have'" >> "$LOG"
}

[ -x "$OMCI" ] || { echo "omcicfgCmd 不存在或不可执行" > "$LOG"; exit 127; }

mode=$(get pon_mode); auth=$(get auth_type_g)
onu_type=$(get onu_type)
loid=$(get loid); loidpw=$(get loid_password); vendor=$(get vendor_id); sn=$(get sn)
equipment=$(get equipment_id); onuver=$(get onu_version); omcc=$(get omcc_version)
spec=$(get omci_spec_ver); pmac=$(get pon_mac); regid=$(get sn_regid_password)

# 留空字段必须完全跳过，绝不把空字符串写入共享配置。
[ -n "$onu_type" ] && run /usr/sbin/fw_setenv onu_type "$onu_type"
[ -n "$onu_type" ] && {
	bootargs=$(/usr/sbin/fw_printenv bootargs 2>/dev/null)
	newargs=$(printf '%s' "$bootargs" | sed "s/onu_type=[0-9A-Fa-f]*/onu_type=$onu_type/")
	[ "$newargs" = "$bootargs" ] || run /usr/sbin/fw_setenv bootargs "$newargs"
}
[ -n "$vendor" ] && run "$OMCI" set vendorId "$vendor"
[ -n "$sn" ] && run "$OMCI" set sn "$sn"
[ -n "$loid" ] && run "$OMCI" set loid "$loid"
[ -n "$loidpw" ] && run "$OMCI" set loidPasswd "$loidpw"
[ -n "$equipment" ] && run "$OMCI" set equipmentId "$equipment"
[ -n "$onuver" ] && run "$OMCI" set onuVersion "$onuver"
[ -n "$omcc" ] && run "$OMCI" set omccVersion "$omcc"
[ -n "$spec" ] && run "$OMCI" set specVer "$spec"
[ -n "$pmac" ] && run ifconfig pon hw ether "$pmac"

# 命令返回 0 不足以证明共享配置已更新；重启前必须核对当前生效值。
verify vendorId "$vendor"
verify sn "$sn"
verify equipmentId "$equipment"
verify onuVersion "$onuver"
verify omccVersion "$omcc"

case "$auth" in
	SN|sn) [ -n "$regid" ] && run "$PONMGR" gpon set passwd regid "$regid" ;;
esac

echo "全部设备参数写入成功" >> "$LOG"
exit 0
