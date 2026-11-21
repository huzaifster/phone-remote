# Phone Remote

A private, secure way to check on your Windows PC from your Android phone.

## What it is

Phone Remote lets you see what is on your PC's screen from your phone, and control its power, without any account, cloud service or internet connection. It has two parts:

- **Phone Remote for Windows**: a small app that lives in the system tray and shares the PC's screen over your home or office Wi-Fi.
- **Phone Remote for Android**: the app you use to pair with your PC, view its windows and send power commands.

Phone Remote is a **viewer, not a full remote desktop**. You see screenshots of the desktop or of a single window. You cannot move the mouse or type on the PC from the phone.

## What you can do

### See your PC

- View the whole desktop (all monitors together) or pick one open window from a list.
- A window that is partly covered by other windows can still be captured on its own.
- Tap refresh for a fresh screenshot, or turn on auto-refresh (every 2 seconds). Auto-refresh only sends a new image when something on screen has changed.
- Pinch to zoom up to 8 times and drag to read small text.
- Minimized windows can be captured with a manual refresh. The PC restores the window for a moment without taking focus, takes the shot, then minimizes it again. Auto-refresh does not work on minimized windows.

### Control power

- **Shut down, restart or sleep** the PC from your phone. Each one starts a 30-second countdown that you can cancel from the phone or on the PC.
- **Shut down when finished**: switch this on before leaving a long download or install. The PC watches network, disk and processor activity and shuts down once everything has been quiet for the time you choose (1, 2, 3, 5, 10 or 15 minutes). It only arms itself after it has seen activity, so turning it on early will not shut the PC down straight away. When it triggers, you get a 60-second warning that you can cancel. It works once, then switches itself off.
- **Background alerts**: while the watcher is on, the phone app keeps a quiet connection to the PC and notifies you before a shutdown, with a **Cancel** button on the notification.

### Stay in control of access

- Pair a phone by scanning a QR code shown on the PC.
- See every paired phone in **Manage phones** and revoke any of them. A revoked phone is disconnected immediately and must pair again.
- The tray icon shows a green dot while a phone is connected, and a notification appears when one connects.
- Optional **app lock** on the phone: a PIN (4 to 8 digits) with optional fingerprint unlock.

## Getting started

### Requirements

- A Windows 10 or Windows 11 PC.
- An Android phone (Android 6.0 or newer) with a camera.
- The phone and PC on the same Wi-Fi network (the PC's network should be set to Private in Windows).

### Install and pair

1. **On the PC**, run `PhoneRemote-Setup.exe` and follow the steps. It adds a Start Menu entry, an optional "Start with Windows" setting and a Windows Firewall rule for private networks.
2. **On the phone**, install the Phone Remote app and allow camera and notification access when asked.
3. **On the PC**, right-click the Phone Remote icon in the system tray (near the clock) and choose **Pair new phone...**. A QR code appears. It works once and expires after 2 minutes.
4. **On the phone**, tap **Scan QR code** and scan it.
5. Tap **Connect**. Pick Desktop or a window to start viewing.

After pairing, the phone reconnects on its own. If your router gives the PC a new IP address, the phone finds it again automatically.

## How it works

1. The Windows app captures screenshots in memory (they are never saved to disk), shrinks them to at most 1280 pixels wide and compresses them as JPEG.
2. It sends them to the phone over a secure WebSocket connection on port 8765, only to devices on your local network.
3. The phone app announces nothing; instead, the PC announces itself on the local network using mDNS, so the phone can find it again after an address change. Only part of the PC's certificate fingerprint is announced. The phone still verifies the full fingerprint when it connects, so a fake announcement cannot trick it.

## Security and privacy

Phone Remote is built so that only your own phones can see your screen.

- **Encrypted connection.** All traffic uses TLS 1.3, the newest version of the protocol.
- **Both sides prove who they are.** The phone checks the PC against a fingerprint it saved from the QR code, and trusts no public certificate authority. The PC accepts only phones that hold a certificate it issued itself.
- **One-time pairing.** The QR code contains a random single-use token that lasts 2 minutes. Three wrong tokens close the pairing window.
- **Brute-force protection.** After 5 failed attempts from one address, that address is blocked for 10 minutes.
- **Local network only.** The PC refuses connections from addresses outside private ranges.
- **Keys stay where they belong.** The PC does not keep a copy of a phone's private key. On the phone, the key and certificate are stored in Android's secure storage.
- **Instant revoke.** Removing a phone on the PC disconnects it and blocks it from reconnecting.
- **App lock.** The PIN is stored as a salted, repeatedly hashed value, never in plain text. Five wrong PINs trigger a growing waiting time. The app is also hidden from the recent-apps preview and blocks screenshots of itself.
- **No cloud, no account, no tracking.** Phone Remote does not send your screen or any other data to a server on the internet. Everything stays between your PC and your phone.

The PC keeps its settings, certificates, list of paired phones and a log file in a folder named `.phone_remote` inside your user folder.

## Limitations

- Phone Remote shows screenshots, not live video, and it cannot control the mouse or keyboard.
- It works only on the same local network. It does not work over mobile data or the internet.
- The PC app is Windows only. A phone can be paired with one PC at a time.
- When the PC is asleep or off, it cannot be reached. Wake it at the PC.
- Some windows, such as protected video, may appear blank in a capture.
- If Windows hibernation is enabled, the Sleep command hibernates instead.
- A phone's certificate is valid for 2 years. After that, pair the phone again.
- If the Windows network profile is set to Public, the firewall rule does not apply and the phone cannot connect. Switch the network to Private.

## Troubleshooting

- **"Couldn't reach your PC"**: check that the PC is on and awake, Phone Remote is running (look for the tray icon), both devices are on the same Wi-Fi and Windows Firewall allows Phone Remote on private networks.
- **"The PC refused this phone"**: the phone was probably removed in Manage phones, or it was blocked for 10 minutes after too many failed attempts. Tap Unpair on the phone and pair again.
- **"The PC's security certificate doesn't match"**: Phone Remote was reinstalled or its data was deleted on the PC. Unpair and pair again.
- **QR code rejected**: the code expired, was already used or a newer one was shown. Choose Pair new phone... again for a fresh code.
- **Camera won't open**: allow Camera for Phone Remote in the phone's app settings.
- **Windows warns "Windows protected your PC" when installing**: the installer is not code-signed. Choose More info, then Run anyway.

If something else goes wrong, the PC app writes errors to `agent.log` in the `.phone_remote` folder.

## Under the hood

- **PC app:** Python, with WebSockets, mss, pywin32, Pillow, psutil, cryptography, pystray and zeroconf. Packaged with PyInstaller and Inno Setup.
- **Phone app:** Flutter, with web\_socket\_channel, mobile\_scanner, flutter\_secure\_storage, local\_auth, flutter\_foreground\_task, flutter\_local\_notifications and nsd.
