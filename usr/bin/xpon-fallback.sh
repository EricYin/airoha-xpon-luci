#!/bin/sh
# xpon-fallback.sh [once]
#
# OLT 未通过 OMCI 自动下发 GEM/ponvlan 规则时兜底补表。
# 安全红线（防重复/防风暴）：
#   * 只加不删；同 gemPort/同 VID 已存在（含 OLT 下发）则跳过；
#   * 手工规则一律使用 gemPort >= xpon.fallback.gem_base（默认 10），
#     避开 OLT 自动分配的 gemPort；
#   * 默认关闭（xpon.fallback.enable='0'），需在 LuCI“VLAN 表”页显式开启。
# 无参数 = 守护模式（每 60s 检查一次）；once = 单次检查后退出。

CONF=/etc/config/xpon
[ -f "$CONF" ] || exit 0
[ "$(uci -q get xpon.fallback.enable)" = "1" ] || exit 0

GEM_BASE=$(uci -q get xpon.fallback.gem_base)
GEM_BASE=${GEM_BASE:-10}
[ "$GEM_BASE" -lt 10 ] 2>/dev/null && GEM_BASE=10

# showGemPortRule 表头：tagFlag uni vid dscp pbit gemPort
gem_used() { # $1=gemPort -> 0 已占用
	gponmapcmd showGemPortRule 2>/dev/null | awk -v g="$1" '
		$1 ~ /^[0-9]+$/ && $NF == g { found=1 }
		END { exit (found ? 0 : 1) }'
}

add_service_rules() {
	local svc gem vid
	for svc in tr069 internet iptv voice; do
		[ "$(uci -q get xpon.$svc.enable)" = "1" ] || continue
		vid=$(uci -q get xpon.$svc.vlan)
		[ -n "$vid" ] || continue
		gem=$GEM_BASE
		while gem_used "$gem"; do gem=$((gem + 1)); done
		# tagCtl=0xb(压 802.1p) tagFlag=1(打 VLAN 标签) userPort=3(VEIP)
		gponmapcmd addGemPortRule tagCtl 0xb tagFlag 1 userPort 3 vid "$vid" dscp 0 pbit 0 gemPort "$gem" >/dev/null 2>&1
		gponmapcmd addDownRule "$gem" 0x0f 0 0 1 1 >/dev/null 2>&1
		GEM_BASE=$((gem + 1))
	done
}

case "${1:-daemon}" in
	once) add_service_rules ;;
	*)
		while :; do
			add_service_rules
			sleep 60
		done
		;;
esac

exit 0
