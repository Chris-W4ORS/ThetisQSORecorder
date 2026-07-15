# Thetis QSO Recorder

A standalone background recorder for [Thetis](https://github.com/ramdor/Thetis) (OpenHPSDR) that
captures a full QSO to MP3 — both sides, RX and TX, automatically switching between them as you
transmit and receive, with independent loudness balancing so neither side drowns out the other in
the finished recording.

- **RX** streams from Thetis over the [TCI](https://github.com/ExpertSDR3/TCI) protocol
  (`audio_start` binary frames).
- **TX** is captured via WASAPI from whatever device carries your mic audio into Thetis (you pick
  it during setup).
- **MOX (transmit/receive) detection** uses Thetis's CAT TCP server, actively polling `ZZTX;` —
  this catches transmit state regardless of *how* you key (mouse, footswitch, hardware PTT), unlike
  relying on TCI push events alone.
- A **Leveler** (slow AGC) and **Compressor/Limiter** chain keeps RX and TX at a consistent, matched
  loudness in the final file, correcting the common "TX is way louder/quieter than RX" problem.
- Live tray icon shows current RX/TX state and levels while recording.

Everything lands as a single timestamped MP3 per session, automatically renamed with the operating
frequency once the session ends.

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11 |
| PowerShell | [7.0+](https://github.com/PowerShell/PowerShell/releases) — Windows ships with 5.1 by default, which is **not** enough. The installer below will offer to install it for you. |
| Thetis | TCI server **and** CAT (network) server both enabled — see below. |
| Network | Internet access on first run only (downloads NAudio + NAudio.Lame via NuGet) |

No admin rights needed for normal use.

## Enabling TCI in Thetis

The recorder connects to Thetis over TCI for RX audio, which is off by default. In Thetis:

**Setup → Serial/Network/Midi CAT → Network → TCI**

- Check **TCI Server Running** (or the equivalent enable checkbox for your Thetis version)
- Leave the port at the default **50001** unless you have a reason to change it
- If this is the first time you've enabled it, Windows may prompt with a Firewall permission dialog
  for Thetis — allow it on at least your **Private** network

## Enabling the CAT (network) server in Thetis

The recorder also needs Thetis's **CAT server** running over TCP, separate from TCI, so it can
detect transmit/receive switching by polling regardless of how you key.

<!-- TODO: confirm exact menu path/labels against your own working setup before publishing —
     this is a best-effort description based on Thetis's general CAT architecture (4 independent
     CAT ports, each assignable to Serial or Network/TCP), not a verified click-by-click path. -->

**Setup → Serial/Network/Midi CAT** → pick one of the four CAT port slots → set its type to
**Network (TCP/IP)** → set the port to **13013** (or whatever you configure — just make sure it
matches the recorder's `$CatPort` setting).

You only need to do this once each; Thetis remembers both settings across restarts.

## Install

**Option A — one-liner** (recommended; opens PowerShell from the Start menu, then paste):

```powershell
irm https://raw.githubusercontent.com/Chris-W4ORS/ThetisQSORecorder/main/Install.ps1 | iex
```

This downloads the recorder, checks for/offers to install PowerShell 7, and creates two Desktop
shortcuts: **"Thetis QSO Recorder"** to run it, and **"Thetis QSO Recorder (Reconfigure)"** to redo
setup later. Re-run the one-liner any time to update to the latest version — your saved setup isn't
touched, since that lives separately in `%APPDATA%\ThetisQSORecorder\`.

**Option B — manual:**

1. Download `ThetisQSORecorder.ps1` from this repo.
2. Right-click → Properties → **Unblock** (or `Unblock-File .\ThetisQSORecorder.ps1`).
3. Run it:
   ```powershell
   pwsh .\ThetisQSORecorder.ps1
   ```

## First run

A short setup wizard runs automatically the first time:

1. Pick which recording device carries your mic audio into Thetis, from a numbered list of
   everything Windows sees.
2. Confirm where recordings should be saved (defaults to `Documents\ThetisQSORecorder`).
3. Confirm the TCI host (press Enter to auto-detect) and port (default `50001`) — live-tested right
   there, so a typo or a not-yet-enabled TCI server is caught immediately.

Every run after that is silent — you'll still get the classic "Recording folder [X], press Enter to
accept or type a different one" prompt each time (handy if you want a different folder for a
specific session), but it now defaults to your saved folder instead of asking cold.

To change devices, folder, or TCI connection later: double-click the **"Thetis QSO Recorder
(Reconfigure)"** Desktop shortcut, or run:

```powershell
pwsh .\ThetisQSORecorder.ps1 -Reconfigure
```

Setup is saved to `%APPDATA%\ThetisQSORecorder\Recorder.config.json`.

## Diagnostics

Every run writes a timestamped session log (falls back to `%APPDATA%\ThetisQSORecorder\logs` if the
script's own folder isn't writable). Useful for tracking down anything that looked off during a
session after the fact.

## Troubleshooting

**Script won't run at all, even after Unblock-File.**
```powershell
Get-ExecutionPolicy
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Recorder exits immediately with a TX capture error.**
Windows may be blocking desktop apps from using your microphone — check **Settings → Privacy &
security → Microphone → "Let desktop apps access your microphone"**, and make sure no other app has
that device open exclusively.

**RX side of recordings is silent/missing.**
Almost always means Thetis's TCI server isn't running — see [Enabling TCI in
Thetis](#enabling-tci-in-thetis) above.

**Recording never detects transmit (always records as RX, even while transmitting).**
Means the CAT TCP server isn't reachable — see [Enabling the CAT (network) server in
Thetis](#enabling-the-cat-network-server-in-thetis) above, and confirm the port matches `$CatPort`.

## License

MIT — see [LICENSE](LICENSE).
