-- xpon-luci：PON设置 配置面板（LOID/SN/MAC/VLAN/业务）
-- 手写 HTML 表单模式（stock 21.02 裁剪版无 luci.model.cbi 库），
-- 结构参考 8311-was-110-firmware-builder 的 controller/8311.lua。

module("luci.controller.xpon", package.seeall)

local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci"
local uci_native = require "uci"
local ltemplate = require "luci.template"
local fs = require "nixio.fs"

local formvalue = http.formvalue

-- build_url() 只接受路径段，不能把含 ? 的完整路径作为单个参数传入；
-- 否则该参数会被丢弃并跳到 /cgi-bin/luci，看起来像 session 被登出。
local function xpon_url(page, query)
	local url = dispatcher.build_url("admin", "xpon", page)
	return query and (url .. "?" .. query) or url
end

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

-- PON 模式（onu_type bootarg 字节）：
--   bits[1:0]=ONU 类型：0=unknown 1=SFU 2=HGU（ra_nat_multicast.c 只在 HGU=0x2 时做组播收敛）
--   bit2=ComboPon  bit3=bbf247
--   bits[7:4]=PON 模式：1=GPON 2=EPON(1G) 3=10G/1G-EPON 4=10G/10G-EPON 5=1G/1G-EPON
--               6=XGPON(10G/2.5G) 7=XGSPON(10G 对称) 8~A=NGPON2 B=GPON-SYM C=TURBO-EPON
-- 设备 PON MAC 支持 XEPON 的 10G LLID/MPCP/FEC/DPoE 路径，
-- module_sel.c 把 3/4 映射到 SYS_10G_1G_EPON_MODE / SYS_10G_10G_EPON_MODE；
-- 光模块 EN7572 BOB 为 10G PON 模块（1577/1270nm 与 XEPON 同波长），
-- 但固件 S00 无 XEPON 专用分支（按 XGSPON 加载），且 OAM 引擎需 pon_mode=EPON 才拉起——
-- 故 XEPON 标记为实验性，需 10G-EPON OLT 实测。
-- 本机 TTL 当前 61 = SFU+XGPON（uboot 仓库 README 的“61=HGU”有误）；
-- 联通 HGU 家庭网关（LAN 桥接+VEIP+IPTV 组播）应切 62。
local pon_modes = {
	{ id = "62", name = "HGU + XGPON",  desc = "推荐（联通 HGU 家庭网关）：10G/2.5G 不对称，LAN 桥接+VEIP+组播完整" },
	{ id = "61", name = "SFU + XGPON",  desc = "本机 TTL 当前值：SFU 桥形态，无 VEIP/组播引擎，仅适合纯桥/实验" },
	{ id = "72", name = "HGU + XGSPON", desc = "10G 对称（XGS-PON 端口）；出厂默认 71 的 HGU 对应值" },
	{ id = "71", name = "SFU + XGSPON", desc = "出厂默认：SFU 桥形态 + 10G 对称（uboot README 误标为 HGU）" },
	{ id = "12", name = "HGU + GPON",   desc = "GPON-only 端口（实验，需 OLT 为 GPON）" },
	{ id = "11", name = "SFU + GPON",   desc = "GPON-only 端口（实验，需 OLT 为 GPON）" },
	{ id = "42", name = "HGU + 10G/10G-EPON", desc = "实验：XEPON 对称（IEEE 802.3av 10G-EPON），需 OLT 10G-EPON 口 + OAM 认证" },
	{ id = "41", name = "SFU + 10G/10G-EPON", desc = "实验：XEPON 对称 SFU 形态" },
	{ id = "32", name = "HGU + 10G/1G-EPON",  desc = "实验：XEPON 不对称（10G 下行/1G 上行）" },
	{ id = "31", name = "SFU + 10G/1G-EPON",  desc = "实验：XEPON 不对称 SFU 形态" },
}

-- 认证页“PON 模式”技术选型（onu_type bits[7:4]）：
--   1=GPON、6=XGPON、7=XGSPON 属 OMCI 族（netifd 引擎 pon_mode=GPON）；
--   3=10G/1G-EPON、4=10G/10G-EPON 属 OAM 族（netifd 引擎 pon_mode=EPON）。
-- 具体 HGU/SFU 形态（61/62/71/72/…）由“模式”页 onu_type 决定，本页只管技术族。
local pon_techs = {
	{ id = "GPON",         name = "GPON（OMCI 管理）",             desc = "bits[7:4]=1；OLT 为 GPON 口时选择" },
	{ id = "XGPON",        name = "XGPON 10G/2.5G（OMCI 管理）",    desc = "bits[7:4]=6；本机 TTL 当前 61/62" },
	{ id = "XGSPON",       name = "XGSPON 10G 对称（OMCI 管理）",   desc = "bits[7:4]=7；出厂默认 71/72" },
	{ id = "EPON_10G_1G",  name = "10G/1G-EPON（XEPON 不对称）",    desc = "bits[7:4]=3；OAM 认证（pon_mode=EPON），实验" },
	{ id = "EPON_10G_10G", name = "10G/10G-EPON（XEPON 对称）",     desc = "bits[7:4]=4；OAM 认证（pon_mode=EPON），实验" },
}

-- 技术 ID <-> onu_type bits[7:4]
local pon_tech_bits = {
	GPON = 1, XGPON = 6, XGSPON = 7,
	EPON_10G_1G = 3, EPON_10G_10G = 4,
}
local pon_tech_by_bits = {}
for _id, _bits in pairs(pon_tech_bits) do pon_tech_by_bits[_bits] = _id end

-- 组合 onu_type = (技术 bits << 4) | ONU 类型（1=SFU 2=HGU）
local function onu_type_hex(tech, low)
	local bits = pon_tech_bits[tech] or 6
	return string.format("%02x", bits * 16 + (tonumber(low) or 1))
end

-- 技术族 -> netifd 引擎值（netifd 二进制只认 GPON/EPON 两个字符串）
local function pon_engine_for(ptech)
	if ptech == "EPON_10G_1G" or ptech == "EPON_10G_10G" then
		return "EPON"
	end
	return "GPON"
end

-- PON 模式名（sys_xpon_mode 取值）
local pon_mode_names = {
	[0]  = "AUTO",
	[1]  = "GPON",
	[2]  = "1G-EPON",
	[3]  = "10G/1G-EPON（XEPON 不对称）",
	[4]  = "10G/10G-EPON（XEPON 对称）",
	[5]  = "1G/1G-EPON",
	[6]  = "XGPON",
	[7]  = "XGSPON",
	[8]  = "NGPON2 10G/10G",
	[9]  = "NGPON2 10G/2G",
	[10] = "NGPON2 2G/2G",
	[11] = "GPON-SYM",
	[12] = "TURBO-EPON",
}

-- 解码 onu_type 十六进制为“人话”：
-- 低 2 bit=ONU 形态 1=SFU/2=HGU，高 4 bit=PON 技术）
local function decode_onu(hex)
	local b = tonumber(hex, 16)
	if not b then
		return { form = "未知", form_cn = "未知", tech = "?", tech_cn = "未知" }
	end
	local low = b % 16
	local form = (low == 2 and "HGU") or (low == 1 and "SFU") or "未知"
	local form_cn = (low == 2 and "HGU（家庭网关）") or (low == 1 and "SFU（桥形态）") or "未知"
	local tid = pon_tech_by_bits[math.floor(b / 16)]
	local tech_cn = tid or "未知"
	for _, t in ipairs(pon_techs) do
		if t.id == tid then tech_cn = t.name end
	end
	return { form = form, form_cn = form_cn, tech = tid or "?", tech_cn = tech_cn }
end

function index()
	entry({"admin", "xpon"}, firstchild(), "PON设置", 39).dependent = false
	entry({"admin", "xpon", "auth"}, call("action_auth"), "认证", 1)
	-- 业务 Services 页默认不内置（模板 services.htm 保留在包内，
	-- 需要时取消下面这行注释即可单独挂出）
	entry({"admin", "xpon", "services"}, call("action_services"), "业务", 3)
	entry({"admin", "xpon", "service-vlan"}, post("action_service_vlan")).leaf = true
	entry({"admin", "xpon", "provision"}, call("action_provision"), "OMCI", 4)
	entry({"admin", "xpon", "status"}, call("action_status"), "状态", 5)

	-- 手写表单直接提交各字段，不包含名为 data 的字段；post_on({data=true})
	-- 会导致路由条件不匹配并回到登录页，表现为“被登出且未保存”。
	entry({"admin", "xpon", "save"}, post("action_save")).leaf = true
	entry({"admin", "xpon", "services", "action"}, post("action_service_action")).leaf = true
	entry({"admin", "xpon", "multicast"}, post("action_multicast")).leaf = true
	entry({"admin", "xpon", "status", "data"}, call("action_status_data")).leaf = true
	entry({"admin", "xpon", "status", "details"}, call("action_status_details")).leaf = true
end

------------------------------------------------------------------------
-- 读取辅助
------------------------------------------------------------------------

local function uget(config, section, option)
	return uci.cursor():get(config, section, option)
end

local function ensure_section(u, config, section, stype)
	u = u or uci.cursor()
	if u:get_all(config, section) then
		return true
	end
	local name, err = u:section(config, stype, section, {})
	return name ~= nil and name ~= false, err
end

local function ensure_xpon_config_file()
	local path = "/etc/config/xpon"
	if fs.access(path) then return true end
	local ok = fs.writefile(path, "config auth 'device'\n")
	return ok and fs.access(path) or false
end

local function sh(cmd)
	-- /tmp/ponstatus 的定长记录带大量 NUL 填充；它们没有文本意义，
	-- 且会被 JSON 编码成成百上千个 \u0000。
	local out = sys.exec(cmd .. " 2>&1") or ""
	return util.trim((out:gsub("%z", "")))
end

-- 写系统日志（logread 可查），单引号转义防注入
local function logger(tag, msg)
	sys.call("logger -t " .. tag .. " '" .. (msg or ""):gsub("'", "'\\''") .. "' 2>/dev/null")
end

local function schedule_reboot(delay)
	delay = tonumber(delay) or 8
	local cmd = "touch /tmp/xpon-reboot-pending; " ..
		"( sleep " .. delay .. "; logger -t xpon '认证参数已保存，执行整机重启'; sync; " ..
		"ubus call system reboot >/dev/null 2>&1 || /sbin/reboot ) " ..
		">/dev/null 2>&1 </dev/null &"
	return sys.call(cmd) == 0
end

-- gponmapcmd / ponvlancmd 的 show 结果由内核日志输出（stdout 为空）。
-- 这里记录执行前 dmesg 行数，执行后取增量；同时保留 stdout（双保险）。
local function klog_show(cmd)
	local before = tonumber(sh("dmesg 2>/dev/null | wc -l")) or 0
	local out = sh(cmd)
	local tail = sh("dmesg 2>/dev/null | tail -n +" .. (before + 1) ..
		" | sed 's/^\\[ *[0-9][0-9]*\\.[0-9][0-9]*\\] //'")
	local parts = {}
	if out ~= "" then parts[#parts + 1] = out end
	if tail ~= "" then parts[#parts + 1] = tail end
	return table.concat(parts, "\n")
end

------------------------------------------------------------------------
-- GEM / ponvlan 只读表解析
------------------------------------------------------------------------

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 按空白拆字段
local function fields(line)
	local f = {}
	for w in (line .. " "):gmatch("%S+") do f[#f + 1] = w end
	return f
end

-- 上行映射：表头 tagFlag uni vid dscp pbit gemPort，
-- 每列 = tagCtl 位决定：位 1 显示值，位 0 显示 N/A=通配不参与匹配）
local function parse_gem_up(text)
	local rows, raw = {}, {}
	for line in (text .. "\n"):gmatch("([^\n]+)") do
		line = trim(line)
		if line ~= "" then
			local f = fields(line)
			if #f == 6 and not f[1]:match("^tagFlag") and not f[1]:match("^gemPortmapping") then
				rows[#rows + 1] = {
					tagFlag = f[1], userPort = f[2], vid = f[3], dscp = f[4], pbit = f[5], gemPort = f[6],
				}
			else
				raw[#raw + 1] = line
			end
		end
	end
	return rows, table.concat(raw, "\n")
end

-- 下行映射：`total rule num is N` + `Gem Port:%d, If Mask:%08x, queue Index:%d,
-- trtcm Id:%d, queue_enable:%d, trtcm_enable:%d, down weight:%d`
local function parse_gem_down(text)
	local total, rows, raw = "", {}, {}
	for line in (text .. "\n"):gmatch("([^\n]+)") do
		line = trim(line)
		if line ~= "" then
			local t = line:match("^total rule num is (%d+)")
			if t then
				total = t
			else
				local gp, im, q, tr, qe, te, w = line:match(
					"Gem Port:(%d+), If Mask:(%x+), queue Index:(%d+), trtcm Id:(%d+), queue_enable:(%d+), trtcm_enable:(%d+), down weight:(%d+)")
				if gp then
					rows[#rows + 1] = { gemPort = gp, ifMask = im, queue = q, trtcm = tr, qEnable = qe, tEnable = te, weight = w }
				else
					raw[#raw + 1] = line
				end
			end
		end
	end
	return total, rows, table.concat(raw, "\n")
end

-- 队列映射：`queuemapping-->` + 表头 gemPort pqMode tcont queue tse tsChannelId + 行
local function parse_gem_queue(text)
	local rows, raw = {}, {}
	for line in (text .. "\n"):gmatch("([^\n]+)") do
		line = trim(line)
		if line ~= "" then
			local f = fields(line)
			if f[1] == "gemPort" or f[1] == "queuemapping" or f[1] == "pqMode" then
				raw[#raw + 1] = line
			elseif #f == 6 and f[1]:match("^%d+$") then
				rows[#rows + 1] = {
					gemPort = f[1], pqMode = f[2], tcont = f[3], queue = f[4], tse = f[5], tsChannelId = f[6],
				}
			else
				raw[#raw + 1] = line
			end
		end
	end
	return rows, table.concat(raw, "\n")
end

-- ponmgr GEM 口表：`%d  Unicast GEM Port:%d, TCONT:%d, MAC If:%s, ...`
-- （G.988 ME 268 GEM port network CTP 的驱动视图）
local function parse_ponmgr_gem(text)
	local rows = {}
	for l in (text .. "\n"):gmatch("([^\n]+)") do
		local kind, gp, tcont, macif =
			l:match("(%a+) GEM Port:%s*(%d+), TCONT:%s*(%d+), MAC If:(%S+),")
			or l:match("GEM Port:%s*(%d+), TCONT:%s*(%d+), MAC If:(%S+),")
		if gp then
			rows[#rows + 1] = { gem = gp, tcont = tcont, macif = macif, kind = kind or "" }
		end
	end
	table.sort(rows, function(a, b) return tonumber(a.gem) < tonumber(b.gem) end)
	return rows
end

------------------------------------------------------------------------
-- 极简 JSON 编码（不依赖 luci.jsonc，裁剪版也能跑）
------------------------------------------------------------------------

local function json_escape(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
	s = s:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
	s = s:gsub("[%z\1-\31]", function(c) return string.format("\\u%04x", c:byte()) end)
	return s
end

local function encode_json(t)
	local out = {}
	local function enc(v)
		if type(v) == "string" then
			out[#out + 1] = '"' .. json_escape(v) .. '"'
		elseif type(v) == "number" or type(v) == "boolean" then
			out[#out + 1] = tostring(v)
		elseif type(v) == "table" then
			if v[1] ~= nil then
				out[#out + 1] = "["
				for i, e in ipairs(v) do
					if i > 1 then out[#out + 1] = "," end
					enc(e)
				end
				out[#out + 1] = "]"
			else
				out[#out + 1] = "{"
				local first = true
				for k, e in pairs(v) do
					if not first then out[#out + 1] = "," end
					first = false
					out[#out + 1] = '"' .. json_escape(k) .. '":'
					enc(e)
				end
				out[#out + 1] = "}"
			end
		else
			out[#out + 1] = "null"
		end
	end
	enc(t)
	return table.concat(out)
end

function auth_values()
	local u = uci.cursor()
	local v = {}
	local private_saved = (uget("xpon", "device", "pon_mode") or "") ~= ""
	-- /etc/config/xpon 是抵抗 S00xponconfig 覆盖的持久源；仅在它没有值时
	-- 才回退到 network.xpon_auth。
	local function saved(field, dflt)
		local s
		if private_saved then
			s = uget("xpon", "device", field)
			if s ~= nil and s ~= "" then return s end
		end
		s = uget("network", "xpon_auth", field)
		if s ~= nil and s ~= "" then return s end
		return dflt
	end
	v.pon_mode          = saved("pon_mode", "GPON")
	v.auth_type_g       = saved("auth_type_g", "LOID")
	v.auth_type_e       = saved("auth_type_e", "LOID")
	v.loid              = saved("loid", "")
	v.loid_password     = saved("loid_password", "")
	v.sn                = saved("sn", "")
	v.xpon_sn_auth_type = saved("xpon_sn_auth_type", "ascii")
	-- PASSWORD（移动 SN+Password）落库为 SN + regid，读回时还原成独立选项
	if v.auth_type_g:lower() == "sn" and v.xpon_sn_auth_type:lower() == "regid" then
		v.auth_type_g = "password"
	end
	v.sn_ascii_password = saved("sn_ascii_password", "")
	v.sn_hex_password   = saved("sn_hex_password", "")
	v.sn_regid_password = saved("sn_regid_password", "")
	-- 页面只保留一个“SN 密码”输入框，格式由 xpon_sn_auth_type 决定（ascii/hex/regid）
	v.sn_password       = ((v.xpon_sn_auth_type == "hex") and v.sn_hex_password or
		(v.xpon_sn_auth_type == "regid") and v.sn_regid_password or v.sn_ascii_password) or ""
	-- 移动 Password = 独立 REG_ID 输入框，存 sn_regid_password（格式 regid）
	v.reg_id            = (v.xpon_sn_auth_type == "regid") and v.sn_regid_password or ""
	v.loid_password_set = v.loid_password ~= ""
	v.vendor_id         = uget("xpon", "device", "vendor_id") or ""
	v.equipment_id      = uget("network", "xpon_auth", "equipment_id") or uget("xpon", "device", "equipment_id") or ""
	v.onu_version       = uget("network", "xpon_auth", "onu_version") or uget("xpon", "device", "onu_version") or ""
	v.omcc_version      = uget("network", "xpon_auth", "omcc_version") or uget("xpon", "device", "omcc_version") or ""
	v.omci_spec_ver     = uget("xpon", "device", "omci_spec_ver") or ""
	v.pon_mac           = uget("xpon", "device", "pon_mac") or ""
	v.epon_oui          = uget("xpon", "device", "epon_oui") or ""
	v.epon_ven_info     = uget("xpon", "device", "epon_ven_info") or ""
	-- 运行时读回（只读展示）：omcicfgCmd get 是 OMCI 层实际生效值，
	-- 输出格式 "field = value" 或 "ONU SN: value"（读不到 = 空串）
	local function omci_get(field)
		local out = sh("/userfs/bin/omcicfgCmd get " .. field .. " 2>&1") .. "\n"
		return out:match("[=:]%s*(.-)%s*\n") or ""
	end
	local function oam_get(field)
		local out = sh("/userfs/bin/oamcfgCmd get " .. field .. " 2>&1") .. "\n"
		return out:match("[=:]%s*(.-)%s*\n") or ""
	end
	local is_epon = v.pon_mode == "EPON"
	local rt = {
		loid         = is_epon and oam_get("loid0") or omci_get("loid"),
		sn           = omci_get("sn"),
		vendor_id    = omci_get("vendorId"),
		equipment_id = omci_get("equipmentId"),
		onu_version  = omci_get("onuVersion"),
		omcc_version = omci_get("omccVersion"),
		spec_ver     = sh("/userfs/bin/omcicfgCmd get specVer 2>&1"):match("(%d+)") or "",
		epon_oui     = is_epon and oam_get("localOui"):gsub("^0[xX]", ""):upper() or "",
		epon_ven_info = is_epon and oam_get("localVenInfo"):gsub("^0[xX]", ""):upper() or "",
	}
	local pon_ifconfig = sh("ifconfig pon 2>/dev/null")
	rt.pon_mac = sh("cat /sys/class/net/pon/address 2>/dev/null"):match("([0-9A-Fa-f:]+)")
		or pon_ifconfig:match("HWaddr%s+([0-9A-Fa-f:]+)")
		or pon_ifconfig:match("ether%s+([0-9A-Fa-f:]+)") or ""
	-- 打开页面默认读取系统现有值：UCI 未显式保存（或保存值为空）时，
	-- 表单回退到 OMCI/驱动实际生效值（rt）——用户看到即现状，改完保存才写入 UCI。
	-- 密码类不回显（留空 = 保持原值）。
	local function sys_fb(field, run, dflt)
		local s
		if private_saved then
			s = uget("xpon", "device", field)
			if s ~= nil and s ~= "" then return s end
		end
		return (run ~= nil and run ~= "") and run or dflt
	end
	local function identity_fb(field, run, dflt)
		local s = uget("network", "xpon_auth", field)
		if s ~= nil and s ~= "" then return s end
		s = uget("xpon", "device", field)
		if s ~= nil and s ~= "" then return s end
		return (run ~= nil and run ~= "") and run or dflt
	end
	-- 输入框表示“下次启动仍要使用的值”，运行态在下方独立展示。
	v.vendor_id     = sys_fb("vendor_id", rt.vendor_id, "")
	v.equipment_id  = identity_fb("equipment_id", rt.equipment_id, "")
	v.onu_version   = identity_fb("onu_version", rt.onu_version, "")
	v.omcc_version  = identity_fb("omcc_version", rt.omcc_version, "")
	v.omci_spec_ver = sys_fb("omci_spec_ver", rt.spec_ver, "")
	-- PON MAC 默认取 DSD wan_mac（ifconfig pon 未就绪时兜底）
	local dsd_mac = sh("grep -o 'wan_mac[=:][0-9A-Fa-f:]*' /tmp/dsd.env 2>/dev/null | head -1"):match("[0-9A-Fa-f:]+$") or ""
	v.pon_mac       = sys_fb("pon_mac", (rt.pon_mac ~= "" and rt.pon_mac or dsd_mac), "")
	if v.loid == "" and rt.loid ~= "" then v.loid = rt.loid end
	if (v.sn == "" or v.sn == "NoNumber") and rt.sn ~= "" then v.sn = rt.sn end
	v.pon_mac_default = dsd_mac
	v.rt = rt
	local pt = saved("pon_tech", "")
	if pt == "" then
		pt = (v.pon_mode == "EPON") and "EPON_10G_10G" or "GPON"
	end
	v.pon_tech          = pt
	v.pon_techs         = pon_techs
	local pmv = ponmode_values()
	v.onu_low           = pmv.cur_low
	v.onu_type_run      = pmv.cmdline
	v.onu_type_env      = pmv.env
	v.onu_type_pending  = pmv.pending
	return v
end

local function service_values()
	local rows, owners = {}, {}
	local uc = uci.cursor()
	uc:foreach("network", "interface", function(s)
		local vid = (s.device or ""):match("^pon%.(%d+)$")
		if vid then owners[vid] = s end
	end)
	uc:foreach("network", "xpon_service", function(s)
		local vid = tonumber(s.vlan_id or "")
		if s.xpon_managed == "1" and vid and vid >= 1 and vid <= 4094 then
			local key = s.service_key or s[".name"]
			if #key > 12 or not key:match("^[A-Za-z0-9_]+$") then key = "svc_" .. tostring(vid) end
			local owner = owners[tostring(vid)]
			local iface = s.interface or (owner and owner[".name"]) or ("xpon_" .. key)
			local raw = sh("ubus call network.interface." .. iface .. " status 2>/dev/null")
			local up = raw:match('"up"%s*:%s*true') ~= nil
			local pending = raw:match('"pending"%s*:%s*true') ~= nil
			local uptime = raw:match('"uptime"%s*:%s*(%d+)') or ""
			local address = raw:match('"address"%s*:%s*"([0-9%.:]+)"') or ""
			local row = {
				key=key, section=s[".name"], name=s.remark or ("VLAN " .. vid),
				vlan_id=tostring(vid), priority=s.priority or "0", remark=s.remark or "",
				enable=s.enable ~= "0" and "1" or "0", service_type=s.service_type or "internet",
				mode=s.mode or s.payload or "routed", proto=s.proto or (owner and owner.proto) or "dhcp", mtu=s.mtu or (owner and owner.mtu) or "1500",
				username=s.username or (owner and owner.username) or "", ipaddr=s.ipaddr or (owner and owner.ipaddr) or "", netmask=s.netmask or (owner and owner.netmask) or "",
				password_set = ((s.password and s.password ~= "") or (owner and owner.password and owner.password ~= "")) and true or nil,
				gateway=s.gateway or (owner and owner.gateway) or "", dns1=s.dns1 or "", dns2=s.dns2 or "",
				lan_port=s.lan_port or "none", mcast_vlan=s.mcast_vlan or "",
				interface=iface, external_owner=owner and owner.xpon_managed ~= "1" and owner[".name"] or nil,
				runtime=up, address=address, uptime=uptime,
				state=up and "已连接" or (pending and "连接中" or (s.enable == "0" and "已禁用" or "未连接"))
			}
			rows[#rows + 1] = row
		end
	end)
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return rows
end

local function kernel_vlan_values()
	local rows, by_vid, refs = {}, {}, {}
	local function ref(vid, text)
		vid = tostring(vid or "")
		if vid ~= "" then refs[vid] = refs[vid] or {}; refs[vid][#refs[vid] + 1] = text end
	end
	local uc = uci.cursor()
	uc:foreach("network", nil, function(s)
		if s[".type"] == "xpon_service" then ref(s.vlan_id, "业务 " .. (s.remark or s.service_key or s[".name"])) end
		if s[".type"] == "wan_vlan" then ref(s.vlan_id, "旧 wan_vlan " .. s[".name"]) end
		local vid = (s.name or s.device or ""):match("^pon%.(%d+)$")
		if vid then ref(vid, s[".type"] .. " " .. s[".name"]) end
	end)
	uci.cursor():foreach("pon", "multicast_vlan", function(s) ref(s.interface_vid, "组播 VLAN " .. (s.vlan_id or "")) end)
	uci.cursor():foreach("xpon", "service", function(s) ref(s.vlan, "旧业务 " .. s[".name"]) end)
	local raw = sh("cat /proc/net/vlan/config 2>/dev/null")
	for name, vid in raw:gmatch("(pon%.(%d+))%s+|%s+%d+%s+|%s+pon") do
		-- Lua 多捕获中第二项就是 VID；name 保留用于兼容不同固件格式。
		vid = name:match("(%d+)$") or vid
		if vid and not by_vid[vid] then
			local r = { name="pon." .. vid, vlan_id=vid, refs=refs[vid] or {}, orphan=(refs[vid] == nil) }
			rows[#rows + 1] = r; by_vid[vid] = r
		end
	end
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return rows
end

function action_service_vlan()
	local vid = tonumber(formvalue("vlan_id") or "")
	if not vid or vid < 1 or vid > 4094 then http.redirect(xpon_url("services", "err=vlan")); return end
	for _, row in ipairs(kernel_vlan_values()) do
		if tonumber(row.vlan_id) == vid then
			if not row.orphan then http.redirect(xpon_url("services", "err=vlan_in_use_" .. vid)); return end
			local rc = sys.call("( timeout 3 vconfig rem pon." .. vid .. " || timeout 3 ip link del pon." .. vid .. " ) >/tmp/xpon-vlan-cleanup.log 2>&1")
			http.redirect(xpon_url("services", rc == 0 and ("vlan_cleaned=" .. vid) or ("err=vlan_cleanup_" .. rc))); return
		end
	end
	http.redirect(xpon_url("services", "err=vlan_not_found"))
end

local function multicast_values()
	local rows, by_vid, registered, bindings = {}, {}, {}, {}
	local raw = sh("/usr/bin/pon-multicast status")
	local snooping, proxy = raw:match("control=([01]),([01])")
	local runtime_snooping, runtime_proxy = raw:match("runtime_control=([01]),([01])")
	local proxy_port = raw:match("proxy_port=([1-4])") or "1"
	local runtime_proxy_port, runtime_proxy_func = raw:match("runtime_proxy_port=([1-4]),([012])")
	local merr = formvalue("merr")
	local error_text = {
		backend_permission = "后端脚本不可执行（权限错误）",
		backend_missing = "后端脚本不存在",
		proxy_port = "代理绑定端口无效",
	}
	for vid in raw:gmatch("mvlan=(%d+)") do registered[vid] = true end
	for port, vid in raw:gmatch("binding=(%d+),(%d+)") do bindings[vid] = port end
	for vid, ifvid, configured_bound, configured_port in
		raw:gmatch("config=(%d+),(%d+),([01]),(%d+)") do
		if vid:match("^%d+$") and ifvid:match("^%d+$") then
			local bound = bindings[ifvid] ~= nil
			local row = { vlan_id=vid, interface_vid=ifvid, bound=bound,
				port=bindings[ifvid] or configured_port or "1", configured=true,
				configured_bound=(configured_bound == "1"),
				state=registered[vid] and (bound and "bound" or "registered") or "error" }
			rows[#rows + 1] = row
			by_vid[vid] = row
		end
	end
	for vid in pairs(registered) do
		if not by_vid[vid] then rows[#rows + 1] = { vlan_id=vid, interface_vid="", bound=false, port="0", state="registered", configured=false } end
	end
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return {
		rows=rows, result=raw, error=error_text[merr] or merr, ok=formvalue("mok"),
		snooping=snooping or "1", proxy=proxy or "0",
		runtime_snooping=runtime_snooping, runtime_proxy=runtime_proxy,
		proxy_port=proxy_port, runtime_proxy_port=runtime_proxy_port,
		runtime_proxy_func=runtime_proxy_func,
	}
end

local function iptv_business_values()
	local rows, seen = {}, {}
	local port_map = { lan1="1", lan2="2", lan3="3", lan4="4" }
	uci.cursor():foreach("network", "xpon_service", function(s)
		local vid = tonumber(s.vlan_id or "")
		if s.service_type == "iptv" and vid and vid >= 1 and vid <= 4094 and not seen[vid] then
			rows[#rows + 1] = { vlan_id=tostring(vid), name=s.remark or "IPTV", port=port_map[s.lan_port] or "1" }; seen[vid] = true
		end
	end)
	uci.cursor():foreach("xpon", "service", function(s)
		local vid = tonumber(s.vlan or "")
		if s[".name"] == "iptv" and vid and vid >= 1 and vid <= 4094 and not seen[vid] then
			local port = tonumber(s.iptv_port or "") or 1; if port < 1 or port > 4 then port = 1 end
			rows[#rows + 1] = { vlan_id=tostring(vid), name="IPTV", port=tostring(port) }; seen[vid] = true
		end
	end)
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return rows
end

function action_multicast()
	local op = formvalue("op") or ""
	if op == "control" then
		local snooping = formvalue("snooping") == "1" and "1" or "0"
		local proxy = formvalue("proxy") == "1" and "1" or "0"
		local proxy_port = tonumber(formvalue("proxy_port") or "")
		if not proxy_port or proxy_port < 1 or proxy_port > 4 then
			http.redirect(xpon_url("services", "merr=proxy_port"))
			return
		end
		if proxy == "1" then snooping = "1" end
		local rc = sys.call(string.format(
			"/usr/bin/pon-multicast control %s %s %d >/tmp/pon-multicast-action.log 2>&1",
			snooping, proxy, proxy_port))
		local result = rc == 0 and "mok=control" or
			(rc == 126 and "merr=backend_permission" or
			(rc == 127 and "merr=backend_missing" or ("merr=driver_" .. rc)))
		http.redirect(xpon_url("services", result))
		return
	end
	local vid = tonumber(formvalue("vlan_id") or "")
	if not vid or vid < 1 or vid > 4094 then
		http.redirect(xpon_url("services", "merr=vlan")); return
	end
	local cmd
	if op == "add" then
		local ver = tonumber(formvalue("igmp_version") or "2") or 2
		local ifvid = tonumber(formvalue("interface_vid") or "")
		local port
		for _, b in ipairs(iptv_business_values()) do if tonumber(b.vlan_id) == ifvid then port = tonumber(b.port) end end
		if not port or port < 1 or port > 4 or (ver ~= 2 and ver ~= 3) or not ifvid or ifvid < 1 or ifvid > 4094 then
			http.redirect(xpon_url("services", "merr=options")); return
		end
		if sh("ip link show pon." .. ifvid) == "" then
			http.redirect(xpon_url("services", "merr=interface")); return
		end
		cmd = string.format("/usr/bin/pon-multicast add %d %d %d %d", vid, ifvid, port, ver)
	elseif op == "bind" then
		cmd = string.format("/usr/bin/pon-multicast bind %d %s", vid, formvalue("bound") == "1" and "1" or "0")
	elseif op == "delete" then
		cmd = string.format("/usr/bin/pon-multicast delete %d", vid)
	else
		http.redirect(xpon_url("services", "merr=operation")); return
	end
	local rc = sys.call(cmd .. " >/tmp/pon-multicast-action.log 2>&1")
	local result
	if rc == 0 then
		if op == "delete" then
			local nu = uci.cursor()
			nu:foreach("network", "xpon_service", function(s)
				if tonumber(s.mcast_vlan or "") == vid then nu:delete("network", s[".name"], "mcast_vlan") end
			end)
			nu:save("network"); nu:commit("network")
			local xu = uci.cursor()
			xu:foreach("xpon", "service", function(s)
				if tonumber(s.mcast_vlan or "") == vid then xu:delete("xpon", s[".name"], "mcast_vlan") end
			end)
			xu:save("xpon"); xu:commit("xpon")
		end
		result = "mok=1"
	elseif rc == 126 then
		result = "merr=backend_permission"
	elseif rc == 127 then
		result = "merr=backend_missing"
	else
		result = "merr=driver_" .. rc
	end
	http.redirect(xpon_url("services", result))
end

-- 组播 M-VLAN“实际登记”只读快照：读 /tmp/xpon-mvlan-act.txt（由 xpon-mvlan-snap.sh
-- 后台刷新，LuCI 绝不直接调 xponigmpcmd——该 ioctl 可能阻塞，同步调用会挂起页面）。
local function mvlan_snapshot()
	local raw = sh("cat /tmp/xpon-mvlan-act.txt 2>/dev/null")
	local ids = {}
	for v in (raw or ""):gmatch("vlan=(%d+)") do
		local n = tonumber(v)
		if n and n >= 1 and n <= 4094 then ids[#ids + 1] = n end
	end
	table.sort(ids)
	return ids, raw
end

function ponmode_values()
	local env_val = sh("fw_printenv onu_type 2>/dev/null")
	local cmdline_val = sh("grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1")
	cmdline_val = cmdline_val:match("=(.*)$") or cmdline_val
	local env_num = env_val:match("=(.*)$") or env_val
	local sys_mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")

	-- 当前生效 hex（cmdline 优先），用于预选与缺省技术推导
	local cur_hex = (cmdline_val ~= "") and cmdline_val or env_num
	local cur_bits = tonumber(cur_hex, 16)
	local cur_tech = (cur_bits and pon_tech_by_bits[math.floor(cur_bits / 16)]) or nil
	local cur_low = (cur_bits and (cur_bits % 16)) or 1

	-- PON 技术以“认证”页为准；未设置时按当前模式推导
	local tech = uget("network", "xpon_auth", "pon_tech") or uget("xpon", "device", "pon_tech") or ""
	if not pon_tech_bits[tech] then tech = cur_tech or "XGPON" end
	local tech_mismatch = (cur_tech ~= nil and tech ~= cur_tech)
	local tech_name = tech
	for _, t in ipairs(pon_techs) do
		if t.id == tech then tech_name = t.name end
	end

	-- 本页只选 SFU/HGU，技术来自认证页，自动组合 onu_type
	local forms = {
		{ low = "2", name = "HGU（家庭网关）", desc = "国内运营商默认：LAN 桥接 + VEIP + IPTV 组播完整" },
		{ low = "1", name = "SFU（桥形态）", desc = "纯桥/实验：无 VEIP 与 LAN 侧组播引擎" },
	}
	local opts = {}
	for _, f in ipairs(forms) do
		opts[#opts + 1] = {
			low = f.low, name = f.name, desc = f.desc,
			hex = onu_type_hex(tech, f.low),
		}
	end

	-- sys_xpon_mode 枚举，供“技术详情”展开
	local sys_mode_names = {
		[0] = "AUTO", [1] = "GPON", [2] = "EPON", [3] = "10G_1G_EPON", [4] = "10G_10G_EPON",
		[5] = "1G_1G_EPON", [6] = "XGPON", [7] = "XGSPON", [8] = "NGPON2_10G_10G",
		[9] = "NGPON2_10G_2G", [10] = "NGPON2_2G_2G", [11] = "GPON_SYM", [12] = "TURBO_EPON",
	}
	local sys_modes = {}
	for i = 0, 12 do
		sys_modes[#sys_modes + 1] = {
			id = i,
			name = pon_mode_names[i] or ("未知(" .. i .. ")"),
			detail = sys_mode_names[i] or "",
		}
	end

	-- PON VLAN 接口列表（内核 802.1q：pon.<VID>，用于 PPPoE/静态 IP 拨号）
	local vlans = {}
	local function add_vlan(name, vid, pri)
		local n = tonumber(vid)
		if name and n and n >= 1 and n <= 4094 then
			vlans[#vlans + 1] = { name = name, vid = n, pbit = tonumber(pri) or 0 }
		end
	end
	local vc = sh("cat /proc/net/vlan/config 2>/dev/null")
	-- 空列表诊断（帮助区分“真没有接口”还是“读表途径缺失”）
	local vlan_diag = {}
	-- 方式1：/proc/net/vlan/config 逐行解析，兼容三种内核输出：
	--   Name: pon.466  VID: 466  REORDER_HDR: 1 ...（5.x）
	--   Name:"pon.466" VID: 466 PRIORITY: 0 ...（老内核）
	--   pon.466  VID: 466  REORDER_HDR: 1 ...（更老）
	for line in (vc .. "\n"):gmatch("([^\n]+)") do
		local name, vid = line:match('Name:%s*"?(pon%.[0-9]+)"?%s+VID:%s*(%d+)')
		if not name then
			name, vid = line:match("(pon%.[0-9]+)%s+VID:%s*(%d+)")
		end
		if name then add_vlan(name, vid, 0) end
	end
	-- 方式2：紧凑旧格式 pon.466 466 0x0000 ...
	if #vlans == 0 then
		for name, vid, pri in vc:gmatch("(pon%.[0-9]+)%s+([0-9]+)%s+([0-9xXa-fA-F]+)%s") do
			add_vlan(name, vid, pri)
		end
	end
	-- 方式3：/proc/net/vlan/ 目录列举
	if #vlans == 0 then
		local vdir = sh("ls /proc/net/vlan/ 2>/dev/null")
		for name in vdir:gmatch("(pon%.[0-9]+)") do
			add_vlan(name, name:match("(%d+)$"), 0)
		end
		if vdir == "" then
			vlan_diag[#vlan_diag + 1] = "/proc/net/vlan/ 目录不可读"
		end
	end
	-- 方式4：ip -o link show type vlan（iproute2）
	if #vlans == 0 then
		local o2 = sh("ip -o link show type vlan 2>/dev/null")
		for name, vid in o2:gmatch("(pon%.[0-9]+)@[^:%s]+:[^\n]* vlan protocol 802%.1Q id (%d+)") do
			add_vlan(name, vid, 0)
		end
	end
	-- 方式5：ifconfig 兜底
	if #vlans == 0 then
		for name in sh("ifconfig 2>/dev/null"):gmatch("(pon%.[0-9]+)") do
			add_vlan(name, name:match("(%d+)$"), 0)
		end
	end
	-- 方式6：sysfs /sys/class/net（8021q 接口必然注册，最可靠兜底）
	local sf = sh("ls /sys/class/net/ 2>/dev/null")
	if #vlans == 0 then
		for name in sf:gmatch("(pon%.[0-9]+)") do
			add_vlan(name, name:match("(%d+)$"), 0)
		end
	end
	table.sort(vlans, function(a, b) return (a.vid or 0) < (b.vid or 0) end)

	if vc == "" then
		vlan_diag[#vlan_diag + 1] = "/proc/net/vlan/config 不存在或为空"
	elseif #vlans == 0 then
		local head = vc:gsub("%s+", " "):sub(1, 120)
		vlan_diag[#vlan_diag + 1] = "config 未匹配（原文：" .. head .. "）"
	end
	if #vlans == 0 then
		local dhead = sh("ls -1 /proc/net/vlan/ 2>/dev/null | tr '\\n' ' '"):sub(1, 80)
		local ihead = sh("ifconfig 2>/dev/null | grep '^pon' | tr '\\n' ' '"):sub(1, 80)
		local shead = sf:gsub("%s+", " "):sub(1, 120)
		vlan_diag[#vlan_diag + 1] = "proc目录[" .. dhead .. "] ifconfig[" .. ihead .. "] sysfs[" .. shead .. "]"
	end
	-- 8021q 是否可用以 /proc/net/vlan 目录为准（内核模块可能编入内核，lsmod 查不到）；
	-- 且已有 pon.<VID> 接口时绝不误报
	if #vlans == 0 and sh("[ -d /proc/net/vlan ] && echo y") ~= "y" then
		vlan_diag[#vlan_diag + 1] = "8021q 未加载（/proc/net/vlan 不存在）"
	end
	if sh("command -v vconfig 2>/dev/null") == "" then
		vlan_diag[#vlan_diag + 1] = "vconfig 缺失（自动改用 ip link 建口）"
	end
	vlan_diag = table.concat(vlan_diag, "；")

	-- 已持久化的 wan_vlan 段（系统启动时自动创建 pon.<VID>）；
	-- 同时收集段内组播 M-VLAN（mcast_vlan 自定义字段）供当前接口列表回显
	local persisted = {}
	local mvid_by_vid = {}
	pcall(function()
		uci.cursor():foreach("network", "wan_vlan", function(s)
			local pvid = tonumber(s.vlan_id or "")
			if pvid and pvid >= 1 and pvid <= 4094 then
				if s.mcast_vlan and s.mcast_vlan ~= "" then mvid_by_vid[pvid] = s.mcast_vlan end
				local present = false
				for _, vl in ipairs(vlans) do
					if vl.vid == pvid then present = true break end
				end
				persisted[#persisted + 1] = {
					name = s[".name"] or "",
					vid = pvid,
					payload = s.payload or "routed",
					mcast = s.mcast_vlan or "",
					present = present,
				}
			end
		end)
	end)
	table.sort(persisted, function(a, b) return a.vid < b.vid end)
	for _, vl in ipairs(vlans) do
		vl.mcast = mvid_by_vid[vl.vid] or ""
	end

	local mvlan_act, mvlan_cnt_raw = mvlan_snapshot()

	return {
		env           = env_val,
		env_hex       = env_num,
		cmdline       = cmdline_val,
		pending       = (env_num ~= "" and cmdline_val ~= "" and env_num ~= cmdline_val),
		sys_mode      = sys_mode,
		sys_mode_name = pon_mode_names[tonumber(sys_mode)] or "未知",
		pon_tech      = tech,
		pon_tech_name = tech_name,
		tech_mismatch = tech_mismatch,
		run_tech      = cur_tech,
		run_hex       = cur_hex,
		run_dec       = decode_onu(cur_hex),
		env_dec       = decode_onu(env_num),
		forms         = opts,
		cur_low       = tostring(cur_low),
		sys_modes     = sys_modes,
		ko            = sh("lsmod 2>/dev/null | awk '$1 ~ /^xpon/ {print $1}' | tr '\\n' ' '"),
		bbf_gpon      = sh("if [ -e /proc/gpon/bbf247Flag ]; then cat /proc/gpon/bbf247Flag; fi"),
		bbf_xgpon     = sh("if [ -e /proc/xgpon/bbf247Flag ]; then cat /proc/xgpon/bbf247Flag; fi"),
		vlans         = vlans,
		persisted     = persisted,
		vlan_diag     = vlan_diag,
		vlan_cfg_raw  = vc,
		vlan_dir_raw  = sh("ls -1 /proc/net/vlan/ 2>/dev/null"),
		vlan_if_raw   = sh("ifconfig 2>/dev/null | grep -E '^(pon|eth)'"),
		vlan_ip_raw   = sh("ip -o link show type vlan 2>/dev/null"),
		mvlan_act     = mvlan_act,
		mvlan_cnt_raw = mvlan_cnt_raw,
	}
end

-- 模式页 PON VLAN 操作结果提示（?vlan=add|del|bad&rc=&vid=）
local function vlan_msg_for(vlan, rc, vid)
	if vlan == "add" then
		if rc == "ok" then
			return ("已创建 <code>pon.%s</code> 802.1q 接口（已写入 network wan_vlan，重启自动重建；组播 VLAN 已写入配置，登记由后台执行、开机自动重放）。"):format(vid), true
		end
		return ("创建 <code>pon.%s</code> 失败：确认 pon 口存在、8021q 模块已加载（<code>lsmod | grep 8021q</code>）。"):format(vid), false
	elseif vlan == "del" then
		return ("已删除 <code>pon.%s</code> 接口（若勾选持久化，对应 network wan_vlan 段已清除）。"):format(vid), true
	elseif vlan == "bad" then
		return "VLAN ID 不合法（需 1~4094）。", false
	elseif vlan == "err" then
		return "PON VLAN 操作失败（内部错误，详见系统日志）。", false
	end
	return nil, true
end

------------------------------------------------------------------------
-- 保存
------------------------------------------------------------------------

local function validate_vid(s)
	local n = tonumber(s or "")
	return n ~= nil and n >= 1 and n <= 4094
end

-- 组播 M-VLAN 列表：接受 "3799" / "3799,4000"（含全角逗号），去重保序，仅保留 1~4094
local function parse_mvids(s)
	local seen, out = {}, {}
	for m in (s or ""):gsub("[,，]+", ","):gmatch("(%d+)") do
		local n = tonumber(m)
		if n and n >= 1 and n <= 4094 and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	return out
end

-- 创建 pon.<VID> 802.1q 拨号子接口 + 持久化 wan_vlan 段 + 登记组播 M-VLAN。
-- 设备 VLAN 创建流程：vconfig add pon <VID> → up →
-- set_egress_map / set_ingress_map（Pbit）；组播登记 xpon_ani_pass_mvlan（xpon_igmp_core.c）。
-- 返回 (ok, exists)：exists=接口是否创建成功（决定 rc=ok/fail）。
local function ponvlan_add(vid, pbit, mvids)
	local existing, unmanaged = nil, false
	uci.cursor():foreach("network", "wan_vlan", function(s)
		if s.vlan_id == tostring(vid) then
			if s.xpon_managed == "1" then existing = s[".name"] else unmanaged = true end
		end
	end)
	if unmanaged then return false, false end
	local ok = pcall(function()
		if sh("command -v vconfig 2>/dev/null") ~= "" then
			sys.call("timeout 3 vconfig add pon " .. vid .. " 2>/dev/null")
			if pbit > 0 then
				sys.call("timeout 3 vconfig set_egress_map pon." .. vid .. " 0 " .. pbit .. " 2>/dev/null")
				sys.call("timeout 3 vconfig set_ingress_map pon." .. vid .. " 0 " .. pbit .. " 2>/dev/null")
			end
		else
			sys.call("timeout 3 ip link add link pon name pon." .. vid .. " type vlan id " .. vid .. " 2>/dev/null")
		end
		sys.call("timeout 3 ifconfig pon." .. vid .. " up 2>/dev/null")
		logger("xpon", ("ponvlan_add vid=%s pbit=%s mvids=%s"):format(vid, pbit, table.concat(mvids, ",")))
		-- 持久化（必做）：netifd 的 wan_vlan 段会在启动时创建 pon.<VID>，
		-- 段内 mcast_vlan 为自定义字段（netifd 忽略），由 xpon-mvlan.sh 重启重放登记
		local u = uci.cursor()
		local sec = existing
		if not sec then
			sec = "pon_vlan_" .. vid
			ensure_section(u, "network", sec, "wan_vlan")
			u:set("network", sec, "vlan_id", tostring(vid))
			u:set("network", sec, "payload", "routed")
		end
		u:set("network", sec, "xpon_managed", "1")
		if #mvids > 0 then
			u:set("network", sec, "mcast_vlan", table.concat(mvids, ","))
			-- 组播登记改后台异步：xponigmpcmd 在部分环境会阻塞 ioctl，
			-- 同步执行会让 LuCI 请求挂起（表现为“保存后登出”）。UCI 已持久化，
			-- 即使这里失败，xpon-app 开机 / xpon-mvlan.sh 也会重放登记。
			local bg = {}
			for _, m in ipairs(mvids) do
				bg[#bg + 1] = "/userfs/bin/xponigmpcmd mvlan del " .. m .. " >/dev/null 2>&1"
				bg[#bg + 1] = "/userfs/bin/xponigmpcmd mvlan add " .. m .. " >/dev/null 2>&1"
			end
			bg[#bg + 1] = "/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1"
			sys.call("( " .. table.concat(bg, "; ") .. " ) >/dev/null 2>&1 </dev/null &")
		else
			u:delete("network", sec, "mcast_vlan")
		end
		u:save("network")
		u:commit("network")
	end)
	local exists = sh("timeout 3 ip link show pon." .. vid .. " 2>/dev/null")
	if exists == "" then exists = sh("timeout 3 ifconfig pon." .. vid .. " 2>/dev/null") end
	return ok, exists ~= ""
end

-- 删除 pon.<VID>；del_persist=1 时连带删除 wan_vlan 段并清组播 M-VLAN 登记
local function ponvlan_del(vid, del_persist)
	if del_persist then
		local owned = false
		uci.cursor():foreach("network", "wan_vlan", function(s)
			if s.vlan_id == tostring(vid) and s.xpon_managed == "1" then owned = true end
		end)
		if not owned then return false end
	end
	return pcall(function()
		sys.call("(timeout 3 vconfig rem pon." .. vid .. " 2>/dev/null || timeout 3 ip link del pon." .. vid .. " 2>/dev/null)")
		logger("xpon", "ponvlan_del vid=" .. vid .. " persist=" .. tostring(del_persist))
		if del_persist then
			local u = uci.cursor()
			u:foreach("network", "wan_vlan", function(s)
				if s.vlan_id == tostring(vid) and s.xpon_managed == "1" then
					local bg = {}
					for _, m in ipairs(parse_mvids(s.mcast_vlan)) do
						bg[#bg + 1] = "/userfs/bin/xponigmpcmd mvlan del " .. m .. " >/dev/null 2>&1"
					end
					if #bg > 0 then
						bg[#bg + 1] = "/usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1"
						sys.call("( " .. table.concat(bg, "; ") .. " ) >/dev/null 2>&1 </dev/null &")
					end
					u:delete("network", s[".name"])
				end
			end)
			u:save("network")
			u:commit("network")
		end
	end)
end

-- ONU 形态保存（modeform，GET/POST 通用）：按 PON 技术 + SFU/HGU 组合 onu_type 写 U-Boot env，
-- apply=reboot 时立即重启。处理完返回 true（调用方直接 return）。
local function save_onu_mode()
	local low = formvalue("onu_low") or ""
	if low ~= "1" and low ~= "2" then
		http.redirect(xpon_url("mode", "err=low"))
		return true
	end
	-- PON 技术以“认证”页为准；缺省按当前 cmdline 推导
	local tech = uget("network", "xpon_auth", "pon_tech") or uget("xpon", "device", "pon_tech") or ""
	if not pon_tech_bits[tech] then
		local cur = sh("grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1"):match("=(.*)$")
		local bits = tonumber(cur or "", 16)
		tech = (bits and pon_tech_by_bits[math.floor(bits / 16)]) or "XGPON"
	end
	local val = onu_type_hex(tech, low)
	local rc = sys.call("/usr/bin/xpon-apply.sh ponmode %s >/dev/null 2>&1" % { val })
	if rc ~= 0 then
		http.redirect(xpon_url("mode", "err=apply"))
		return true
	end
	if formvalue("apply") == "reboot" then
		http.prepare_content("text/html; charset=utf-8")
		http.write("<html><body><h3>onu_type=" .. val .. " 已写入 U-Boot env，正在重启…</h3><p>约 1 分钟后重新登录。若无法注册，按复位键进 U-Boot 用 <code>setenv onu_type 61; saveenv; reset</code> 恢复。</p></body></html>")
		sys.call("(sleep 2; reboot) >/dev/null 2>&1 </dev/null &")
		return true
	end
	http.redirect(xpon_url("mode", "saved=1"))
	return true
end

-- Equipment ID：可选；非空时允许 1~24 个可打印 ASCII 字符。
local function ascii24_optional(s)
	if #s == 0 then return true end
	if #s > 24 then return false end
	for i = 1, #s do
		local b = s:byte(i)
		if not (b >= 32 and b <= 126) then return false end
	end
	return true
end

-- OMCI 协议版本 specVer：固件存 uint8（0~255），接受十进制或 0x 十六进制
local function specver_ok(s)
	s = (s or ""):gsub("%s+", "")
	if s == "" then return true end
	local n = tonumber(s)
	if not n and s:match("^0[xX][0-9a-fA-F]+$") then
		n = tonumber(s:sub(3), 16)
	end
	return n ~= nil and n >= 0 and n <= 255
end

-- Lua pattern 不支持正则表达式的 {n,m} 数量语法，长度必须显式判断。
local function hex_len(s, min_len, max_len)
	s = s or ""
	return #s >= min_len and #s <= max_len and s:match("^%x+$") ~= nil
end

local function normalize_omccver(s)
	s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return "" end
	local n
	if s:match("^0[xX]%x+$") then
		n = tonumber(s:sub(3), 16)
	elseif s:match("^%x+$") and s:match("[a-fA-F]") then
		n = tonumber(s, 16)
	elseif s:match("^%d+$") then
		-- 一至两位数字沿用界面的十六进制语义；三位数字按十进制兼容。
		n = (#s <= 2) and tonumber(s, 16) or tonumber(s, 10)
	end
	if not n or n < 0 or n > 255 then return nil end
	return string.format("0x%02X", n)
end

local function ponmac_ok(s)
	return #(s or "") == 17 and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function save_auth(fv)
	if not ensure_xpon_config_file() then
		return nil, "persist_config_xpon"
	end
	-- 认证持久化使用固件自带的原生 uci.so，绕开 luci.model.uci 的 ubus
	-- session 包装层；后者对新增的 xpon package 可能返回成功但没有落盘。
	local u = uci_native.cursor()
	local ptech = fv("pon_tech") or "GPON"
	local valid = {}
	for _, t in ipairs(pon_techs) do valid[t.id] = true end
	if not valid[ptech] then ptech = "GPON" end
	local pmode = pon_engine_for(ptech)
	local auth_type = fv("auth_type_g") or "LOID"
	-- netifd 对 auth_type 的 sn / LOID 值做精确匹配，
	-- 只认 SN* 或 LOID 两种：REG_ID（移动 Password）= SN + regid 密码，落库为 SN + xpon_sn_auth_type=regid
	local snf = (fv("xpon_sn_auth_type") or "ascii"):lower()
	local ui_auth = auth_type:lower()
	if ui_auth == "regid" then
		auth_type, snf = "SN", "regid"
	elseif ui_auth == "password" then
		auth_type, snf = "SN", "regid"
	elseif ui_auth == "loid" then
		auth_type = "LOID"
	else
		auth_type = "SN"
	end
	local submitted_loid_password = fv("loid_password") or ""
	local stored_loid_password = u:get("xpon", "device", "loid_password")
		or u:get("network", "xpon_auth", "loid_password") or ""
	local loid_password = submitted_loid_password ~= "" and submitted_loid_password
		or (fv("loid_password_clear") == "1" and "" or stored_loid_password)
	-- EPON/XEPON 用 auth_type_e（TYPE_EPON_AUTH），EPON 只支持 LOID 认证，必须大写
	local auth_type_e = "LOID"
	-- 页面只接收完整 PON SN；Vendor ID 始终由前 4 位派生，避免两个配置源不一致。
	local sn = (fv("sn") or ""):gsub("%s+", ""):upper()
	if sn == "NONUMBER" then sn = "" end
	local vendor_id = (#sn == 12) and sn:sub(1, 4) or ""
	-- EPON OUI = PON MAC 前 3 字节（含 OUI 的 MAC 才是 EPON OLT 认的东西），填了 MAC 就自动提取
	local pon_mac = fv("pon_mac") or ""
	local eoui = fv("epon_oui") or ""
	if eoui == "" and ponmac_ok(pon_mac) then
		eoui = pon_mac:gsub(":", ""):sub(1, 6):upper()
	end
	-- OMCI 协议版本（specVer）：固件存 uint8；omcicfgCmd 用 atoi 解析 -> 统一落库为十进制
	local omci_spec_ver = (fv("omci_spec_ver") or ""):gsub("%s+", "")
	local omcc_version = normalize_omccver(fv("omcc_version")) or ""
	if omci_spec_ver ~= "" then
		local svn = tonumber(omci_spec_ver)
		if not svn and omci_spec_ver:match("^0[xX][0-9a-fA-F]+$") then
			svn = tonumber(omci_spec_ver:sub(3), 16)
		end
		if svn and svn >= 0 and svn <= 255 then
			omci_spec_ver = tostring(svn)
		else
			omci_spec_ver = ""
		end
	end

	local network_ok = ensure_section(u, "network", "xpon_auth", "xpon_auth")
	if not network_ok then return nil, "persist_section_network" end
	u:set("network", "xpon_auth", "pon_mode", pmode)
	u:set("network", "xpon_auth", "pon_tech", ptech)
	if pmode == "EPON" then
		u:set("network", "xpon_auth", "auth_type_e", auth_type_e)
		u:delete("network", "xpon_auth", "auth_type_g")
	else
		u:set("network", "xpon_auth", "auth_type_g", auth_type)
		u:delete("network", "xpon_auth", "auth_type_e")
	end
	if fv("loid") and fv("loid") ~= "" then u:set("network", "xpon_auth", "loid", fv("loid")) end
	-- libuci 会把空字符串保存为“选项不存在”；设备重放脚本将其解释为
	-- LOID-only，并在 OMCI 就绪后显式清空原厂 netifd 注入的 ECONET。
	u:set("network", "xpon_auth", "loid_password", loid_password)
	if sn ~= "" then u:set("network", "xpon_auth", "def_sn", sn); u:set("network", "xpon_auth", "sn", sn) end
	u:set("network", "xpon_auth", "xpon_sn_auth_type", snf)
	if fv("equipment_id") and fv("equipment_id") ~= "" then u:set("network", "xpon_auth", "equipment_id", fv("equipment_id")) end
	if fv("onu_version") and fv("onu_version") ~= "" then u:set("network", "xpon_auth", "onu_version", fv("onu_version")) end
	if omcc_version ~= "" then u:set("network", "xpon_auth", "omcc_version", omcc_version) end
	-- 移动 Password = 只填 REG_ID（regid ≤36）；SN 认证 = ascii/hex 密码（可空）
	local snpwd = (ui_auth == "password") and (fv("reg_id") or "") or (fv("sn_password") or "")
	if snpwd ~= "" then
		if snf == "hex" then
			u:set("network", "xpon_auth", "sn_hex_password", snpwd)
			u:delete("network", "xpon_auth", "sn_ascii_password")
			u:delete("network", "xpon_auth", "sn_regid_password")
		elseif snf == "regid" then
			u:set("network", "xpon_auth", "sn_regid_password", snpwd)
			u:delete("network", "xpon_auth", "sn_ascii_password")
			u:delete("network", "xpon_auth", "sn_hex_password")
		else
			u:set("network", "xpon_auth", "sn_ascii_password", snpwd)
			u:delete("network", "xpon_auth", "sn_hex_password")
			u:delete("network", "xpon_auth", "sn_regid_password")
		end
	end

	-- 镜像到 /etc/config/xpon（auth 类型段 device）：开机 restore-auth 的持久源，
	-- 抵消 S00xponconfig 每次开机把 network.xpon_auth 打回 sn 的问题
	local device_ok = ensure_section(u, "xpon", "device", "auth")
	if not device_ok then return nil, "persist_section_device" end
	u:set("xpon", "device", "pon_mode", pmode)
	u:set("xpon", "device", "pon_tech", ptech)
	if pmode == "EPON" then
		u:set("xpon", "device", "auth_type_e", auth_type_e)
		u:delete("xpon", "device", "auth_type_g")
	else
		u:set("xpon", "device", "auth_type_g", auth_type)
		u:delete("xpon", "device", "auth_type_e")
	end
	if fv("loid") and fv("loid") ~= "" then u:set("xpon", "device", "loid", fv("loid")) end
	u:set("xpon", "device", "loid_password", loid_password)
	if sn ~= "" then u:set("xpon", "device", "def_sn", sn); u:set("xpon", "device", "sn", sn) end
	u:set("xpon", "device", "xpon_sn_auth_type", snf)
	if snpwd ~= "" then
		if snf == "hex" then
			u:set("xpon", "device", "sn_hex_password", snpwd)
			u:delete("xpon", "device", "sn_ascii_password")
			u:delete("xpon", "device", "sn_regid_password")
		elseif snf == "regid" then
			u:set("xpon", "device", "sn_regid_password", snpwd)
			u:delete("xpon", "device", "sn_ascii_password")
			u:delete("xpon", "device", "sn_hex_password")
		else
			u:set("xpon", "device", "sn_ascii_password", snpwd)
			u:delete("xpon", "device", "sn_hex_password")
			u:delete("xpon", "device", "sn_regid_password")
		end
	end
	if vendor_id ~= "" then u:set("xpon", "device", "vendor_id", vendor_id) end
	if fv("equipment_id") and fv("equipment_id") ~= "" then u:set("xpon", "device", "equipment_id", fv("equipment_id")) end
	if fv("onu_version") and fv("onu_version") ~= "" then u:set("xpon", "device", "onu_version", fv("onu_version")) end
	if omcc_version ~= "" then u:set("xpon", "device", "omcc_version", omcc_version) end
	if omci_spec_ver ~= "" then u:set("xpon", "device", "omci_spec_ver", omci_spec_ver) end
	if pon_mac ~= "" then u:set("xpon", "device", "pon_mac", pon_mac) end
	u:set("xpon", "device", "epon_oui", eoui)
	u:set("xpon", "device", "epon_ven_info", fv("epon_ven_info") or "")

	u:save("network")
	local network_commit = u:commit("network")
	if not network_commit then return nil, "persist_commit_network" end
	u:save("xpon")
	local xpon_commit = u:commit("xpon")
	if not xpon_commit then return nil, "persist_commit_xpon" end
	-- 原厂 OMCI 启动脚本从 gpon.ONU.OMCCVersion 读取默认值；同步该配置，
	-- 再由 xpon-replay 在 OMCI 就绪后覆盖运行态，避免启动窗口使用旧版本。
	if omcc_version ~= "" and u:get("gpon", "ONU") then
		local gv = omcc_version:gsub("^0[xX]", ""):upper()
		u:set("gpon", "ONU", "OMCCVersion", gv)
		u:save("gpon")
		local gpon_commit = u:commit("gpon")
		if not gpon_commit then return nil, "persist_commit_gpon" end
	end
	-- UCI Lua API 的写操作可能只返回 nil 而不抛异常；提交后使用新 cursor
	-- 回读关键身份字段，禁止“页面提示成功但持久配置没写进去”。
	local check = uci_native.cursor()
	local equipment = fv("equipment_id") or ""
	local onu_version = fv("onu_version") or ""
	if equipment ~= "" and check:get("network", "xpon_auth", "equipment_id") ~= equipment then
		return nil, "persist_equipment_id"
	end
	if onu_version ~= "" and check:get("network", "xpon_auth", "onu_version") ~= onu_version then
		return nil, "persist_onu_version"
	end
	if omcc_version ~= "" and check:get("network", "xpon_auth", "omcc_version") ~= omcc_version then
		return nil, "persist_omcc_version"
	end
	return true
end

local function save_services(fv)
	local rows, count = {}, tonumber(fv("vlan_count") or "0") or 0
	local seen, ports, keys, mvids = {}, {}, {}, {}
	local allowed_type = { internet=true, tr069=true, iptv=true, voice=true, other=true }
	local allowed_proto = { pppoe=true, dhcp=true, static=true, none=true }
	local allowed_port = { none=true, lan1=true, lan2=true, lan3=true, lan4=true }
	local function valid_ipv4(v)
		if v == "" then return true end
		local a,b,c,d = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		return a and tonumber(a)<=255 and tonumber(b)<=255 and tonumber(c)<=255 and tonumber(d)<=255
	end
	local valid_masks = { ["0.0.0.0"]=true, ["128.0.0.0"]=true, ["192.0.0.0"]=true, ["224.0.0.0"]=true, ["240.0.0.0"]=true, ["248.0.0.0"]=true, ["252.0.0.0"]=true, ["254.0.0.0"]=true, ["255.0.0.0"]=true }
	for bits=9,32 do
		local n, oct = bits, {}
		for j=1,4 do local b=math.min(n,8); oct[j]=tostring(256-2^(8-b)); n=n-b end
		valid_masks[table.concat(oct, ".")] = true
	end
	for i = 0, count - 1 do
		if fv("vlan_" .. i .. "_deleted") ~= "1" then
			local p = "vlan_" .. i .. "_"
			local row = {
				key=fv(p.."key") or "", interface=fv(p.."interface") or "", adopt=fv(p.."adopt") == "1",
				vlan_id=fv(p.."id") or "", priority=fv(p.."priority") or "0",
				remark=fv(p.."remark") or "", enable=fv(p.."enable") == "1" and "1" or "0",
				service_type=fv(p.."service_type") or "internet", mode=fv(p.."mode") or "routed",
				proto=fv(p.."proto") or "dhcp", mtu=fv(p.."mtu") or "1500",
				username=fv(p.."username") or "", password=fv(p.."password") or "",
				ipaddr=fv(p.."ipaddr") or "", netmask=fv(p.."netmask") or "",
				gateway=fv(p.."gateway") or "", dns1=fv(p.."dns1") or "", dns2=fv(p.."dns2") or "",
				lan_port=fv(p.."lan_port") or "none", mcast_vlan=fv(p.."mcast_vlan") or ""
			}
			local vid = tonumber(row.vlan_id)
			local pri, mtu, mvid = tonumber(row.priority), tonumber(row.mtu), tonumber(row.mcast_vlan)
			if row.key == "" then row.key = "svc_" .. tostring(vid or i) end
			if #row.key > 12 or not row.key:match("^[A-Za-z0-9_]+$") or keys[row.key] then return nil, "service_key" end
			if row.interface ~= "" and not row.interface:match("^[A-Za-z0-9_]+$") then return nil, "interface_name" end
			keys[row.key] = true
			if not vid or vid < 1 or vid > 4094 or not pri or pri < 0 or pri > 7 then return nil, "vlan" end
			if seen[vid] then return nil, "vlan_duplicate" end
			if not allowed_type[row.service_type] or (row.mode ~= "routed" and row.mode ~= "bridged") or not allowed_proto[row.proto] then return nil, "service_mode" end
			if row.mode == "bridged" then row.proto = "none" end
			if row.mode == "routed" and row.proto == "none" then return nil, "service_proto" end
			if not mtu or mtu < 576 or mtu > 2000 then return nil, "mtu" end
			if row.proto == "pppoe" and row.username == "" then return nil, "pppoe_username" end
			if row.proto == "static" and (row.ipaddr == "" or row.netmask == "") then return nil, "static_required" end
			if not valid_ipv4(row.ipaddr) or not valid_ipv4(row.netmask) or not valid_ipv4(row.gateway) or not valid_ipv4(row.dns1) or not valid_ipv4(row.dns2) then return nil, "ipv4" end
			if row.proto == "static" and not valid_masks[row.netmask] then return nil, "netmask" end
			if not allowed_port[row.lan_port] then return nil, "lan_port" end
			if row.lan_port ~= "none" and (row.mode ~= "bridged" or ports[row.lan_port]) then return nil, ports[row.lan_port] and "port_conflict" or "port_mode" end
			if row.lan_port ~= "none" then ports[row.lan_port] = true end
			if row.mcast_vlan ~= "" and (row.service_type ~= "iptv" or not mvid or mvid < 1 or mvid > 4094) then return nil, "mcast_vlan" end
			if mvid and mvids[mvid] then return nil, "mcast_duplicate" end
			if mvid then mvids[mvid] = true end
			seen[vid] = true
			rows[#rows + 1] = row
		end
	end
	local u = uci.cursor()
	local pu, mcast_conflict = uci.cursor(), false
	pu:foreach("pon", "multicast_vlan", function(s)
		if s.xpon_managed ~= "1" and mvids[tonumber(s.vlan_id or "")] then mcast_conflict = true end
	end)
	if mcast_conflict then return nil, "unmanaged_mcast_conflict" end
	-- 拒绝覆盖任何未受管的同名接口或同 VLAN device。
	local conflict
	u:foreach("network", nil, function(s)
		if s.xpon_managed ~= "1" then
			local dev = s.name or s.device
			for _, row in ipairs(rows) do
				local legacy_vlan = s[".type"] == "wan_vlan" and s.vlan_id == row.vlan_id
				local adopt_this = row.adopt and s[".type"] == "interface" and s[".name"] == row.interface and s.device == "pon." .. row.vlan_id
				if not adopt_this and (dev == "pon." .. row.vlan_id or legacy_vlan or s[".name"] == "xpon_" .. row.key) then conflict = row.vlan_id end
			end
		end
	end)
	if conflict then return nil, "unmanaged_conflict_" .. conflict end
	local old_password, old_password_iface = {}, {}
	u:foreach("network", "interface", function(s)
		if s.password then old_password_iface[s[".name"]] = s.password end
		if s.xpon_managed == "1" and s.xpon_service and s.password then old_password[s.xpon_service] = s.password end
	end)
	-- 接管是唯一允许触碰未受管段的路径，且必须由该行显式勾选。
	for _, row in ipairs(rows) do if row.adopt and row.interface ~= "" then u:delete("network", row.interface) end end
	-- 只删除本插件拥有的段；其他 network 配置保持原样。
	local remove = {}
	u:foreach("network", nil, function(s)
		if s.xpon_managed == "1" and (s[".type"] == "xpon_service" or s.xpon_service) then
			remove[#remove + 1] = s[".name"]
		end
	end)
	for _, s in ipairs(remove) do u:delete("network", s) end
	local wan_ifaces = {}
	for _, row in ipairs(rows) do
		local meta = "xpon_service_" .. row.key
		local iface = row.adopt and row.interface or ("xpon_" .. row.key)
		local vlan_dev = "pon." .. row.vlan_id
		u:section("network", "xpon_service", meta, {
			service_key=row.key, vlan_id=row.vlan_id, priority=row.priority, remark=row.remark,
			enable=row.enable, service_type=row.service_type, mode=row.mode, proto=row.proto,
			mtu=row.mtu, username=row.username, ipaddr=row.ipaddr, netmask=row.netmask,
			gateway=row.gateway, dns1=row.dns1, dns2=row.dns2, lan_port=row.lan_port,
			mcast_vlan=row.mcast_vlan
		})
		u:set("network", meta, "interface", iface); u:set("network", meta, "payload", row.mode); u:set("network", meta, "xpon_managed", "1")
		local devsec = "xpon_vlan_" .. row.key
		u:section("network", "device", devsec, { type="8021q", ifname="pon", vid=row.vlan_id, name=vlan_dev, mtu=row.mtu, xpon_managed="1", xpon_service=row.key })
		local ifdev = vlan_dev
		if row.mode == "bridged" then
			local brsec, brname = "xpon_bridge_" .. row.key, "bx-" .. row.key
			u:section("network", "device", brsec, { type="bridge", name=brname, xpon_managed="1", xpon_service=row.key })
			local list = { vlan_dev }
			local pmap = { lan1="eth0.8", lan2="eth0.7", lan3="eth0.5", lan4="eth0.4" }
			if row.lan_port ~= "none" then list[#list + 1] = pmap[row.lan_port] end
			u:set_list("network", brsec, "ports", list); ifdev = brname
		end
		local opts = { device=ifdev, proto=row.proto, auto=row.enable, mtu=row.mtu, xpon_managed="1", xpon_service=row.key }
		if row.mode == "routed" then wan_ifaces[#wan_ifaces + 1] = iface end
		if row.proto == "pppoe" then
			opts.username=row.username; opts.ipv6="auto"
			-- netifd defaults to "pppoe-<UCI interface>". xpon_<service_key>
			-- can exceed Linux IFNAMSIZ (15 visible bytes), so use the unique VID.
			opts.pppname="pppoe-pon" .. row.vlan_id
		end
		if row.proto == "static" then opts.ipaddr=row.ipaddr; opts.netmask=row.netmask; opts.gateway=row.gateway end
		u:section("network", "interface", iface, opts)
		local password = row.password ~= "" and row.password or old_password[row.key] or old_password_iface[iface]
		if password then u:set("network", iface, "password", password) end
		local dns = {}; if row.dns1 ~= "" then dns[#dns+1]=row.dns1 end; if row.dns2 ~= "" then dns[#dns+1]=row.dns2 end
		if #dns > 0 then u:set("network", iface, "peerdns", "0"); u:set_list("network", iface, "dns", dns) end
	end
	u:save("network"); u:commit("network")
	-- 将路由业务加入 firewall wan zone。用独立清单记录本插件拥有的列表项，
	-- 更新时只替换这些项，并顺带清除旧版本遗留的 xpon_* 接口名。
	local fu, wan_zone = uci.cursor(), nil
	fu:foreach("firewall", "zone", function(s) if s.name == "wan" then wan_zone = s[".name"] end end)
	if wan_zone then
		local function as_list(v)
			if type(v) == "table" then return v end
			local out = {}; for x in tostring(v or ""):gmatch("%S+") do out[#out + 1] = x end; return out
		end
		local xu = uci.cursor()
		local old_managed, drop, merged, have = as_list(xu:get("xpon", "firewall", "wan_networks")), {}, {}, {}
		for _, n in ipairs(old_managed) do drop[n] = true end
		for _, n in ipairs(as_list(fu:get("firewall", wan_zone, "network"))) do
			if not drop[n] and not n:match("^xpon_") and not have[n] then merged[#merged + 1] = n; have[n] = true end
		end
		for _, n in ipairs(wan_ifaces) do if not have[n] then merged[#merged + 1] = n; have[n] = true end end
		fu:set_list("firewall", wan_zone, "network", merged)
		fu:save("firewall"); fu:commit("firewall")
		if not xu:get_all("xpon", "firewall") then xu:section("xpon", "firewall", "firewall", {}) end
		xu:set_list("xpon", "firewall", "wan_networks", wan_ifaces)
		xu:save("xpon"); xu:commit("xpon")
	end
	-- 已提交的业务对象是组播关联真源，由后端统一重建配置，避免 LuCI
	-- 多 cursor/多 config 提交时 network 与 pon 状态不同步。
	if sys.call("/usr/bin/pon-multicast sync-services >/tmp/pon-multicast-sync.log 2>&1") ~= 0 then return nil, "mcast_sync" end
	return true
end

local function save_vlan(fv)
	local u = uci.cursor()
	-- 手动写入表单不携带回退开关字段，避免把已保存的开关/gem_base 重置
	if fv("fallback_enable") == nil and fv("gem_base") == nil then
		return
	end
	ensure_section(u, "xpon", "rules", "fallback")
	u:set("xpon", "rules", "enable", fv("fallback_enable") == "1" and "1" or "0")
	u:set("xpon", "rules", "gem_base", fv("gem_base") or "10")
	u:save("xpon")
	u:commit("xpon")
end

------------------------------------------------------------------------
-- 手工写入 GEM 规则（VLAN 页“手动写入”区块，命令与 TTL 实测一致）
--   addGemPortRule tagCtl 0xb tagFlag 1 userPort 3 vid <vid> dscp 0 pbit <pbit> gemPort <gem>
--   addDownRule    <gem> <ifmask> 0 0 1 1
--   delGemPortRule …（同键）/ delDownRule <gem>
-- 默认“已存在则跳过”：上行表中已有同 VID（或 vid=N/A 通配）规则时跳过，防重复/风暴。
-- 返回 (成功数, 跳过数, 失败数)。
------------------------------------------------------------------------

-- 上行表是否已覆盖本次写入：同 VID、vid=N/A 通配、或同 gemPort 任一命中即视为已存在
-- （OLT 下发的通配规则会把全部业务 VLAN 都覆盖掉——这正是“无需手工加规则”的信号）
local function gem_up_conflict(vid, gem)
	local text = klog_show("/userfs/bin/gponmapcmd showGemPortRule")
	local rows, _ = parse_gem_up(text)
	for _, r in ipairs(rows) do
		if r.vid == vid or r.vid == "N/A" or r.gemPort == gem then
			return true
		end
	end
	return false
end

local function manual_gem(fv)
	local svc = fv("msvc") or ""
	local svc_ok = false
	for _, sd in ipairs(service_defs) do
		if sd.id == svc then svc_ok = true break end
	end
	if not svc_ok then
		return 0, 0, 1
	end
	local vid = fv("mvid") or ""
	local pbit = tonumber(fv("mpbit") or "0")
	local gem = tonumber(fv("mgem") or "")
	local ifmask = fv("mifmask") or "0x0f"
	local mvid = fv("mmvid") or ""
	local op = fv("mgo") or "updown"
	if not validate_vid(vid) then return 0, 0, 1 end
	if op ~= "ponif" and op ~= "mvl" then
		if not gem or gem < 1 or gem > 65534 then return 0, 0, 1 end
		if not pbit or pbit < 0 or pbit > 7 then pbit = 0 end
		if not ifmask:match("^0[xX][0-9a-fA-F]+$") then ifmask = "0x0f" end
	end

	local ok, skip, fail = 0, 0, 0
	-- 参数已全部校验（数字/白名单），可安全拼接
	local function run(...)
		local parts = { ... }
		return sys.call("timeout 3 " .. table.concat(parts, " "))
	end

	if op == "ponif" then
		-- 手动添加 = 建内核 8021q 子接口 pon.<VID>（加/剥标签由内核完成，
		-- 驱动只按上行表把“带 Tag 帧”分类到 GEM 口；OLT 通配已覆盖则无需加 GEM 规则）
		run("vconfig add pon", vid, "2>/dev/null")
		run("ip link add link pon name pon." .. vid .. " type vlan id", vid, "2>/dev/null")
		run("ifconfig pon." .. vid .. " up 2>/dev/null")
		local exists = sh("ip link show pon." .. vid .. " 2>/dev/null")
		if exists ~= "" then
			ok = 1
			local u = uci.cursor()
			ensure_section(u, "xpon", svc, "service")
			u:set("xpon", svc, "vlan", vid)
			u:save("xpon")
			u:commit("xpon")
		else
			fail = 1
		end
	elseif op == "mvl" then
		-- 组播 M-VLAN 登记：xpon_ani_pass_mvlan(vid) 白名单（下行组播帧 VID 必须已登记）
		-- OLT 经 OMCI 下发的不用管；无下发时必须手动登记
		if mvid == "" then mvid = vid end
		if not validate_vid(mvid) then return 0, 0, 1 end
		-- 后台 detach 执行（xponigmpcmd ioctl 可能阻塞，同步会挂起页面）；UCI 先落盘，
		-- 重启由 xpon-app / xpon-mvlan.sh 重放登记
		sys.call("( /userfs/bin/xponigmpcmd mvlan add " .. mvid ..
			" >/dev/null 2>&1; /usr/bin/xpon-mvlan-snap.sh >/dev/null 2>&1 ) >/dev/null 2>&1 </dev/null &")
		ok = 1
		local u = uci.cursor()
		ensure_section(u, "xpon", svc, "service")
		u:set("xpon", svc, "mcast_vlan", mvid)
		u:save("xpon")
		u:commit("xpon")
	elseif op == "del" then
		local rc1 = run("/userfs/bin/gponmapcmd delGemPortRule tagCtl 0xb tagFlag 1 userPort 3",
			"vid " .. vid, "dscp 0", "pbit " .. pbit, "gemPort " .. gem)
		local rc2 = run("/userfs/bin/gponmapcmd delDownRule", gem)
		if rc1 == 0 and rc2 == 0 then ok = 1 else fail = 1 end
	elseif (fv("mskip") ~= "1") or not gem_up_conflict(vid, tostring(gem)) then
		local rc1 = run("/userfs/bin/gponmapcmd addGemPortRule tagCtl 0xb tagFlag 1 userPort 3",
			"vid " .. vid, "dscp 0", "pbit " .. pbit, "gemPort " .. gem)
		local rc2 = 0
		if op == "updown" then
			rc2 = run("/userfs/bin/gponmapcmd addDownRule", gem, ifmask, "0 0 1 1")
		end
		if rc1 == 0 and rc2 == 0 then
			ok = 1
			-- 回写配置，便于页面临场预填/守护脚本参考
			local u = uci.cursor()
			ensure_section(u, "xpon", svc, "service")
			u:set("xpon", svc, "vlan", vid)
			u:set("xpon", svc, "pbit", tostring(pbit))
			u:set("xpon", svc, "gem", tostring(gem))
			u:set("xpon", svc, "ifmask", ifmask)
			u:save("xpon")
			u:commit("xpon")
		else
			fail = 1
		end
	else
		skip = 1
	end
	return ok, skip, fail
end

function action_save()
	local page = formvalue("page") or "auth"
	local err = nil

	if page == "auth" then
		local loid = formvalue("loid") or ""
		local sn = (formvalue("sn") or ""):gsub("%s+", "")
		local atg = (formvalue("auth_type_g") or ""):lower()
		local ptech = formvalue("pon_tech") or "GPON"
		local pmode = pon_engine_for(ptech)
		local pon_mac = formvalue("pon_mac") or ""
		local onu_low = formvalue("onu_low") or ""
		-- EPON OUI（3 字节 hex）/ 厂商信息（4 字节 hex），oamcfgCmd localOui/localVenInfo
		local eoui = formvalue("epon_oui") or ""
		local even = formvalue("epon_ven_info") or ""
		if onu_low ~= "1" and onu_low ~= "2" then
			err = "onu_low"
		elseif pmode ~= "EPON" and (#sn ~= 12 or not sn:sub(1, 4):match("^[A-Za-z0-9]+$") or not sn:sub(5, 12):match("^[0-9a-fA-F]+$")) then
			err = "sn"
		elseif not ascii24_optional(formvalue("equipment_id") or "") then
			err = "equipment_id"
		elseif not specver_ok(formvalue("omci_spec_ver")) then
			err = "omci_spec_ver"
		elseif #eoui > 0 and not hex_len(eoui, 6, 6) then
			err = "epon_oui"
		elseif #even > 0 and not hex_len(even, 8, 8) then
			err = "epon_ven_info"
		elseif #pon_mac > 0 and not ponmac_ok(pon_mac) then
			err = "pon_mac"
		elseif #loid > 24 then
			err = "loid"
		elseif pmode == "EPON" and #loid == 0 then
			err = "loid"
		elseif pmode == "EPON" and #pon_mac == 0 then
			err = "pon_mac"
		elseif atg == "loid" and #loid == 0 then
			err = "loid"
		elseif atg == "sn" or atg == "regid" then
			-- PON SN 已在通用校验中按完整格式验证；这里只校验可选密码。
			-- SN 密码（可选）：ascii ≤10 / hex ≤20 位且只能 0-9a-f。
			if not err then
				local snf = (formvalue("xpon_sn_auth_type") or "ascii"):lower()
				local sp = formvalue("sn_password") or ""
				if #sp > 0 then
					if snf == "hex" then
						if #sp > 20 or not sp:match("^[0-9a-fA-F]*$") then err = "sn_password" end
					elseif snf == "regid" then
						if #sp > 36 then err = "sn_password" end
					elseif #sp > 10 then
						err = "sn_password"
					end
				end
			end
		elseif atg == "password" then
			-- 移动 Password：PON SN + REG_ID。
			local rp = formvalue("reg_id") or ""
			if #rp > 36 then
				err = "reg_id"
			end
		end
		if not err then
			local saved_ok, save_err = save_auth(formvalue)
			if not saved_ok then
				err = save_err or "persist_auth"
			else
				local onu_val = onu_type_hex(ptech, onu_low)
				local u = uci.cursor(); u:set("xpon","device","onu_type",onu_val); u:save("xpon"); u:commit("xpon")
				local rc = sys.call("/usr/bin/xpon-auth-native.sh")
				if rc ~= 0 then
					err = "native_write_" .. tostring(rc)
				else
					http.prepare_content("text/html; charset=utf-8")
					if schedule_reboot(8) then
						http.write("<html><head><meta charset='utf-8'><meta http-equiv='refresh' content='150;url=/cgi-bin/luci/'></head><body><h2>认证参数写入并回读成功</h2><p>重启任务已创建，设备将在约 8 秒后整机重启。</p><p>重启预计耗时 2-3 分钟，恢复后请重新登录核对当前生效值。</p></body></html>")
						return
					end
					err = "reboot_schedule"
				end
			end
		end
	elseif page == "services" then
		local ok, why = save_services(formvalue)
		if not ok then
			http.redirect(xpon_url("services", "err=" .. tostring(why))); return
		end
	elseif page == "provision" then
		local act = formvalue("action") or "save"
		if act == "manual" then
			local mok, mskip, mfail = manual_gem(formvalue)
			http.redirect(xpon_url("provision", "act=manual&mok=" .. mok ..
				"&mskip=" .. mskip .. "&mfail=" .. mfail))
			return
		end
		save_vlan(formvalue)
		if act == "fallback" then
			sys.call("/usr/bin/xpon-fallback.sh once >/dev/null 2>&1")
			http.redirect(xpon_url("provision", "act=fallback"))
		elseif act == "refresh" then
			http.redirect(xpon_url("provision", "act=refresh"))
		else
			sys.call("/usr/bin/xpon-apply.sh network >/dev/null 2>&1")
			http.redirect(xpon_url("provision", "act=save"))
		end
		return
	elseif page == "mode" then
		-- PON VLAN 接口管理（内核 802.1q：pon.<VID>，PPPoE/静态 IP 拨号子接口）
		local pvop = formvalue("ponvlan_op") or ""
		if pvop ~= "" then
			local vid = tonumber(formvalue("ponvlan_vid") or "")
			if not vid or vid < 1 or vid > 4094 then
				http.redirect(xpon_url("mode", "vlan=bad"))
				return
			end
			if pvop == "add" then
				local pbit = tonumber(formvalue("ponvlan_pbit") or "0") or 0
				if pbit < 0 or pbit > 7 then pbit = 0 end
				local ok, exists = ponvlan_add(vid, pbit, parse_mvids(formvalue("ponvlan_mvids")))
				http.redirect(xpon_url("mode", "vlan=add&rc=" ..
					(ok and exists and "ok" or "fail") .. "&vid=" .. vid))
				return
			elseif pvop == "del" then
				-- 删除即连持久化段一起删（否则重启后 netifd 会重建 pon.<VID>）
				local ok = ponvlan_del(vid, true)
				http.redirect(xpon_url("mode", "vlan=del&rc=" .. (ok and "ok" or "fail") .. "&vid=" .. vid))
				return
			end
		end
		save_onu_mode()
		return
	end

	if err then
		http.redirect(xpon_url(page, "err=" .. err))
		return
	end

	-- 应用：认证参数必须脱离 LuCI 请求后台下发。apply_auth 会重启 OMCI/PON
	-- 进程，若同步执行会在 HTTP 响应前断开网络，表现为“保存后被登出”。
	if page == "auth" then
		sys.call("( /usr/bin/xpon-apply.sh auth; /usr/bin/xpon-apply.sh mac ) >/tmp/xpon-auth-apply.log 2>&1 </dev/null &")
	elseif page == "services" then
		sys.call("( /etc/init.d/network reload; /etc/init.d/firewall reload; sleep 2; /usr/bin/pon-multicast apply-all ) >/tmp/pon-services.log 2>&1 </dev/null &")
	end

	http.redirect(xpon_url(page, "saved=1"))
end

------------------------------------------------------------------------
-- 页面
------------------------------------------------------------------------

function action_auth()
	local page_err = formvalue("err")
	-- r5 已将 OMCC 设为非阻断可选项；忽略旧页面 URL 遗留的废弃错误码。
	if page_err == "omcc_version" then page_err = nil end
	ltemplate.render("xpon/auth", {
		v = auth_values(),
		saved = (formvalue("saved") == "1"),
		err = page_err,
	})
end

function action_services()
	ltemplate.render("xpon/services", {
		services = service_values(), kernel_vlans = kernel_vlan_values(), multicast = multicast_values(),
		iptv_businesses = iptv_business_values(),
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
		vlan_cleaned = formvalue("vlan_cleaned"),
	})
end

function action_service_action()
	local key = formvalue("service") or ""
	local op = formvalue("op") or ""
	if not key:match("^[A-Za-z0-9_]+$") or (op ~= "up" and op ~= "down") then
		http.redirect(xpon_url("services", "err=service_action")); return
	end
	local uc, iface = uci.cursor(), nil
	uc:foreach("network", "xpon_service", function(v)
		if v.xpon_managed == "1" and v.service_key == key then iface = v.interface end
	end)
	iface = iface or ("xpon_" .. key)
	local s = uc:get_all("network", iface)
	if not s or s[".type"] ~= "interface" or s.xpon_managed ~= "1" or s.xpon_service ~= key then
		http.redirect(xpon_url("services", "err=service_owner")); return
	end
	local rc = sys.call((op == "up" and "ifup " or "ifdown ") .. iface .. " >/tmp/xpon-service-action.log 2>&1")
	http.redirect(xpon_url("services", rc == 0 and ("service_op=" .. op) or ("err=service_runtime_" .. rc)))
end

function action_mode()
	-- PON VLAN 添加/删除：GET + token（绕开部分 LuCI 21.02 对 POST 手写表单的会话拦截，
	-- 且 GET 提交不触发 post_on 的 CSRF 校验，这里手动核对 session token）
	local pvop = formvalue("ponvlan_op") or ""
	if pvop ~= "" then
		if formvalue("token") ~= dispatcher.context.authtoken then
			http.status(403, "Invalid token")
			return
		end
		local vid = tonumber(formvalue("ponvlan_vid") or "")
		if not vid or vid < 1 or vid > 4094 then
			http.redirect(xpon_url("mode", "vlan=bad"))
			return
		end
		if pvop == "add" then
			local pbit = tonumber(formvalue("ponvlan_pbit") or "0") or 0
			if pbit < 0 or pbit > 7 then pbit = 0 end
			local ok, exists = ponvlan_add(vid, pbit, parse_mvids(formvalue("ponvlan_mvids")))
			http.redirect(xpon_url("mode", "vlan=add&rc=" ..
				(ok and exists and "ok" or "fail") .. "&vid=" .. vid))
			return
		elseif pvop == "del" then
			-- 删除即连持久化段一起删（否则重启后 netifd 会重建 pon.<VID>）
			local ok = ponvlan_del(vid, true)
			http.redirect(xpon_url("mode", "vlan=del&rc=" ..
				(ok and "ok" or "fail") .. "&vid=" .. vid))
			return
		end
	end
	-- ONU 形态保存（modeform 改 GET 后走这里；POST 旧路径在 action_save）
	local low = formvalue("onu_low") or ""
	if low ~= "" then
		if formvalue("token") ~= dispatcher.context.authtoken then
			http.status(403, "Invalid token")
			return
		end
		save_onu_mode()
		return
	end
	local v = ponmode_values()
	v.vlan_msg, v.vlan_ok = vlan_msg_for(formvalue("vlan"), formvalue("rc"), formvalue("vid"))
	ltemplate.render("xpon/mode", {
		v = v,
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
	})
end

------------------------------------------------------------------------
-- GEM ↔ VLAN ↔ 业务 联动分析（vlan 页 / status 页共用）
-- 数据源：上行映射表（vid 列 × gemPort）、下行映射表（If Mask）、队列表（tcont）、
-- ME84（vid → gem 显式打标）、ponmgr GEM 硬表、本机业务配置（xpon.<svc>.vlan）
------------------------------------------------------------------------
local function build_gem_vlan_analysis(opt)
	opt = opt or {}
	local up_text    = opt.up_text    or klog_show("/userfs/bin/gponmapcmd showGemPortRule")
	local down_text  = opt.down_text  or klog_show("/userfs/bin/gponmapcmd showDownRule")
	local queue_text = opt.queue_text or klog_show("/userfs/bin/gponmapcmd showQueueRule")
	local gp_out     = opt.gp_out     or sh("/userfs/bin/ponmgr gpon get gemport 2>&1")
	local me84_out   = opt.me84_out   or sh("cat /tmp/ponstatus/me84_tag_info 2>/dev/null")
	local me171_out  = opt.me171_out  or sh("cat /tmp/ponstatus/me171_tag_info 2>/dev/null")
	local up_rows, _ = parse_gem_up(up_text)
	local down_total, down_rows, _ = parse_gem_down(down_text)
	local queue_rows, _ = parse_gem_queue(queue_text)

	-- 本机业务 VID → 名称（/etc/config/pon 的 service 列表）
	local svc_by_vid = {}
	for _, v in ipairs(service_values()) do
		if v.vlan_id ~= "" then svc_by_vid[v.vlan_id] = v.name end
	end

	-- ME84：下行显式打标（vid → gem）
	local me84_map = {}
	for l in (me84_out .. "\n"):gmatch("([^\n]+)") do
		local vid, gp = l:match("vid=(%d+).-gemPort=(%d+)")
		if vid then
			me84_map[gp] = me84_map[gp] or {}
			me84_map[gp][#me84_map[gp] + 1] = vid
		end
	end
	-- 上行表：显式 VID / 通配（vid=N/A）/ pbit
	local up_explicit, up_wild, up_pbit = {}, {}, {}
	for _, r in ipairs(up_rows) do
		local g = r.gemPort
		if r.vid ~= "N/A" and r.vid ~= "" then
			up_explicit[g] = up_explicit[g] or {}
			up_explicit[g][#up_explicit[g] + 1] = r.vid
		elseif r.vid == "N/A" then
			up_wild[g] = true
		end
		if r.pbit ~= "N/A" and r.pbit ~= "" then
			up_pbit[g] = up_pbit[g] or {}
			up_pbit[g][r.pbit] = true
		end
	end
	local down_map, queue_map = {}, {}
	for _, r in ipairs(down_rows) do down_map[r.gemPort] = r.ifMask end
	for _, r in ipairs(queue_rows) do
		queue_map[r.gemPort] = { tcont = r.tcont, queue = r.queue, pq = r.pqMode }
	end
	local omcc_gem = sh("/userfs/bin/ponmgr gpon get omcc 2>&1"):match("gemport%s+ID%s*:%s*(%d+)") or "57"

	-- GEM 全集：上行表 ∪ 下行表 ∪ ME84 ∪ ponmgr 硬表
	local gem_set, gem_meta = {}, {}
	for _, r in ipairs(up_rows) do gem_set[r.gemPort] = true end
	for _, r in ipairs(down_rows) do gem_set[r.gemPort] = true end
	for gp in pairs(me84_map) do gem_set[gp] = true end
	for l in (gp_out .. "\n"):gmatch("([^\n]+)") do
		local kind, gp, tcont, macif =
			l:match("(%a+) GEM Port:%s*(%d+), TCONT:%s*(%d+), MAC If:(%S+),")
			or l:match("GEM Port:%s*(%d+), TCONT:%s*(%d+), MAC If:(%S+),")
		if gp then
			gem_set[gp] = true
			gem_meta[gp] = { tcont = tcont, macif = macif, kind = kind or "" }
		end
	end

	local rows, wild_gems, gem_count = {}, 0, 0
	for g in pairs(gem_set) do
		local vids, vids_plain, seen = {}, {}, {}
		for _, v in ipairs(me84_map[g] or {}) do
			vids[#vids + 1] = v .. "（ME84 显式打标）"
			vids_plain[#vids_plain + 1] = v
		end
		for _, v in ipairs(up_explicit[g] or {}) do
			vids[#vids + 1] = v .. "（上行表）"
			vids_plain[#vids_plain + 1] = v
		end
		local plain = {}
		for _, v in ipairs(vids_plain) do
			if not seen[v] then seen[v] = true plain[#plain + 1] = v end
		end
		-- 业务推测：优先用实际 VID 匹配本机业务配置，不硬编码
		local biz_parts = {}
		for _, v in ipairs(plain) do
			if svc_by_vid[v] then
				biz_parts[#biz_parts + 1] = svc_by_vid[v] .. "（VID " .. v .. "）"
			else
				biz_parts[#biz_parts + 1] = "VID " .. v .. "（OLT 下发，未匹配本机业务配置）"
			end
		end
		local pbits = {}
		for p in pairs(up_pbit[g] or {}) do pbits[#pbits + 1] = p end
		table.sort(pbits)
		local meta = gem_meta[g] or {}
		local q = queue_map[g]
		local wild = up_wild[g]
		if wild then wild_gems = wild_gems + 1 end
		local role = (g == omcc_gem) and "OMCC 管理"
			or (g == "65534") and "组播"
			or (meta.kind == "Multicast") and "组播"
			or "业务"
		local biz = table.concat(biz_parts, "、")
		if biz == "" then
			if role == "组播" then
				biz = "组播/广播通道（下行专用，组播 VLAN 白名单）"
			elseif role == "OMCC 管理" then
				biz = "OMCI 管理通道"
			elseif wild then
				biz = "通配承载任意 VLAN（OLT 未标注业务，需 OLT 侧工单/抓包确认）"
			else
				biz = "（OLT 未标注，无显式 VID）"
			end
		elseif wild then
			biz = biz .. "（另含通配）"
		end
		gem_count = gem_count + 1
		rows[#rows + 1] = {
			gem = g, tcont = (q and q.tcont) or meta.tcont or "—",
			queue = (q and q.queue) or "—", pq = (q and q.pq) or "—",
			ifmask = down_map[g] or "", kind = meta.kind or "",
			macif = meta.macif or "", role = role,
			vids = table.concat(vids, "、"), wild = wild and "是（任意 VLAN）" or "否",
			wild_bool = wild, pbits = table.concat(pbits, ","), biz = biz,
			omcc = (g == omcc_gem),
		}
	end
	table.sort(rows, function(a, b) return tonumber(a.gem) < tonumber(b.gem) end)

	local has_up = #up_rows > 0
	local conclusion
	if has_up and wild_gems > 0 then
		conclusion = {
			level = "ok",
			title = "OLT 已下发通配规则（vid=N/A）",
			text = "上行表存在 " .. wild_gems .. " 个通配 GEM（任意 VLAN），所有带 Tag 的业务 VLAN 会自动匹配到对应 GEM，"
				.. "无需手动添加任何规则。请保持「已存在则跳过」勾选；重复/错配写入可能引发匹配冲突（风暴）并被运营商封锁。",
		}
	elseif has_up then
		conclusion = {
			level = "warn",
			title = "OLT 按 VID 显式下发（无通配）",
			text = "上行表只有显式 VID 规则。页面已将其与本机 Services 自动匹配；未匹配项表示 OLT 工单与本机配置可能不一致，请核对业务配置，禁止在通配关系不明时重复写表。",
		}
	else
		conclusion = {
			level = "manual",
			title = "尚未读取到 OMCI 业务规则",
			text = "GEM 上行表、ME84 和 ME171 当前为空。可能是 ONU 尚未进入 O5、OLT 尚未下发，或 OMCI 守护未就绪；请稍后刷新，勿在状态不明时写入规则。",
		}
	end
	local svc_parts = {}
	for _, v in ipairs(service_values()) do
		if v.vlan_id ~= "" then svc_parts[#svc_parts + 1] = v.name .. "=" .. v.vlan_id end
	end
	local me84_txt = (me84_out ~= "") and me84_out:gsub("\n", "；") or "无"
	local note = "上行表 vid=N/A = 该 GEM 通配承载任意 VLAN——OLT 未按 VID 显式下发，本机业务 VID（"
		.. (table.concat(svc_parts, "、") ~= "" and table.concat(svc_parts, "、") or "未配置")
		.. "）由通配 GEM 承载；ME84 显式打标：" .. me84_txt .. "。"

	return {
		rows = rows, note = note, conclusion = conclusion,
		gem_count = gem_count, wild_gems = wild_gems,
		has_up = has_up, has_omci = (#rows > 0 or me84_out ~= "" or me171_out ~= ""),
		down_total = down_total, omcc_gem = omcc_gem,
	}
end

function action_provision()
	local gem_up_text = klog_show("/userfs/bin/gponmapcmd showGemPortRule")
	local me84 = sh("cat /tmp/ponstatus/me84_tag_info 2>/dev/null")
	local me171 = sh("cat /tmp/ponstatus/me171_tag_info 2>/dev/null")
	local gem_up_rows = parse_gem_up(gem_up_text)
	-- G.988 结构化：ME84 下行打标 / ME171 打标操作 / ME268 GEM 口（OLT 下发视图）
	local me84_rows = {}
	for line in (me84 .. "\n"):gmatch("([^\n]+)") do
		local vid, gp, tp, tf =
			line:match("vid=(%d+)"), line:match("gemPort=(%d+)"),
			line:match("tpType=(%d+)"), line:match("tagFlag=(%d+)")
		if vid then me84_rows[#me84_rows + 1] = { vid = vid, gem = gp or "?", tp = tp or "?", tf = tf or "?" } end
	end
	local tm_names = {
		["0"] = "透传（不改标签）", ["1"] = "丢弃", ["21"] = "加 1 层标签",
		["22"] = "加 2 层标签", ["23"] = "加标签并改外层", ["31"] = "剥 1 层标签",
		["32"] = "剥 2 层标签", ["33"] = "剥标签并改内层", ["40"] = "改内层标签",
		["41"] = "改外层标签", ["42"] = "内外层都改",
	}
	local me171_rows = {}
	for line in (me171 .. "\n"):gmatch("([^\n]+)") do
		local tm = line:match("treatment_method=(%d+)")
		local fv = line:match("filter_inner_vid=(%d+)")
		if tm or fv then
			me171_rows[#me171_rows + 1] = {
				tm = tm or "?", tm_name = tm_names[tm] or "（设备未定义）",
				fv = fv or "?", fv_txt = (fv == "4096") and "不过滤内层 VID" or ("内层 VID " .. fv),
			}
		end
	end
	local gem_entries = parse_ponmgr_gem(sh("/userfs/bin/ponmgr gpon get gemport 2>&1"))
	local omci_me_dump = sh("for m in 84 171 268; do echo \"==== ME $m（G.988 §9.3） ====\"; timeout 2 /usr/sbin/gmtk_omci_dbg me $m 2>&1; done")
	local gem_down_text = klog_show("/userfs/bin/gponmapcmd showDownRule")
	local down_total, gem_down_rows = parse_gem_down(gem_down_text)
	local gem_queue_text = klog_show("/userfs/bin/gponmapcmd showQueueRule")
	local gem_queue_rows = parse_gem_queue(gem_queue_text)
	local analysis = build_gem_vlan_analysis({
		up_text = gem_up_text, down_text = gem_down_text, queue_text = gem_queue_text,
		me84_out = me84, me171_out = me171,
	})
	ltemplate.render("xpon/provision", {
		ctl_ver = "2",
		gem_up_rows = gem_up_rows,
		gem_down_rows = gem_down_rows,
		gem_down_total = down_total,
		gem_queue_rows = gem_queue_rows,
		me84_rows = me84_rows,
		me171_rows = me171_rows,
		gem_entries = gem_entries,
		omci_me_dump = omci_me_dump,
		analysis = analysis,
		services = service_values(),
		gem_up_raw = gem_up_text,
		gem_down_raw = gem_down_text,
		gem_queue_raw = gem_queue_text,
	})
end

local function onu_state_name(state_id)
	local names = {
		["O1"] = "O1 初始 Initial",
		["O2"] = "O2 待命 Standby",
		["O3"] = "O3 序列号 Serial-Number",
		["O4"] = "O4 测距 Ranging",
		["O5"] = "O5 运行 Operation（已注册）",
		["O6"] = "O6 中断 Interruption",
		["O7"] = "O7 去激活 Deactivated",
		["O9"] = "O9 紧急停止 Emergency-Stop（NGPON2）",
	}
	return names[state_id] or (state_id and ("O" .. state_id)) or ""
end

-- EPON：/tmp/epon_reg_auth_status 原厂进程不写，由本控制器按需生成。
-- 从 ponmgr epon get llid_info 读取 LLID：有效 LLID 即视为已注册并认证。
local function ensure_epon_status_file()
	local mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")
	local n = tonumber(mode)
	if not (n == 2 or n == 3 or n == 4 or n == 5 or n == 12) then return end
	local llid_info = sh("/userfs/bin/ponmgr epon get llid_info 2>&1")
	local llid = tonumber(llid_info:match("LLID%s*=%s*(%d+)"))
	local oui_out = sh("/userfs/bin/oamcfgCmd get localOui 2>&1")
	local ven_out = sh("/userfs/bin/oamcfgCmd get localVenInfo 2>&1")
	local loid_out = sh("/userfs/bin/oamcfgCmd get loid0 2>&1")
	local body = "Auth Status: \n"
	if llid and llid > 0 and llid < 32768 then
		body = "Auth Status: REG_AND_AUTH\nLLID: " .. llid .. "\n" .. llid_info
			.. "\nOUI: " .. oui_out .. "\nVendor Info: " .. ven_out .. "\nLOID: " .. loid_out .. "\n"
	end
	local f = io.open("/tmp/epon_reg_auth_status", "w")
	if f then f:write(body) f:close() end
end

------------------------------------------------------------------------
-- 光模块 DDM / 温度：
--   en7572.ko（BOB 驱动）→ /proc/lddla/debug 写 bob_info/bosa_info，
--     printk 打到 dmesg（private/lddla/en7572_cmd.c）：
--     bob_info  → LOS/Temp/VccT/Ibias/Imod/TxPwr(dBm)/RxPwr(dBm)
--     bosa_info → BOSA Temp / 校准（TxPwr_cal/RxPwr1~3_cal）
--   phy_10g.ko → /proc/pon_phy/temperature（hex，0x2c=44°C，可负=补码）
--   libblapi 用户态 → /userfs/bin/xponblapicmd get transTemp（%.1lf C）
--   CPU 温度 → /userfs/bin/cputemp_cmd（temp=[%d]）
------------------------------------------------------------------------

-- 千分位格式化
local function fmt_num(n)
	local s = tostring(n or 0)
	local out = {}
	local c = 0
	for i = #s, 1, -1 do
		c = c + 1
		out[#out + 1] = s:sub(i, i)
		if c % 3 == 0 and i > 1 then out[#out + 1] = "," end
	end
	return table.concat(out):reverse()
end

-- 执行写 proc 命令并取 dmesg 增量（与 klog_show 同法）
local function ktail(cmd)
	local before = tonumber(sh("dmesg 2>/dev/null | wc -l")) or 0
	sh(cmd)
	return sh("dmesg 2>/dev/null | tail -n +" .. (before + 1) ..
		" | sed 's/^\\[ *[0-9][0-9]*\\.[0-9][0-9]*\\] //'")
end

-- 汇总光模块 DDM 原始输出（无 /proc/lddla/debug 时返回空）
local function optical_diag()
	local notes = {}
	local out = {}
	local lddla_ok = (sh("test -e /proc/lddla/debug && echo yes") == "yes")
	local ko = sh("lsmod 2>/dev/null | awk '$1 ~ /^(en7572|phy_10g)/ {print $1}' | tr '\\n' ' '")
	if lddla_ok then
		local b = ktail("printf 'bob_info' > /proc/lddla/debug 2>/dev/null")
		if not (b:match("TxPwr") or b:match("RxPwr") or b:match("VccT")) then
			-- dmesg 增量可能被 OMCI 日志淹没/错过：回退全量最近一次 DDM 输出
			b = sh("dmesg 2>/dev/null | grep -E 'VccT|Ibias|Imod|TxPwr|RxPwr|bob_info' | tail -25")
		end
		if b:match("TxPwr") or b:match("RxPwr") then
			out[#out + 1] = "==== /proc/lddla/debug: bob_info（实时 DDM） ====\n" .. b
		else
			notes[#notes + 1] = "（诊断：bob_info 无 TxPwr/RxPwr 输出——DDM I2C 读取可能未就绪或光模块无响应）"
		end
		local s = ktail("printf 'bosa_info' > /proc/lddla/debug 2>/dev/null")
		if s == "" or s:match("^%s*$") then
			s = sh("dmesg 2>/dev/null | grep -E 'BOSA|bosa_info' | tail -15")
		end
		if s ~= "" and not s:match("^%s*$") then
			out[#out + 1] = "==== /proc/lddla/debug: bosa_info（BOSA 温度/校准） ====\n" .. s
		end
	else
		notes[#notes + 1] = "（诊断：/proc/lddla/debug 不存在，BOB 驱动未加载；当前相关模块：" ..
			(ko ~= "" and ko or "无 en7572/phy_10g") .. "）"
	end
	local tt = sh("/userfs/bin/xponblapicmd get transTemp 2>&1")
	if tt ~= "" then out[#out + 1] = "==== xponblapicmd get transTemp ====\n" .. tt end
	local pt = sh("cat /proc/pon_phy/temperature 2>/dev/null")
	if pt ~= "" then out[#out + 1] = "==== /proc/pon_phy/temperature ====\n" .. pt end
	local body = table.concat(out, "\n\n")
	if #notes > 0 then
		body = (body ~= "" and (body .. "\n\n") or "") .. table.concat(notes, "\n")
	end
	return body ~= "" and body or "（无任何输出：/proc/lddla/debug 不存在且备用命令均无输出）"
end

-- 收集一次状态（服务端渲染 + JSON 轮询共用同一份数据）
local function collect_status(include_details)
	include_details = include_details == true
	local function sec(title, cmd)
		return { title = title, body = sh(cmd) }
	end
	local function ksec(title, cmd)
		return { title = title, body = klog_show(cmd) }
	end

	-- 驱动模式比 UCI 更接近当前实际运行状态。EPON 家族包括
	-- 1G/10G/Turbo EPON；其余模式均使用 GPON/OMCI 查询接口。
	local sys_mode = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")
	local sys_mode_num = tonumber(sys_mode)
	local is_epon = sys_mode_num == 2 or sys_mode_num == 3 or sys_mode_num == 4
		or sys_mode_num == 5 or sys_mode_num == 12
	local pon_family = is_epon and "epon" or "gpon"
	local pon_info
	if is_epon then
		ensure_epon_status_file()
		pon_info = sh("cat /tmp/epon_reg_auth_status 2>/dev/null")
	else
		pon_info = sh("/userfs/bin/ponmgr gpon get info 2>&1")
	end
	local fec_out
	local mac_cnt
	if is_epon then
		fec_out = sh("/userfs/bin/ponmgr epon get txfec 2 2>&1; /userfs/bin/ponmgr epon get rxfec 2 2>&1")
		mac_cnt = sh("/userfs/bin/ponmgr epon get wanCntStatus 2>&1")
	else
		fec_out = sh("/userfs/bin/ponmgr gpon get fec_status 2>&1")
		mac_cnt = sh("/userfs/bin/ponmgr gpon get WanCnt 2>&1")
	end

	-- 光模块 DDM：收发光 dBm / BOSA 温度 / CPU 温度
	local diag = optical_diag()
	local tx_pwr = diag:match("TxPwr%s*=%s*([%-]?%d+%.%d+)%s*dBm")
	local rx_pwr = diag:match("RxPwr%s*=%s*([%-]?%d+%.%d+)%s*dBm")
	local vcc    = diag:match("VccT%s*=%s*([%-]?%d+%.?%d*)%s*V?")
	local ibias  = diag:match("Ibias%s*=%s*([%-]?%d+%.%d+)%s*mA")
	local imod   = diag:match("Imod%s*=%s*([%-]?%d+%.%d+)%s*mA")
	local los    = diag:match("LOS%s*=%s*(%d+)")
	local bosa_t = diag:match("BOSA%s+Temp%s*=%s*([%-]?%d+)'C")
	local xp_t   = sh("/userfs/bin/xponblapicmd get transTemp 2>&1"):match("temperature%s+is%s+([%-]?%d+%.?%d*)")
	-- /proc/pon_phy/temperature 的 hex（0x2c=44，>127 为负数补码）
	local pp_t
	local pp_hex = sh("cat /proc/pon_phy/temperature 2>/dev/null"):match("0x(%x+)")
	if pp_hex then
		pp_t = tonumber(pp_hex, 16)
		if pp_t and pp_t > 127 then pp_t = pp_t - 256 end
	end
	local xp_t_c = tonumber(xp_t)
	local bosa_t_c = tonumber(bosa_t)
	local temp_level = (xp_t_c and xp_t_c >= 75) and "warn" or "ok"
	local bosa_level = (bosa_t_c and bosa_t_c >= 75) and "warn" or "ok"
	-- OLT 下发的光功率门限（olt_info，单位 0.001 dBm）：收光低于低门限即告警
	local olt = sh("cat /tmp/ponstatus/olt_info 2>/dev/null")
	local rx_low = olt:match("lowOptThreshold=([%-]?%d+)")
	local rx_low_db = rx_low and (tonumber(rx_low) / 1000) or nil
	local rx_level = (los == "1") and "err"
		or (rx_pwr and rx_low_db and tonumber(rx_pwr) < rx_low_db and "warn")
		or (rx_pwr and "ok") or "info"
	local rx_note = (los == "1") and "（LOS 无光）"
		or (rx_pwr and rx_low_db and tonumber(rx_pwr) < rx_low_db and
			("（低于 OLT 低门限 " .. rx_low_db .. " dBm）")) or ""

	-- PON 接口收发（ifconfig pon 计数），可视化用 bars
	local ifc = sh("ifconfig pon 2>/dev/null | grep -E 'RX packets|TX packets'")
	local pon_rx  = tonumber(ifc:match("RX packets:(%d+)")) or 0
	local pon_tx  = tonumber(ifc:match("TX packets:(%d+)")) or 0
	local rx_err  = tonumber(ifc:match("RX packets:%d+ errors:(%d+)")) or 0
	local rx_drop = tonumber(ifc:match("RX packets:%d+ errors:%d+ dropped:(%d+)")) or 0
	local tx_err  = tonumber(ifc:match("TX packets:%d+ errors:(%d+)")) or 0
	local tx_drop = tonumber(ifc:match("TX packets:%d+ errors:%d+ dropped:(%d+)")) or 0
	local pmax = math.max(pon_rx, pon_tx, 1)
	local pon_bars = {
		{ name = "RX 收", val = fmt_num(pon_rx) .. "（err " .. rx_err .. " / drop " .. rx_drop .. "）",
		  pct = math.floor(pon_rx / pmax * 100), cls = "xpon-fill-rx" },
		{ name = "TX 发", val = fmt_num(pon_tx) .. "（err " .. tx_err .. " / drop " .. tx_drop .. "）",
		  pct = math.floor(pon_tx / pmax * 100), cls = "xpon-fill-tx" },
	}

	-- PON MAC 层计数不同于 ifconfig 的业务接口计数，可直接反映 FEC、
	-- CRC/BIP 和驱动丢包。字段格式已在 XGPON 真机及 AN7583 固件核对。
	local mac_rx = tonumber(mac_cnt:match("rxFrameCnt%s+(%d+)") or mac_cnt:match("rx packets:%s*(%d+)"))
	local mac_tx = tonumber(mac_cnt:match("txFrameCnt:%s*(%d+)") or mac_cnt:match("tx packets:%s*(%d+)"))
	local mac_rx_drop = tonumber(mac_cnt:match("rxDropCnt:%s*(%d+)")) or 0
	local mac_tx_drop = tonumber(mac_cnt:match("txDropCnt:%s*(%d+)")) or 0
	local fec_uncorrectable = tonumber(mac_cnt:match("rxFecErrorCnt:%s*(%d+)")
		or mac_cnt:match("rx FEC error cnt:%s*(%d+)")) or 0
	local fec_corrected = tonumber(mac_cnt:match("rxFecCerrorCnt:%s*(%d+)"))
	local crc_errors = tonumber(mac_cnt:match("rxCrcCnt:%s*(%d+)"))
	local bip_errors = tonumber(mac_cnt:match("BipError:%s*(%d+)"))
	local fec_rx = fec_out:match("fec_rx_status%s+is%s+(%w+)")
		or fec_out:match("fec_rx%s*=%s*(%d+)")
	local fec_tx = fec_out:match("fec_tx_status%s+is%s+(%w+)")
		or fec_out:match("FEC state%s*=%s*(%d+)")
	local fec_label = "RX " .. (fec_rx or "?") .. " / TX " .. (fec_tx or "?")
	local mac_label = (mac_rx and mac_tx) and
		("RX " .. fmt_num(mac_rx) .. " / TX " .. fmt_num(mac_tx)
		 .. "（drop " .. mac_rx_drop .. "/" .. mac_tx_drop .. "）") or "N/A"
	local err_parts = { "不可纠正 FEC " .. fec_uncorrectable }
	if fec_corrected then err_parts[#err_parts + 1] = "已纠正 FEC " .. fmt_num(fec_corrected) end
	if crc_errors then err_parts[#err_parts + 1] = "CRC " .. crc_errors end
	if bip_errors then err_parts[#err_parts + 1] = "BIP " .. bip_errors end
	local pon_error_label = table.concat(err_parts, " / ")
	local pon_error_level = (fec_uncorrectable > 0 or (crc_errors or 0) > 0 or (bip_errors or 0) > 0)
		and "warn" or "ok"

	-- 摘要：ONU State / 认证 / OMCC / 模式 / OLT 下发（尽量取 OMCI 可查状态）
	local omcc_out  = is_epon and "" or sh("/userfs/bin/ponmgr gpon get omcc 2>&1")
	local alloc_id  = omcc_out:match("alloc%s+ID%s*:%s*(%d+)")
	local gem_id    = omcc_out:match("gemport%s+ID%s*:%s*(%d+)")
	local gemport_out = is_epon and "" or sh("/userfs/bin/ponmgr gpon get gemport 2>&1")
	local tcont_out = is_epon and "" or sh("/userfs/bin/ponmgr gpon get tcont 2>&1")
	local gem_entries = gemport_out:match("Entries%s*:%s*(%d+)")
	local tcont_entries = is_epon and "?" or tostring(select(2, tcont_out:gsub("ALLOC ID:", "")))
	-- GEM ↔ VLAN 关联：ponmgr GEM 表 × 上行映射（vid 列）× ME84 显式打标
	local map_up, map_down, map_queue = "", "", ""
	if include_details and not is_epon then
		map_up = klog_show("/userfs/bin/gponmapcmd showGemPortRule")
		map_down = klog_show("/userfs/bin/gponmapcmd showDownRule")
		map_queue = klog_show("/userfs/bin/gponmapcmd showQueueRule")
	end
	local analysis = is_epon and { rows = {}, note = "EPON/OAM 模式不使用 GPON GEM/TCONT 映射。" }
		or include_details and build_gem_vlan_analysis({
			up_text = map_up, down_text = map_down, queue_text = map_queue,
			gp_out = gemport_out,
		}) or { rows = {}, note = "" }
	local gem_vlan = { rows = analysis.rows, note = analysis.note }

	-- ONU State：优先使用 ponmgr/EPON 认证状态文件的正式运行状态，
	-- 再回退内核日志；全部不可读时才根据 OMCC alloc 推断。
	local state_id
	if is_epon then
		local epon_auth = pon_info:match("Auth Status:%s*([^\n]+)")
		if epon_auth == "REG_AND_AUTH" then state_id = "5" end
	else
		state_id = pon_info:match("ONU State:%s*O(%d+)")
	end
	local last_pt = ""
	local pt_src = "ponmgr"
	if not state_id then
		last_pt = sh("dmesg 2>/dev/null | grep -o 'ponTime:O[0-9]*' | tail -1")
		pt_src = "dmesg"
	end
	if not state_id and last_pt == "" then
		last_pt = sh("logread 2>/dev/null | grep -o 'ponTime:O[0-9]*' | tail -1")
		pt_src  = "logread"
	end
	if not state_id then state_id = last_pt:match("O(%d+)$") end
	local state_inf  = false
	if not state_id and alloc_id and alloc_id ~= "1023" then
		state_id = "5"
		state_inf = true
	end
	local pt_tail = sh("dmesg 2>/dev/null | grep ponTime | tail -8")
	if pt_tail == "" then pt_tail = sh("logread 2>/dev/null | grep ponTime | tail -8") end

	local auth_out = is_epon and pon_info or sh("/userfs/bin/omcicfgCmd get authStat 2>&1")
	local auth_raw = is_epon and (pon_info:match("Auth Status:%s*([^\n]+)") or "")
		or (auth_out:match("authStat%s*=%s*(%d+)") or "")
	-- OLT 标识：/tmp/ponstatus/olt_info（axon_platform_manager 写 ME131 OLT-G）
	local olt_out    = sh("cat /tmp/ponstatus/olt_info 2>/dev/null")
	local olt_vendor = olt_out:match("oltVendorId%s*=%s*([%w]+)") or ""
	-- %s 会跨越换行；equipmentId 为空时不能误把下一行的键名当设备型号。
	local olt_equip  = olt_out:match("equipmentId[ \t]*=[ \t]*([^\r\n]*)") or ""
	olt_equip = util.trim(olt_equip)
	local olt_names  = {
		HWTC = "华为 Huawei", ZTEG = "中兴 ZTE", FHTT = "烽火 FiberHome",
		FHTS = "烽火 FiberHome", ALCL = "诺基亚 Nokia(原阿尔卡特)", UTST = "UT 斯达康",
	}
	local olt_label = olt_vendor
	if olt_names[olt_vendor] then olt_label = olt_names[olt_vendor] end
	if olt_equip ~= "" and olt_equip ~= "0" then olt_label = olt_label .. " / " .. olt_equip end

	local onu_env_raw = sh("fw_printenv onu_type 2>/dev/null")
	local onu_env   = onu_env_raw:match("=([0-9a-fA-F]+)$") or onu_env_raw
	local onu_cmd   = sh("grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1"):match("=(.*)$") or ""
	local onu_env_dec = decode_onu(onu_env)
	local onu_cmd_dec = decode_onu(onu_cmd)

	local epon_llid = is_epon and pon_info:match("LLID:%s*(%d+)") or nil
	local state_label
	local level = "info"
	if is_epon then
		if auth_raw == "REG_AND_AUTH" then
			state_label = "已注册并认证（MPCP LLID=" .. (epon_llid or "?") .. " / OAM REG_AND_AUTH）"
			level = "ok"
		elseif auth_raw == "REG_BUT_NOT_AUTH" then
			state_label = "已注册（MPCP LLID=" .. (epon_llid or "?") .. "），OAM 认证未完成（REG_BUT_NOT_AUTH）"
			level = "warn"
		elseif epon_llid then
			state_label = "已注册（MPCP LLID=" .. epon_llid .. "），OAM 认证进行中"
			level = "warn"
		else
			state_label = "未注册（MPCP 发现中，LLID 未分配）"
			level = "err"
		end
	else
		state_label = onu_state_name(state_id)
		if state_inf then
			state_label = "O5 运行（推断：OMCC alloc=" .. alloc_id .. " 已分配，dmesg 不可读）"
		end
		if state_id == "5" then
			level = (alloc_id and alloc_id ~= "1023") and "ok" or "warn"
		elseif state_id then
			level = "err"
		end
	end
	local auth_label
	if is_epon and auth_raw == "REG_AND_AUTH" then
		auth_label = "已注册并认证（REG_AND_AUTH）"
	elseif is_epon and auth_raw == "REG_BUT_NOT_AUTH" then
		auth_label = "已注册但未认证（REG_BUT_NOT_AUTH）"
	elseif auth_raw == "1" then
		auth_label = "已认证（authStat=1）"
	elseif auth_raw == "0" then
		auth_label = "未认证（authStat=0）"
	else
		auth_label = (auth_raw ~= "" and ("authStat=" .. auth_raw)) or "获取失败"
	end

	local summary = {
		{ label = is_epon and "ONU 状态（MPCP/OAM）" or "ONU 状态", value = state_label, level = level, group = "reg", wide = true },
		{ label = is_epon and "OAM 认证" or "OMCI 认证", value = auth_label,
		  level = (auth_raw == "1" or auth_raw == "REG_AND_AUTH") and "ok"
			or (auth_raw == "0" or auth_raw == "REG_BUT_NOT_AUTH") and "warn"
			or "info", group = "reg" },
		{ label = "OLT 设备", value = (olt_label ~= "" and olt_label)
			or (is_epon and "EPON/OAM 模式不查询 ME131") or "N/A（未收到 ME131 OLT-G）",
		  level = (olt_vendor ~= "") and "ok" or "info", group = "reg" },
		{ label = "PON 模式（驱动 sys_xpon_mode）", value = (sys_mode ~= "" and (sys_mode .. " → " .. (pon_mode_names[tonumber(sys_mode)] or "未知"))) or "N/A", group = "reg" },
		{ label = "ONU 形态（env / 本次启动）", value = (onu_env_dec.form .. " / " .. onu_cmd_dec.form), group = "reg" },
		{ label = "OMCC 分配（alloc / gemport）", value = ((alloc_id or "?") .. " / " .. (gem_id or "?")), group = "reg" },
		{ label = "OLT 下发（GEM / TCONT）", value = ((gem_entries or "?") .. " 条 / " .. tcont_entries .. " 条"
			.. (#gem_vlan.rows > 0 and "（关联见下）" or "")), group = "reg" },
		{ label = "PON 接口流量", value = "RX " .. fmt_num(pon_rx) .. " | TX " .. fmt_num(pon_tx), bars = pon_bars, group = "traffic", wide = true },
		{ label = "PON MAC 计数（" .. string.upper(pon_family) .. "）", value = mac_label,
		  level = (mac_rx and mac_tx) and "ok" or "info", group = "traffic", wide = true },
		{ label = "FEC 状态", value = fec_label, level = (fec_rx or fec_tx) and "ok" or "info", group = "traffic" },
		{ label = "PON 错误计数", value = pon_error_label, level = pon_error_level, group = "traffic" },
		{ label = "收光（OLT→ONU 下行）", value = (rx_pwr and (rx_pwr .. " dBm" .. rx_note) or "N/A"), level = rx_level, group = "optical" },
		{ label = "发光（ONU→OLT 上行）", value = (tx_pwr and (tx_pwr .. " dBm") or "N/A"), level = tx_pwr and "ok" or "info", group = "optical" },
		{ label = "供电电压（Vcc）", value = (vcc and (vcc .. " V") or "N/A"), level = vcc and "ok" or "info", group = "optical" },
		{ label = "偏置电流（Ibias）", value = (ibias and (ibias .. " mA") or "N/A"), level = ibias and "ok" or "info", group = "optical" },
		{ label = "调制电流（Imod）", value = (imod and (imod .. " mA") or "N/A"), level = imod and "ok" or "info", group = "optical" },
		{ label = "光模块温度（Transceiver）", value = (xp_t and (xp_t .. " °C") or "N/A"), level = (xp_t and temp_level or "info"), group = "optical" },
		{ label = "BOSA 温度", value = (bosa_t and (bosa_t .. " °C") or "N/A"), level = (bosa_t and bosa_level or "info"), group = "optical" },
	}
	if is_epon then
		-- EPON 无 OMCI/OMCC 概念：移除 GPON 专属卡片，避免显示 "?"
		local filtered = {}
		for _, it in ipairs(summary) do
			local l = it.label
			if not (l:match("^OMCC 分配") or l:match("^OLT 下发")) then
				filtered[#filtered + 1] = it
			end
		end
		summary = filtered
	end
	local sections = include_details and {
		is_epon and { title = "EPON 注册与认证", body = pon_info }
			or sec("认证参数 (omcicfgCmd)",
				"/userfs/bin/omcicfgCmd get loid; /userfs/bin/omcicfgCmd get sn; /userfs/bin/omcicfgCmd get vendorId; /userfs/bin/omcicfgCmd get equipmentId; /userfs/bin/omcicfgCmd get onuVersion; /userfs/bin/omcicfgCmd get omccVersion; /userfs/bin/omcicfgCmd get authStat"),
		is_epon and { title = "OLT-G", body = "EPON/OAM 模式不查询 OMCI ME 131。" }
			or sec("OLT-G (ME 131, OLT 标识/型号)",
				"timeout 3 /usr/sbin/gmtk_omci_dbg me 131 2>&1"),
		sec("PON 接口",
			"ifconfig pon 2>/dev/null | head -6; ip link show pon 2>/dev/null | head -3"),
		{ title = "PON MAC / FEC 原生计数（" .. string.upper(pon_family) .. "）",
		  body = "---- FEC ----\n" .. fec_out .. "\n\n---- counters ----\n" .. mac_cnt },
		{ title = "光模块 DDM（en7572.ko /proc/lddla/debug + phy_10g.ko /proc/pon_phy）",
		  body = (diag ~= "" and diag) or "（空：/proc/lddla/debug 不存在，BOB 驱动未加载）" },
		is_epon and { title = "EPON OAM 状态", body = pon_info }
			or { title = "OMCC / GEM / TCONT",
				body = omcc_out .. "\n" .. gemport_out .. "\n" .. tcont_out },
		is_epon and { title = "GEM 映射", body = "EPON/OAM 模式不使用 GPON GEM 映射。" }
			or { title = "GEM 上行映射", body = map_up },
		is_epon and { title = "GEM 下行映射", body = "EPON/OAM 模式不使用 GPON GEM 映射。" }
			or { title = "GEM 下行映射", body = map_down },
		is_epon and { title = "GEM 队列映射", body = "EPON/OAM 模式不使用 GPON GEM 映射。" }
			or { title = "GEM 队列映射", body = map_queue },
		ksec("PON VLAN 规则",
			"/userfs/bin/ponvlancmd showrule 1; /userfs/bin/ponvlancmd showrule 2; /userfs/bin/ponvlancmd showrule 3; /userfs/bin/ponvlancmd showrule 4"),
		sec("LED 状态",
			"for d in /sys/class/leds/*/brightness; do echo $d=$(cat $d 2>/dev/null); done"),
		sec("接口状态",
			"ifstatus wan 2>/dev/null | head -c 600; echo; ip addr show 2>/dev/null | grep -E '^[0-9]+:|inet ' | head -40"),
		{ title = "最近 PON 状态变化 (ponTime)",
		  body = pt_tail },
		sec("BBF247 标志",
			"for f in /proc/xgpon/bbf247Flag /proc/gpon/bbf247Flag; do [ -e $f ] && echo $f=$(cat $f 2>/dev/null); done"),
		sec("PON 模式 (onu_type)",
			"echo -n 'env: '; fw_printenv onu_type 2>/dev/null || echo N/A; echo -n 'cmdline: '; grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1; echo -n 'sys_xpon_mode: '; cat /proc/tc3162/sys_xpon_mode 2>/dev/null || echo N/A; lsmod 2>/dev/null | awk '$1 ~ /^xpon/ {print $1}' | tr '\\n' ' '"),
		sec("组播登记快照 (xpon-mvlan-snap.sh)",
			"cat /tmp/xpon-mvlan-act.txt 2>/dev/null || echo '未生成：开机/添加组播后由后台刷新'"),
		sec("OMCI 运行文件 (/tmp/ponstatus)",
			"for f in olt_info me84_tag_info me171_tag_info omci_trap_event error_cnts xpon_mode; do if [ -e /tmp/ponstatus/$f ]; then echo '--- ' $f; cat /tmp/ponstatus/$f 2>/dev/null; fi; done"),
	} or {}

	return {
		summary = summary,
		summary_groups = {
			{ id = "reg", name = "注册与链路（ONU 状态 / 认证 / OLT / 模式）" },
			{ id = "optical", name = "光模块 DDM（收光 / 发光 / 供电 / 温度）" },
			{ id = "traffic", name = "接口流量（PON 收发）" },
		},
		sections = sections,
		gem_vlan = gem_vlan,
	}
end

function action_status()
	-- 首屏只渲染骨架，设备状态由浏览器异步加载。
	ltemplate.render("xpon/status", { status = {
		summary = { { label = "PON 状态", value = "正在读取...", level = "info", wide = true } },
		sections = {}, gem_vlan = { rows = {}, note = "" },
	} })
end

function action_status_data()
	local ok, st = pcall(collect_status, false)
	if not ok then
		st = {
			summary = { { label = "ONU State", value = "读取失败：" .. tostring(st), level = "err" } },
			sections = {},
		}
	end
	http.prepare_content("application/json")
	http.write(encode_json(st))
end

function action_status_details()
	local ok, st = pcall(collect_status, true)
	if not ok then
		st = { sections = {}, gem_vlan = { rows = {}, note = "" }, error = tostring(st) }
	end
	http.prepare_content("application/json")
	http.write(encode_json({ sections = st.sections or {}, gem_vlan = st.gem_vlan or {}, error = st.error }))
end
