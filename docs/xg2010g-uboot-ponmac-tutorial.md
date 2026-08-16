# XG2010G 10G-EPON 注册失败：U-Boot PON MAC 修复教程

> 适用范围：ECONET/Airoha EN7581 方案的光猫（Brightspeed/Gemtek XG2010G 等），
> OpenWrt 21.02 + xpon 固件，EPON（10G/1G-EPON、10G/10G-EPON）模式。
> 本教程所有命令均已在真机验证。

---

## 一、症状

- 状态页显示：`OAM 认证 = 获取失败`、`OLT 设备 = N/A（未收到 ME131 OLT-G）`、ONU 状态为空；
- `ifconfig pon`：RX 持续增长但 **dropped ≈ RX**（全部被过滤），TX 只有少量计数（周期性的注册重试）；
- 收光正常（比如 -20 ~ -26 dBm），PON 模式、认证参数都已按运营商填好，但就是不注册；
- 换到别的光猫/旧猫能正常注册。

## 二、根因

这台机器的 **MPCP 注册 MAC（EPON 注册阶段 OLT 唯一能看到的身份）来自 U-Boot 环境变量 `ethaddr`**，
而不是 LuCI 认证页里的 "PON MAC" 字段：

| 层面 | MAC 来源 | 作用 |
|---|---|---|
| 认证页 "PON MAC" 字段 | uci 配置 | 只改网卡显示 MAC（`ifconfig pon hw ether`），**不参与注册** |
| 网卡 MAC（/sys/class/net/pon/address） | 开机由 DSD/uci 设置 | 显示用 |
| **MPCP 注册 MAC** | **U-Boot env `ethaddr`** | **REGISTER_REQ 里发的就是它，OLT 按它放行** |

刷机教程（TTL 刷机时的 `setenv bootargs ... ethaddr=00:AA:BB:01:23:40 ...`）在 env 里留下了占位值
`00:AA:BB:01:23:40`。如果刷机后从未改过它，那么无论网页里填什么，OLT 收到的注册请求
始终带着占位 MAC → 不在白名单 → 永远不给 LLID → OAM 起不来 → 注册失败。

**结论：认证参数没配错，固件也没坏——只是注册身份（env ethaddr）被喂了占位值。**

## 三、诊断（确认是不是这个问题）

```sh
# 1. 内核启动日志里的 FE MAC（注册 MAC 的真源）
logread | grep -i "FE MAC"
# 期望看到占位值：eth0: FE MAC Ethernet address: 00:AA:BB:01:23:40

# 2. epon_oam 守护进程实际使用的 MAC
grep -m3 getOnuMacAddr /tmp/oam_debug
# 期望看到：src_mac= 00:aa:bb:01:23:40

# 3. 当前 env
fw_printenv | grep -E '^ethaddr='
fw_printenv -n bootargs | tr ' ' '\n' | grep ethaddr

# 4. LLID 是否分配（有值 = 已注册；0xFFFF/无 = 未注册）
/userfs/bin/ponmgr epon get llid_info
```

如果 1、2 显示占位 MAC 而它不是你运营商登记的旧猫 PON MAC，就是这个问题。

## 四、修复步骤

### 1. 备份

```sh
fw_printenv > /etc/env.bak
```

把 `/etc/env.bak` 拷出来保存（scp / 直接 cat 复制），改坏时可以对照恢复。

### 2. 写入正确的 PON MAC

```sh
# 目标 MAC = 旧猫的 PON MAC（注意是 PON MAC，不是 LAN MAC！）
# 北京联通等 EPON 区域：OLT 只认 PON MAC，SN/LOID 都不校验
fw_setenv ethaddr AA:BB:CC:DD:EE:FF
```

### 3. 同步 bootargs 里的 ethaddr=（关键，漏掉不生效）

`bootargs` 字符串里也带了一份 `ethaddr=`，必须一起改：

```sh
OLD=$(fw_printenv -n bootargs)
NEW=$(printf '%s' "$OLD" | sed 's/ethaddr=[0-9A-Fa-f:]*/ethaddr=AA:BB:CC:DD:EE:FF/')
[ "$NEW" != "$OLD" ] && fw_setenv bootargs "$NEW"
```

> 注意：`sed` 只替换 `ethaddr=` 这一个 token，其余启动参数原样保留。
> 改之前先看一遍 `fw_printenv bootargs`，确保 `onu_type` 等参数没被误伤。

### 4. 回读验证（必须做）

```sh
fw_printenv | grep -E '^ethaddr='
fw_printenv -n bootargs | tr ' ' '\n' | grep ethaddr
```

两个都显示新 MAC 才算写成功。

### 5. 重启并验证

```sh
sync && reboot
```

重启后逐项核对：

| 检查点 | 命令 | 期望 |
|---|---|---|
| 内核 FE MAC | `logread \| grep -i "FE MAC"` | 新的 PON MAC |
| OAM 注册 MAC | `grep -m3 getOnuMacAddr /tmp/oam_debug` | `src_mac= 新MAC` |
| LLID | `/userfs/bin/ponmgr epon get llid_info` | `LLID = <非零值>` |
| 状态页 | LuCI → PON设置 → 状态 | `已注册并认证（MPCP LLID=xx / OAM REG_AND_AUTH）` |
| 业务 | 状态页 PON 流量 / PPPoE 拨号 | RX dropped 不再全丢，拨号成功 |

## 五、风险与恢复

- **只改 env（配置数据），不碰固件**：内核、PON 驱动、epon_oam、rootfs 均不受影响。
- 清空 overlay（`rm -rf /overlay` 等恢复出厂操作）**不会清掉 env**，但刷机（`flash erase`）会。
- 如果手滑把 `bootargs` 写坏导致无法启动：接 TTL 进 U-Boot 提示符，
  用 `setenv bootargs <原值>`（对照之前保存的 `/etc/env.bak`）+ `saveenv` + `reset` 恢复。
- 如果只是想换回占位 MAC：重复第四步，把目标 MAC 换成原值即可。

## 六、常见问题

**Q：为什么网页里明明填了 PON MAC 还是不注册？**
A：如第二节所述，网页字段只改显示 MAC。注册 MAC 只认 env `ethaddr`（本固件行为）。

**Q：怎么拿到旧猫的 PON MAC？**
A：旧猫背面标签上的 "PON MAC"（华为/中兴部分猫的标签直接印有；注意区分 LAN MAC）。
最可靠的是旧猫插电进它的管理页看 PON 信息/注册状态。

**Q：没有旧猫怎么办？**
A：打运营商客服（如 10010 宽带专席）要求"换光猫重新绑定 MAC"，
把**新猫的实际 PON MAC**（`fw_printenv ethaddr` 里即将写入的值）报给装维绑定。

**Q：GPON/XGPON 也适用吗？**
A：不适用。GPON 体系按 SN/LOID（OMCI）认证，注册身份与 env `ethaddr` 无关。
本教程仅针对 EPON（10G/1G-EPON、10G/10G-EPON）的 MPCP MAC 注册。

**Q：改了 MAC 后收光还是偏弱（-26 dBm 左右）有关系吗？**
A：-26 dBm 在 10G-EPON 接收灵敏度（约 -28.5 dBm）范围内，能注册，但余量小。
建议顺带清洁法兰/接头（APC-UPC 不匹配是常见光衰源），避免以后波动掉线。

---

*基于 OpenWrt 21.02.1（airoha/en7581，XG2010G）+ 北京联通 10G-EPON 实机排障记录整理。*
