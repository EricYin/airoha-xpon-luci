#!/bin/sh
# 严格调用设备原生命令；任一步失败立即退出，禁止静默失败。
OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
PONMGR=/userfs/bin/ponmgr
LOG=/tmp/xpon-auth-native.log
: > "$LOG"

run() {
	echo "+ $*" >> "$LOG"
	"$@" >> "$LOG" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || { echo "失败：exit_code=$rc" >> "$LOG"; exit "$rc"; }
}
run_secret() {
	label=$1
	shift
	echo "+ $label <已隐藏>" >> "$LOG"
	"$@" >> "$LOG" 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || { echo "失败：$label exit_code=$rc" >> "$LOG"; exit "$rc"; }
}
get() { uci -q get "xpon.device.$1"; }
identity_get() {
	v=$(uci -q get "network.xpon_auth.$1")
	[ -n "$v" ] || v=$(get "$1")
	printf '%s' "$v"
}
omci_read() {
	$OMCI get "$1" 2>>"$LOG" | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}
oam_read() {
	$OAM get "$1" 2>>"$LOG" | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}
verify() {
	attr=$1
	want=$2
	[ -n "$want" ] || return 0
	have=$(omci_read "$attr")
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

verify_secret() {
	attr=$1
	want=$2
	have=$(omci_read "$attr")
	if [ "$have" != "$want" ]; then
		echo "回读校验失败：$attr（密码值已隐藏）" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：$attr（密码值已隐藏）" >> "$LOG"
}

verify_mac() {
	want=$(printf '%s' "$1" | tr 'a-f' 'A-F')
	[ -n "$want" ] || return 0
	have=$(cat /sys/class/net/pon/address 2>/dev/null | tr 'a-f' 'A-F')
	[ -n "$have" ] || have=$(ifconfig pon 2>/dev/null | sed -n 's/.*HWaddr[[:space:]]*\([0-9A-Fa-f:]*\).*/\1/p; s/.*ether[[:space:]]*\([0-9A-Fa-f:]*\).*/\1/p' | head -1 | tr 'a-f' 'A-F')
	if [ "$have" != "$want" ]; then
		echo "回读校验失败：pon_mac want='$want' have='$have'" >> "$LOG"
		exit 65
	fi
	echo "回读校验成功：pon_mac='$have'" >> "$LOG"
}

verify_oam() {
	attr=$1
	want=$2
	secret=$3
	[ -n "$want" ] || return 0
	have=$(oam_read "$attr")
	cmp_have=$have
	cmp_want=$want
	case "$attr" in
		localOui|localVenInfo)
			cmp_have=$(printf '%s' "$have" | sed 's/^0[xX]//' | tr 'a-f' 'A-F')
			cmp_want=$(printf '%s' "$want" | sed 's/^0[xX]//' | tr 'a-f' 'A-F')
			;;
	esac
	if [ "$cmp_have" != "$cmp_want" ]; then
		if [ "$secret" = "1" ]; then
			echo "回读校验失败：$attr（密码值已隐藏）" >> "$LOG"
		else
			echo "回读校验失败：$attr want='$want' have='$have'" >> "$LOG"
		fi
		exit 65
	fi
	if [ "$secret" = "1" ]; then
		echo "回读校验成功：$attr（密码值已隐藏）" >> "$LOG"
	else
		echo "回读校验成功：$attr='$have'" >> "$LOG"
	fi
}

mode=$(get pon_mode); auth=$(get auth_type_g)
onu_type=$(get onu_type)
# 旧版认证页可能只写入了独立的 U-Boot onu_type，未在 xpon UCI 镜像中
# 留下同名字段。仍须用该目标值同步 bootargs，否则重启会继续沿用旧模式。
[ -n "$onu_type" ] || onu_type=$(/usr/sbin/fw_printenv -n onu_type 2>/dev/null)
loid=$(get loid); loidpw=$(get loid_password); sn=$(get sn)
[ -n "$sn" ] || sn=$(uci -q get network.xpon_auth.sn)
equipment=$(identity_get equipment_id); onuver=$(identity_get onu_version); omcc=$(identity_get omcc_version)
spec=$(get omci_spec_ver); pmac=$(get pon_mac); regid=$(get sn_regid_password)
[ -n "$pmac" ] || pmac=$(sed -n 's/^wan_mac=//p' /tmp/dsd.env 2>/dev/null | tr -d "'\"" | head -1)
sn_type=$(get xpon_sn_auth_type); asciipw=$(get sn_ascii_password); hexpw=$(get sn_hex_password)
epon_oui=$(get epon_oui); epon_ven=$(get epon_ven_info)

# PON SN 是唯一输入源；SDK 仍要求分别设置 ME 256 SN 与 ME 7 Vendor ID。
sn=$(printf '%s' "$sn" | tr -d '[:space:]' | tr 'a-z' 'A-Z')
valid_sn=
if [ "${#sn}" -eq 12 ]; then
	vendor_part=${sn%????????}
	serial_part=${sn#????}
	case "$vendor_part" in *[!A-Z0-9]*|'') : ;; *)
		case "$serial_part" in *[!0-9A-F]*|'') : ;; *) valid_sn=$sn ;; esac
		;;
	esac
fi
vendor=
[ -n "$valid_sn" ] && vendor=${valid_sn%????????}
if [ "$mode" != "EPON" ] && [ -z "$valid_sn" ]; then
	echo "PON SN 非法：读取值='$sn' 长度=${#sn}；必须为 4 位厂商代码 + 8 位十六进制序列号" >> "$LOG"
	exit 64
fi

# 一般留空字段跳过；LOID 密码例外，空字符串表示明确使用 LOID-only。
[ -n "$onu_type" ] && run /usr/sbin/fw_setenv onu_type "$onu_type"
[ -n "$onu_type" ] && {
	bootargs_raw=$(/usr/sbin/fw_printenv -n bootargs 2>/dev/null)
	bootargs=$bootargs_raw
	# 旧脚本把 `fw_printenv bootargs` 的键名也写回，可能累积 bootargs= 前缀。
	while [ "${bootargs#bootargs=}" != "$bootargs" ]; do bootargs=${bootargs#bootargs=}; done
	newargs=$(printf '%s' "$bootargs" | sed "s/onu_type=[0-9A-Fa-f]*/onu_type=$onu_type/")
	[ "$newargs" = "$bootargs_raw" ] || run /usr/sbin/fw_setenv bootargs "$newargs"
}
if [ "$mode" = "EPON" ]; then
	[ -x "$OAM" ] || { echo "oamcfgCmd 不存在或不可执行" >> "$LOG"; exit 127; }
	run "$OAM" set mode 2
	[ -n "$loid" ] && run "$OAM" set loid0 "$loid"
	[ -n "$loidpw" ] && run_secret "oamcfgCmd set loidPasswd0" "$OAM" set loidPasswd0 "$loidpw"
	[ -n "$epon_oui" ] && run "$OAM" set localOui "$epon_oui"
	[ -n "$epon_ven" ] && run "$OAM" set localVenInfo "$epon_ven"
	verify_oam loid0 "$loid" 0
	verify_oam loidPasswd0 "$loidpw" 1
	verify_oam localOui "$epon_oui" 0
	verify_oam localVenInfo "$epon_ven" 0
else
	[ -x "$OMCI" ] || { echo "omcicfgCmd 不存在或不可执行" >> "$LOG"; exit 127; }
	[ -n "$vendor" ] && run "$OMCI" set vendorId "$vendor"
	[ -n "$valid_sn" ] && run "$OMCI" set sn "$valid_sn"
	[ -n "$loid" ] && run "$OMCI" set loid "$loid"
	case "$auth" in
		LOID|loid) run_secret "omcicfgCmd set loidPasswd" "$OMCI" set loidPasswd "$loidpw" ;;
	esac
	[ -n "$equipment" ] && run "$OMCI" set equipmentId "$equipment"
	[ -n "$onuver" ] && run "$OMCI" set onuVersion "$onuver"
	[ -n "$omcc" ] && run "$OMCI" set omccVersion "$omcc"
	[ -n "$spec" ] && run "$OMCI" set specVer "$spec"

	# 命令返回 0 不足以证明共享配置已更新；重启前必须核对当前生效值。
	verify vendorId "$vendor"
	verify sn "$valid_sn"
	verify loid "$loid"
	case "$auth" in
		LOID|loid) verify_secret loidPasswd "$loidpw" ;;
	esac
	verify equipmentId "$equipment"
	verify onuVersion "$onuver"
	verify omccVersion "$omcc"
	verify specVer "$spec"

	case "$auth" in
		SN|sn)
			case "$sn_type" in
				hex) [ -n "$hexpw" ] && run_secret "ponmgr gpon set passwd hex" "$PONMGR" gpon set passwd hex "$hexpw" ;;
				regid) [ -n "$regid" ] && run_secret "ponmgr gpon set passwd regid" "$PONMGR" gpon set passwd regid "$regid" ;;
				*) [ -n "$asciipw" ] && run_secret "ponmgr gpon set passwd ascii" "$PONMGR" gpon set passwd ascii "$asciipw" ;;
			esac
			;;
	esac
fi

[ -n "$pmac" ] && run ifconfig pon hw ether "$pmac"
verify_mac "$pmac"

echo "全部设备参数写入成功" >> "$LOG"
exit 0
