// xpon-luci：认证/业务表单联动校验 + 状态页自动刷新

// 认证页：记录打开时的初始值（页面默认已回显系统当前生效值），
// 用户修改后提交前弹窗确认“将重启 OMCI 重新注册”。
var xponAuthInit = {};
function xponAuthCaptureInit(form) {
	if (!form) return;
	var fields = ['onu_low', 'pon_tech', 'auth_type_g', 'loid', 'loid_password', 'def_sn', 'sn',
		'xpon_sn_auth_type', 'sn_password', 'reg_id', 'equipment_id', 'onu_version',
		'omcc_version', 'omci_spec_ver', 'pon_mac', 'epon_oui', 'epon_ven_info'];
	fields.forEach(function (id) {
		var el = form.elements[id];
		if (el) xponAuthInit[id] = el.value;
	});
}
function xponAuthChanged(form) {
	var k;
	for (k in xponAuthInit) {
		var el = form.elements[k];
		if (el && el.value !== xponAuthInit[k]) return true;
	}
	return false;
}

// 认证页：按认证方式显示 LOID 组 / SN 组（GPONPWD）/ REG_ID 组（移动 Password）
function xponAuthToggle() {
	var sel = document.getElementById('auth_type_g');
	var pm = document.getElementById('pon_tech');
	var epon = pm && (pm.value === 'EPON_10G_1G' || pm.value === 'EPON_10G_10G');
	var auth = (sel ? sel.value : 'LOID').toUpperCase();
	var loid = epon || auth === 'LOID';
	var pwd = auth === 'PASSWORD';
	document.querySelectorAll('.xpon-loid').forEach(function (el) {
		el.style.display = loid ? '' : 'none';
	});
	// SN 密码（ascii/hex，GPONPWD）只在 SN 认证时显示；移动 Password 只显示独立的 REG_ID
	document.querySelectorAll('.xpon-sn').forEach(function (el) {
		el.style.display = (loid || pwd) ? 'none' : '';
	});
	document.querySelectorAll('.xpon-regid').forEach(function (el) {
		el.style.display = pwd ? '' : 'none';
	});
	document.querySelectorAll('.xpon-gpon-auth').forEach(function (el) {
		el.style.display = epon ? 'none' : '';
	});
	document.querySelectorAll('.xpon-epon-auth').forEach(function (el) {
		el.style.display = epon ? '' : 'none';
	});
}

// 业务页：按拨号方式显示 PPPoE/静态字段
function xponProtoToggle(sel) {
	if (!sel) return;
	var fs = sel.closest('fieldset');
	if (!fs) return;
	var mode = sel.value;
	fs.querySelectorAll('.xpon-pppoe').forEach(function (el) {
		el.style.display = mode === 'pppoe' ? '' : 'none';
	});
	fs.querySelectorAll('.xpon-static').forEach(function (el) {
		el.style.display = mode === 'static' ? '' : 'none';
	});
}

function xponAuthCheck(form) {
	var pm = form.pon_tech.value;
	var epon = (pm === 'EPON_10G_1G' || pm === 'EPON_10G_10G');
	var auth = (form.auth_type_g.value || '').toUpperCase();
	if ((epon || auth === 'LOID') && form.loid.value.length > 24) {
		alert('LOID 不能超过 24 字节');
		return false;
	}
	if (epon && form.loid.value.trim().length === 0) {
		alert('EPON/10G-EPON 需保留 LOID 字段（多数运营商不校验，可填任意占位值）');
		return false;
	}
	var snv = form.sn.value.trim();
	if (!epon && snv.length === 0) {
		alert('GPON/XGPON/XGSPON 需要填写完整 PON SN');
		return false;
	}
	if (!epon && !/^[A-Za-z0-9]{4}[0-9A-Fa-f]{8}$/.test(snv)) {
		alert('PON SN 必须是 12 字符：前 4 位厂商代码 + 后 8 位十六进制序列号（如 AXON10503407）');
		return false;
	}
	if (form.equipment_id.value.trim() && !/^[\x20-\x7E]{1,24}$/.test(form.equipment_id.value.trim())) {
		alert('Equipment ID 非空时须为 1~24 个可打印 ASCII 字符');
		return false;
	}
	if (form.omci_spec_ver.value.trim()) {
		var sv = form.omci_spec_ver.value.trim();
		var svn = /^0[xX][0-9a-fA-F]+$/.test(sv) ? parseInt(sv, 16) : parseInt(sv, 10);
		if (isNaN(svn) || svn < 0 || svn > 255) {
			alert('OMCI 协议版本（specVer）需为 0~255 的十进制或 0x 十六进制');
			return false;
		}
	}
	if (epon && form.pon_mac.value.trim().length === 0) {
		alert('EPON/10G-EPON 模式必须填写 PON MAC（EPON OLT 绑定 MAC 不绑 SN）');
		return false;
	}
	if ((auth === 'SN' || auth === 'REGID') && form.sn_password.value.trim().length > 0) {
		var fmt = (form.xpon_sn_auth_type.value || 'ascii').toLowerCase();
		var pwd = form.sn_password.value.trim();
		if (fmt === 'hex') {
			if (pwd.length > 20 || !/^[0-9a-fA-F]*$/.test(pwd)) {
				alert('SN 密码（hex）需为 0~20 位 16 进制字符（0-9a-f）');
				return false;
			}
		} else if (fmt === 'regid') {
			if (pwd.length > 36) {
				alert('SN 密码（regid）不能超过 36 个字符');
				return false;
			}
		} else if (pwd.length > 10) {
			alert('SN 密码（ascii）不能超过 10 个字符');
			return false;
		}
	}
	if (auth === 'PASSWORD' && form.reg_id && form.reg_id.value.trim().length > 36) {
		alert('REG_ID（移动 Password）不能超过 36 个字符');
		return false;
	}
	if (form.pon_mac.value && !/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(form.pon_mac.value)) {
		alert('PON MAC 格式应为 00:AA:BB:01:23:40');
		return false;
	}
	if (form.epon_oui.value && !/^[0-9A-Fa-f]{6}$/.test(form.epon_oui.value)) {
		alert('EPON OUI 需为 6 位 16 进制字符（如 089AC7）');
		return false;
	}
	if (form.epon_ven_info.value && !/^[0-9A-Fa-f]{8}$/.test(form.epon_ven_info.value)) {
		alert('EPON 厂商信息需为 8 位 16 进制字符（如 4D150100）');
		return false;
	}
	var snChanged = xponAuthInit.sn !== undefined && form.sn.value !== xponAuthInit.sn;
	if (snChanged && !confirm('你正在修改 ONU 身份（PON SN，Vendor ID 将取前 4 位）。错误参数可能导致 OLT 拒绝注册。已记录原值，是否继续？')) {
		return false;
	}
	if (!confirm('保存后将立即重启设备，预计耗时 2-3 分钟，是否继续？')) {
		return false;
	}
	return true;
}

function xponAuthLiveCheck() {
	var sn=document.getElementById('sn'), loid=document.getElementById('loid');
	if (!sn || !loid) return;
	function validate() {
		var s=sn.value.trim();
		var invalid=s.length>0 && !/^[A-Za-z0-9]{4}[0-9A-Fa-f]{8}$/.test(s);
		sn.style.borderColor=invalid?'#d70000':'';
		sn.setCustomValidity(invalid?'须为 4 位厂商代码 + 8 位十六进制序列号':'');
		loid.setCustomValidity(new TextEncoder().encode(loid.value).length>24?'LOID 不能超过 24 字节':'');
	}
	sn.addEventListener('input',validate); loid.addEventListener('input',validate); validate();
}

function xponServicesCheck(form) {
	var seen = {}, ports = {}, rows = document.querySelectorAll('.pon-vlan-row');
	function val(idx, name) { var e=form.elements['vlan_'+idx+'_'+name]; return e ? e.value.trim() : ''; }
	function ipv4(s) { if (!s) return true; var p=s.split('.'); return p.length===4 && p.every(function(x){return /^\d{1,3}$/.test(x)&&+x<=255;}); }
	for (var i = 0; i < rows.length; i++) {
		var idx = rows[i].getAttribute('data-index');
		if (form.elements['vlan_' + idx + '_deleted'].value === '1') continue;
		var vid = parseInt(val(idx,'id'), 10), mtu=parseInt(val(idx,'mtu'),10);
		if (!(vid >= 1 && vid <= 4094)) { alert('VLAN ID 必须在 1~4094 之间'); return false; }
		if (seen[vid]) { alert('相同 VLAN ID 绝对禁止保存'); return false; }
		seen[vid] = true;
		if (!(mtu>=576&&mtu<=2000)) { alert('MTU 必须在 576~2000 之间'); return false; }
		var mode=val(idx,'mode'), proto=val(idx,'proto'), port=val(idx,'lan_port');
		if (mode==='bridged' && proto!=='none') { alert('桥接业务的协议必须选择“无（桥接）”'); return false; }
		if (mode==='routed' && proto==='none') { alert('路由业务必须选择 DHCP、PPPoE 或静态 IPv4'); return false; }
		if (proto==='pppoe' && !val(idx,'username')) { alert('PPPoE 业务必须填写用户名'); return false; }
		if (proto==='static' && (!val(idx,'ipaddr')||!val(idx,'netmask'))) { alert('静态 IPv4 必须填写地址和子网掩码'); return false; }
		for (var j=0,names=['ipaddr','netmask','gateway','dns1','dns2'];j<names.length;j++) if(!ipv4(val(idx,names[j]))){alert('IPv4 地址格式错误：'+val(idx,names[j]));return false;}
		if (port!=='none') { if(mode!=='bridged'){alert('LAN/STB 端口只能绑定到桥接业务');return false;} if(ports[port]){alert(port.toUpperCase()+' 已被其他业务绑定');return false;} ports[port]=true; }
		var mv=val(idx,'mcast_vlan'); if(mv && (val(idx,'service_type')!=='iptv' || +mv<1 || +mv>4094)){alert('组播 VLAN 只能关联 IPTV 业务，范围 1~4094');return false;}
	}
	return confirm('将重建所有 xpon_managed=1 的业务配置并重载网络。未受管配置不会修改。\n绑定 LAN/STB 端口可能使该端口暂时断连，是否继续？');
}
function xponVlanDelete(btn){if(!confirm('删除该受管业务及其 device/interface 配置，是否继续？'))return;var r=btn.closest('.pon-vlan-row'),i=r.dataset.index;r.querySelector('[name="vlan_'+i+'_deleted"]').value='1';r.style.display='none';}
function xponVlanAdd(){var c=document.getElementById('vlan_count'),n=parseInt(c.value,10)||0,t=document.getElementById('pon-vlan-template').innerHTML.replace(/__N__/g,n);document.getElementById('pon-vlan-body').insertAdjacentHTML('beforeend',t);c.value=n+1;xponServiceFields(document.querySelector('.pon-vlan-row[data-index="'+n+'"] select[name$="_mode"]'));}
function xponServiceFields(el){var row=el&&el.closest('.pon-vlan-row');if(!row)return;var mode=row.querySelector('select[name$="_mode"]').value,proto=row.querySelector('select[name$="_proto"]').value,type=row.querySelector('select[name$="_service_type"]').value;if(mode==='bridged'){row.querySelector('select[name$="_proto"]').value='none';proto='none';}else if(proto==='none'){row.querySelector('select[name$="_proto"]').value='dhcp';proto='dhcp';}row.querySelectorAll('[data-proto]').forEach(function(x){x.style.display=x.getAttribute('data-proto')===proto?'':'none';});row.querySelectorAll('[data-routed]').forEach(function(x){x.style.display=mode==='routed'?'':'none';});row.querySelectorAll('[data-iptv]').forEach(function(x){x.style.display=type==='iptv'?'':'none';});}
function xponMulticastToggle(cb){document.getElementById('multicast-fields').style.display=cb.checked?'':'none';}
function xponMulticastControl(form, changed) {
	if (!form) return;
	var snooping = form.elements.snooping;
	var proxy = form.elements.proxy;
	if (changed === 'proxy' && proxy.checked) snooping.checked = true;
	if (changed === 'snooping' && !snooping.checked) proxy.checked = false;
}

// 模式页：预览组合出的 onu_type；重启前二次确认
var xponModeInit = null;
function xponModeCaptureInit(form) {
	if (!form) return;
	var el = form.elements['onu_low'];
	xponModeInit = el ? el.value : null;
}
function xponModeChanged(form) {
	var el = form.elements['onu_low'];
	return !!el && xponModeInit !== null && el.value !== xponModeInit;
}

function xponModePreview() {
	var sel = document.getElementById('onu_low');
	var p = document.getElementById('onu-type-preview');
	if (!sel || !p) return;
	var o = sel.options[sel.selectedIndex];
	if (o) p.textContent = o.getAttribute('data-hex');
}

function xponModeCheck(form) {
	var sel = form.onu_low;
	var o = sel.options[sel.selectedIndex];
	var hex = (o && o.getAttribute('data-hex')) || '';
	if (!hex || !/^[0-9a-fA-F]{2}$/.test(hex)) {
		alert('请选择 SFU 或 HGU 形态');
		return false;
	}
	var reboot = form.apply.value === 'reboot';
	if (xponModeChanged(form) || reboot) {
		return confirm('将写入 onu_type=' + hex + '（' + (o ? o.text : '') + '）' +
			(reboot ? '并立即重启' : '（重启后生效）') + '。\n\n' +
			'PON 技术来自“认证 → PON 模式”；确保与 OLT 端口能力一致，否则可能无法注册（O5）。\n' +
			'恢复方法：U-Boot 提示符 setenv onu_type 62; saveenv; reset。\n\n' +
			(reboot ? '确认重启？' : '确认写入？'));
	}
	return true;
}

// 模式页：PON VLAN 接口（pon.<VID> 802.1q）添加/删除校验与确认
function xponPonVlanCheck(form) {
	var vid = parseInt(form.ponvlan_vid.value, 10);
	if (!(vid >= 1 && vid <= 4094)) {
		alert('VLAN ID 需在 1~4094 之间');
		return false;
	}
	if (form.ponvlan_op.value === 'del') {
		return confirm('删除 pon.' + vid + ' 802.1q 接口？' +
			'\n将同时删除 network 里的 wan_vlan 持久化段（否则重启后会重建）。' +
			'\n正在使用该接口拨号的业务会中断。');
	}
	var pbit = form.ponvlan_pbit.value;
	if (pbit && !/^[0-7]$/.test(pbit)) {
		alert('Pbit 需为 0~7 的整数');
		return false;
	}
	var mv = (form.ponvlan_mvids && form.ponvlan_mvids.value || '').replace(/，/g, ',').trim();
	if (mv) {
		var parts = mv.split(',');
		for (var i = 0; i < parts.length; i++) {
			var m = parseInt(parts[i], 10);
			if (!(m >= 1 && m <= 4094)) {
				alert('组播 VLAN 需为 1~4094 的整数，多个用逗号分隔');
				return false;
			}
		}
	}
	return confirm('创建 pon.' + vid + ' 802.1q 接口（Pbit=' + (pbit || '0') + '）？' +
		'\n将自动写入 network wan_vlan 段（重启后自动重建）。' +
		(mv ? '\n组播 VLAN：' + mv + '（mvlan add 登记）' : '') +
		'\n前提：PON 侧 GEM 通路已就绪（OLT 已下发通配规则），否则拨号会 PADO 超时。');
}

// 状态页：每 10 秒拉取只读状态（JSON：summary 卡片 + 单块可折叠日志）
(function () {
	var sum = document.getElementById('xpon-status-summary');
	var el = document.getElementById('xpon-status-dump');
	var note = document.getElementById('xpon-status-note');
	if (!el) return;
	var url = (window.L && L.url) ? L.url('admin/xpon/status/data') : 'status/data';
	var detailsUrl = (window.L && L.url) ? L.url('admin/xpon/status/details') : 'status/details';
	var loading = false;
	var detailsStarted = false;

	function noteMsg(msg) {
		if (!note) return;
		note.style.display = msg ? '' : 'none';
		note.textContent = msg || '';
	}

	function esc(s) {
		return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
			return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
		});
	}

	function render(data, includeDetails) {
		if (data.summary && sum) {
			var html = '';
			for (var i = 0; i < data.summary.length; i++) {
				var it = data.summary[i];
				var level = (it.level === 'ok' || it.level === 'warn' || it.level === 'err') ? it.level : 'info';
				var wide = it.wide ? ' xpon-sum-wide' : '';
				html += '<div class="xpon-sum-item xpon-sum-' + level + wide + '">' +
					'<div class="xpon-sum-label">' + esc(it.label) + '</div>' +
					'<div class="xpon-sum-value">' + esc(it.value) + '</div>';
				if (it.bars) {
					html += '<div class="xpon-ifbars">';
					for (var k = 0; k < it.bars.length; k++) {
						var b = it.bars[k];
						html += '<div class="xpon-ifbar">' +
							'<span class="xpon-ifbar-label">' + esc(b.name) + ' <b>' + esc(b.val) + '</b></span>' +
							'<div class="xpon-ifbar-track"><div class="xpon-ifbar-fill ' + esc(b.cls || '') + '" style="width:' + b.pct + '%"></div></div>' +
							'</div>';
					}
					html += '</div>';
				}
				html += '</div>';
			}
			sum.innerHTML = html;
		}
		var gv = document.getElementById('xpon-gemvlan');
		if (includeDetails && gv) {
			var html = '';
			if (data.gem_vlan && data.gem_vlan.rows && data.gem_vlan.rows.length) {
				html = '<fieldset class="cbi-section">' +
					'<legend>GEM ↔ VLAN 关联（OLT 下发 GEM × 上行映射 × ME84）</legend>' +
					'<table class="cbi-section-table xpon-gemvlan">' +
					'<tr><th>GEM 口</th><th>TCONT</th><th>MAC If</th><th>角色</th><th>显式 VLAN</th><th>通配</th></tr>';
				for (var i = 0; i < data.gem_vlan.rows.length; i++) {
					var r = data.gem_vlan.rows[i];
					html += '<tr><td><code>' + esc(r.gem) + '</code></td>' +
						'<td><code>' + esc(r.tcont) + '</code></td>' +
						'<td><code>' + esc(r.macif) + '</code></td>' +
						'<td>' + esc(r.role) + '</td>' +
						'<td>' + (r.vids ? esc(r.vids) : '<span class="xpon-na">无（未显式绑定）</span>') + '</td>' +
						'<td>' + esc(r.wild) + '</td></tr>';
				}
				html += '</table><div class="cbi-value-description">' + esc(data.gem_vlan.note || '') + '</div></fieldset>';
			}
			gv.innerHTML = html;
		}
		if (includeDetails && data.sections) {
			var out = [];
			for (var j = 0; j < data.sections.length; j++) {
				var s = data.sections[j];
				out.push('==== ' + s.title + ' ====\n' + (s.body || '（空）'));
			}
			el.textContent = out.join('\n\n');
		}
		noteMsg('');
	}

	function load() {
		if (loading) return;
		loading = true;
		var xhr = new XMLHttpRequest();
		xhr.open('GET', url, true);
		xhr.timeout = 5000;
		xhr.onload = function () {
			loading = false;
			if (xhr.status === 200 && xhr.responseText) {
				try {
					render(JSON.parse(xhr.responseText), false);
					window.setTimeout(loadDetails, 100);
				} catch (e) {
					noteMsg('状态解析失败：' + e.message + '（保留上次内容）');
				}
			} else {
				noteMsg('状态接口返回 HTTP ' + xhr.status + '（保留上次内容）');
			}
		};
		xhr.onerror = function () {
			loading = false;
			noteMsg('获取状态失败（保留上次内容）');
		};
		xhr.ontimeout = function () {
			loading = false;
			noteMsg('状态读取超时（保留上次内容）');
		};
		xhr.send();
	}

	function loadDetails() {
		if (detailsStarted) return;
		detailsStarted = true;
		function retryDetails(msg) {
			detailsStarted = false;
			noteMsg(msg);
		}
		var xhr = new XMLHttpRequest();
		xhr.open('GET', detailsUrl, true);
		xhr.timeout = 15000;
		xhr.onload = function () {
			if (xhr.status === 200 && xhr.responseText) {
				try {
					var data = JSON.parse(xhr.responseText);
					if (data.error) throw new Error(data.error);
					render(data, true);
				} catch (e) {
					retryDetails('详细诊断读取失败：' + e.message);
				}
			} else {
				retryDetails('详细诊断接口返回 HTTP ' + xhr.status);
			}
		};
		xhr.onerror = function () { retryDetails('详细诊断读取失败'); };
		xhr.ontimeout = function () { retryDetails('详细诊断读取超时'); };
		xhr.send();
	}
	load();
	setInterval(load, 10000);
})();
