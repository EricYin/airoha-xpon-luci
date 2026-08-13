#!/bin/sh
# xpon-cputemp.sh — EN7581 CPU 温度（XG2010G）
#
# 数据源优先级：
#   1) Linux 标准 thermal_zone（毫摄氏度；本固件通常没有）
#   2) cputemp_cmd（BSP 守护 /tmp/cpu_temp_sock，本 OpenWrt 未运行守护时常回 0，忽略 0）
#   3) /usr/bin/xpon-cputemp（静态二进制，通过 mmap /dev/mem 读取温度寄存器）
#   4) devmem / dd+hexdump 直读（旧包未部署二进制时兜底）
#
# 输出：temp=44.3   或   temp=NA

# --- 1) thermal_zone（标准框架） ---
TZ=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1)
if [ -n "$TZ" ] && [ "$TZ" -gt 0 ] 2>/dev/null; then
	echo "temp=$((TZ / 1000)).$(( (TZ % 1000) / 100 ))"
	exit 0
fi

# --- 2) cputemp_cmd（BSP 守护；0 = 不可用） ---
CN=$(/userfs/bin/cputemp_cmd 2>/dev/null | sed -n 's/.*temp=\[\([-0-9]*\)\].*/\1/p')
if [ -n "$CN" ] && [ "$CN" -gt 0 ] 2>/dev/null; then
	echo "temp=$CN.0"
	exit 0
fi

# --- 3) 静态二进制（首选） ---
if [ -x /usr/bin/xpon-cputemp ]; then
	R=$(/usr/bin/xpon-cputemp 2>/dev/null)
	case "$R" in
		temp=*) echo "$R"; exit 0 ;;
	esac
fi

# --- 4) devmem / dd+hexdump 兜底 ---
command -v devmem >/dev/null 2>&1 || command -v dd >/dev/null 2>&1 || { echo temp=NA; exit 0; }
if command -v devmem >/dev/null 2>&1; then
	rd() { devmem "$1" 32 2>/dev/null; }
	wr() { devmem "$1" 32 "$2" 2>/dev/null; }
else
	rd() { # $1=addr → stdout 十进制
		local b
		b=$(dd if=/dev/mem bs=1 skip=$(( $1 )) count=4 2>/dev/null | hexdump -v -e '1/1 "%02x "')
		set -- $b
		[ $# -ge 4 ] || return 1
		echo $(( (0x$4 << 24) | (0x$3 << 16) | (0x$2 << 8) | 0x$1 ))
	}
	wr() { # $1=addr $2=value
		local v=$2 b0 b1 b2 b3
		b0=$((v & 0xff)); b1=$(((v >> 8) & 0xff)); b2=$(((v >> 16) & 0xff)); b3=$(((v >> 24) & 0xff))
		printf '%b' "\\0$(printf '%03o' $b0)\\0$(printf '%03o' $b1)\\0$(printf '%03o' $b2)\\0$(printf '%03o' $b3)" \
			| dd of=/dev/mem bs=1 seek=$(( $1 )) conv=notrunc 2>/dev/null
	}
fi

# PTP（热敏/efuse）与 SCU（TADC）寄存器基址
PTP=0x1efbd000
SCU=0x1fa20000
PLLRG_PROTECT=0x268
MUX_TADC=0x2ec
DOUT_TADC=0x2f8
MUX_TADC_CPU=0x2fc
DOUT_TADC_CPU=0x308

# 校验可读性
E=$(rd 0x1efbdf20) || { echo temp=NA; exit 0; }   # PTP+0xf20 = PTPSPARE0
[ -n "$E" ] || { echo temp=NA; exit 0; }
K=$(rd 0x1fa20268) || { echo temp=NA; exit 0; }   # PLLRG_PROTECT
[ -n "$K" ] || { echo temp=NA; exit 0; }

# 关闭寄存器写保护（key=0x12）
wr 0x1fa20268 0x12 2>/dev/null

# 复刻 thermal_init()：复位 TADC / TADC_CPU，设置模式
set_tadc_mode() { # $1=MUX 寄存器
	local cur new
	cur=$(rd "$1") || return 1
	# 复位脉冲 bit4: 0 -> 1
	new=$(( (cur & ~16) )) ;        wr "$1" "$new" 2>/dev/null
	new=$(( (cur & ~16) | 16 )) ;   wr "$1" "$new" 2>/dev/null
	# 写入 TADC 采样模式。
	# → (cur & ~0xf3ff) | (0x0390 & 0xf3ff) = (cur & ~0xf3ff) | 0x290
	# 即 bits[9]=1、bits[7]=1、bits[4]=1；bit8 被 0xf3ff 掩码清 0；bits[10:11] 保持原值
	cur=$(rd "$1") || return 1
	new=$(( (cur & ~0xf3ff) | 0x290 )) ; wr "$1" "$new" 2>/dev/null
	return 0
}
set_tadc_mode 0x1fa202ec || { wr 0x1fa20268 "$K" 2>/dev/null; echo temp=NA; exit 0; }
set_tadc_mode 0x1fa202fc || { wr 0x1fa20268 "$K" 2>/dev/null; echo temp=NA; exit 0; }

# 选温度/二极管通道：MUX_TADC bits[3:1] = 0x7（thermal_TADC_mode(0,1,10)）
M=$(rd 0x1fa202ec) || { wr 0x1fa20268 "$K" 2>/dev/null; echo temp=NA; exit 0; }
M=$((M))
wr 0x1fa202ec $(( (M & ~0xe) | 0xe )) 2>/dev/null
wr 0x1fa20268 "$K" 2>/dev/null
usleep 10000 2>/dev/null || sleep 0.01

# efuse code30（PTPSPARE0 高 16 位）；无效时用首次 ADC（NONK 路径，缓存到 /tmp 复用）
E=$((E))
CODE30=0
SLOPE=5710
INIT=550   # NONK
if [ "$E" -ne 0 ]; then
	CODE30=$(( (E >> 16) & 0xffff ))
	F=$(rd 0x1efbdf28)   # PTP+0xf28 = PTPSPARE2：0=CPK/AVS
	F=$((F))
	if [ "$F" -eq 0 ]; then SLOPE=5645; INIT=300; else SLOPE=5710; INIT=620; fi
else
	CACHE=/tmp/xpon-cputemp-code30
	if [ -f "$CACHE" ]; then
		CODE30=$(cat "$CACHE" 2>/dev/null)
		CODE30=${CODE30:-0}
	else
		CODE30=$(rd 0x1fa202f8 2>/dev/null)
		CODE30=$((CODE30))
		echo "$CODE30" > "$CACHE" 2>/dev/null
	fi
fi

# 读 6 次 ADC，去最大最小，中间 4 个平均（ThermalGetT_7581）
MIN=999999999; MAX=0; SUM=0; i=0
while [ "$i" -lt 6 ]; do
	A=$(rd 0x1fa202f8 2>/dev/null)
	[ -n "$A" ] || { echo temp=NA; exit 0; }
	A=$((A))
	[ "$A" -lt "$MIN" ] && MIN=$A
	[ "$A" -gt "$MAX" ] && MAX=$A
	SUM=$((SUM + A))
	i=$((i + 1))
done
AVG=$(( (SUM - MIN - MAX) >> 2 ))

# temp_x10 = 1000*(AVG-CODE30)/SLOPE + INIT；输出 temp=xx.x
TX10=$(( (1000 * (AVG - CODE30)) / SLOPE + INIT ))
SIGN= ; T=$TX10
[ "$T" -lt 0 ] && { SIGN=-; T=$(( -T )); }
echo "temp=$SIGN$((T / 10)).$((T % 10))"
exit 0
