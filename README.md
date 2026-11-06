# EdgePlay

A PS5/PS4 Remote Play client for iPhone that fills the whole screen, built on
[chiaki-ng](https://github.com/streetpea/chiaki-ng), the open-source Remote Play library.

**What you get over Sony's app**

- **True full screen.** *Fill* mode uses the entire display, notch/Dynamic Island area included.
  A *Stretch ↔ Crop* slider splits the extra width between a little stretching and a little
  cropping, so the default (middle) is about 10% of each instead of roughly 20% of one. You can also pinch the picture during play.
- **No system chrome.** The status bar and home indicator are hidden, and edge swipes need a second swipe, so you don't drop out of the game by accident.
- **Away-from-home play.** Each console has a home address and an away address (Tailscale IP or
  MagicDNS name, or a public IP if you use port forwarding). The app checks both
  and uses whichever answers. *Wake* sends the wake-from-rest packet over either one.
- **Stream stats.** A HUD shows resolution, codec, fps, received Mb/s, RTT, packet loss and dropped frames.
  You can choose 720p/1080p, 30/60 fps, a bitrate preset, and H.264 or HEVC.
- **Controllers.** DualSense, DualShock 4, Xbox, Backbone and other MFi controllers work. The DualSense touchpad, rumble and lightbar color are passed through.
  Tap PS for the console's PS button, or hold PS for 1 s to open the EdgePlay menu.

---

## Install by sideloading (no Mac needed)

EdgePlay ships as an **unsigned `.ipa`**. A sideloading tool signs it with your own Apple ID when it installs it.

### 1. Get the IPA (GitHub builds it for you)

1. Create a GitHub repo and push this folder to it. Make it **public** if you want AltStore/SideStore
   auto-updates; release files in private repos need a login the apps can't do.
2. Go to **Actions › Build IPA › Run workflow**. The first run takes about 20 minutes because it compiles OpenSSL and chiaki-ng. Later runs reuse that work and take about 5 minutes.
   Download `EdgePlay.ipa` from the run's **Artifacts**.
3. For proper releases, push a tag instead. The workflow then publishes a Release with the IPA and a `source.json`:
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```

### 2. Install it on the iPhone (pick one)

| Tool | Needs | Refresh (free Apple ID) |
|---|---|---|
| **SideStore** | One-time setup from a computer, then runs entirely on the iPhone | Refreshes itself on the phone |
| **AltStore** | AltServer running on a Windows PC or Mac on the same Wi-Fi | Refreshes over Wi-Fi in the background |
| **Sideloadly** | Windows PC or Mac + cable/Wi-Fi | You re-install every 7 days |

With AltStore or SideStore, add the source
`https://github.com/<you>/<repo>/releases/latest/download/source.json`. EdgePlay then appears in the
app's catalogue with an **Update** button for each new release.

### 3. First launch

- **Settings › Privacy & Security › Developer Mode** → On (iOS asks after the first sideload; the phone restarts).
- **Settings › General › VPN & Device Management** → trust your Apple ID's certificate (Sideloadly only;
  AltStore/SideStore handle this).
- Allow **Local Network** access when EdgePlay asks. Without it, the app can't reach the console.

**Free Apple ID limits:** apps expire after 7 days unless refreshed, at most 3 sideloaded apps are active at a time,
and you can register 10 app IDs a week. A paid developer account ($99/yr) makes installs last a year.

## Build it yourself on a Mac (optional)

Needs Xcode 15+, `brew install cmake ninja pkg-config autoconf automake libtool xcodegen` and
`python3 -m pip install --user protobuf grpcio-tools`.

```bash
./scripts/build-ipa.sh           # → build/EdgePlay.ipa (unsigned, for sideloading)
# or, to run straight from Xcode on a plugged-in iPhone:
./scripts/build-chiaki-ios.sh && xcodegen generate && open EdgePlay.xcodeproj
```
In Xcode, pick your Team under Signing & Capabilities, choose a unique bundle id, and press Run.

## First-time setup (on your home Wi-Fi)

1. **On the PS5:** turn on Settings › System › Remote Play › *Enable Remote Play*. Under
   Settings › System › Power Saving › Features Available in Rest Mode, turn on
   *Stay Connected to the Internet* and *Enable Turning On PS5 from Network*.
2. Note the console's IP (Settings › Network › View Connection Status) and **reserve it** in the router.
   On the Archer AXE95 that's Advanced › Network › DHCP Server › Address Reservation.
3. In EdgePlay, tap **+**:
   - enter the IP
   - tap **Sign in** to get your PSN account ID. Sony's own login page opens, and only the numeric
     account ID is kept.
   - on the PS5 open Settings › System › Remote Play › **Link Device** and type the 8-digit code
   - tap **Link**.
4. Press ▶ to play.

## Playing away from home (Tailscale)

Your router can't run Tailscale, so put it on any always-on device at home instead:

```bash
# on a Raspberry Pi / Linux box at home
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-routes=192.168.0.0/24     # your home subnet
```

Approve the route in the Tailscale admin console and install Tailscale on the iPhone. Then, in EdgePlay,
**Edit** the console and set the **away address** to the console's home IP (it is reachable through the
subnet router). The app picks whichever address answers. Use the 5–10 Mb/s bitrate on mobile data.

(Port forwarding works too: TCP 9295 and UDP 9295–9304 to the console, then use your public IP or a DDNS name
as the away address. That won't work if your ISP puts you behind CGNAT.)

## How it fits together

```
EdgePlay/
  Bridge/RPBridge.{h,c}     flat C API over chiaki-ng (session, pairing, probe, wake)
  Stream/StreamSession      owns a chiaki session, routes callbacks to Swift
  Stream/VideoDecoder       Annex-B → CMSampleBuffer → AVSampleBufferDisplayLayer (hardware decode)
  Stream/AudioPlayer        Opus PCM → AVAudioEngine with a 40 ms jitter buffer
  Stream/ControllerInput    GameController → PlayStation pad state, rumble, lightbar
  Stream/ConsoleServices    unicast status probe, pairing, wake
  UI/StreamViewController   full-screen player, fill geometry, HUD, in-stream menu
  UI/*View.swift            console list, add/link, PSN sign-in, settings
scripts/build-chiaki-ios.sh builds Frameworks/ChiakiCore.xcframework
scripts/build-ipa.sh        unsigned IPA for sideloading
scripts/make-source.py      AltStore/SideStore source.json
.github/workflows/          builds the IPA on GitHub's Macs
```

Status checks use **unicast** pings to the address you entered rather than broadcast discovery, so they work
over Tailscale and don't need Apple's multicast entitlement.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Not reachable" at home | Allow Local Network access (iOS Settings › EdgePlay). Check the IP. |
| Linking fails | The code expires after ~5 min. The account ID must belong to the user signed in on the console. |
| Connects, then ends straight away | Another device is using Remote Play, or the console was updated and needs re-linking. |
| Stutter away from home | Lower bitrate / 720p. Check that Tailscale shows a *direct* connection, not a DERP relay. |
| Black screen after switching apps | It recovers on the next keyframe. Disconnect and reconnect if it doesn't. |

## Licence

AGPL-3.0, the same as chiaki-ng (see `LICENSE`). Not affiliated with or endorsed by Sony Interactive Entertainment.
"PlayStation", "PS5" and "DualSense" are trademarks of Sony Interactive Entertainment.
