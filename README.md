# xpon-luci —— XG2010G PON 配置面板（LuCI）

面向 ECONET EN7581 XGPON ONT（stock `XG2010G_fw_1.0.0.13`）的中文 LuCI 插件，
参考 [8311-was-110-firmware-builder](https://github.com/djGrrr/8311-was-110-firmware-builder)
的“手写表单 + 后端脚本”模式实现，用于可视化设置：

- **认证**：LOID / LOID 密码 / PON SN / SN 密码 / 厂商 ID / 设备 ID / ONU 版本 / OMCC 版本 / PON MAC
- **模式**：切换 HGU / SFU × GPON / XGPON / XGSPON（写 U-Boot `onu_type` env，重启生效）
- **业务**：TR069(3600) / INTERNET(466, PPPoE) / IPTV(3169 + 组播 3799) / VOICE(3040, 静态或 DHCP)
- **VLAN 表**：只读回显 GEM 上行/下行、ponvlan 规则、桥接现状；可选“缺才补”回退守护
- **状态**：每 5s 刷新只读汇总（OMCC/GEM/TCONT/LED/接口/最近 PON 状态）

## 设计依据（重要逆向结论）

1. stock `sbin/netifd` 内置完整 xpon 引擎（= SDK `airoha_network/uci.c` 集成版），
   开机/重载网络时自动读 `network.xpon_auth` + `network.wan_vlan` 并执行
   `omcicfgCmd` → 重启 omci → `vconfig add pon.<vid>`。
2. **LOID 重启失效根因**：出厂 `auth_type_g='sn'`，netifd 只重放 SN 不重放 LOID。
   认证页改成 `loid` 后，重启由 netifd 自动重放，无需守护进程。
3. `xponconfig`(S00) 会用 `/tmp/dsd.env` 的 `fsan` 覆盖 `network.xpon_auth.sn`；
   `xpon-app`(START=11) 在其后重写用户配置。
4. stock LuCI 21.02 裁剪版**没有 `luci.model.cbi` 库**，因此采用手写 HTML 表单
   （`controller/xpon.lua` + `view/xpon/*.htm`），POST 带 `token` 防 CSRF。
5. **PON 模式切换**：stock 固件自带 `fw_setenv`（uboot-envtools，`/etc/fw_env.config`
   指向 `/dev/mtd1`=uenv 分区），运行时可直接改 U-Boot env。`onu_type` bootarg 字节
   由 SDK `dump_pon_type_mode_info` 官方解码：**bits[1:0]=ONU 类型（1=SFU、2=HGU）**，
   **bits[7:4]=PON 模式（1=GPON、6=XGPON、7=XGSPON）**。出厂 `71`=SFU+XGSPON，
   本机 TTL 当前 `61`=**SFU**+XGPON（uboot 仓库 README 曾把“61=HGU”写错，已修正；
   以 SDK + TTL 日志 952-953 行的 `PON MAC GET ONU_TYPE = SFU` / `ONU_MODE = XGPON`
   为准）；联通 HGU 家庭网关请切 `62`=HGU+XGPON。
6. **`61` 的来历**：刷机时按旧版 uboot README 手工写了 `bootflag=0` + 固定
   `bootargs`（含 `onu_type=61`）+ `bootcmd="flash read 0x602100 ...; bootm"`，
   所以后续每次启动都是 `onu_type=61`。它解出来就是 **SFU+XGPON**，不是 HGU；
   想切 HGU 用 `xpon-mode 62`（会同步改 `bootargs` 与独立 `onu_type` 变量）。
7. **EPON 不支持**：SDK 有 EPON 代码（`epon_oam`/`eponcmd`/`eponmapcmd` + `uci.c`
   `airoha_epon_active()` 走 `oamcfgCmd set loid0`），但绑定 `eth0.1~eth0.4` 与
   独立 EPON 驱动；XG2010G 无 EPON PHY、厂商迁移未启用，LuCI 不暴露 EPON。

## 文件清单

```
etc/config/xpon                          # 私有配置（厂商信息/业务模板/LED/回退）
etc/uci-defaults/zzz-xpon                # 首次安装：重建默认包 + 补 xpon_auth 缺省键
etc/init.d/xpon-app                      # START=11：重放认证/MAC/LED/IPTV 组播，可选规则守护
etc/hotplug.d/iface/25-iptv-port         # IPTV 专口透传（可选，stb_port 非空时生效）
usr/bin/xpon-apply.sh                    # 后端：UCI → omcicfgCmd → 重启 omci → reload network
usr/bin/xpon-iptv.sh                     # IPTV 组播后端：xponigmpcmd M-VLAN/端口/版本/快离 + ecnt snooping
usr/bin/xpon-fallback.sh                 # 规则守护：仅缺才补，已存在即跳过
usr/bin/xpon-mode                        # CLI 一键切换 PON 模式（TTL/SSH，见下）
usr/lib/lua/luci/controller/xpon.lua     # 菜单 + 保存/应用 + 状态数据
usr/lib/lua/luci/view/xpon/auth.htm      # 认证页
usr/lib/lua/luci/view/xpon/mode.htm      # PON 模式切换页（HGU/SFU × GPON/XGPON/XGSPON）
usr/lib/lua/luci/view/xpon/services.htm  # 业务页
usr/lib/lua/luci/view/xpon/vlan.htm      # VLAN 表页
usr/lib/lua/luci/view/xpon/status.htm    # 状态页
www/luci-static/resources/view/xpon.js   # 表单联动校验 + 状态轮询
```

## 安装（SSH/TFTP 覆盖拷贝，不依赖 opkg）

```sh
# 在本机把 xpon-luci/ 打包成 tar，拷到 /tmp（scp/tftp 均可）
scp xpon-luci.tar.gz root@192.168.0.1:/tmp/

cd /tmp && tar xzf xpon-luci.tar.gz
cp -a xpon-luci/* /

# 清 LuCI 缓存并重启相关服务
rm -rf /tmp/luci-* /tmp/.uci
/etc/init.d/xpon-app enable
/etc/init.d/xpon-app start
/etc/init.d/uhttpd restart
```

浏览器打开 `http://192.168.0.1/cgi-bin/luci` → 菜单 **XG2010G PON**。

## CLI 一键切换（TTL / SSH，不进网页）

```sh
xpon-mode                     # 查看当前模式（env / cmdline / 驱动 / 模块 / BBF247）
xpon-mode 62                  # 写入 onu_type=62（HGU+XGPON，联通推荐，重启后生效）
xpon-mode 72 -r               # 写入 72（HGU+XGSPON）并立即重启
```

等同于 LuCI“模式”页；写入复用 `xpon-apply.sh ponmode`（同步更新 `bootargs`
里的 `onu_type=` 与独立 `onu_type` 变量）。选错无法 O5 时在 U-Boot 提示符恢复：
`setenv onu_type 62; saveenv; reset`（或恢复切换前的值）。

模式速查（HGU=末尾 2，SFU=末尾 1）：

```text
62 = HGU + XGPON   推荐（联通 HGU 家庭网关：LAN 桥接 + VEIP + 组播完整）
61 = SFU + XGPON   本机 TTL 当前值（纯桥/实验，无 VEIP/组播引擎）
72 = HGU + XGSPON  10G 对称（XGS-PON 端口）
71 = SFU + XGSPON  出厂默认
12 = HGU + GPON    11 = SFU + GPON（GPON-only 实验）
2x = EPON          勿选（SDK 有代码，XG2010G 硬件未启用）
```

## 使用步骤（联通 HGU 示例）

1. **认证页**：认证方式选 `LOID`；LOID 填 `H060161032`；PON SN 保持 12 字节出厂值；
   厂商 ID `MTKG`。保存后 OMCI 重启 → 串口应出现 `ponTime:O5`。
2. **模式页**（仅当需要切换时）：本机 TTL 当前 `61`=SFU+XGPON；联通 HGU 全家桶
   （LAN 桥接 + IPTV 组播）请选 `62`=HGU+XGPON；XGS-PON 对称端口选 `72`。
   SFU 变体无 VEIP/组播引擎，不要把 `x1` 当作 HGU 用。选好后“仅保存到 env”或
   “保存并重启”。切错无法注册时，在 U-Boot 提示符恢复：`setenv onu_type 62; saveenv; reset`。
3. **业务页**：
   - INTERNET：VLAN 466，PPPoE 拨号，账号 `clan1909302010`，MTU 1492；
   - IPTV：VLAN 3169，组播 VLAN 3799（可留空，多数省份 OLT 直接在 3169 内送组播），
     PPPoE/IPoE 拨号（按省份），STB 带标签禁二次打标；组播模式 Snooping/Proxy V2，
     快速离开建议开启；可单独绑定某个 LAN 口（`iptv_port`，port 号需真机验证）。
   - VOICE：VLAN 3040，静态 `23.50.128.40/255.255.240.0` 网关 `23.50.128.1`（部分省份 DHCP）；
   - TR069：VLAN 3600，pbit 7，MTU 1500（无 ACS 可不启用）。
   保存后 netifd 自动建 `pon.466 / pon.3169 / pon.3040 / pon.3600`。
4. **VLAN 表页**：确认 OLT 已下发 GEM 规则（`showGemPortRule` 非空）。
   若 OLT 不下发且业务不通，再开启“回退补表”（默认关闭，防重复/防风暴）。
5. **状态页**：确认 `ponTime:O5`、OMCC 有条目、PPPoE 拿到 IP。

## 安全红线（防风暴 / 防封号）

- HGU 模式不整桥：`payload` 一律 `routed`，PON VLAN 不进 `br-lan`。
- IPTV STB 自带 VLAN 标签：禁止在 LAN 侧二次打标/重复加规则。
- 同一 VLAN 不能配给两个业务（保存时校验拦截）。
- 手工 GEM 规则只用 `gemPort ≥ 10`，与 OLT 自动分配空间隔离；
  回退守护“只加不删、已存在即跳过”。
- 禁用业务会删除对应 `wan_vlan` 段与接口，避免旧规则残留。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 重启后 LOID 未生效 | 认证方式必须为 `loid`（auth_type_g）；S00xponconfig 只覆盖 sn 不覆盖 loid |
| 切换模式后无法 O5 | onu_type 与 OLT 端口能力不符；U-Boot 恢复 `setenv onu_type 62; saveenv; reset`（或恢复原值） |
| IPTV 组播不通 | 确认模式页为 HGU（末尾 2，SFU 无组播引擎）；状态页看 `igmp_get_fwdmode`；
   `iptv_port` 需与真机 LAN 口验证（SDK 默认 port 1~4=eth0.1~eth0.4，XG2010G 是 eth0.4/5/7） |
| `omcicfgCmd` 报 `Exec. Failed, invalid length` | 预期行为：`sn` 必须 12 字节，出厂默认 `NoNumber`(8) 会被跳过、不覆盖出厂 SN（`logread \| grep xpon` 可见 `skip set sn`） |
| 开机出现 `## Error: "fwupd_type" not defined` | 固件自带 `S95done` 读 `fwupd_type` env 的噪音，与 xpon-luci 无关，可忽略 |
| 出现 `killall: epon_oam: no process killed` | SDK netifd 引擎的 EPON 分支例行清理，无害；若反复出现请确认 `uci get network.xpon_auth.pon_mode` 为 `GPON` |
| O5 但 PPPoE PADO 超时 | GEM/ponvlan 规则缺失或 tagCtl/tagFlag 与 OLT 不匹配，对照 VLAN 表页回显修正 |
| 保存后页面 403 | LuCI 会话过期，重新登录 |
| 页面 500 | 检查 `logread | grep luci`；确认文件路径与权限（目录 755、文件 644、脚本 755） |

## 已知边界

- `omcicfgCmd set loidPasswd`（netifd/SDK 拼写）与 usage 文本 `set loid_password` 均兼容。
- 状态页部分命令（`ponvlancmd showrule`）在未注册态可能报错，页面已容错显示。
- IPTV 专口透传是“带标签桥接”模型；若 OLT 期望路由拨号 + IGMP Proxy，保持 `stb_port` 为空。
- LuCI 菜单位置：System 之前（order 39）；若与其他包冲突，改 `controller/xpon.lua` 的 order。
