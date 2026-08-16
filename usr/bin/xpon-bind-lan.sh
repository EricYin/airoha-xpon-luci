#!/bin/sh
# Reconcile managed Access bridge ports after netifd creates the devices.

port_device() {
	case "$1" in
		lan1) echo eth0.8 ;;
		lan2) echo eth0.7 ;;
		lan3) echo eth0.5 ;;
		lan4) echo eth0.4 ;;
		*) return 1 ;;
	esac
}

service_meta() {
	local interface="$1" meta

	case "$interface" in
		xpon_*)
			meta="xpon_service_${interface#xpon_}"
			if [ "$(uci -q get "network.$meta.interface")" = "$interface" ]; then
				echo "$meta"
				return 0
			fi
			;;
	esac
	for meta in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=xpon_service$/\1/p"); do
		if [ "$(uci -q get "network.$meta.interface")" = "$interface" ]; then
			echo "$meta"
			return 0
		fi
	done
	return 1
}

bind_interface() {
	local interface="$1" key meta port lan_if bridge attempt

	meta=$(service_meta "$interface") || return 0
	[ "$(uci -q get "network.$meta.xpon_managed")" = 1 ] || return 0
	[ "$(uci -q get "network.$meta.mode")" = bridged ] || return 0
	key=$(uci -q get "network.$meta.service_key")
	[ -n "$key" ] || return 0
	port=$(uci -q get "network.$meta.lan_port")
	lan_if=$(port_device "$port") || return 0
	bridge="bx-$key"

	# A network reload is asynchronous. Wait briefly for both devices instead
	# of relying on one particular hotplug ordering.
	attempt=0
	while [ "$attempt" -lt 10 ]; do
		if [ -d "/sys/class/net/$lan_if" ] && [ -d "/sys/class/net/$bridge" ]; then
			brctl delif br-lan "$lan_if" 2>/dev/null
			brctl delif "$bridge" "$lan_if" 2>/dev/null
			if brctl addif "$bridge" "$lan_if" 2>/dev/null; then
				ip link set "$lan_if" up
				logger -t xpon-services "bound $port ($lan_if) to $interface ($bridge)"
				return 0
			fi
		fi
		attempt=$((attempt + 1))
		sleep 1
	done

	logger -t xpon-services "failed to bind $port ($lan_if) to $interface ($bridge)"
	return 1
}

bind_all() {
	local meta interface rc=0
	for meta in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=xpon_service$/\1/p"); do
		[ "$(uci -q get "network.$meta.enable")" = 1 ] || continue
		interface=$(uci -q get "network.$meta.interface")
		[ -n "$interface" ] || continue
		bind_interface "$interface" || rc=1
	done
	return "$rc"
}

case "${1:-all}" in
	all) bind_all ;;
	bind) bind_interface "$2" ;;
	*) echo "usage: $0 {all|bind INTERFACE}" >&2; exit 2 ;;
esac
