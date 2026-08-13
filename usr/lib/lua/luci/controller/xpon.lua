-- xpon-luci：XG2010G PON 配置面板（LOID/SN/MAC/VLAN/业务）
-- 手写 HTML 表单模式（stock 21.02 裁剪版无 luci.model.cbi 库），
-- 结构参考 8311-was-110-firmware-builder 的 controller/8311.lua。

module("luci.controller.xpon", package.seeall)

local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci"
local ltemplate = require "luci.template"

local formvalue = http.formvalue

-- 业务标识与中文名（顺序即页面展示顺序）
local service_defs = {
	{ id = "tr069",   name = "TR069 管理" },
	{ id = "internet", name = "INTERNET 上网" },
	{ id = "iptv",    name = "IPTV 电视" },
	{ id = "voice",   name = "VOICE 语音" },
}

-- 目标接口名（netifd 原生接口，device 指向 pon.<vid>）
local service_ifaces = {
	tr069 = "tr069",
	internet = "wan",
	iptv = "iptv",
	voice = "voice",
}

-- PON 模式（onu_type bootarg 字节，SDK `dump_pon_type_mode_info` 官方解码）：
--   bits[1:0]=ONU 类型：0=unknown 1=SFU 2=HGU（ra_nat_multicast.c 只在 HGU=0x2 时做组播收敛）
--   bit2=ComboPon  bit3=bbf247
--   bits[7:4]=PON 模式：1=GPON 2=EPON 6=XGPON(10G/2.5G) 7=XGSPON(10G 对称)
-- 本机 TTL 当前 61 = SFU+XGPON（uboot 仓库 README 的“61=HGU”有误）；
-- 联通 HGU 家庭网关（LAN 桥接+VEIP+IPTV 组播）应切 62。
local pon_modes = {
	{ id = "62", name = "HGU + XGPON",  desc = "推荐（联通 HGU 家庭网关）：10G/2.5G 不对称，LAN 桥接+VEIP+组播完整" },
	{ id = "61", name = "SFU + XGPON",  desc = "本机 TTL 当前值：SFU 桥形态，无 VEIP/组播引擎，仅适合纯桥/实验" },
	{ id = "72", name = "HGU + XGSPON", desc = "10G 对称（XGS-PON 端口）；出厂默认 71 的 HGU 对应值" },
	{ id = "71", name = "SFU + XGSPON", desc = "出厂默认：SFU 桥形态 + 10G 对称（uboot README 误标为 HGU）" },
	{ id = "12", name = "HGU + GPON",   desc = "GPON-only 端口（实验，需 OLT 为 GPON）" },
	{ id = "11", name = "SFU + GPON",   desc = "GPON-only 端口（实验，需 OLT 为 GPON）" },
}

function index()
	entry({"admin", "xpon"}, firstchild(), "XG2010G PON", 39).dependent = false
	entry({"admin", "xpon", "auth"}, call("action_auth"), "认证", 1)
	entry({"admin", "xpon", "mode"}, call("action_mode"), "模式", 2)
	entry({"admin", "xpon", "services"}, call("action_services"), "业务", 3)
	entry({"admin", "xpon", "vlan"}, call("action_vlan"), "VLAN", 4)
	entry({"admin", "xpon", "status"}, call("action_status"), "状态", 5)

	entry({"admin", "xpon", "save"}, post_on({ data = true }, "action_save")).leaf = true
	entry({"admin", "xpon", "status", "data"}, call("action_status_data")).leaf = true
end

------------------------------------------------------------------------
-- 读取辅助
------------------------------------------------------------------------

local function uget(config, section, option)
	return uci.cursor():get(config, section, option)
end

local function section_exists(config, section)
	return uci.cursor():get_all(config, section) ~= nil
end

local function ensure_section(config, section, stype)
	local u = uci.cursor()
	if not section_exists(config, section) then
		u:add(config, stype, section)
	end
end

local function sh(cmd)
	return util.trim(sys.exec(cmd .. " 2>&1") or "")
end

function auth_values()
	local u = uci.cursor()
	local v = {}
	v.pon_mode          = uget("network", "xpon_auth", "pon_mode") or "GPON"
	v.auth_type_g       = uget("network", "xpon_auth", "auth_type_g") or "sn"
	v.loid              = uget("network", "xpon_auth", "loid") or ""
	v.loid_password     = uget("network", "xpon_auth", "loid_password") or ""
	v.def_sn            = uget("network", "xpon_auth", "def_sn") or ""
	v.sn                = uget("network", "xpon_auth", "sn") or ""
	v.xpon_sn_auth_type = uget("network", "xpon_auth", "xpon_sn_auth_type") or "ascii"
	v.sn_ascii_password = uget("network", "xpon_auth", "sn_ascii_password") or ""
	v.sn_hex_password   = uget("network", "xpon_auth", "sn_hex_password") or ""
	v.vendor_id         = uget("xpon", "device", "vendor_id") or ""
	v.equipment_id      = uget("xpon", "device", "equipment_id") or ""
	v.onu_version       = uget("xpon", "device", "onu_version") or ""
	v.omcc_version      = uget("xpon", "device", "omcc_version") or ""
	v.pon_mac           = uget("xpon", "device", "pon_mac") or ""
	return v
end

function service_values(svc)
	local v = {}
	v.enable       = uget("xpon", svc, "enable") or "0"
	v.vlan         = uget("xpon", svc, "vlan") or ""
	v.pbit         = uget("xpon", svc, "pbit") or "0"
	v.mtu          = uget("xpon", svc, "mtu") or "1500"
	v.proto        = uget("xpon", svc, "proto") or "ipoe"
	v.username     = uget("xpon", svc, "username") or ""
	v.password     = uget("xpon", svc, "password") or ""
	v.ipaddr       = uget("xpon", svc, "ipaddr") or ""
	v.netmask      = uget("xpon", svc, "netmask") or ""
	v.gateway      = uget("xpon", svc, "gateway") or ""
	v.metric       = uget("xpon", svc, "metric") or "10"
	v.mcast_vlan   = uget("xpon", svc, "mcast_vlan") or ""
	v.stb_port     = uget("xpon", svc, "stb_port") or ""
	v.iptv_port    = uget("xpon", svc, "iptv_port") or ""
	v.igmp         = uget("xpon", svc, "igmp") or "snooping"
	v.igmp_version = uget("xpon", svc, "igmp_version") or "2"
	v.igmp_fastleave = uget("xpon", svc, "igmp_fastleave") or "1"
	return v
end

function ponmode_values()
	local env_val = sh("fw_printenv onu_type 2>/dev/null")
	local cmdline_val = sh("grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1")
	cmdline_val = cmdline_val:match("=(.*)$") or cmdline_val
	return {
		env      = env_val,
		cmdline  = cmdline_val,
		sys_mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null"),
		ko       = sh("lsmod 2>/dev/null | grep -E 'xpon(_10g)?' | awk '{print $1}' | tr '\\n' ' '"),
		bbf_gpon = sh("cat /proc/gpon/bbf247Flag 2>/dev/null"),
		bbf_xgpon = sh("cat /proc/xgpon/bbf247Flag 2>/dev/null"),
		modes    = pon_modes,
	}
end

------------------------------------------------------------------------
-- 保存
------------------------------------------------------------------------

local function validate_vid(s)
	local n = tonumber(s or "")
	return n ~= nil and n >= 1 and n <= 4094
end

local function save_auth(fv)
	local u = uci.cursor()

	ensure_section("network", "xpon_auth", "xpon_auth")
	u:set("network", "xpon_auth", "pon_mode", fv("pon_mode") or "GPON")
	u:set("network", "xpon_auth", "auth_type_g", fv("auth_type_g") or "sn")
	u:set("network", "xpon_auth", "loid", fv("loid") or "")
	if fv("loid_password") and fv("loid_password") ~= "" then
		u:set("network", "xpon_auth", "loid_password", fv("loid_password"))
	end
	u:set("network", "xpon_auth", "def_sn", fv("def_sn") or "")
	u:set("network", "xpon_auth", "sn", fv("sn") or "")
	u:set("network", "xpon_auth", "xpon_sn_auth_type", fv("xpon_sn_auth_type") or "ascii")
	if fv("sn_ascii_password") and fv("sn_ascii_password") ~= "" then
		u:set("network", "xpon_auth", "sn_ascii_password", fv("sn_ascii_password"))
	end
	if fv("sn_hex_password") and fv("sn_hex_password") ~= "" then
		u:set("network", "xpon_auth", "sn_hex_password", fv("sn_hex_password"))
	end

	ensure_section("xpon", "device", "auth")
	u:set("xpon", "device", "vendor_id", fv("vendor_id") or "")
	u:set("xpon", "device", "equipment_id", fv("equipment_id") or "")
	u:set("xpon", "device", "onu_version", fv("onu_version") or "")
	u:set("xpon", "device", "omcc_version", fv("omcc_version") or "")
	u:set("xpon", "device", "pon_mac", fv("pon_mac") or "")

	u:save("network")
	u:commit("network")
	u:save("xpon")
	u:commit("xpon")
end

local function save_services(fv)
	local u = uci.cursor()

	for _, sd in ipairs(service_defs) do
		local svc = sd.id
		local iface = service_ifaces[svc]
		local enable = (fv(svc .. "_enable") == "1") and "1" or "0"
		local vid = fv(svc .. "_vlan") or ""
		local proto = fv(svc .. "_proto") or "ipoe"

		ensure_section("xpon", svc, "service")
		u:set("xpon", svc, "enable", enable)
		u:set("xpon", svc, "vlan", vid)
		u:set("xpon", svc, "pbit", fv(svc .. "_pbit") or "0")
		u:set("xpon", svc, "mtu", fv(svc .. "_mtu") or "1500")
		u:set("xpon", svc, "proto", proto)
		u:set("xpon", svc, "username", fv(svc .. "_username") or "")
		if fv(svc .. "_password") and fv(svc .. "_password") ~= "" then
			u:set("xpon", svc, "password", fv(svc .. "_password"))
		end
		u:set("xpon", svc, "ipaddr", fv(svc .. "_ipaddr") or "")
		u:set("xpon", svc, "netmask", fv(svc .. "_netmask") or "")
		u:set("xpon", svc, "gateway", fv(svc .. "_gateway") or "")
		u:set("xpon", svc, "metric", fv(svc .. "_metric") or "10")
		u:set("xpon", svc, "mcast_vlan", fv(svc .. "_mcast_vlan") or "")
		u:set("xpon", svc, "stb_port", fv(svc .. "_stb_port") or "")
		u:set("xpon", svc, "iptv_port", fv(svc .. "_iptv_port") or "")
		u:set("xpon", svc, "igmp", fv(svc .. "_igmp") or "snooping")
		u:set("xpon", svc, "igmp_version", fv(svc .. "_igmp_version") or "2")
		if svc == "iptv" then
			u:set("xpon", svc, "igmp_fastleave", fv(svc .. "_igmp_fastleave") or "0")
		end

		-- 同步生成/删除 network 段
		if enable == "1" then
			ensure_section("network", svc .. "_vlan", "wan_vlan")
			u:set("network", svc .. "_vlan", "vlan_id", vid)
			u:set("network", svc .. "_vlan", "payload", "routed")

			ensure_section("network", iface, "interface")
			u:set("network", iface, "device", "pon." .. vid)
			u:set("network", iface, "mtu", fv(svc .. "_mtu") or "1500")
			if proto == "pppoe" then
				u:set("network", iface, "proto", "pppoe")
				u:set("network", iface, "username", fv(svc .. "_username") or "")
				u:set("network", iface, "password", fv(svc .. "_password") or "")
			elseif proto == "static" then
				u:set("network", iface, "proto", "static")
				u:set("network", iface, "ipaddr", fv(svc .. "_ipaddr") or "")
				u:set("network", iface, "netmask", fv(svc .. "_netmask") or "")
				u:set("network", iface, "gateway", fv(svc .. "_gateway") or "")
				u:set("network", iface, "metric", fv(svc .. "_metric") or "10")
			else
				u:set("network", iface, "proto", "dhcp")
				u:set("network", iface, "metric", fv(svc .. "_metric") or "10")
			end
			if svc == "iptv" and fv("iptv_igmp") == "proxy" then
				u:set("network", "iptv", "igmp_proxy", "1")
			else
				u:delete("network", "iptv", "igmp_proxy")
			end
		else
			-- 禁用业务：删对应 wan_vlan 段与接口（防旧规则残留/风暴）
			u:delete("network", svc .. "_vlan")
			u:delete("network", iface)
		end
	end

	u:save("network")
	u:commit("network")
	u:save("xpon")
	u:commit("xpon")
end

local function save_vlan(fv)
	local u = uci.cursor()
	ensure_section("xpon", "rules", "fallback")
	u:set("xpon", "rules", "enable", fv("fallback_enable") == "1" and "1" or "0")
	u:set("xpon", "rules", "gem_base", fv("gem_base") or "10")
	u:save("xpon")
	u:commit("xpon")
end

function action_save()
	local page = formvalue("page") or "auth"
	local err = nil

	if page == "auth" then
		local loid = formvalue("loid") or ""
		local sn = formvalue("sn") or ""
		if #loid > 24 then
			err = "loid"
		elseif formvalue("auth_type_g") == "sn" and #sn == 0 then
			err = "sn"
		else
			save_auth(formvalue)
		end
	elseif page == "services" then
		local bad = nil
		local seen_vids = {}
		for _, sd in ipairs(service_defs) do
			local svc = sd.id
			if formvalue(svc .. "_enable") == "1" then
				local vid = formvalue(svc .. "_vlan") or ""
				if not validate_vid(vid) then
					bad = svc .. "_vlan"
					break
				end
				if seen_vids[vid] then
					bad = svc .. "_vlan_dup_" .. vid
					break
				end
				seen_vids[vid] = sd.name
				local mcast = formvalue(svc .. "_mcast_vlan") or ""
				if #mcast > 0 and not validate_vid(mcast) then
					bad = svc .. "_mcast_vlan"
					break
				end
				local mtu = tonumber(formvalue(svc .. "_mtu") or "1500")
				if mtu == nil or mtu < 576 or mtu > 9600 then
					bad = svc .. "_mtu"
					break
				end
				if formvalue(svc .. "_proto") == "pppoe" and #(formvalue(svc .. "_username") or "") == 0 then
					bad = svc .. "_username"
					break
				end
			end
		end
		if bad then
			err = bad
		else
			save_services(formvalue)
		end
	elseif page == "vlan" then
		save_vlan(formvalue)
		if formvalue("action") == "fallback" then
			sys.call("/usr/bin/xpon-fallback.sh once >/dev/null 2>&1")
			http.redirect(dispatcher.build_url("admin/xpon/vlan?act=fallback"))
		elseif formvalue("action") == "refresh" then
			http.redirect(dispatcher.build_url("admin/xpon/vlan?act=refresh"))
		else
			sys.call("/usr/bin/xpon-apply.sh network >/dev/null 2>&1")
			http.redirect(dispatcher.build_url("admin/xpon/vlan?act=save"))
		end
		return
	elseif page == "mode" then
		local val = formvalue("custom_onu_type") or ""
		if #val == 0 then
			val = formvalue("onu_type") or ""
		end
		val = val:lower()
		if not val:match("^%x%x$") then
			http.redirect(dispatcher.build_url("admin/xpon/mode?err=hex"))
			return
		end
		local rc = sys.call("/usr/bin/xpon-apply.sh ponmode %s >/dev/null 2>&1" % { val })
		if rc ~= 0 then
			http.redirect(dispatcher.build_url("admin/xpon/mode?err=apply"))
			return
		end
		if formvalue("apply") == "reboot" then
			http.prepare_content("text/html; charset=utf-8")
			http.write("<html><body><h3>onu_type=" .. val .. " 已写入 U-Boot env，正在重启…</h3><p>约 1 分钟后重新登录。若无法注册，按复位键进 U-Boot 用 <code>setenv onu_type 61; saveenv; reset</code> 恢复。</p></body></html>")
			sys.call("(sleep 2; reboot) &")
			return
		end
		http.redirect(dispatcher.build_url("admin/xpon/mode?saved=1"))
		return
	end

	if err then
		http.redirect(dispatcher.build_url("admin/xpon/" .. page .. "?err=" .. err))
		return
	end

	-- 应用：auth 页立即下发并重启 OMCI；services/vlan 页 reload network/补规则
	if page == "auth" then
		sys.call("/usr/bin/xpon-apply.sh all >/dev/null 2>&1")
	elseif page == "services" then
		sys.call("/usr/bin/xpon-apply.sh network >/dev/null 2>&1")
		sys.call("/usr/bin/xpon-iptv.sh >/dev/null 2>&1")
	end

	http.redirect(dispatcher.build_url("admin/xpon/" .. page .. "?saved=1"))
end

------------------------------------------------------------------------
-- 页面
------------------------------------------------------------------------

function action_auth()
	ltemplate.render("xpon/auth", {
		v = auth_values(),
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
	})
end

function action_services()
	local services = {}
	for _, sd in ipairs(service_defs) do
		services[#services + 1] = {
			id = sd.id,
			name = sd.name,
			v = service_values(sd.id),
		}
	end
	ltemplate.render("xpon/services", {
		services = services,
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
	})
end

function action_mode()
	ltemplate.render("xpon/mode", {
		v = ponmode_values(),
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
	})
end

function action_vlan()
	ltemplate.render("xpon/vlan", {
		fallback_enable = uget("xpon", "rules", "enable") or "0",
		gem_base = uget("xpon", "rules", "gem_base") or "10",
		gem_up = sh("/userfs/bin/gponmapcmd showGemPortRule"),
		gem_down = sh("/userfs/bin/gponmapcmd showDownRule"),
		ponvlan = sh("/userfs/bin/ponvlancmd showrule 1; /userfs/bin/ponvlancmd showrule 3; /userfs/bin/ponvlancmd showrule 4"),
		bridge = sh("brctl show"),
		act = formvalue("act"),
	})
end

function action_status()
	ltemplate.render("xpon/status")
end

function action_status_data()
	local out = {}
	local function sec(title, cmd)
		out[#out + 1] = "==== " .. title .. " ===="
		out[#out + 1] = sh(cmd)
		out[#out + 1] = ""
	end

	sec("认证参数 (omcicfgCmd)",
		"/userfs/bin/omcicfgCmd get loid; /userfs/bin/omcicfgCmd get sn; /userfs/bin/omcicfgCmd get vendor_id; /userfs/bin/omcicfgCmd get equipment_id; /userfs/bin/omcicfgCmd get onu_version; /userfs/bin/omcicfgCmd get omcc_version")
	sec("PON 接口",
		"ifconfig pon 2>/dev/null | head -6; ip link show pon 2>/dev/null | head -3")
	sec("OMCC / GEM / TCONT",
		"/userfs/bin/ponmgr gpon get omcc 2>&1; /userfs/bin/ponmgr gpon get gemport 2>&1; /userfs/bin/ponmgr gpon get tcont 2>&1")
	sec("GEM 上行映射",
		"/userfs/bin/gponmapcmd showGemPortRule 2>&1")
	sec("GEM 下行映射",
		"/userfs/bin/gponmapcmd showDownRule 2>&1")
	sec("PON VLAN 规则",
		"/userfs/bin/ponvlancmd showrule 1 2>&1; /userfs/bin/ponvlancmd showrule 3 2>&1")
	sec("LED 状态",
		"for d in /sys/class/leds/*/brightness; do echo $d=$(cat $d 2>/dev/null); done")
	sec("接口状态",
		"ifstatus wan 2>/dev/null | head -c 600; echo; ip addr show 2>/dev/null | grep -E '^[0-9]+:|inet ' | head -40")
	sec("最近 PON 状态变化",
		"dmesg 2>/dev/null | grep ponTime | tail -5")
	sec("BBF247 标志",
		"cat /proc/xgpon/bbf247Flag 2>/dev/null; cat /proc/gpon/bbf247Flag 2>/dev/null")
	sec("PON 模式 (onu_type)",
		"echo -n 'env: '; fw_printenv onu_type 2>/dev/null || echo N/A; echo -n 'cmdline: '; grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1; echo -n 'sys_xpon_mode: '; cat /proc/tc3162/sys_xpon_mode 2>/dev/null || echo N/A; lsmod 2>/dev/null | grep -E 'xpon(_10g)?' | awk '{print $1}'")
	sec("IPTV 组播 (xponigmpcmd / ecnt_igmp_cmd)",
		"/userfs/bin/xponigmpcmd igmp_get_onu_type 2>&1; /userfs/bin/xponigmpcmd igmp_get_mulvlan_cnt 2>&1; /userfs/bin/xponigmpcmd igmp_get_mulvlan_id 2>&1; /userfs/bin/xponigmpcmd igmp_get_fwdmode 2>&1; /userfs/bin/xponigmpcmd igmp_get_xpon_mode 2>&1; /userfs/bin/ecnt_igmp_cmd get_mode 2>&1; /userfs/bin/ecnt_igmp_cmd get_snooping 2>&1")

	http.prepare_content("text/plain; charset=utf-8")
	http.write(table.concat(out, "\n"))
end
