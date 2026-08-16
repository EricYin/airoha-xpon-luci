# EN7581 10G-EPON 认证修复与调试

适用环境：ECONET/Airoha EN7581、OpenWrt 21.02、10G/1G-EPON。本文仅记录脱敏后的实测方法，不包含 MAC、LOID、序列号或宽带账号。

## 已验证的身份层

EPON 替换注册至少需要同时满足以下三层，任何一层错误都可能表现为周期掉线或 OLT 发送 DE_Register：

1. MPCP 注册身份：U-Boot `ethaddr`，即 OLT 注册阶段看到的 ONU MAC。
2. ONU/OAM 身份：LOID、`localOui`、`localVenInfo`、`onuVenID` 和 CTC ONUSN 中独立的 6 字节 ONU ID。
3. CTC 扩展协商：`ctcOui` 必须与 OLT Information OAMPDU 中的扩展 OUI 一致。

本次中兴 OLT 抓包显示扩展 OUI 为 `0x111111`。这个值是 CTC OAM 扩展组织标识，不是设备 OUI，也不是占位符。把它错误地改成 PON MAC 前三字节会导致 MPCP 已注册但 `authStatus=0`，OLT 不下发业务。

## 当前修复

- `xpon-epon-sn.sh` 为已校验的 `epon_oam` 提供 CTC ONUSN 6 字节 ONU ID 读写。
- OAM 引擎重启后重放 LOID、OUI、厂商信息、ONU Vendor ID 和 ONUSN。
- `xpon-epon-sn.sh watch` 监视 `epon_oam` PID；新进程就绪后自动重放完整身份，同一进程每 30 秒只读校验一次 ONUSN，仅在漂移时回写。
- `ctcOui` 与 `localOui` 解耦，默认及空值回退为抓包验证的 `111111`，仍允许手动覆盖。
- 状态页分开显示 MPCP 注册与 OAM 认证，且不再周期调用不稳定的 `ponmgr epon` 查询。

EPON 模式下，`omcicfgCmd get sn`、`equipmentId` 等 OMCI 运行值可能在重启后恢复为 DSD/出厂派生值，例如 AXON 或 BVMN。这些属于 GPON/OMCI 身份，不参与本机 EPON OAM 认证，也不应由 EPON 身份守护反复覆盖。认证页在 EPON 模式下会隐藏这些字段。

## 抓包方法

OAM 通道的外层封装可能使用 `0x2202/0x440b`，内层 `0x8809` 为 OAMPDU：

```sh
tcpdump -i oam -e -n -XX
```

重点比较 OLT Information OAMPDU 的扩展 OUI、能力列表，以及 ONU 应答中的 ONUSN、厂商和型号字段。

## 安全状态检查

```sh
/userfs/bin/oamcfgCmd get authStatus
/userfs/bin/oamcfgCmd get ctcOui
/userfs/bin/oamcfgCmd get localOui
/userfs/bin/oamcfgCmd get onuVenID
/usr/bin/xpon-epon-sn.sh get
cat /tmp/epon_reg_auth_status
tail -100 /tmp/oam_debug
```

某些固件的 `ponmgr epon get llid_info` 会段错误，并在 `libxpon` 的 GPON 事件队列路径产生 `Invalid shared information`。不要把它用于页面轮询；需要 LLID/MPCP 证据时优先读取 `/proc/epon/debug`、状态文件、内核日志或直接抓包。

## 身份模板

所有值应以被替换原装 ONU 的实际输出或抓包为准：

```text
PON MAC / ethaddr = 原装 ONU 的 PON MAC
EPON SN / ONUSN   = 原装 ONU 的 EPON SN
LOID              = 运营商下发的 LOID
ctcOui            = OLT Information OAMPDU 中的扩展 OUI
onuVenID          = 原装 ONU 的厂商代码
localOui          = 原装 ONU 的本地 OUI
localVenInfo      = 原装 ONU 的厂商信息
pon_tech          = 与线路一致的 EPON_10G_1G 或 EPON_10G_10G
```

本次设备观察到 EPON SN 的末字节比 PON MAC 大 `0x08`，但这不是已证明的中兴通用规则。只能作为输入辅助，最终必须以原装 ONU 输出或 OAM 抓包确认，不能静默自动派生。

## 判定顺序

1. 能收到 OLT Gate/Register 响应：光路与 MPCP 发现流程基本正常。
2. 获得 LLID：MPCP 注册已通过，但不代表 OAM 认证成功。
3. `authStatus=1` 且 PON RX 持续增长：OAM 扩展协商和业务下发正常。
4. PPPoE 完成认证并保持在线：业务 VLAN、账号和数据面均已打通。

拒绝码随身份组合变化只能说明 OLT 进入了不同校验分支，具体含义仍应结合 OAM 报文和 OLT 侧日志判断。
