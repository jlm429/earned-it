# Visual Asset Specification

## Existing assets

### App icon

The app target contains `EarnedIt/Assets.xcassets/AppIcon.appiconset/AppIcon.png`:

- 1024 by 1024 pixels;
- PNG, sRGB, no alpha channel;
- connected to `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for Debug and Release.

The artwork is friendly and family-oriented, but two release questions remain:

1. The repository contains no source file, author record, or commercial-use license for the artwork. Confirm provenance before public distribution.
2. The bitmap includes a rounded tile and white corner area. iOS applies its own icon mask, so obtain a square edge-to-edge master without pre-rounded corners or approve the current appearance after installing the release build on a device.

Do not silently replace the shipping icon. A designer should deliver an approved 1024 by 1024 opaque PNG or an Icon Composer source, plus a note recording ownership and permitted commercial use. Optional dark and tinted appearances can follow later.

### Repository banner

`assets/earned-it-banner.png` is a 2172 by 724 pixel opaque PNG. Its shared-chore positioning, iOS 18 requirement, and iCloud privacy language fit the product, but its provenance and commercial-use rights are undocumented. The final README pass removes the banner and its unverified App Store availability link. Reintroduce artwork only after rights and final-screen accuracy are confirmed.

### Public preview

`assets/earned-it-preview.png` is not suitable for current public or App Store use. It shows an older UI and icon, says iOS 17+, calls the product an allowance tracker, and says family data stays on device. The current app targets iOS 18 and can synchronize family data through iCloud.

The file remains as historical artwork so this audit does not delete potentially useful material. Do not use it in the README or App Store listing.

## Required App Store screenshots

Capture screenshots that accurately represent the final release candidate with fictional family information. Include portrait and landscape review of the important iPad flows even when the submitted screenshot set uses one orientation. Simulator captures can illustrate the interface but do not prove signed CloudKit behavior.

[Apple's current screenshot specification](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), checked October 10, 2026, requires at least one screenshot for iPhone with Dynamic Island (medium display) and, because this app supports iPad, at least one for the iPad 13-inch display. Up to ten screenshots per device size are accepted as JPEG or PNG without alpha. Accepted portrait examples are 1179 by 2556 or 1206 by 2622 for that iPhone group, and 2064 by 2752 or 2048 by 2732 for iPad 13-inch. Confirm the final upload slots and Apple's scaling rules rather than assuming an older 6.5-inch-only set remains sufficient.

Existing native weekly captures under `docs/weekly-allowance-evidence/` are engineering examples with fictional fixture data, not an approved final submission set. The UI polish lane owns updated screen evidence. Final public marketing and store images must use the integrated candidate and cleared assets; repository development previews must be labeled as such. Follow [the system artwork review](quotes-and-attribution.md#system-artwork-and-names) for emoji and SF Symbols restrictions.

The README also includes explicitly labeled UI-candidate previews under [`assets/screenshots/`](../../assets/screenshots/README.md), supplied through the supervisor's October 10 handoff. They show the running native interface with fictional fixtures, without banner/icon marketing artwork or live invitations. Their capture/source details distinguish pending UI work from tested `main`; they must be rechecked after integration and are not final listing assets.

Recommended set:

1. Parent dashboard with fictional children and clear daily status.
2. Shared daily chore list showing individual completion states.
3. Child view with weekly progress and streak.
4. Chore setup showing repeating, as-needed, and alternating choices without exposing private invitation data.
5. Manage Family or invitation setup that communicates private family sharing without displaying a live QR code, link, or code.

Use the product positioning consistently:

> Earned It<br>
> A simple shared chore app for families.<br>
> Free. No ads. No tracking.

Avoid claims that all data stays on device, that synchronization is instantaneous, or that CloudKit role restrictions are server-enforced.

## Wordmark proposal brief

No separate wordmark exists. If one is commissioned, request:

- a horizontal `Earned It` wordmark and icon lockup;
- a transparent SVG or PDF vector master and PNG exports;
- a light-background and dark-background version;
- clear space and minimum-size guidance;
- simple, friendly, trustworthy forms with restrained color;
- no childish clip art, coins as payment promises, or visual claims of financial transfer;
- documented ownership and commercial-use rights.

Suggested repository locations after approval:

- `assets/brand/earned-it-wordmark.svg`
- `assets/brand/earned-it-wordmark-dark.svg`
- `assets/brand/README.md` for provenance, license, colors, and usage
- `assets/app-store/` for final screenshots and listing artwork
