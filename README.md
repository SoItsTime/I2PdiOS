# i2pd for iPhone

Source for an experimental iPhone app embedding [i2pd](https://github.com/PurpleI2P/i2pd). It includes an I2P browser, i2pd's built-in I2P torrent engine, the local i2pd web console, router diagnostics, a searchable address book, and a shutdown Live Activity. It targets iOS 17 or later.

## Build

1. Install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `./scripts/bootstrap.sh` on a Mac. This downloads pinned i2pd, Boost, and OpenSSL sources, applies `patches/i2pd-ios.patch`, builds OpenSSL for iPhone and Apple Silicon Simulator, renders the app icon from its SVG source, and generates `I2PdiOS.xcodeproj`.
3. Open `I2PdiOS.xcodeproj`, select the `I2PDApp` scheme, set your own development team and bundle identifier, then build for your iPhone.

For an unsigned iPhone IPA that can be signed with your own certificate and provisioning profile, run `./scripts/build-unsigned-ipa.sh /path/to/i2pd.ipa` after bootstrapping. The IPA includes the app and its Live Activity extension; both must be signed for installation. The packaged app uses the placeholder bundle ID `website.i2pd.ios.prototype`, which your signer may need to change to match your profile.

The repository contains source, the icon's SVG source, bootstrap names, and the i2pd patch. `Vendor/`, downloaded certificates, compiled libraries, the generated icon PNG, Xcode output, profiles, and local router data are ignored by Git. The bootstrap script retrieves i2pd's **public reseed certificates** into the ignored `Vendor/` directory because verified reseeding requires them. No personal keys or certificates are supplied.

The app stores its router keys, torrent identity, and address book in its own Application Support directory on the device. Torrent downloads go to `Documents/Torrents`, visible in Files under On My iPhone > i2pd. These files are created at runtime and are never part of this repository.

## Dependencies and sources

- i2pd 2.61.0 source at commit `ca007dc57dad3ea743e018ed7f652a8671ec8bed`, BSD 3-Clause. App-specific C++ changes are in `patches/i2pd-ios.patch`.
- Boost 1.86.0, Boost Software License 1.0.
- OpenSSL 3.5.8, Apache License 2.0.
- Bootstrap names from the [I2P project's hosts.txt](https://github.com/i2p/i2p.i2p/blob/37039e6594f1372368f0c1cf8258cdaf805a7fb4/installer/resources/hosts.txt) and selected entries from NotBob's I2P address book.
- App icon from [PurpleI2P/i2pd-logo](https://github.com/PurpleI2P/i2pd-logo), by omen, BSD 3-Clause.
- Apple frameworks: SwiftUI, WebKit, Network, AVFoundation, UIKit, ActivityKit, WidgetKit, Foundation, and Combine.

## Background behavior

The optional background audio loop is experimental. A background task offers limited extra time; iOS can still suspend or terminate the app. The router should not be relied on for continuous background service. Thanks to [XITRIX](https://github.com/XITRIX), the developer of [iTorrent](https://github.com/XITRIX/iTorrent), for the background audio approach that inspired this implementation.

## I2P torrents

The Torrents screen uses i2pd's built-in `type=torrents` tunnel. It accepts I2P magnet links and `.torrent` files, shows transfer progress and rates, and can pause, resume, or remove transfers. The tunnel has a persistent identity and DHT enabled. Its config is created once in `tunnels.d/i2pd-ios-torrents.conf`; existing custom tunnel configurations are left intact. The app controls torrents through its embedded C++ bridge and does not open a torrent RPC listener. Public BitTorrent peers and trackers are not available through this I2P tunnel. Transfers only continue while iOS keeps the router running.

The built-in browser also sends tapped `magnet:` links and downloaded `.torrent` files to this tunnel. Other files download to `Documents/Downloads`, visible in Files under On My iPhone > i2pd. The browser has a download tray with progress, cancellation, and a list of recent downloads. Browser downloads depend on the app remaining active; iOS may suspend them in the background.

## Custom reseed source

In **Settings → Reseed settings**, enter an HTTPS reseed server base URL (for example, `https://reseed.example.org/`) or a direct HTTPS `.su3` URL. A custom server replaces i2pd's built-in reseed server list. Clear the setting to restore the built-in list. The choice is saved on the device and takes effect on the next router start, when i2pd determines that its network database needs reseeding.

SU3 signature verification stays enabled. If the chosen source uses a signing certificate that i2pd does not already trust, import its public PEM `.crt` certificate on the same screen, then restart the router. Reseeding contacts the HTTPS server directly during bootstrap, so that server can see the device's public IP address. Torrent peer traffic runs through I2P after the router connects.

## Security and project status

The built-in browser uses i2pd's loopback SOCKS proxy for `.i2p` sites. It keeps controls compact on narrow screens and moves tabs and navigation to a side panel on wider or shorter screens, including iPhone Duo's inner display. It supports up to 12 tabs with saved addresses. Tabs resume loading after the router is ready. In Browser settings, you can optionally enter the `http://` URL of an I2P HTTP outproxy. The browser's website access menu and its settings both offer an **Allow non-.i2p websites** control. When enabled, the browser uses i2pd's loopback HTTP proxy, which forwards public requests through the chosen outproxy. Non-`.i2p` websites are blocked by default and whenever the switch is off; the app does not supply an outproxy service. The outproxy can see destination hostnames and unencrypted HTTP traffic. JavaScript starts disabled, and the selected user agent is sent through both proxy modes. The router's HTTP and SOCKS proxies bind to loopback. This is a prototype, and a successful build does not establish that connectivity or background execution will work on every device.

The embedded router allows transit tunnels while running, with a 48 KiB/s bandwidth limit and a 64-tunnel cap. It advertises SSU2 so that other routers can find a contact route; NTCP2 remains unpublished because incoming TCP may be blocked on mobile networks. Live Diagnostics shows whether transit requests are allowed, whether a contact route exists, how many transit tunnels are active, and how much transit traffic has passed through this router. A zero count means no transit tunnels are active at that moment; other routers may take time to select it, and network reachability varies by connection. Graceful shutdown declines new transit tunnels while existing ones finish.

## Donations

If you like the project and want to support it, donations are optional:

- Monero (XMR): `483YVLUtXPhiZ2zVZJSNgkMTMJCphTRjtGMEHu4iHUkNJN6dBWev8RBNp6VaECFgzX7jEDZxF6CfP58srhrJKRfQSLkkGoz`
- Litecoin (LTC): `ltc1qxhxzqtd97u2hrj3wldst6g0paa4fhw9et2fphq`
- Bitcoin (BTC): `bc1qthw9rmk872yvzqlf2yvgawpcskvsjpvyehkxw7`
