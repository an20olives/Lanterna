# atvloadly on the Raspberry Pi

atvloadly signs and installs the unsigned tvOS IPA onto the Apple TV with a free Apple ID and refreshes it automatically before the 7-day profile expires.

## Before you start

1. Confirm the Pi runs a 64-bit OS: `uname -m` should print `aarch64`.
2. Confirm the image has an arm64 build (not verified yet): `docker manifest inspect ghcr.io/bitxeno/atvloadly:latest | grep -i arm64`. If nothing prints, stop; the image will not run on the Pi.
3. Create a dedicated Apple ID for signing. Never use your main Apple ID. Give it your phone number as the trusted number so 2FA codes arrive by SMS. atvloadly warns that missing the 2FA code window can freeze the account until a password reset.
4. Turn off automatic tvOS updates on the Apple TV. New tvOS releases usually break atvloadly until it catches up, and every OS update requires re-pairing.

## Network (UniFi)

- atvloadly discovers and pairs over mDNS. If the Pi and the Apple TV sit on different VLANs, discovery will fail. Either put them on the same VLAN or enable multicast DNS forwarding between those two networks in UniFi.
- Expose port 5533 to the LAN and Tailscale only. Never forward it to the internet.

## Install

```
sudo apt-get -y install avahi-daemon
sudo systemctl restart avahi-daemon

docker run --privileged -d --name=atvloadly --restart=always \
  -p 5533:80 \
  -v /srv/atvloadly:/data \
  -v /var/run/dbus:/var/run/dbus \
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \
  ghcr.io/bitxeno/atvloadly:latest
```

The container runs privileged with host D-Bus access, on the same Pi as Ente Photos and Jellyfin. That is a real lateral-movement path if the container is ever compromised. Acceptable on a segmented homelab VLAN; keep the web UI off the internet.

## Pair and install

1. On the Apple TV: Settings, Remotes and Devices, Remote App and Devices. Leave it in pairing mode.
2. Open `http://<pi>:5533`, select the Apple TV, and complete pairing.
3. On the Mac: `make ipa-tvos`.
4. Upload `build/Lanterna-tvOS.ipa` in the atvloadly UI and install. Sign in with the dedicated Apple ID.

## Limits

- 3 active sideloaded apps per Apple ID. Installing a fourth disables an earlier one.
- Re-pair after any tvOS update.
- iPhone: install `build/Lanterna-iOS.ipa` through AltStore. AltStore itself counts toward the 3-app limit on the iPhone.
