# Phone Trackpad (Macpad)

Use an Android phone as a full-screen trackpad for a Mac, with MacBook-style gestures: smooth scrolling with glide, pinch to zoom, tap-to-drag, three- and four-finger swipes, and per-phone pairing.

- `mac/`: Swift menu-bar app. Recognises gestures and posts native macOS input events.
- `android/`: Kotlin app. A full-screen touch surface that streams raw finger positions to the Mac.

The ready-to-use package (`PhoneTrackpad-1.1.zip`) contains:

| File | What it is |
|---|---|
| `PhoneTrackpad.app` | Mac menu-bar app. Receives the touches and moves the pointer |
| `PhoneTrackpad.apk` | Android app: the touch surface |
| `README.md` | This guide |

## Requirements

- **Mac:** macOS 14 (Sonoma) or newer. Apple Silicon or Intel.
- **Phone:** Android 11 or newer.
- **Both on the same Wi-Fi network.** Guest networks and "client isolation" (common in offices and hotels) block it.

---

## 1. Set up the Mac

1. Move `PhoneTrackpad.app` into **Applications**.
2. Open it. macOS will block it the first time, because the app isn't signed with an Apple developer certificate:
   - Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to "PhoneTrackpad".
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/PhoneTrackpad.app`
3. When asked, allow it in **System Settings → Privacy & Security → Accessibility**. Then **quit and reopen** the app (hand icon in the menu bar → Quit).
4. If macOS asks to allow incoming network connections or local network access, click **Allow**.

A **hand icon** appears in the menu bar. It's filled in while a phone is connected.

## 2. Set up the phone

1. Copy `PhoneTrackpad.apk` to the phone and open it. Allow "install unknown apps" when asked. If Play Protect warns, choose **Install anyway**.
2. Open **Trackpad**. It goes full screen in landscape and looks for Macs running Phone Trackpad.
   - With one Mac on the network, it connects to it. With several, a **Choose your Mac** list appears.
3. **Approve the phone on the Mac (first time only).** The Mac asks *"Allow '<phone>' to control this Mac?"* with a 4-digit code, and the phone shows the same code. If they match, click **Allow**. From then on the phone reconnects without asking.

That's it. The sections below are optional extras.

### Pairing and security

- Only phones you've allowed can control the Mac. Other phones on the same Wi-Fi are refused.
- One phone at a time: while your phone is connected, another approved phone gets "being used by another phone".
- To switch Macs on the phone: five-finger tap → **Choose another Mac**.
- To revoke access on the Mac: hand icon → **Forget Paired Phones…**

---

## Gestures

| On the phone | On the Mac |
|---|---|
| Slide one finger | Move the pointer |
| Tap | Click (after a 0.3 s wait, in case a drag follows) |
| Tap, then within 0.3 s touch again and slide | Click and drag (select, move items, Figma marquee) |
| Tap, then touch again and lift without sliding | Double-click |
| While dragging, lift and touch again within 0.4 s | Keep dragging (re-grip). Tap to drop straight away |
| Two-finger tap (both fingers together) | Right-click |
| Slide two fingers | Scroll or pan, with glide |
| Hold two fingers still for 0.5 s (the phone vibrates and a ←→ badge appears by the pointer), then drag right / left | Back / Forward in browsers and Finder |
| Pinch two fingers | Zoom |
| Three or four fingers left / right | Next / previous Space or full-screen app |
| Three or four fingers up | Mission Control (swipe down to close) |
| Three or four fingers down | App Exposé (swipe up to close) |
| Four fingers spread / pinch | Show Desktop / Apps |
| **Five-finger tap** | Phone options: pin screen, close app |

## Mac menu (hand icon)

- **Natural scrolling:** follows the Mac's own setting. Click it to open **System Settings → Mouse**, where you change it.
- **Tracking speed:** Slow, Medium, Fast or Very fast.
- **Forget Paired Phones…:** every phone has to be allowed again.
- **Install Wi-Fi Lag Fix…:** see below.
- **Open at Login**

## If the trackpad feels laggy (Mac on Wi-Fi)

The Mac's AWDL radio, used by AirDrop, AirPlay Receiver and Universal Control, makes its Wi-Fi pause briefly now and then. Choose **Install Wi-Fi Lag Fix…** in the menu and enter your Mac password. A small system service then switches AWDL off **only while the phone is connected** and back on afterwards, including after restarts. Remove it with **Uninstall Wi-Fi Lag Fix…**.

While the phone is connected, AirDrop, AirPlay to this Mac, Universal Control and wireless Sidecar don't work. Normal Wi-Fi, Bluetooth and internet are unaffected. A Mac on Ethernet doesn't need the fix.

## Stop the phone's own three-finger gestures (OPPO / OnePlus / Realme)

On ColorOS phones, three-finger swipes also take screenshots or open split screen. The Mac app can switch those off while the trackpad is open and back on when you close it. This needs **adb** on the Mac and **Wireless debugging** on the phone, paired once:

1. On the Mac, install adb: `brew install android-platform-tools`
2. On the phone: **Settings → About device → Version**, tap **Build number** 7 times to unlock Developer options. Then **Settings → Additional settings → Developer options**:
   - turn on **Wireless debugging**
   - turn on **Disable adb authorisation timeout** (keeps the pairing)
3. In **Wireless debugging**, tap **Pair device with pairing code**. On the Mac, run `adb pair <IP:port shown> <code shown>`.
4. Reopen Phone Trackpad on the Mac. From now on it pauses those gestures whenever the phone connects.

Wireless debugging turns itself off after a phone restart or a Wi-Fi change. Turn it back on to keep the gestures blocked.

On other phone brands, turn off any three-finger gestures in the phone's settings by hand.

## Lowest latency: USB cable

With adb installed, plug the phone into the Mac with a cable and allow USB debugging on the phone. The app switches to the cable by itself (about 1 ms delay instead of Wi-Fi's few milliseconds).

## Troubleshooting

| Problem | Fix |
|---|---|
| Phone shows "Looking for your Mac…" | Same Wi-Fi network? Phone Trackpad running on the Mac (hand icon)? Not a guest network? |
| No approval prompt on the Mac | It may be behind other windows: check the Dock or press Cmd+Tab |
| Phone says it "wasn't allowed" | Don't Allow was clicked. Five-finger tap → **Choose another Mac** → pick the Mac again to get a new prompt |
| Pointer doesn't move, but the phone says Connected | Turn PhoneTrackpad off and on in **Privacy & Security → Accessibility**, then quit and reopen the app |
| Feels laggy or jumpy | Install the Wi-Fi Lag Fix, or use a USB cable |
| Phone takes screenshots on three-finger swipes | See "Stop the phone's own three-finger gestures" above, or turn them off in phone settings |
| Phone's Home or Back gesture gets in the way | Five-finger tap → **Pin screen**. To unpin: five-finger tap → **Unpin screen**. If pinning does nothing, turn on **App pinning** in the phone's security settings |

## Uninstall

- **Mac:** menu → **Uninstall Wi-Fi Lag Fix…** (if installed), → **Quit**, then delete the app and remove it from **Privacy & Security → Accessibility**.
- **Phone:** uninstall **Trackpad** like any app.

---

## Build from source

Needs Xcode command-line tools (`swiftc`), JDK 17+ and the Android SDK (`android/local.properties` with `sdk.dir=...`).

```bash
./mac/build.sh        # builds mac/build/PhoneTrackpad.app (Apple Silicon + Intel)
./package.sh          # builds dist/PhoneTrackpad-1.1.zip: Mac app, APK and this README
```

The Mac app is ad-hoc signed, so macOS asks for the Accessibility permission again after every rebuild.
