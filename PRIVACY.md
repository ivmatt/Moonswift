# Moonswift Privacy Policy

**Effective November 22, 2026**

Moonswift is a free and open-source app for streaming games from your own PC to your iPhone or iPad. This policy explains what data the app handles, where that data goes, and how to remove it.

## The short version

- Moonswift has no accounts, ads, analytics, or tracking.
- The developer runs no server for the app and does not receive your hosts, games, streams, voice, or clipboard.
- Your settings and library stay on your device, and your stream goes between your device and your PC.
- A few features contact outside services. They are listed below so you know what each one receives.

## Data stored on your device

Moonswift keeps the following on your device so the app can work:

- **Hosts:** each PC's name, local and public addresses, port, network adapter (MAC) address, and pairing certificate.
- **Library:** game names, artwork, favorites, hidden games, when you last played, and your edits.
- **Settings:** stream, controller, touch, gesture, and interface preferences.
- **Keychain items:** the certificate and private key that identify this device to your PCs, and your SteamGridDB API key if you add one.
- **Pictures you choose:** a saved copy of any image you pick for a game. Moonswift only receives the images you select in the photo picker.

Depending on your device settings, app data may be included in your iCloud or computer backups. Those backups are controlled by you and Apple.

## Data sent to your PC

When you pair with or stream from a PC, Moonswift exchanges the following directly with that PC:

- Pairing details, including this device's certificate and the device name "Moonswift".
- Stream settings, such as resolution, frame rate, and HDR.
- Your controller, touch, keyboard, and mouse input.
- Text on your clipboard, **only when you choose** to send it. Text you choose to copy from the PC is placed on this device's clipboard.

Your PC's host software, such as Sunshine or Vibepollo, is separate from Moonswift and has its own settings and logs.

## Outside services

| Service | When it's used | What it receives |
|---|---|---|
| **SteamGridDB** | When online artwork is on and you've added your own API key | Your API key, the game names being looked up, and your IP address |
| **Steam's image servers and SteamGridDB's image hosts** | When downloading artwork | The image being requested and your IP address |
| **Moonlight's STUN server** (`stun.moonlight-stream.org`) | Automatically, when a paired PC answers on your home network, to learn the public address for playing away from home | Your network's public IP address |
| **Apple Speech Recognition** | When you search by voice, only if your device can't recognize speech on its own | Your voice recording for that search, handled under Apple's privacy terms |

Moonswift asks for microphone and speech recognition permission the first time you use voice search. It listens only while voice search is active and doesn't save recordings.

Links in the app, such as the source code or SteamGridDB's website, open outside the app and are covered by those sites' own policies.

## Apple's services

Apple handles App Store downloads, purchases, and payments. The developer does not receive your payment details. If you choose to share analytics with app developers in your device settings, Apple may provide the developer with crash reports and combined usage statistics.

If you join the **TestFlight** beta, Apple shares your tester details, such as your name and email if you were invited directly, along with your install and session information, crash reports, and any feedback you send.

## How your data is used

Data is used only to provide the features described above. The developer does not sell or share your data, or use it for advertising.

## Removing your data

- **A host and its games:** use **Remove Host** on the Hosts page.
- **Your SteamGridDB key:** clear the key in Moonswift's settings.
- **Microphone or speech access:** turn it off in the iOS Settings app.
- **Everything else:** delete Moonswift from your device.

iOS may keep Keychain items after an app is deleted, so clear your SteamGridDB key before deleting the app. To revoke this device's access to a PC, remove it from the paired clients in your host software.

Because the developer doesn't hold your app data, there is nothing for the developer to delete on your behalf. Any data held by an outside service is handled under that service's policy.

## Children

Moonswift is not directed at children and does not knowingly collect personal information from anyone, including children.

## Changes

If this policy changes, the new version will be published here with a new effective date. Its full history is available in this project's public repository.

## Contact

For privacy questions, [open an issue on GitHub](https://github.com/ivmatt/Moonswift/issues). Issues are public, so please don't include personal information.
