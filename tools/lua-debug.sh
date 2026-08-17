#!/bin/sh
set -eu

LUA_BIN="${LUA_BIN:-${HOME}/.local/bin}"
LUA="${LUA_BIN}/lua"
LUAC="${LUA_BIN}/luac"

if [ ! -x "$LUA" ] || [ ! -x "$LUAC" ]; then
	echo "Lua 5.1 not found in $LUA_BIN" >&2
	echo "Install it to ~/.local/bin or set LUA_BIN." >&2
	exit 1
fi

case "${1:-check}" in
	check)
		"$LUAC" -p usr/lib/lua/luci/controller/xpon.lua
		for file in $(find lib usr -type f -name '*.lua' -print); do
			"$LUAC" -p "$file"
		done
		echo "Lua 5.1 syntax: OK"
		;;
	repl)
		exec "$LUA" -i
		;;
	version)
		"$LUA" -v
		"$LUAC" -v
		;;
	*)
		echo "Usage: $0 [check|repl|version]" >&2
		exit 2
		;;
esac
