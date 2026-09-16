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

### Public preview

`assets/earned-it-preview.png` is not suitable for current public or App Store use. It shows an older UI and icon, says iOS 17+, calls the product an allowance tracker, and says family data stays on device. The current app targets iOS 18 and can synchronize family data through iCloud.

The file remains as historical artwork so this audit does not delete potentially useful material. Do not use it in the README or App Store listing.

## Required App Store screenshots

Capture screenshots from the signed release candidate with fictional family information. Provide at least one, preferably four or five, at an App Store accepted iPhone size. A current 6.9-inch portrait option is 1260 by 2736, 1290 by 2796, or 1320 by 2868 pixels. Screenshots must not contain alpha.

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
