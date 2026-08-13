-- xpon-luci：PON设置 配置面板（LOID/SN/MAC/VLAN/业务）
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
	entry({"admin", "xpon", "provision"}, call("action_provision"), "OMCI", 4)
	entry({"admin", "xpon", "status"}, call("action_status"), "状态", 5)

	-- 手写表单直接提交各字段，不包含名为 data 的字段；post_on({data=true})
	-- 会导致路由条件不匹配并回到登录页，表现为“被登出且未保存”。
	entry({"admin", "xpon", "save"}, post("action_save")).leaf = true
	entry({"admin", "xpon", "multicast"}, post("action_multicast")).leaf = true
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

-- 写系统日志（logread 可查），单引号转义防注入
local function logger(tag, msg)
	sys.call("logger -t " .. tag .. " '" .. (msg or ""):gsub("'", "'\\''") .. "' 2>/dev/null")
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
	v.pon_mode          = uget("network", "xpon_auth", "pon_mode") or "GPON"
	v.auth_type_g       = uget("network", "xpon_auth", "auth_type_g") or "LOID"
	v.auth_type_e       = uget("network", "xpon_auth", "auth_type_e") or "LOID"
	v.loid              = uget("network", "xpon_auth", "loid") or ""
	v.loid_password     = uget("network", "xpon_auth", "loid_password") or ""
	v.sn                = uget("network", "xpon_auth", "sn") or ""
	v.xpon_sn_auth_type = uget("network", "xpon_auth", "xpon_sn_auth_type") or "ascii"
	-- PASSWORD（移动 SN+Password）落库为 SN + regid，读回时还原成独立选项
	if v.auth_type_g:lower() == "sn" and v.xpon_sn_auth_type:lower() == "regid" then
		v.auth_type_g = "password"
	end
	v.sn_ascii_password = uget("network", "xpon_auth", "sn_ascii_password") or ""
	v.sn_hex_password   = uget("network", "xpon_auth", "sn_hex_password") or ""
	v.sn_regid_password = uget("network", "xpon_auth", "sn_regid_password") or ""
	-- 页面只保留一个“SN 密码”输入框，格式由 xpon_sn_auth_type 决定（ascii/hex/regid）
	v.sn_password       = ((v.xpon_sn_auth_type == "hex") and v.sn_hex_password or
		(v.xpon_sn_auth_type == "regid") and v.sn_regid_password or v.sn_ascii_password) or ""
	-- 移动 Password = 独立 REG_ID 输入框，存 sn_regid_password（格式 regid）
	v.reg_id            = (v.xpon_sn_auth_type == "regid") and v.sn_regid_password or ""
	v.loid_password_set = (uget("network", "xpon_auth", "loid_password") or "") ~= ""
	-- 厂商信息缺省 = 固件出厂默认（OLT 校验设备标识符，必填；用户没保存过时直接回显）
	v.vendor_id         = uget("xpon", "device", "vendor_id") or "MTKG"
	v.equipment_id      = uget("xpon", "device", "equipment_id") or "KE2.119.241R2B"
	v.onu_version       = uget("xpon", "device", "onu_version") or "RP0201"
	v.omcc_version      = uget("xpon", "device", "omcc_version") or "0xA3"
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
	local rt = {
		loid         = omci_get("loid"),
		sn           = omci_get("sn"),
		vendor_id    = omci_get("vendorId"),
		equipment_id = omci_get("equipmentId"),
		onu_version  = omci_get("onuVersion"),
		omcc_version = omci_get("omccVersion"),
		spec_ver     = sh("/userfs/bin/omcicfgCmd get specVer 2>&1"):match("(%d+)") or "",
	}
	rt.pon_mac = sh("ifconfig pon 2>/dev/null"):match("HWaddr%s+([0-9A-Fa-f:]+)") or ""
	-- 打开页面默认读取系统现有值：UCI 未显式保存（或保存值为空）时，
	-- 表单回退到 OMCI/驱动实际生效值（rt）——用户看到即现状，改完保存才写入 UCI。
	-- 密码类不回显（留空 = 保持原值）。
	local function sys_fb(field, run, dflt)
		local s = uget("xpon", "device", field)
		if s ~= nil and s ~= "" then return s end
		return (run ~= nil and run ~= "") and run or dflt
	end
	-- 运行时值优先：UCI 只是下次启动的配置，不能覆盖 OMCI 当前实际值。
	-- 旧版本仅在 UCI 有值时显示 UCI，导致“页面显示已改、设备实际没改”。
	v.vendor_id     = (rt.vendor_id ~= "" and rt.vendor_id) or sys_fb("vendor_id", "", "MTKG")
	v.equipment_id  = (rt.equipment_id ~= "" and rt.equipment_id) or sys_fb("equipment_id", "", "KE2.119.241R2B")
	v.onu_version   = (rt.onu_version ~= "" and rt.onu_version) or sys_fb("onu_version", "", "RP0201")
	v.omcc_version  = (rt.omcc_version ~= "" and rt.omcc_version) or sys_fb("omcc_version", "", "0xA3")
	v.omci_spec_ver = sys_fb("omci_spec_ver", rt.spec_ver, "")
	-- PON MAC 默认取 DSD wan_mac（ifconfig pon 未就绪时兜底）
	local dsd_mac = sh("grep -o 'wan_mac[=:][0-9A-Fa-f:]*' /tmp/dsd.env 2>/dev/null | head -1"):match("[0-9A-Fa-f:]+$") or ""
	v.pon_mac       = sys_fb("pon_mac", (rt.pon_mac ~= "" and rt.pon_mac or dsd_mac), "")
	if v.loid == "" and rt.loid ~= "" then v.loid = rt.loid end
	if v.sn == "" and rt.sn ~= "" then v.sn = rt.sn end
	v.pon_mac_default = dsd_mac
	v.rt = rt
	local pt = uget("network", "xpon_auth", "pon_tech") or ""
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
	local rows, by_vid = {}, {}
	uci.cursor():foreach("network", "wan_vlan", function(s)
		local vid = tonumber(s.vlan_id or "")
		if vid and vid >= 1 and vid <= 4094 then
			local row = { name = s.remark or ("VLAN " .. vid), type = "vlan", vlan_id = tostring(vid),
				priority = s.priority or "0", remark = s.remark or "", runtime = false }
			by_vid[vid] = row; rows[#rows + 1] = row
		end
	end)
	-- 仅用有效 wan_vlan 作为可保存列表。运行时孤儿接口不能自动回填，否则删除
	-- UCI 后 pon.10 尚未消失时，下一次保存会把 VLAN 10 再次写回配置。
	local cfg = sh("cat /proc/net/vlan/config 2>/dev/null")
	for _, vid_s in cfg:gmatch("(pon%.(%d+))%s+|%s+(%d+)%s+|%s+pon") do
		local vid = tonumber(vid_s)
		if vid and by_vid[vid] then by_vid[vid].runtime = true end
	end
	table.sort(rows, function(a,b) return tonumber(a.vlan_id) < tonumber(b.vlan_id) end)
	return rows
end

local function multicast_values()
	local rows, by_vid, registered, bindings = {}, {}, {}, {}
	local raw = sh("/usr/bin/pon-multicast status")
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
	return { rows=rows, result=raw, error=formvalue("merr"), ok=formvalue("mok") }
end

function action_multicast()
	local op = formvalue("op") or ""
	local vid = tonumber(formvalue("vlan_id") or "")
	if not vid or vid < 1 or vid > 4094 then
		http.redirect(xpon_url("services", "merr=vlan")); return
	end
	local cmd
	if op == "add" then
		local port = tonumber(formvalue("port") or "1") or 1
		local ver = tonumber(formvalue("igmp_version") or "2") or 2
		local ifvid = tonumber(formvalue("interface_vid") or "")
		if port < 1 or port > 4 or (ver ~= 2 and ver ~= 3) or not ifvid or ifvid < 1 or ifvid > 4094 then
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
	http.redirect(xpon_url("services", rc == 0 and "mok=1" or ("merr=driver_" .. rc)))
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
			return ("已创建 <code>pon.%s</code> 802.1q 接口（已写入 network wan_vlan，重启自动重建；组播 M-VLAN 已写入配置，登记由后台执行、开机自动重放）。"):format(vid), true
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
		local sec = nil
		u:foreach("network", "wan_vlan", function(s)
			if s.vlan_id == tostring(vid) then sec = s[".name"] end
		end)
		if not sec then
			sec = "pon_vlan_" .. vid
			ensure_section("network", sec, "wan_vlan")
			u:set("network", sec, "vlan_id", tostring(vid))
			u:set("network", sec, "payload", "routed")
		end
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
	return pcall(function()
		sys.call("(timeout 3 vconfig rem pon." .. vid .. " 2>/dev/null || timeout 3 ip link del pon." .. vid .. " 2>/dev/null)")
		logger("xpon", "ponvlan_del vid=" .. vid .. " persist=" .. tostring(del_persist))
		if del_persist then
			local u = uci.cursor()
			u:foreach("network", "wan_vlan", function(s)
				if s.vlan_id == tostring(vid) then
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

-- 设备标识：OMCI equipmentId 属性为 20 字节可打印 ASCII。
local function ascii20(s)
	if #s < 1 or #s > 20 then return false end
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

local function save_auth(fv)
	local u = uci.cursor()
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
	-- EPON/XEPON 用 auth_type_e（TYPE_EPON_AUTH），EPON 只支持 LOID 认证，必须大写
	local auth_type_e = "LOID"
	-- 厂商信息：PON Vendor ID（4 字节 ASCII，须与 SN 前 4 位一致）；8 位 hex SN = 旧猫 setmac GPONSN 后半段
	local vendor_id = (fv("vendor_id") or ""):gsub("%s+", "")
	local sn = fv("sn") or ""
	if #sn == 8 and sn:match("^[0-9a-fA-F]+$") and #vendor_id == 4 then
		sn = vendor_id .. sn
	end
	-- EPON OUI = PON MAC 前 3 字节（含 OUI 的 MAC 才是 EPON OLT 认的东西），填了 MAC 就自动提取
	local pon_mac = fv("pon_mac") or ""
	local eoui = fv("epon_oui") or ""
	if eoui == "" and pon_mac:match("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$") then
		eoui = pon_mac:gsub(":", ""):sub(1, 6):upper()
	end
	-- OMCI 协议版本（specVer）：固件存 uint8；omcicfgCmd 用 atoi 解析 -> 统一落库为十进制
	local omci_spec_ver = (fv("omci_spec_ver") or ""):gsub("%s+", "")
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

	ensure_section("network", "xpon_auth", "xpon_auth")
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
	if fv("loid_password") and fv("loid_password") ~= "" then
		u:set("network", "xpon_auth", "loid_password", fv("loid_password"))
	end
	if sn ~= "" then u:set("network", "xpon_auth", "def_sn", sn); u:set("network", "xpon_auth", "sn", sn) end
	u:set("network", "xpon_auth", "xpon_sn_auth_type", snf)
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
	ensure_section("xpon", "device", "auth")
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
	if fv("loid_password") and fv("loid_password") ~= "" then
		u:set("xpon", "device", "loid_password", fv("loid_password"))
	end
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
	if fv("omcc_version") and fv("omcc_version") ~= "" then u:set("xpon", "device", "omcc_version", fv("omcc_version")) end
	if omci_spec_ver ~= "" then u:set("xpon", "device", "omci_spec_ver", omci_spec_ver) end
	if pon_mac ~= "" then u:set("xpon", "device", "pon_mac", pon_mac) end
	u:set("xpon", "device", "epon_oui", eoui)
	u:set("xpon", "device", "epon_ven_info", fv("epon_ven_info") or "")

	u:save("network")
	u:commit("network")
	u:save("xpon")
	u:commit("xpon")
end

local function save_services(fv)
	local rows, count = {}, tonumber(fv("vlan_count") or "0") or 0
	local seen = {}
	for i = 0, count - 1 do
		if fv("vlan_" .. i .. "_deleted") ~= "1" then
			local p = "vlan_" .. i .. "_"
			local row = { vlan_id=fv(p.."id") or "", priority=fv(p.."priority") or "0", remark=fv(p.."remark") or "" }
			local vid = tonumber(row.vlan_id)
			local pri = tonumber(row.priority)
			if not vid or vid < 1 or vid > 4094 or not pri or pri < 0 or pri > 7 then return nil, "vlan" end
			if seen[vid] then return nil, "vlan_duplicate" end
			seen[vid] = true
			rows[#rows + 1] = row
		end
	end
	local u = uci.cursor()
	local desired = {}; for _, row in ipairs(rows) do desired[tonumber(row.vlan_id)] = true end
	local cfg = sh("cat /proc/net/vlan/config 2>/dev/null")
	for vid_s in cfg:gmatch("pon%.(%d+)%s+|%s+%d+%s+|%s+pon") do
		local vid = tonumber(vid_s)
		if vid and not desired[vid] then sys.call("timeout 3 vconfig rem pon." .. vid .. " >/dev/null 2>&1") end
	end
	-- 完整重建有效 wan_vlan；清理 stock 遗留空 section，避免缺省创建 VLAN 10。
	u:foreach("network", "wan_vlan", function(s) u:delete("network", s[".name"]) end)
	for _, row in ipairs(rows) do
		local s = u:add("network", "wan_vlan")
		u:set("network",s,"vlan_id",row.vlan_id); u:set("network",s,"payload","routed")
		u:set("network",s,"priority",row.priority); u:set("network",s,"remark",row.remark); u:set("network",s,"xpon_managed","1")
	end
	u:save("network"); u:commit("network")
	return true
end

local function save_vlan(fv)
	local u = uci.cursor()
	-- 手动写入表单不携带回退开关字段，避免把已保存的开关/gem_base 重置
	if fv("fallback_enable") == nil and fv("gem_base") == nil then
		return
	end
	ensure_section("xpon", "rules", "fallback")
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
			ensure_section("xpon", svc, "service")
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
		ensure_section("xpon", svc, "service")
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
			ensure_section("xpon", svc, "service")
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
		local vendor_id = (formvalue("vendor_id") or ""):gsub("%s+", "")
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
		elseif #vendor_id > 0 and not vendor_id:match("^[%w]{4}$") then
			err = "vendor_id"
		elseif not ascii20(formvalue("equipment_id") or "") then
			err = "equipment_id"
		elseif #(formvalue("omcc_version") or "") > 0 and not (formvalue("omcc_version") or ""):match("^0[xX][0-9a-fA-F]{1,2}$") then
			err = "omcc_version"
		elseif not specver_ok(formvalue("omci_spec_ver")) then
			err = "omci_spec_ver"
		elseif #eoui > 0 and not eoui:match("^[0-9a-fA-F]{6}$") then
			err = "epon_oui"
		elseif #even > 0 and not even:match("^[0-9a-fA-F]{8}$") then
			err = "epon_ven_info"
		elseif #pon_mac > 0 and not pon_mac:match("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$") then
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
			-- GPON SN 认证：SN 必填（12 字节完整或 8 位 hex 后半段），SN 密码可选
			if #sn == 0 then
				err = "sn"
			elseif #sn ~= 12 and not (#sn == 8 and sn:match("^[0-9a-fA-F]+$")) then
				err = "sn"
			elseif #sn == 12 and #vendor_id == 4 and sn:sub(1, 4):upper() ~= vendor_id:upper() then
				-- PON Vendor ID 必须与 SN 前 4 位完全匹配（G.988 ME7 厂商代码）
				err = "vendor_id"
			end
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
			-- 移动 Password：只填 REG_ID（regid ≤36，旧猫认证页 REG_ID 直接抄）；SN 用厂商信息里已回显的当前值
			local rp = formvalue("reg_id") or ""
			if #rp > 36 then err = "reg_id" end
		end
		if not err then
			save_auth(formvalue)
			local onu_val = onu_type_hex(ptech, onu_low)
			local u = uci.cursor(); u:set("xpon","device","onu_type",onu_val); u:save("xpon"); u:commit("xpon")
			local rc = sys.call("/usr/bin/xpon-auth-native.sh")
			if rc ~= 0 then
				err = "native_write_" .. tostring(rc)
			else
				http.prepare_content("text/html; charset=utf-8")
				http.write("<html><head><meta charset='utf-8'><meta http-equiv='refresh' content='150;url=/cgi-bin/luci/'></head><body><h2>认证参数写入并回读成功</h2><p>设备将在约 8 秒后整机重启，当前 LuCI 登录会话将失效，这是正常现象。</p><p>重启预计耗时 2-3 分钟，恢复后请重新登录核对当前生效值。</p></body></html>")
				sys.call("( sleep 8; sync; reboot ) >/dev/null 2>&1 </dev/null &")
				return
			end
		end
	elseif page == "services" then
		local ok, why = save_services(formvalue)
		if not ok then err = why end
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
		sys.call("( /etc/init.d/network reload ) >/tmp/pon-services.log 2>&1 </dev/null &")
	end

	http.redirect(xpon_url(page, "saved=1"))
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
	ltemplate.render("xpon/services", {
		services = service_values(), multicast = multicast_values(),
		saved = (formvalue("saved") == "1"),
		err = formvalue("err"),
	})
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
				biz = "组播/广播通道（下行专用，组播 M-VLAN 白名单）"
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
local function collect_status()
	local function sec(title, cmd)
		return { title = title, body = sh(cmd) }
	end
	local function ksec(title, cmd)
		return { title = title, body = klog_show(cmd) }
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

	-- 摘要：ONU State / 认证 / OMCC / 模式 / OLT 下发（尽量取 OMCI 可查状态）
	local omcc_out  = sh("/userfs/bin/ponmgr gpon get omcc 2>&1")
	local alloc_id  = omcc_out:match("alloc%s+ID%s*:%s*(%d+)")
	local gem_id    = omcc_out:match("gemport%s+ID%s*:%s*(%d+)")
	local gem_entries = sh("/userfs/bin/ponmgr gpon get gemport 2>&1"):match("Entries%s*:%s*(%d+)")
	local tcont_entries = sh("/userfs/bin/ponmgr gpon get tcont 2>&1 | awk 'NR>1 && NF>0{n++} END{print n+0}'")
	-- GEM ↔ VLAN 关联：ponmgr GEM 表 × 上行映射（vid 列）× ME84 显式打标
	local analysis = build_gem_vlan_analysis()
	local gem_vlan = { rows = analysis.rows, note = analysis.note }

	-- ONU State：dmesg 优先，dmesg 不可读时回退 logread，
	-- 都没有则按 OMCC alloc（≠1023 说明已注册）推断 O5
	local last_pt  = sh("dmesg 2>/dev/null | grep -o 'ponTime:O[0-9]*' | tail -1")
	local pt_src   = "dmesg"
	if last_pt == "" then
		last_pt = sh("logread 2>/dev/null | grep -o 'ponTime:O[0-9]*' | tail -1")
		pt_src  = "logread"
	end
	local state_id   = last_pt:match("O(%d+)$")
	local state_inf  = false
	if not state_id and alloc_id and alloc_id ~= "1023" then
		state_id = "5"
		state_inf = true
	end
	local pt_tail = sh("dmesg 2>/dev/null | grep ponTime | tail -8")
	if pt_tail == "" then pt_tail = sh("logread 2>/dev/null | grep ponTime | tail -8") end

	local auth_out = sh("/userfs/bin/omcicfgCmd get authStat 2>&1")
	local auth_raw = auth_out:match("authStat%s*=%s*(%d+)") or ""
	-- OLT 标识：/tmp/ponstatus/olt_info（axon_platform_manager 写 ME131 OLT-G）
	local olt_out    = sh("cat /tmp/ponstatus/olt_info 2>/dev/null")
	local olt_vendor = olt_out:match("oltVendorId%s*=%s*([%w]+)") or ""
	local olt_equip  = olt_out:match("equipmentId%s*=%s*([%w._%-]+)") or ""
	local olt_names  = {
		HWTC = "华为 Huawei", ZTEG = "中兴 ZTE", FHTT = "烽火 FiberHome",
		FHTS = "烽火 FiberHome", ALCL = "诺基亚 Nokia(原阿尔卡特)", UTST = "UT 斯达康",
	}
	local olt_label = olt_vendor
	if olt_names[olt_vendor] then olt_label = olt_names[olt_vendor] end
	if olt_equip ~= "" and olt_equip ~= "0" then olt_label = olt_label .. " / " .. olt_equip end

	local sys_mode  = sh("cat /proc/tc3162/sys_xpon_mode 2>/dev/null")
	local onu_env   = sh("fw_printenv onu_type 2>/dev/null")
	local onu_cmd   = sh("grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1"):match("=(.*)$") or ""
	local onu_env_dec = decode_onu(onu_env)
	local onu_cmd_dec = decode_onu(onu_cmd)

	local state_label = onu_state_name(state_id)
	if state_inf then
		state_label = "O5 运行（推断：OMCC alloc=" .. alloc_id .. " 已分配，dmesg 不可读）"
	end
	local level = "info"
	if state_id == "5" then
		level = (alloc_id and alloc_id ~= "1023") and "ok" or "warn"
	elseif state_id then
		level = "err"
	end
	local auth_label
	if auth_raw == "1" then
		auth_label = "已认证（authStat=1）"
	elseif auth_raw == "0" then
		auth_label = "未认证（authStat=0）"
	else
		auth_label = (auth_raw ~= "" and ("authStat=" .. auth_raw)) or "获取失败"
	end

	local summary = {
		{ label = "ONU 状态", value = state_label, level = level, group = "reg", wide = true },
		{ label = "OMCI 认证", value = auth_label, group = "reg" },
		{ label = "OLT 设备", value = (olt_label ~= "" and olt_label) or "N/A（未收到 ME131 OLT-G）",
		  level = (olt_vendor ~= "") and "ok" or "info", group = "reg" },
		{ label = "PON 模式（驱动 sys_xpon_mode）", value = (sys_mode ~= "" and (sys_mode .. " → " .. (pon_mode_names[tonumber(sys_mode)] or "未知"))) or "N/A", group = "reg" },
		{ label = "ONU 形态（env / 本次启动）", value = (onu_env_dec.form .. " / " .. onu_cmd_dec.form), group = "reg" },
		{ label = "OMCC 分配（alloc / gemport）", value = ((alloc_id or "?") .. " / " .. (gem_id or "?")), group = "reg" },
		{ label = "OLT 下发（GEM / TCONT）", value = ((gem_entries or "?") .. " 条 / " .. tcont_entries .. " 条"
			.. (#gem_vlan.rows > 0 and "（关联见下）" or "")), group = "reg" },
		{ label = "PON 接口流量", value = "RX " .. fmt_num(pon_rx) .. " | TX " .. fmt_num(pon_tx), bars = pon_bars, group = "traffic", wide = true },
		{ label = "收光（OLT→ONU 下行）", value = (rx_pwr and (rx_pwr .. " dBm" .. rx_note) or "N/A"), level = rx_level, group = "optical" },
		{ label = "发光（ONU→OLT 上行）", value = (tx_pwr and (tx_pwr .. " dBm") or "N/A"), level = tx_pwr and "ok" or "info", group = "optical" },
		{ label = "供电电压（Vcc）", value = (vcc and (vcc .. " V") or "N/A"), level = vcc and "ok" or "info", group = "optical" },
		{ label = "偏置电流（Ibias）", value = (ibias and (ibias .. " mA") or "N/A"), level = ibias and "ok" or "info", group = "optical" },
		{ label = "调制电流（Imod）", value = (imod and (imod .. " mA") or "N/A"), level = imod and "ok" or "info", group = "optical" },
		{ label = "光模块温度（Transceiver）", value = (xp_t and (xp_t .. " °C") or "N/A"), level = (xp_t and temp_level or "info"), group = "optical" },
		{ label = "BOSA 温度", value = (bosa_t and (bosa_t .. " °C") or "N/A"), level = (bosa_t and bosa_level or "info"), group = "optical" },
	}
	local sections = {
		sec("认证参数 (omcicfgCmd)",
			"/userfs/bin/omcicfgCmd get loid; /userfs/bin/omcicfgCmd get sn; /userfs/bin/omcicfgCmd get vendorId; /userfs/bin/omcicfgCmd get equipmentId; /userfs/bin/omcicfgCmd get onuVersion; /userfs/bin/omcicfgCmd get omccVersion; /userfs/bin/omcicfgCmd get authStat"),
		sec("OLT-G (ME 131, OLT 标识/型号)",
			"timeout 3 /usr/sbin/gmtk_omci_dbg me 131 2>&1"),
		sec("PON 接口",
			"ifconfig pon 2>/dev/null | head -6; ip link show pon 2>/dev/null | head -3"),
		{ title = "光模块 DDM（en7572.ko /proc/lddla/debug + phy_10g.ko /proc/pon_phy）",
		  body = (diag ~= "" and diag) or "（空：/proc/lddla/debug 不存在，BOB 驱动未加载）" },
		sec("OMCC / GEM / TCONT",
			"/userfs/bin/ponmgr gpon get omcc 2>&1; /userfs/bin/ponmgr gpon get gemport 2>&1; /userfs/bin/ponmgr gpon get tcont 2>&1"),
		ksec("GEM 上行映射",
			"/userfs/bin/gponmapcmd showGemPortRule"),
		ksec("GEM 下行映射",
			"/userfs/bin/gponmapcmd showDownRule"),
		ksec("GEM 队列映射",
			"/userfs/bin/gponmapcmd showQueueRule"),
		ksec("PON VLAN 规则",
			"/userfs/bin/ponvlancmd showrule 1; /userfs/bin/ponvlancmd showrule 2; /userfs/bin/ponvlancmd showrule 3; /userfs/bin/ponvlancmd showrule 4"),
		sec("LED 状态",
			"for d in /sys/class/leds/*/brightness; do echo $d=$(cat $d 2>/dev/null); done"),
		sec("接口状态",
			"ifstatus wan 2>/dev/null | head -c 600; echo; ip addr show 2>/dev/null | grep -E '^[0-9]+:|inet ' | head -40"),
		sec("最近 PON 状态变化 (ponTime)",
			pt_tail),
		sec("BBF247 标志",
			"for f in /proc/xgpon/bbf247Flag /proc/gpon/bbf247Flag; do [ -e $f ] && echo $f=$(cat $f 2>/dev/null); done"),
		sec("PON 模式 (onu_type)",
			"echo -n 'env: '; fw_printenv onu_type 2>/dev/null || echo N/A; echo -n 'cmdline: '; grep -o 'onu_type=[0-9a-fA-F]*' /proc/cmdline | head -1; echo -n 'sys_xpon_mode: '; cat /proc/tc3162/sys_xpon_mode 2>/dev/null || echo N/A; lsmod 2>/dev/null | awk '$1 ~ /^xpon/ {print $1}' | tr '\\n' ' '"),
		sec("组播登记快照 (xpon-mvlan-snap.sh)",
			"cat /tmp/xpon-mvlan-act.txt 2>/dev/null || echo '未生成：开机/添加组播后由后台刷新'"),
		sec("OMCI 运行文件 (/tmp/ponstatus)",
			"for f in olt_info me84_tag_info me171_tag_info omci_trap_event error_cnts xpon_mode; do if [ -e /tmp/ponstatus/$f ]; then echo '--- ' $f; cat /tmp/ponstatus/$f 2>/dev/null; fi; done"),
	}

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
	local ok, st = pcall(collect_status)
	if not ok then
		st = {
			summary = { { label = "ONU State", value = "读取失败：" .. tostring(st), level = "err" } },
			sections = {},
		}
	end
	ltemplate.render("xpon/status", { status = st })
end

function action_status_data()
	local ok, st = pcall(collect_status)
	if not ok then
		st = {
			summary = { { label = "ONU State", value = "读取失败：" .. tostring(st), level = "err" } },
			sections = {},
		}
	end
	http.prepare_content("application/json")
	http.write(encode_json(st))
end
