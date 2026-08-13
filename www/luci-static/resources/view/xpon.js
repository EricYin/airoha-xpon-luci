// xpon-luci：认证/业务表单联动校验 + 状态页自动刷新

// 认证页：按认证方式显示 LOID 组或 SN 组
function xponAuthToggle() {
	var sel = document.getElementById('auth_type_g');
	var loid = sel && sel.value === 'loid';
	document.querySelectorAll('.xpon-loid').forEach(function (el) {
		el.style.display = loid ? '' : 'none';
	});
	document.querySelectorAll('.xpon-sn').forEach(function (el) {
		el.style.display = loid ? 'none' : '';
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
	var auth = form.auth_type_g.value;
	if (auth === 'loid' && form.loid.value.length > 24) {
		alert('LOID 不能超过 24 字节');
		return false;
	}
	if (auth === 'sn' && form.sn.value.trim().length === 0) {
		alert('SN 认证需要填写 PON SN（12 字节）');
		return false;
	}
	if (form.pon_mac.value && !/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(form.pon_mac.value)) {
		alert('PON MAC 格式应为 00:AA:BB:01:23:40');
		return false;
	}
	return true;
}

function xponServicesCheck(form) {
	var ids = ['tr069', 'internet', 'iptv', 'voice'];
	var i, id;
	for (i = 0; i < ids.length; i++) {
		id = ids[i];
		if (!form[id + '_enable'].checked) continue;
		var vid = parseInt(form[id + '_vlan'].value, 10);
		if (!(vid >= 1 && vid <= 4094)) {
			alert('[' + id + '] 业务 VLAN 需在 1~4094 之间');
			return false;
		}
		var mtu = parseInt(form[id + '_mtu'].value, 10);
		if (!(mtu >= 576 && mtu <= 9600)) {
			alert('[' + id + '] MTU 需在 576~9600 之间');
			return false;
		}
		if (id === 'iptv' && form.iptv_mcast_vlan.value) {
			var mv = parseInt(form.iptv_mcast_vlan.value, 10);
			if (!(mv >= 1 && mv <= 4094)) {
				alert('[iptv] 组播 VLAN 需在 1~4094 之间');
				return false;
			}
		}
		if (id === 'iptv' && form.iptv_port.value) {
			var ports = form.iptv_port.value.trim().split(/\s+/);
			for (i = 0; i < ports.length; i++) {
				var p = parseInt(ports[i], 10);
				if (!(p >= 1 && p <= 4)) {
					alert('[iptv] 组播绑定 LAN 口需为 1~4 的数字（空格分隔）');
					return false;
				}
			}
		}
		if (form[id + '_proto'].value === 'pppoe' && !form[id + '_username'].value.trim()) {
			alert('[' + id + '] PPPoE 模式需要填写拨号账号');
			return false;
		}
	}
	return true;
}

// 模式页：校验 onu_type 格式；重启前二次确认
function xponModeCheck(form) {
	var val = (form.custom_onu_type.value || '').trim() || form.onu_type.value;
	if (!/^[0-9a-fA-F]{2}$/.test(val)) {
		alert('onu_type 需为 2 位十六进制（如 61 / 71）');
		return false;
	}
	if (form.apply.value === 'reboot') {
		return confirm('将写入 onu_type=' + val + ' 并立即重启。\n\n' +
			'确保该模式与 OLT 端口能力一致，否则可能无法注册（O5）。\n' +
			'恢复方法：U-Boot 提示符 setenv onu_type 62; saveenv; reset（或恢复切换前的值）。\n\n确认重启？');
	}
	return true;
}

// 状态页：每 5 秒拉取只读状态
(function () {
	var el = document.getElementById('xpon-status-dump');
	if (!el) return;
	var url = (window.L && L.url) ? L.url('admin/xpon/status/data') : 'status/data';
	function load() {
		var xhr = new XMLHttpRequest();
		xhr.open('GET', url, true);
		xhr.timeout = 8000;
		xhr.onload = function () {
			if (xhr.status === 200) {
				el.textContent = xhr.responseText;
			}
		};
		xhr.onerror = function () {
			el.textContent = '获取状态失败，请刷新页面重试';
		};
		xhr.send();
	}
	load();
	setInterval(load, 5000);
})();
