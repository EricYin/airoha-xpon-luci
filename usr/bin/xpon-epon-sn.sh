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
	*)
		fail "用法：$0 get | set XX:XX:XX:XX:XX:XX"
		;;
esac
