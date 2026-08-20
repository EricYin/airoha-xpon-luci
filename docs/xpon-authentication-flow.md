# XPON Authentication Flow

This project has two different authentication engines. The engine is selected by
the high nibble of the current boot `onu_type`, not by a stale UCI value:

| `onu_type` high nibble | Engine | Authentication channel |
| --- | --- | --- |
| `2`, `3`, `4`, `5`, `C` | EPON, 10G EPON, 1G/1G EPON, or Turbo EPON | MPCP registration plus EPON OAM |
| `1`, `6`, `7` | GPON, XGPON, XGSPON | OMCI plus GPON registration password |

## EPON

EPON authentication is not OMCI SN authentication. It has two layers:

1. MPCP registration uses the EPON PON MAC. The project reads
   `xpon.device.epon_pon_mac`, then legacy `pon_mac`, and finally DSD
   `wan_mac`. For EPON the resulting MAC is applied to the PON interface and
   synchronized to U-Boot `ethaddr` and the `ethaddr=` token in `bootargs`.
   The driver uses that value as the MPCP/LLID registration MAC.
2. OAM identity uses `loid`, `loid_password`, `epon_oui`, `epon_ctc_oui`,
   `epon_ven_info`, `epon_onu_vendor_id`, and `epon_serial`.

The native commands are:

```text
oamcfgCmd set mode 2
oamcfgCmd set loid0 <loid>
oamcfgCmd set loidPasswd0 <password>
oamcfgCmd set localOui <epon_oui>
oamcfgCmd set ctcOui <epon_ctc_oui>
oamcfgCmd set localVenInfo <epon_ven_info>
oamcfgCmd set onuVenID <epon_onu_vendor_id>
xpon-epon-sn.sh set <epon_serial>
```

These EPON fields are independent: `localOui` is a 3-byte OUI,
`localVenInfo` is separate 4-byte hexadecimal vendor information, and
`onuVenID` is a separate 4-byte printable ASCII value. The project does not
derive `onuVenID` from the GPON `vendor_id` or from `localVenInfo`; an empty
EPON Vendor ID is left unset.

`loid0` is limited to 24 bytes and `loidPasswd0` to 12 bytes by the firmware
CLI. An empty `epon_ctc_oui` is normalized to the verified default `111111`.

EPON does not use `omcicfgCmd set sn`, `vendor_id`, `equipment_id`,
`onu_version`, or `omcc_version` as its authentication identity. Values such as
OMCI `AXON` are therefore unrelated to EPON OAM authentication.

## GPON LOID

The page stores:

```text
auth_type_g=LOID
auth_method_g=loid
loid=<LOID>
loid_password=<optional LOID password>
sn=<12-character PON SN>
def_sn=<same SN, compatibility mirror>
```

`sn` is the canonical PON SN. Its first four characters are the only source
for the OMCI Vendor ID. The project writes:

```text
omcicfgCmd set vendor_id <sn[0:4]>
omcicfgCmd set sn <sn>
omcicfgCmd set loid <loid>
omcicfgCmd set loid_password <loid_password>
```

Optional `equipment_id`, `onu_version`, `omcc_version`, and `omci_spec_ver`
are written only when explicitly configured, using `equipment_id`,
`onu_version`, `omcc_version`, and `spec_version` respectively.

## GPON PASSWORD

The page's mobile PASSWORD mode is persisted as:

```text
auth_type_g=sn
auth_method_g=password
xpon_sn_auth_type=regid
sn_regid_password=<REG_ID>
sn=<12-character PON SN>
def_sn=<same SN, compatibility mirror>
```

It writes the OMCI identity fields:

```text
omcicfgCmd set vendor_id <sn[0:4]>
omcicfgCmd set sn <sn>
```

It does **not** write `omcicfgCmd set loid` or `set loid_password`. The
registration password is sent through the firmware-native command:

```text
ponmgr gpon set passwd regid <REG_ID>
```

The firmware does not provide a reliable password getter, so success is based
on the command return code and the surrounding OMCI identity read-back. The
old `loid` and `loid_password` fields are deleted when PASSWORD is saved or
restored, preventing `mtk1111` from being replayed as a LOID.

## Reboot restore

At boot, `restore-auth` mirrors the durable `xpon.device` authentication
section into `network.xpon_auth` after the current `onu_type` is decoded. The
replay helper then waits for the matching engine:

```text
EPON -> epon_oam -> xpon-auth-native.sh -> OAM writes/read-back
GPON -> omci     -> xpon-auth-native.sh -> OMCI writes/read-back
```

If `network.xpon_auth.pon_mode` disagrees with the current `onu_type`, the
current engine wins and a warning is logged. In old configurations without
`xpon.device.pon_mode`, `auth_method_g` and `auth_type_g` are consulted before
falling back to a non-default LOID; the sentinel `mtk1111` is ignored.

This prevents the following cross-engine mistakes after reboot:

* GPON PASSWORD writing a leftover LOID into OMCI.
* GPON settings being sent to EPON OAM, or EPON OAM settings being sent to OMCI,
  when the UCI mode is stale.
* A stale `def_sn` generating a Vendor ID different from the configured PON SN.

Useful logs and checks:

```text
cat /tmp/xpon-auth-native.log
uci show network.xpon_auth
uci show xpon.device
/userfs/bin/omcicfgCmd get sn
/userfs/bin/omcicfgCmd get vendor_id
/userfs/bin/omcicfgCmd get loid
/userfs/bin/omcicfgCmd get loid_password
/userfs/bin/omcicfgCmd get auth_status
/userfs/bin/oamcfgCmd get loid0
```

## Firmware CLI names

The current firmware's `omcicfgCmd` help text prints display labels such as
`vendorId`, `equipmentId`, `onuVersion`, `omccVersion`, `specVer`,
`loidPasswd`, and `authStat`. Those are **not** accepted `set`/`get`
subcommands. The accepted names are `vendor_id`, `equipment_id`,
`onu_version`, `omcc_version`, `spec_version`, `loid_password`, and
`auth_status`. EPON is a different program: its `oamcfgCmd` subcommands such
as `loidPasswd0` and `authStatus` remain camelCase.
