#!/bin/sh
# xpon-apply.sh {restore-auth|auth|network|mac|leds|iptv|ponmode <hex>|all}
#
# 读 UCI -> omcicfgCmd/oamcfgCmd 下发 -> 重启 OMCI -> reload network
# 按设备原生认证流程执行：
#   GPON SN  : set sn + ponmgr gpon set passwd ascii|hex <pwd>
#   GPON LOID: set sn <def_sn> + set loid + set loidPasswd
#   /tmp/load_process 存在则只发 `omci set reconfig`，否则重启 omci/ponmgr_cfg

OMCI=/userfs/bin/omcicfgCmd
OAM=/userfs/bin/oamcfgCmd
PONMGR=/userfs/bin/ponmgr_cfg
PONMGRCLI=/userfs/bin/ponmgr
OMCID=/userfs/bin/omci
EPON_OAM=/userfs/bin/epon_oam

uci_get() { uci -q get "$1"; }

# 开机恢复：S00xponconfig 的 validate_xponauth_section() 有 `-z $gponauth` 笔误
# （变量从未赋值，恒真），每次开机都把 network.xpon_auth 打回
#   pon_mode=GPON / auth_type_g=sn / sn=$fsan（fsan 来自 /tmp/dsd.env）
# 这里是 LOID 重启失效的真正根因。restore_auth 从 LuCI 保存的持久源
# /etc/config/xpon（auth 类型段 device）重写 network.xpon_auth，
# 必须在 netifd 加载网络配置（S20network）之前运行（xpon-app START=11）。
# xpon.device.pon_mode 只由 LuCI 认证页成功保存时写入，并作为“用户已保存”标志。
# EPON 走 OAM（oamcfgCmd loid0），GPON 走 OMCI（omcicfgCmd）。
restore_auth() {
	local t p k v factory_sn old_loid
	if ! uci -q get xpon.device.pon_mode >/dev/null; then
		# 旧包/覆盖安装没有“已保存”标志时，不把模板默认冒充用户配置。
		# 保留 network 中已有 LOID，并用 DSD 的合法 FSAN 替换 NoNumber。
		factory_sn=$(sed -n "s/^fsan='\(.*\)'/\1/p" /tmp/dsd.env 2>/dev/null | head -1)
		old_loid=$(uci_get network.xpon_auth.loid)
		uci set network.xpon_auth='xpon_auth'
		uci set network.xpon_auth.pon_mode='GPON'
		[ "${#factory_sn}" -eq 12 ] && {
			uci set network.xpon_auth.sn="$factory_sn"
			uci set network.xpon_auth.def_sn="$factory_sn"
		}
		if [ -n "$old_loid" ]; then
			uci set network.xpon_auth.auth_type_g='LOID'
		else
			uci set network.xpon_auth.auth_type_g='SN'
		fi
		uci commit network
		logger -t xpon "restore-auth: 未找到已保存标志，使用 DSD/现存 LOID 初始化（sn=$factory_sn）"
		return 0
	fi
	p=$(uci_get xpon.device.pon_mode); p=${p:-GPON}
	t=$(uci_get xpon.device.auth_type_g)
	if [ "$p" = "EPON" ]; then
		[ -n "$(uci_get xpon.device.loid)" ] || {
			logger -t xpon "restore-auth: pon_mode=EPON 但 loid 为空，跳过覆盖"
			return 0
		}
	else
		[ -n "$t" ] || return 0
		case "$t" in
			loid|LOID)
				[ -n "$(uci_get xpon.device.loid)" ] || {
					logger -t xpon "restore-auth: auth_type_g=$t 但 loid 为空，跳过覆盖"
					return 0
				}
				;;
			sn|SN) : ;;
			*) logger -t xpon "restore-auth: 未知 auth_type_g=$t，跳过"; return 0 ;;
		esac
	fi

	uci set network.xpon_auth='xpon_auth'
	uci set network.xpon_auth.pon_mode="$p"
	pt=$(uci_get xpon.device.pon_tech); [ -z "$pt" ] && pt=GPON
	case "$pt" in GPON|XGPON|XGSPON|EPON_10G_1G|EPON_10G_10G) : ;; *) pt=GPON ;; esac
	uci set network.xpon_auth.pon_tech="$pt"
	if [ "$p" = "EPON" ]; then
		te=$(uci_get xpon.device.auth_type_e); te=${te:-LOID}
		uci set network.xpon_auth.auth_type_e="$te"
		uci -q delete network.xpon_auth.auth_type_g
	else
		uci set network.xpon_auth.auth_type_g="$t"
		uci -q delete network.xpon_auth.auth_type_e
	fi
	for k in loid def_sn sn xpon_sn_auth_type sn_ascii_password sn_hex_password sn_regid_password; do
		v=$(uci_get xpon.device.$k)
		[ -n "$v" ] && uci set network.xpon_auth.$k="$v"
	done
	# libuci 无法保存空字符串；空密码由 OMCI 就绪后的认证重放显式下发。
	v=$(uci_get xpon.device.loid_password)
	if [ -n "$v" ]; then
		uci set network.xpon_auth.loid_password="$v"
	else
		uci -q delete network.xpon_auth.loid_password
	fi
	uci commit network
	logger -t xpon "restore-auth: 已恢复 pon_mode=$p auth_type=$([ "$p" = EPON ] && echo EPON-LOID || echo "$t")（loid=$(uci_get network.xpon_auth.loid)）"
}

apply_auth() {
	local mode auth sn_type loid loidpw defsn sn apwd hexpwd regpwd identity_sn identity_vendor
	local equipment_val onuver_val omcc_val
	identity_get() {
		iv=$(uci_get network.xpon_auth.$1)
		[ -n "$iv" ] || iv=$(uci_get xpon.device.$1)
		printf '%s' "$iv"
	}
	mode=$(uci_get network.xpon_auth.pon_mode); [ -z "$mode" ] && mode=GPON
	auth=$(uci_get network.xpon_auth.auth_type_g); [ -z "$auth" ] && auth=LOID
	case "$auth" in loid|LOID) auth=loid ;; sn|SN) auth=sn ;; esac
	sn=$(uci_get network.xpon_auth.sn)
	sn=$(printf '%s' "$sn" | tr 'a-z' 'A-Z')
	loid=$(uci_get network.xpon_auth.loid)
	loidpw=$(uci_get network.xpon_auth.loid_password)
	defsn=$(uci_get network.xpon_auth.def_sn)
	defsn=$(printf '%s' "$defsn" | tr 'a-z' 'A-Z')
	sn_type=$(uci_get network.xpon_auth.xpon_sn_auth_type); [ -z "$sn_type" ] && sn_type=ascii
	apwd=$(uci_get network.xpon_auth.sn_ascii_password)
	hexpwd=$(uci_get network.xpon_auth.sn_hex_password)
	regpwd=$(uci_get network.xpon_auth.sn_regid_password)
	equipment_val=$(identity_get equipment_id)
	onuver_val=$(identity_get onu_version)
	omcc_val=$(identity_get omcc_version)
	valid_pon_sn() {
		[ "${#1}" -eq 12 ] || return 1
		vpart=${1%????????}
		spart=${1#????}
		case "$vpart" in *[!A-Z0-9]*|'') return 1 ;; esac
		case "$spart" in *[!0-9A-F]*|'') return 1 ;; esac
		return 0
	}

	# omcicfgCmd 对参数有长度校验（如 SN 必须 12 字节、loid ≤24 字节），
	# 空值/非法长度一律跳过并记日志——避免误覆盖出厂 SN（NoNumber 8 字节会被拒）。
	set_sn() { # $1=sn
		[ -n "$1" ] || return 0
		if valid_pon_sn "$1"; then
			$OMCI set sn "$1" >/dev/null 2>&1
		else
			logger -t xpon "skip set sn '$1'（须为 4 位厂商代码 + 8 位 hex，保持出厂 SN）"
		fi
	}

	if [ "$mode" = "GPON" ]; then
		if [ "$auth" = "loid" ]; then
			set_sn "${defsn:-$sn}"
			[ -n "$loid" ] && $OMCI set loid "$loid" >/dev/null 2>&1
			# 空字符串是有效配置，表示 LOID-only；不能保留 netifd 的 ECONET 默认值。
			$OMCI set loidPasswd "$loidpw" >/dev/null 2>&1
		else
			set_sn "$sn"
			# SN 密码：本固件 omcicfgCmd 无 passwdAscii/passwdHex 子命令
			# （netifd 会调用，但被 omcicfgCmd 静默拒绝），
			# 实际生效入口是 ponmgr：`gpon set passwd <ascii|hex|regid> <值>`
			#   ascii ≤10 字符、hex ≤20 位（=10 字节的十六进制编码）、regid ≤36（移动 Password / 电信注册码）
			# 按 xpon_sn_auth_type 三选一（hex->hex，regid->regid，其它->ascii）
			if [ "$sn_type" = "hex" ]; then
				[ -n "$hexpwd" ] && $PONMGRCLI gpon set passwd hex "$hexpwd" >/dev/null 2>&1
			elif [ "$sn_type" = "regid" ]; then
				[ -n "$regpwd" ] && $PONMGRCLI gpon set passwd regid "$regpwd" >/dev/null 2>&1
			else
				[ -n "$apwd" ] && $PONMGRCLI gpon set passwd ascii "$apwd" >/dev/null 2>&1
			fi
		fi
		# 厂商信息（netifd 引擎不管）。pon_mode 同时作为认证页已成功保存标志；
		# 没有标志时不能把旧安装包的模板默认当成用户配置下发。
		# omcicfgCmd 子命令为驼峰：vendorId / equipmentId / onuVersion / omccVersion
		# （snake_case 会打印 valid subcommands 帮助并静默失败）
		if [ -n "$(uci_get xpon.device.pon_mode)" ]; then
			identity_sn=${defsn:-$sn}
			identity_vendor=
			if valid_pon_sn "$identity_sn"; then
				identity_vendor=${identity_sn%????????}
			fi
			[ -n "$identity_vendor" ] && $OMCI set vendorId "$identity_vendor" >/dev/null 2>&1
			[ -n "$equipment_val" ] && $OMCI set equipmentId "$equipment_val" >/dev/null 2>&1
			[ -n "$onuver_val" ] && $OMCI set onuVersion "$onuver_val" >/dev/null 2>&1
			[ -n "$omcc_val" ] && $OMCI set omccVersion "$omcc_val" >/dev/null 2>&1
			# 记录实际回读值，区分 UCI 保存成功与 OMCI 下发成功。
			for attr in vendorId equipmentId onuVersion omccVersion; do
				want=$(identity_get "$(printf '%s' "$attr" | sed 's/vendorId/vendor_id/;s/equipmentId/equipment_id/;s/onuVersion/onu_version/;s/omccVersion/omcc_version/')")
				[ "$attr" = vendorId ] && want=$identity_vendor
				[ -n "$want" ] || continue
				have=$($OMCI get "$attr" 2>/dev/null | sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1)
				[ "$have" = "$want" ] || logger -t xpon "apply_auth: $attr 下发不一致 want='$want' have='$have'"
			done
		else
			# 未保存状态采用 DSD/网络 SN 的前四字节，避免旧模板 MTKG 与 AXON SN 不一致。
			factory_vendor=${sn%????????}
			[ "${#sn}" -eq 12 ] && [ "${#factory_vendor}" -eq 4 ] && \
				$OMCI set vendorId "$factory_vendor" >/dev/null 2>&1
		fi
		# OMCI 消息交互协议版本（specVer，uint8；与 G.988 标准 2 字节版本的映射需真机验证）
		[ -n "$(uci_get xpon.device.omci_spec_ver)" ] && $OMCI set specVer "$(uci_get xpon.device.omci_spec_ver)" >/dev/null 2>&1
	elif [ "$mode" = "EPON" ]; then
		# 10G-EPON（XEPON，onu_type bits[7:4]=3/4）OAM 认证。
		# 按 stock netifd 的 EPON 激活流程执行：
		#   oamcfgCmd set mode 2（LINK_MODE_EPON）
		#   oamcfgCmd set loid0 <loid> / set loidPasswd0 <pwd>
		# XEPON 需“模式”页切到 42/41/32/31 且 OLT 为 10G-EPON 口，实验性。
		$OAM set mode 2 >/dev/null 2>&1
		[ -n "$loid" ] && $OAM set loid0 "$loid" >/dev/null 2>&1
		[ -n "$loidpw" ] && $OAM set loidPasswd0 "$loidpw" >/dev/null 2>&1
		# EPON 侧 OUI / 厂商信息（ZTE setmac EPONSN 前 6 位 = OUI，VENDORID 的 OAM 对应）
		[ -n "$(uci_get xpon.device.epon_oui)" ] && $OAM set localOui "$(uci_get xpon.device.epon_oui)" >/dev/null 2>&1
		[ -n "$(uci_get xpon.device.epon_ven_info)" ] && $OAM set localVenInfo "$(uci_get xpon.device.epon_ven_info)" >/dev/null 2>&1
	fi

	# 让共享内存配置生效。
	if [ "$mode" = "EPON" ]; then
		# XEPON/EPON：重启 OAM 引擎
		killall epon_oam >/dev/null 2>&1
		rm -f /tmp/epon_oam.pid
		sleep 1
		killall ponmgr_cfg >/dev/null 2>&1
		$PONMGR &
		$EPON_OAM &
	else
		# GPON：认证属性（尤其 vendorId/equipmentId）写入共享配置后只需 reconfig。
		# 不能在 LuCI 保存请求中 kill/restart omci/ponmgr，否则 PON 短断并导致页面登出。
		# 设备未运行时由 xpon-app 开机流程负责拉起，不在这里强制重启。
		[ -x "$OMCID" ] && $OMCID set reconfig >/dev/null 2>&1
	fi
}

apply_network() {
	uci commit network
	/etc/init.d/network reload
}

apply_mac() {
	# pon 是业务侧 Ethernet 接口；GPON/XGPON/XGSPON 的 PLOAM/OMCI
	# 注册身份来自 SN/Registration ID，而不是 Ethernet MAC。
	# EPON 的 MPCP ONU MAC 则由驱动启动时通过 get_ethaddr() 取得。
	local mode pmac ba ba_raw newba old_eth read_eth read_ba read_ba_eth
	local backup_dir backup_stamp backup_path backup_tmp
	mode=$(uci_get network.xpon_auth.pon_mode)
	[ "$mode" = EPON ] || mode=$(uci_get xpon.device.pon_mode)
	[ "$mode" = EPON ] || mode=GPON
	pmac=$(uci_get xpon.device.pon_mac)
	[ -n "$pmac" ] || pmac=$(sed -n 's/^wan_mac=//p' /tmp/dsd.env 2>/dev/null | tr -d "'\"" | head -1)
	case "$pmac" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) : ;;
		*)
			[ "$mode" = EPON ] && {
				echo "EPON 注册 MAC 无效，且未取得有效 DSD wan_mac" >&2
				return 1
			}
			logger -t xpon "GPON 业务接口 MAC 未配置且 DSD wan_mac 无效，保持 pon 当前地址"
			return 0
			;;
	esac
	pmac=$(printf '%s' "$pmac" | tr 'a-f' 'A-F')

	if [ "$mode" != EPON ]; then
		ifconfig pon hw ether "$pmac" 2>/dev/null || {
			echo "设置 pon 业务接口 MAC 失败" >&2
			return 1
		}
		logger -t xpon "GPON 业务接口 MAC 已设置：pon=$pmac；未修改 U-Boot ethaddr"
		return 0
	fi

	command -v fw_setenv >/dev/null 2>&1 && command -v fw_printenv >/dev/null 2>&1 || {
		echo "fw_setenv/fw_printenv 不可用（缺 uboot-envtools 或 fw_env.config）" >&2
		return 1
	}

	ba_raw=$(fw_printenv -n bootargs 2>/dev/null)
	ba=$ba_raw
	while [ "${ba#bootargs=}" != "$ba" ]; do ba=${ba#bootargs=}; done
	[ -n "$ba" ] || { echo "读取 env bootargs 失败" >&2; return 1; }
	case " $ba " in
		*" ethaddr="*) newba=$(printf '%s' "$ba" | sed "s/ethaddr=[^[:space:]]*/ethaddr=$pmac/") ;;
		*) newba="$ba ethaddr=$pmac" ;;
	esac

	backup_dir=/etc/xpon-env-backups
	backup_stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null)
	[ -n "$backup_stamp" ] || backup_stamp=unknown
	backup_path="$backup_dir/ponmac-$backup_stamp-$$.bak"
	backup_tmp="$backup_path.tmp"
	umask 077
	mkdir -p "$backup_dir" || { echo "创建 U-Boot env 备份目录失败" >&2; return 1; }
	chmod 700 "$backup_dir" 2>/dev/null || true
	fw_printenv > "$backup_tmp" 2>/dev/null || {
		rm -f "$backup_tmp"
		echo "备份 U-Boot env 失败，拒绝修改注册 MAC" >&2
		return 1
	}
	mv "$backup_tmp" "$backup_path" || {
		rm -f "$backup_tmp"
		echo "保存 U-Boot env 备份失败，拒绝修改注册 MAC" >&2
		return 1
	}

	old_eth=$(fw_printenv -n ethaddr 2>/dev/null | tr 'a-f' 'A-F')
	[ "$old_eth" = "$pmac" ] || fw_setenv ethaddr "$pmac" || {
		echo "写入 env ethaddr 失败；原环境已备份到 $backup_path" >&2
		return 1
	}
	[ "$newba" = "$ba" ] || fw_setenv bootargs "$newba" || {
		echo "写入 env bootargs ethaddr 失败；原环境已备份到 $backup_path" >&2
		return 1
	}

	read_eth=$(fw_printenv -n ethaddr 2>/dev/null | tr 'a-f' 'A-F')
	read_ba=$(fw_printenv -n bootargs 2>/dev/null)
	read_ba_eth=$(printf '%s\n' "$read_ba" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ethaddr=/) { print substr($i, 9); exit } }' | tr 'a-f' 'A-F')
	[ "$read_eth" = "$pmac" ] || {
		echo "env ethaddr 回读失败：期望 $pmac，实际 ${read_eth:-空}" >&2
		return 1
	}
	[ "$read_ba_eth" = "$pmac" ] || {
		echo "env bootargs 回读失败：期望 ethaddr=$pmac，实际 ${read_ba_eth:-空}" >&2
		return 1
	}

	ifconfig pon hw ether "$pmac" 2>/dev/null || true
	logger -t xpon "EPON MPCP 注册 MAC env 写入并回读成功：ethaddr=$pmac backup=$backup_path"
}

apply_leds() {
	local led
	# sts_green 常亮修复：缺 aliases 时设备默认闪绿。
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
# PON 模式来自 onu_type bootarg 字节：
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
	local ba ba_raw newba
	ba_raw=$(fw_printenv -n bootargs 2>/dev/null)
	ba=$ba_raw
	while [ "${ba#bootargs=}" != "$ba" ]; do ba=${ba#bootargs=}; done
	if [ -n "$ba" ]; then
		newba=$(printf '%s' "$ba" | sed "s/onu_type=[0-9a-fA-F]*/onu_type=$val/")
		[ -n "$newba" ] && [ "$newba" != "$ba_raw" ] && fw_setenv bootargs "$newba"
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
	restore-auth) restore_auth ;;
	auth)    apply_auth ;;
	network) apply_network ;;
	mac)     apply_mac ;;
	leds)    apply_leds ;;
	iptv)    apply_iptv ;;
	ponmode) apply_ponmode "$2" ;;
	all)
		restore_auth
		apply_auth
		apply_mac
		apply_network
		apply_leds
		;;
	*) echo "usage: $0 {restore-auth|auth|network|mac|leds|iptv|ponmode <hex>|all}" >&2; exit 1 ;;
esac

exit 0
