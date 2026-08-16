#!/bin/sh
# Read or override the 6-byte ONU ID carried inside CTC OAM ONUSN.
# This ECONET epon_oam build keeps it in a private, non-PIE BSS object and
# exposes no oamcfgCmd setter. Refuse unknown binaries before touching memory.

BIN=/userfs/bin/epon_oam
EXPECTED_SHA256=7d0d3ef68528a35a93bc4487eda57f88c4221ebb36a7ee8385a3c8ffc2a75415
ONUSN_ADDR=4520363

fail() {
	echo "$*" >&2
	exit 1
}

normalize_mac() {
	printf '%s' "$1" | tr 'a-f' 'A-F' | tr -d ':-'
}

format_mac() {
	printf '%s' "$1" | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)$/\1:\2:\3:\4:\5:\6/'
}

check_binary() {
	[ -r "$BIN" ] || fail "epon_oam 不可读：$BIN"
	command -v sha256sum >/dev/null 2>&1 || fail "缺少 sha256sum，无法安全识别 epon_oam"
	have=$(sha256sum "$BIN" | awk '{print $1}')
	[ "$have" = "$EXPECTED_SHA256" ] || fail "不支持的 epon_oam：sha256=$have"
}

find_pid() {
	pid=$(pidof epon_oam 2>/dev/null | awk '{print $1}')
	[ -n "$pid" ] || fail "epon_oam 未运行"
	[ -r "/proc/$pid/mem" ] || fail "无法访问 /proc/$pid/mem"
}

read_hex() {
	dd if="/proc/$pid/mem" bs=1 skip="$ONUSN_ADDR" count=6 2>/dev/null |
		hexdump -v -e '1/1 "%02X"'
}

write_hex() {
	hex=$1
	i=1
	while [ "$i" -le 11 ]; do
		byte=$(printf '%s' "$hex" | cut -c "$i-$((i + 1))")
		printf "\\$(printf '%03o' "$((0x$byte))")"
		i=$((i + 2))
	done
}

watch_identity() {
	interval=${1:-5}
	case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
	[ "$interval" -ge 2 ] 2>/dev/null || interval=2
	pidfile=/var/run/xpon-epon-sn-watch.pid
	oldpid=$(cat "$pidfile" 2>/dev/null)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		fail "EPON OAM 身份守护已运行：pid=$oldpid"
	fi
	echo $$ > "$pidfile" || fail "无法创建守护 pidfile：$pidfile"
	cleanup_watch() {
		[ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"
	}
	trap 'cleanup_watch' 0
	trap 'cleanup_watch; exit 0' 1 2 15

	last_pid=
	check_elapsed=30
	replay_failures=0
	while :; do
		sleep "$interval"
		mode=$(cat /proc/tc3162/sys_xpon_mode 2>/dev/null)
		case "$mode" in 2|3|4|5|12) ;; *) last_pid=; continue ;; esac
		pid=$(pidof epon_oam 2>/dev/null | awk '{print $1}')
		[ -n "$pid" ] || { last_pid=; continue; }

		if [ "$pid" != "$last_pid" ]; then
			# Wait until the new process has attached its shared state before replay.
			/userfs/bin/oamcfgCmd get mode >/dev/null 2>&1 || continue
			if /usr/bin/xpon-auth-native.sh >/dev/null 2>&1; then
				logger -t xpon "EPON OAM pid=$pid 启动后已自动重放完整身份（含 CTC ONUSN）"
				last_pid=$pid
				check_elapsed=0
				replay_failures=0
			else
				replay_failures=$((replay_failures + 1))
				if [ "$replay_failures" -eq 1 ] || [ $((replay_failures % 12)) -eq 0 ]; then
					logger -t xpon "EPON OAM pid=$pid 身份自动重放失败，详见 /tmp/xpon-auth-native.log"
				fi
			fi
			continue
		fi

		# A same-PID drift is unusual, but some vendor control paths reinitialize
		# the BSS object in place. Check infrequently and write only on mismatch.
		check_elapsed=$((check_elapsed + interval))
		[ "$check_elapsed" -ge 30 ] || continue
		check_elapsed=0
		desired=$(uci -q get xpon.device.epon_serial)
		[ -n "$desired" ] || continue
		desired_hex=$(normalize_mac "$desired")
		case "$desired_hex" in
			????????????) case "$desired_hex" in *[!0-9A-F]*) continue ;; esac ;;
			*) continue ;;
		esac
		have=$("$0" get 2>/dev/null) || continue
		[ "$(normalize_mac "$have")" = "$desired_hex" ] && continue
		if /usr/bin/xpon-auth-native.sh >/dev/null 2>&1; then
			logger -t xpon "检测到 CTC ONUSN 漂移，已重放完整 EPON OAM 身份"
		else
			logger -t xpon "CTC ONUSN 漂移修复失败，详见 /tmp/xpon-auth-native.log"
		fi
	done
}

case "${1:-get}" in
	get)
		check_binary
		find_pid
		hex=$(read_hex)
		[ "${#hex}" -eq 12 ] || fail "读取 CTC ONUSN ONU ID 失败"
		format_mac "$hex"
		;;
	set)
		hex=$(normalize_mac "$2")
		case "$hex" in
			????????????) case "$hex" in *[!0-9A-F]*) fail "EPON 序列号格式错误" ;; esac ;;
			*) fail "EPON 序列号必须为 6 字节 MAC 格式" ;;
		esac
		check_binary
		find_pid
		resumed=0
		resume_oam() {
			[ "$resumed" = 1 ] || kill -CONT "$pid" 2>/dev/null
			resumed=1
		}
		trap 'resume_oam' 0
		trap 'resume_oam; exit 130' 1 2 15
		kill -STOP "$pid" 2>/dev/null || fail "无法暂停 epon_oam"
		write_hex "$hex" | dd of="/proc/$pid/mem" bs=1 seek="$ONUSN_ADDR" count=6 conv=notrunc 2>/dev/null || fail "写入 CTC ONUSN ONU ID 失败"
		kill -CONT "$pid" 2>/dev/null || fail "无法恢复 epon_oam"
		resumed=1
		have=$(read_hex)
		[ "$have" = "$hex" ] || fail "CTC ONUSN ONU ID 回读失败：want=$hex have=$have"
		format_mac "$have"
		;;
	watch)
		watch_identity "${2:-5}"
		;;
	*)
		fail "用法：$0 get | set XX:XX:XX:XX:XX:XX | watch [秒]"
		;;
esac
