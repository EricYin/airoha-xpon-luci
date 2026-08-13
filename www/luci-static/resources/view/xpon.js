// xpon-luci：认证/业务表单联动校验 + 状态页自动刷新

// 认证页：记录打开时的初始值（页面默认已回显系统当前生效值），
// 用户修改后提交前弹窗确认“将重启 OMCI 重新注册”。
var xponAuthInit = {};
function xponAuthCaptureInit(form) {
	if (!form) return;
	var fields = ['onu_low', 'pon_tech', 'auth_type_g', 'loid', 'loid_password', 'def_sn', 'sn',
		'xpon_sn_auth_type', 'sn_password', 'reg_id', 'vendor_id', 'equipment_id', 'onu_version',
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
		alert('EPON/10G-EPON 认证需要填写 LOID');
		return false;
	}
	if ((auth === 'SN' || auth === 'REGID') && form.sn.value.trim().length === 0) {
		alert('SN 认证需要填写 PON SN');
		return false;
	}
	if (auth === 'SN' || auth === 'REGID') {
		var snv = form.sn.value.trim();
		if (snv.length !== 12 && !(snv.length === 8 && /^[0-9a-fA-F]+$/.test(snv))) {
			alert('PON SN 需为 12 字节完整 SN，或 8 位十六进制后半段（保存时自动拼厂商代码）');
			return false;
		}
		if (snv.length === 12 && form.vendor_id.value.trim()) {
			var vid = form.vendor_id.value.trim().toUpperCase();
			if (snv.toUpperCase().substring(0, 4) !== vid) {
				alert('PON Vendor ID（' + vid + '）必须与 PON SN 前 4 位（' + snv.substring(0, 4) + '）完全匹配');
				return false;
			}
		}
	}
	if (form.vendor_id.value.trim() && !/^[A-Za-z0-9]{4}$/.test(form.vendor_id.value.trim())) {
		alert('PON Vendor ID 需为 4 字节 ASCII（如 ZTEG）');
		return false;
	}
	if (!/^[\x20-\x7E]{1,20}$/.test(form.equipment_id.value.trim())) {
		alert('设备标识为必填项，须为 1~20 个可打印 ASCII 字符；OMCI Equipment ID 字段不能容纳 24 字符格式');
		return false;
	}
	if (form.omcc_version.value.trim() && !/^0[xX][0-9a-fA-F]{1,2}$/.test(form.omcc_version.value.trim())) {
		alert('OMCC 版本需为 0x 开头的 1~2 位十六进制（如 0xA3 / 0xA4 / 0xB0）');
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
	var vendorChanged = xponAuthInit.vendor_id !== undefined && form.vendor_id.value !== xponAuthInit.vendor_id;
	var snChanged = xponAuthInit.sn !== undefined && form.sn.value !== xponAuthInit.sn;
	if ((vendorChanged || snChanged) && !confirm('你正在修改 ONU 身份（PON SN / Vendor ID）。错误参数可能导致 OLT 拒绝注册。已确认两者匹配并已记录原值，是否继续？')) {
		return false;
	}
	if (!confirm('保存后将立即重启设备，预计耗时 2-3 分钟，是否继续？')) {
		return false;
	}
	return true;
}

function xponAuthLiveCheck() {
	var vendor=document.getElementById('vendor_id'), sn=document.getElementById('sn'), loid=document.getElementById('loid');
	if (!vendor || !sn || !loid) return;
	function validate() {
		var v=vendor.value.trim().toUpperCase(), s=sn.value.trim().toUpperCase();
		var mismatch=s.length===12 && v.length===4 && s.substring(0,4)!==v;
		vendor.style.borderColor=mismatch?'#d70000':''; sn.style.borderColor=mismatch?'#d70000':'';
		vendor.setCustomValidity(mismatch?'SN 前 4 位必须与 Vendor ID 一致':'');
		sn.setCustomValidity(mismatch?'SN 前 4 位必须与 Vendor ID 一致':'');
		loid.setCustomValidity(new TextEncoder().encode(loid.value).length>24?'LOID 不能超过 24 字节':'');
	}
	vendor.addEventListener('input',validate); sn.addEventListener('input',validate); loid.addEventListener('input',validate); validate();
}

function xponServicesCheck(form) {
	var seen = {}, rows = form.querySelectorAll('.pon-vlan-row');
	for (var i = 0; i < rows.length; i++) {
		var idx = rows[i].getAttribute('data-index');
		if (form.elements['vlan_' + idx + '_deleted'].value === '1') continue;
		var vid = parseInt(form.elements['vlan_' + idx + '_id'].value, 10);
		if (!(vid >= 1 && vid <= 4094)) { alert('VLAN ID 必须在 1~4094 之间'); return false; }
		if (seen[vid]) { alert('相同 VLAN ID 绝对禁止保存'); return false; }
		seen[vid] = true;
	}
	if (form.multicast_enabled && form.multicast_enabled.checked) { var mv=parseInt(form.multicast_vlan.value,10); if(!(mv>=1&&mv<=4094)){alert('启用组播后必须填写 1~4094 的组播 VLAN');return false;} }
	return confirm('此操作将重载 PON 网络，可能导致短暂断连，是否继续？');
}
function xponVlanDelete(btn){if(!confirm('删除该 VLAN 将重载 PON 网络，可能导致短暂断连，是否继续？'))return;var r=btn.closest('tr'),i=r.dataset.index;r.querySelector('[name="vlan_'+i+'_deleted"]').value='1';r.style.display='none';}
function xponVlanAdd(){var c=document.getElementById('vlan_count'),n=parseInt(c.value,10)||0,t=document.getElementById('pon-vlan-template').innerHTML.replace(/__N__/g,n);document.getElementById('pon-vlan-body').insertAdjacentHTML('beforeend',t);c.value=n+1;}
function xponMulticastToggle(cb){document.getElementById('multicast-fields').style.display=cb.checked?'':'none';}

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
				alert('组播 M-VLAN 需为 1~4094 的整数，多个用逗号分隔');
				return false;
			}
		}
	}
	return confirm('创建 pon.' + vid + ' 802.1q 接口（Pbit=' + (pbit || '0') + '）？' +
		'\n将自动写入 network wan_vlan 段（重启后自动重建）。' +
		(mv ? '\n组播 M-VLAN：' + mv + '（mvlan add 登记）' : '') +
		'\n前提：PON 侧 GEM 通路已就绪（OLT 已下发通配规则），否则拨号会 PADO 超时。');
}

// 状态页：每 10 秒拉取只读状态（JSON：summary 卡片 + 单块可折叠日志）
(function () {
	var sum = document.getElementById('xpon-status-summary');
	var el = document.getElementById('xpon-status-dump');
	var note = document.getElementById('xpon-status-note');
	if (!el) return;
	var url = (window.L && L.url) ? L.url('admin/xpon/status/data') : 'status/data';

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

	function render(data) {
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
		if (gv) {
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
		if (data.sections) {
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
		var xhr = new XMLHttpRequest();
		xhr.open('GET', url, true);
		xhr.timeout = 8000;
		xhr.onload = function () {
			if (xhr.status === 200 && xhr.responseText) {
				try {
					render(JSON.parse(xhr.responseText));
				} catch (e) {
					noteMsg('状态解析失败：' + e.message + '（保留上次内容）');
				}
			} else {
				noteMsg('状态接口返回 HTTP ' + xhr.status + '（保留上次内容）');
			}
		};
		xhr.onerror = function () {
			noteMsg('获取状态失败（保留上次内容）');
		};
		xhr.send();
	}
	load();
	setInterval(load, 10000);
})();
