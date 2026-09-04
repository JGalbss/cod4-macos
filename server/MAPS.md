# Custom map compatibility

This client and the dedicated server run Call of Duty 4's IW3 data model. A map
therefore needs to be built as a CoD4/IW3 usermap containing matching `.ff`,
`_load.ff` and `.iwd` files. Renaming an IW4 (MW2) or IW5 (MW3) fastfile does
not convert its world, collision, entities or renderer data.

The OpenAssetTools fork supports inspecting and linking assets for IW3, IW4 and
IW5, but it is not currently a complete cross-engine map converter. In
particular, its supported-asset table does not provide disk dump/load support
for the map-defining `GfxWorld`, `clipMap`, `GameWorld` and `ComWorld` types.

- [OpenAssetTools overview](https://github.com/JGalbss/OpenAssetTools#readme)
- [Supported asset types](https://github.com/JGalbss/OpenAssetTools/blob/main/docs/SupportedAssetTypes.md)

## Requested MW2 maps

| Map | CoD4/IW3 status | Installer status |
| --- | --- | --- |
| Scrapyard | Verified `mp_scrapyard` remake; DM/TDM/SD/DOM | Included with pinned SHA-256 |
| Wasteland | No exact CoD4/IW3 remake verified yet | Not included |
| Afghan | No CoD4/IW3 remake verified yet | Not included |

The verified Scrapyard release is the 56,471,137-byte
[`mp_sps_scrapyard.rar`](https://www.customapscod.com/map.php?id=OTYy) by
PanzerMan and Dugynight. `maps.sh` downloads it from the publisher's map host,
checks SHA-256, and installs only the three required `mp_scrapyard` files.

The similarly named IW4 originals (`mp_boneyard`, `mp_brecourt`, and
`mp_afghan`) are MW2 zones and cannot be loaded by this IW3 client. Wasteland
was inspired by Brecourt, and CoD4 remakes named Brecourt exist, but they are
not the requested MW2 Wasteland layout and are not silently substituted here.
