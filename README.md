# IOSGridView

A tweak that brings the iPad layout of the YouTube home feed to the iPhone.

On an iPad, YouTube shows the home feed as a grid with several videos per row. On an iPhone it shows one full-width video after another, so a single screen holds only two or three videos. IOSGridView gives the iPhone the same grid: two videos per row, with compact tiles that still show everything you need, and twice as many videos per screen.

<p align="center"><img src="docs/screenshot.png" width="360" alt="YouTube home feed as a two-column grid"></p>

> This tweak was vibe-coded with Claude Opus and Claude Fable: the code was written by the models in conversation, with YouTube's view hierarchy reverse-engineered step by step and every change tested on a real device.

## Features

- Two videos per row on the Home page, including the feeds behind its top chips (Subs, Music, Live). Shelves, chips, posts and everything that is not a video keep their full width.
- Compact tiles: the ⋮ menu moves into the top-right corner of the thumbnail, the title gets the full tile width, below it a small channel avatar with the channel name, and a line with views and age.
- Preview autoplay follows reading order: left, right, next row.
- Everything else in the app is untouched, including Subscriptions, search results and channel pages.
- Toggle in YouTube settings under **IOSGridView** (grouped under *Tweaks* when [YouGroupSettings](https://github.com/PoomSmart/YouGroupSettings) is installed). The toggle takes effect after an app restart.
- Available in English and German.

## Compatibility

- Built for iOS 14 and later, arm64.
- Tested with YouTube 21.42.4 on iOS 27.0.1 (iPhone 15 Pro Max), sideloaded together with [YouMod](https://github.com/Tonwalter888/YouMod) and PoomSmart's tweaks. IOSGridView does not depend on either of them.
- Designed for iPhone. The grid uses two fixed columns, which has not been tuned for iPad.
- The tile layout follows YouTube's current video lockup element. If a YouTube update changes it, please open an issue with the YouTube version and a screenshot.

## Installation

**Jailbroken:** install the `.deb` from the [releases](https://github.com/TributeOne/IOSGridView/releases). Packages are provided for rootful, rootless and roothide.

**Sideloaded:** inject `IOSGridView.dylib` from the `.deb` into a decrypted YouTube IPA with a tool such as [cyan](https://github.com/asdfzxcvbn/pyzule-rw), then sign and install the IPA as usual. The tweak can be combined with YouMod or any other YouTube tweak in the same IPA.

## Building

Requires [Theos](https://theos.dev) and [YouTubeHeader](https://github.com/PoomSmart/YouTubeHeader) in `$THEOS/include/YouTubeHeader`.

```sh
make clean package FINALPACKAGE=1
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

The GitHub Actions workflow in `.github/workflows/build.yml` builds all three packages and attaches them to a draft release for tags starting with `v`.

## How it works

YouTube's iPad grid is not a layout switch the iPhone app can simply enable, so the tweak rebuilds it on top of the iPhone feed. Video entries on the Home feed are measured at half width. The feed's collection view layout is swapped at runtime for a subclass that places those half-width cells side by side and leaves all other cells at full width. Inside each tile the metadata row is rearranged on the AsyncDisplayKit nodes YouTube already created, so the tiles stay native and tappable. For preview autoplay, the left column reports itself slightly higher during YouTube's visibility calculation, which makes the previews advance in reading order.

## Credits

- [PoomSmart](https://github.com/PoomSmart) for YouTubeHeader and YouGroupSettings.
- [Theos](https://theos.dev).

## License

[MIT](LICENSE)
