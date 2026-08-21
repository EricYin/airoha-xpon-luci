#!/bin/sh
# Keep GPON runtime-only OMCI identity fields aligned after omci restarts.

OMCI=/userfs/bin/omcicfgCmd
PIDFILE=/var/run/xpon-gpon-identity-watch.pid

fail() {
	echo "$*" >&2
	exit 1
}

current_pon_mode() {
	local sys_mode onu_type onu_high
	sys_mode=$(cat /proc/tc3162/sys_xpon_mode 2>/dev/null)
	case "$sys_mode" in
		1|6|7) printf '%s' GPON; return 0 ;;
		2|3|4|5|12) printf '%s' EPON; return 0 ;;
	esac
	onu_type=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^onu_type=/) { print substr($i, 10); exit } }' /proc/cmdline 2>/dev/null)
	case "$onu_type" in
		[0-9A-Fa-f][0-9A-Fa-f]) : ;;
		*) onu_type=$(fw_printenv -n onu_type 2>/dev/null) ;;
	esac
	case "$onu_type" in [0-9A-Fa-f][0-9A-Fa-f]) : ;; *) return 1 ;; esac
	onu_high=${onu_type%?}
	case "$onu_high" in
		1|6|7) printf '%s' GPON ;;
		2|3|4|5|c|C) printf '%s' EPON ;;
		*) return 1 ;;
	esac
}

gpon_sn() {
	local has_private v
	has_private=$(uci -q get xpon.device.pon_mode)
	v=$(uci -q get xpon.device.gpon_sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get xpon.device.sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get xpon.device.def_sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get network.xpon_auth.sn)
	[ -n "$v" ] || [ -n "$has_private" ] || v=$(uci -q get network.xpon_auth.def_sn)
	printf '%s' "$v" | tr -d '[:space:]' | tr 'a-z' 'A-Z'
}

valid_pon_sn() {
	[ "${#1}" -eq 12 ] || return 1
	vendor=${1%????????}
	serial=${1#????}
	case "$vendor" in *[!A-Z0-9]*|'') return 1 ;; esac
	case "$serial" in *[!0-9A-F]*|'') return 1 ;; esac
	return 0
}

omci_value() {
	"$OMCI" get "$1" 2>/dev/null |
		sed -n 's/^[^=:]*[=:][[:space:]]*//p' | head -1
}

repair_runtime_drift() {
	local sn vendor have_sn have_vendor
	sn=$(gpon_sn)
	valid_pon_sn "$sn" || return 0
	vendor=${sn%????????}
	have_sn=$(omci_value sn | tr -d '[:space:]' | tr 'a-z' 'A-Z')
	have_vendor=$(omci_value vendorId | tr -d '[:space:]' | tr 'a-z' 'A-Z')
	if [ "$have_sn" = "$sn" ] && [ "$have_vendor" = "$vendor" ]; then
		return 0
	fi
	if /usr/bin/xpon-auth-native.sh >/dev/null 2>&1; then
		logger -t xpon "GPON OMCI 身份漂移已自动重放：sn=$sn vendorId=$vendor（此前 sn=${have_sn:-空} vendorId=${have_vendor:-空}）"
		return 0
	fi
	logger -t xpon "GPON OMCI 身份漂移重放失败，详见 /tmp/xpon-auth-native.log"
	return 1
}

watch_identity() {
	local interval oldpid last_pid pid check_elapsed replay_failures drift_failures mode
	interval=${1:-5}
	case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
	[ "$interval" -ge 2 ] 2>/dev/null || interval=2
	oldpid=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		fail "GPON OMCI 身份守护已运行：pid=$oldpid"
	fi
	echo $$ > "$PIDFILE" || fail "无法创建守护 pidfile：$PIDFILE"
	cleanup_watch() {
		[ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"
	}
	trap 'cleanup_watch' 0
	trap 'cleanup_watch; exit 0' 1 2 15

	last_pid=
	check_elapsed=30
	replay_failures=0
	drift_failures=0
	while :; do
		sleep "$interval"
		mode=$(current_pon_mode 2>/dev/null)
		[ "$mode" = GPON ] || { last_pid=; continue; }
		pid=$(pidof omci 2>/dev/null | awk '{print $1}')
		[ -n "$pid" ] || { last_pid=; continue; }

		if [ "$pid" != "$last_pid" ]; then
			"$OMCI" get sn >/dev/null 2>&1 || continue
			if /usr/bin/xpon-auth-native.sh >/dev/null 2>&1; then
				logger -t xpon "GPON OMCI pid=$pid 启动后已自动重放 SN/Vendor ID/设备信息"
				last_pid=$pid
				check_elapsed=0
				replay_failures=0
			else
				replay_failures=$((replay_failures + 1))
				if [ "$replay_failures" -eq 1 ] || [ $((replay_failures % 12)) -eq 0 ]; then
					logger -t xpon "GPON OMCI pid=$pid 身份自动重放失败，详见 /tmp/xpon-auth-native.log"
				fi
			fi
			continue
		fi

		check_elapsed=$((check_elapsed + interval))
		[ "$check_elapsed" -ge 30 ] || continue
		check_elapsed=0
		if repair_runtime_drift; then
			drift_failures=0
		else
			drift_failures=$((drift_failures + 1))
			if [ "$drift_failures" -eq 1 ] || [ $((drift_failures % 10)) -eq 0 ]; then
				logger -t xpon "GPON OMCI 身份漂移修复连续失败 $drift_failures 次"
			fi
		fi
	done
}

case "${1:-watch}" in
	watch) watch_identity "${2:-5}" ;;
	check) repair_runtime_drift ;;
	*) fail "用法：$0 watch [秒] | check" ;;
esac
