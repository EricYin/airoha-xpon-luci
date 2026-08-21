# ImmortalWrt vendor tool integration

The LuCI scripts in this project retain the original `/userfs/bin` command
paths used by the factory firmware. The stock Airoha firmware already ships
those commands, so the opkg package is self-contained there. On ImmortalWrt,
install the companion `airoha-xpon-vendor-tools` package separately to provide
the missing factory command ABI.

That package provides an isolated AArch64 glibc runtime below
`/opt/airoha-xpon/vendor` and compatibility links for the commands used by
the authentication flow:

```text
/userfs/bin/ponmgr
/userfs/bin/ponmgr_cfg
/userfs/bin/omci
/userfs/bin/omcicfgCmd
/userfs/bin/oamcfgCmd
/userfs/bin/xponblapicmd
/userfs/bin/xponigmpcmd
/userfs/bin/epon_oam
```

The LuCI authentication page can then apply GPON/XGPON SN, LOID, LOID
password, SN password format, vendor ID, equipment ID, ONU version and OMCC
version through the original command ABI. The kernel XPON devices and the
`pon` network interface must already be available; the vendor userspace
package does not replace `xpon_int.ko`, `gpon_flow.ko`, or the OMCI kernel
transport.

The original `epon_oam` daemon and its additional proprietary PPE, QDMA,
switch-management and traffic libraries are also included in the isolated
runtime. It is available through:

```text
/usr/sbin/airoha-epon_oam
/userfs/bin/epon_oam
```

This is an experimental userspace path. Starting the daemon still requires
the proprietary XPON kernel data path, `/dev/pon`, the `oam` network interface,
and the matching private kernel ABI. Packaging the glibc executable does not
replace `xpon_int.ko`, `xpon_10g.ko`, `xponmap.ko`, `ponvlan.ko`, or the other
vendor-only EPON/XPON kernel modules.
