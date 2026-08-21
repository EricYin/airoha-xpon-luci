# OMCI/OAM Runtime Identity Notes

This note records the gotchas found while adding the GPON OMCI and EPON OAM
runtime identity views on the XG2010G/Airoha EN7581 image.

## GPON OMCI identity

The GPON `/admin/xpon/moci` page should treat `omcicfgCmd get ...` as the
runtime truth and UCI as the intended override. The important fields are:

```text
omcicfgCmd get sn
omcicfgCmd get vendorId
omcicfgCmd get loid
omcicfgCmd get loidPasswd
omcicfgCmd get equipmentId
omcicfgCmd get onuVersion
omcicfgCmd get omccVersion
omcicfgCmd get specVer
omcicfgCmd get authStat
```

`onuVersion` is runtime/shared-memory state. When OMCI starts before replay, it
can show the stock product value `XG2010G`. After replay, it should match
`xpon.device.onu_version` if that option is configured.

The field can be confusing because the device also has DSD and system product
values:

```text
/tmp/dsd.env: serial_number='XG2010G2414004031'
/etc/device_info: DEVICE_PRODUCT='XG2010G'
/etc/product: XG2010G
/etc/os-release: OPENWRT_DEVICE_PRODUCT="XG2010G"
```

The live test on the device changed only DSD `serial_number` from
`XG2010G2414004031` to `CODTEST2414004031`, regenerated `/tmp/dsd.env`, and
read `omcicfgCmd get onuVersion`. The result did not become `CODTEST`; it read
the configured override `1.0.0` after the GPON identity replay ran. The original
DSD value was restored immediately after the test.

Practical conclusion: `XG2010G` in `omcicfgCmd get onuVersion` is best treated
as the OMCI process's stock/default product value until the replay path applies
`xpon.device.onu_version`. Do not backfill that stock runtime value into the
editable auth form and save it as user intent.

## EPON OAM identity

EPON registration is not OMCI registration. The OAM page should show OAM/MPCP
fields from the EPON commands and avoid interpreting GPON OMCI values as EPON
identity:

```text
oamcfgCmd get mode
oamcfgCmd get loid0
oamcfgCmd get loidPasswd0
oamcfgCmd get localOui
oamcfgCmd get ctcOui
oamcfgCmd get localVenInfo
oamcfgCmd get onuVenID
xpon-epon-sn.sh get
```

`localOui` is derived from the active EPON PON MAC OUI. The form and replay
script both rederive it so stale UCI cannot drift away from the MPCP
registration MAC.

`ctcOui` is independent of `localOui`. On the tested line the OLT advertised
CTC OUI `111111`, and using the PON MAC OUI there caused MPCP registration to
exist without successful OAM authentication.

`localVenInfo` and `onuVenID` are separate fields. Do not derive `onuVenID` from
`localVenInfo` or GPON `vendorId`.

## Persistence and replay

The vendor `epon_oam` process keeps several identity values in RAM. The helper
`xpon-epon-oam-save.sh` sends the stock TCAPI_SAVE/update-config notification
(`cmdType=24`) to the `epon_oam` queue, but that message is only a best-effort
runtime sync hook on this OpenWrt image. The durable source remains UCI plus
boot-time replay.

For EPON, the watcher repairs drift for `localOui`, `ctcOui`, `localVenInfo`,
`onuVenID`, `loidPasswd0`, and CTC ONUSN. It waits through the short window
where `epon_oam` can restore built-in defaults after the IPC endpoint first
becomes readable.

For GPON, `xpon-gpon-identity-watch.sh` replays OMCI identity after OMCI process
changes and can repair drift back to the configured SN/Vendor/Equipment/Version
values.

## UI notes

The user-visible runtime identity tables intentionally show both current
runtime values and saved configuration values. Password-like fields such as
LOID password, SN password, and REG_ID are displayed as values because this
tool is being used as a field diagnostic page; callers should protect access to
the LuCI session accordingly.
