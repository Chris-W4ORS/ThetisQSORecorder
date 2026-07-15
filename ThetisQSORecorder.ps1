#Requires -Version 7.0
<#
.SYNOPSIS
    Thetis QSO Recorder - W4ORS / HAL1
    RX audio via TCI WebSocket binary stream (float32 stereo 48kHz from Thetis DSP)
    TX audio via WASAPI capture of Voicemeeter Out B1 (post NVIDIA Broadcast +
    Voicemeeter EQ/Compressor — see chain note below)
    Output: MP3 file per session via NAudio.Lame

.DESCRIPTION
    Connection:  ws://127.0.0.1:50001  (Thetis TCI server)
    RX source:   TCI audio_start:0 binary frames  → float32 stereo → MP3
    TX source:   WASAPI capture "Voicemeeter Out B1" → float32 → MP3
                 TX chain as of this version: FDUCE mic → NVIDIA Broadcast
                 (noise suppression) → Voicemeeter Potato strip A1 (EQ +
                 Compressor, gain staging) → B1 bus → also sent to Thetis via
                 VMP's ASIO driver. This script captures that same B1 bus, so
                 the recording matches what Thetis actually transmits.
    MOX trigger: trx:0,true / trx:0,false TCI push events (no polling)
    Both audio paths run continuously; only the active one writes to the encoder.
    A silence gap is inserted at each RX↔TX transition to prevent encoder artifacts.

.NOTES
    Requires: PowerShell 7+, internet access on first run (NAudio + NAudio.Lame bootstrap)
    TCI Server must be running: Thetis Setup → Serial/Network/Midi CAT → Network → TCI Server Running
#>

param(
    [switch]$Reconfigure   # re-run the first-time device/output-folder/TCI setup wizard even if a saved config exists
)

# ─────────────────────────────────────────────────────────────────────────────
# USER CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
$TciHost            = "auto"        # "auto" = discover TCI bind address automatically
                                    # or set a specific IP like "127.0.0.1" / "192.168.0.10"
$TciPort            = 50001
$TciTrxIndex        = 0             # TRX index (0 = first/only receiver)

# ── MOX detection via CAT (port 13013) ────────────────────────────────────────
# Thetis does not reliably PUSH trx/MOX over TCI on hardware PTT, so MOX state is
# detected by actively POLLING the CAT TCP server with "ZZTX;" (responds ZZTX0=RX,
# ZZTX1=TX) regardless of how you key. TCI is still used for RX audio.
$CatMoxEnabled      = $true
$CatHost            = "127.0.0.1"  # CAT TCP server host (usually same machine)
$CatPort            = 13013        # Thetis TCP/IP CAT server port
$CatPollMs          = 100          # how often to poll ZZTX; (ms)

$SampleRate         = 48000
$Channels           = 2             # Stereo

# MP3 settings
$Mp3BitRate         = 128           # kbps — 128 stereo = ~57MB/hr, 64 = ~28MB/hr

# Output folder — default; you'll be prompted at startup to confirm or change it
$OutputFolder       = "E:\Chris\Music\Thetis\ThetisQSORecorder"

# ── TX audio source ───────────────────────────────────────────────────────────
# "tci"    = record the TCI binary stream during TX too (TX monitor/sidetone, if
#            Thetis sends it). Free, no WASAPI capture. Try this first.
# "wasapi" = capture the Voicemeeter B1 bus via WASAPI during TX — this is the
#            final output of the chain (FDUCE mic → NVIDIA Broadcast noise
#            suppression → Voicemeeter A1 EQ/Compressor → B1), i.e. exactly
#            what Thetis transmits.
$TxAudioSource      = "wasapi"

# Voicemeeter B1 bus as a RECORDING (capture) device — used when
# $TxAudioSource="wasapi". In the Windows Sound "Recording" tab this is
# usually "Voicemeeter Out B1" (VB-Audio Voicemeeter AUX). Partial match,
# case-insensitive. If the script can't find it on startup it prints all
# available capture devices so you can copy the exact name here.
$TxDeviceSubstr     = "Voicemeeter Out B1"

# Auto-detect mono vs stereo for the whole recording, based on the TX capture
# device's actual native channel count. If the device is genuinely stereo
# (2 distinct channels), the recording is made in stereo. If it reports mono
# (1 channel), the recording is made in mono instead, which avoids writing out
# a stereo file with two identical duplicated channels (no audio benefit,
# just extra file size). Only applies when $TxAudioSource = "wasapi" (that's
# the only path where the true native channel count is knowable at startup)
# — in "tci" mode $Channels is used as configured, unchanged.
# Force the whole recording (RX + TX) to mono, regardless of what channel
# count the TX capture device reports. Voicemeeter's B1 bus always exposes
# itself to Windows as 2-channel even when the content inside is duplicated
# mono (e.g. a mono mic signal fed through an EQ/Compressor strip upstream),
# so channel-count auto-detection alone can't distinguish "true stereo" from
# "mono duplicated to stereo." Forcing is the reliable option here. When the
# device's native format is still 2-channel, the TX capture is downmixed
# (L+R averaged) to real mono before it hits the Leveler/Compressor/Limiter.
$ForceMono          = $true

# Only used if $ForceMono = $false — falls back to trusting the TX device's
# reported channel count, which (per above) won't catch duplicated-mono content.

$AutoDetectChannels = $true

# Silence gap at RX↔TX transitions (ms) — prevents LAME encoder state artifacts
$SwitchSilenceMs    = 60

# Short fade-in applied to the very first moment of audio after each RX<->TX
# switch. Without this, a loud syllable starting right at a switch (before
# the Leveler/Compressor have had any time to react) hits the Limiter cold —
# it has to do all the gain-reduction work alone on that first transient,
# which can pin several samples near the ceiling in a row (audible as a
# slight "thump"/squash right at transitions, even though it's not full-scale
# clipping). This ramp is far too short to be heard as a fade — it just
# prevents a hard instantaneous edge from ever reaching the processing chain.
$FadeInMs           = 20

# TCI audio frame setup
$TciFrameSamples    = 2400          # samples per TCI audio frame (50ms at 48kHz)
$TciHeaderBytes     = 64            # TCI binary frame header size in bytes

# ── Leveler (slow AGC — corrects persistent RX/TX loudness offset) ───────────
# Runs BEFORE the compressor in the chain. Where the compressor reacts fast to
# peaks, this tracks long-term average loudness and slowly nudges gain to keep
# both sources parked near the same target — this is what actually fixes a
# static "TX always runs N dB hotter than RX" offset that compression alone
# won't fully correct. Independent RX/TX instances, same settings.
$LevelerEnabled           = $true
$LevelerTargetDb          = -20.0   # dB — target long-term RMS loudness
                                    # (moved back down from -18 based on
                                    # real-world calibration: RX naturally
                                    # sits around -24dB and can't be changed
                                    # at the source, so -18 was asking for a
                                    # full 6dB of continuous manufactured
                                    # gain; TX/mic was independently observed
                                    # landing almost exactly at -20dB on its
                                    # own. -20 cuts RX's required correction
                                    # to 4dB and lets TX need almost none —
                                    # closer to the "small occasional nudge"
                                    # role the Leveler is meant to play. The
                                    # original -18 was chosen when peaks were
                                    # landing short of a -6dB goal, but that
                                    # was diagnosed and fixed separately (see
                                    # the Leveler control-loop fix below) —
                                    # revisit if peaks drift again now that
                                    # the loop actually converges correctly.
$LevelerWindowSeconds     = 3.5     # seconds — averaging window
$LevelerMaxAdjustDbPerSec = 2.0     # dB/sec — max gain change rate (reverted
                                    # from 3.0 back to 2.0 — the faster rate
                                    # was meant to shorten the slow-start
                                    # period, but a recording came back with
                                    # audible harshness/distortion specifically
                                    # in the first several seconds, correlating
                                    # with 129 Limiter engagements in the first
                                    # 10 seconds alone — far more frequent than
                                    # the rest of the clip. That's the Leveler
                                    # still actively ramping gain while real
                                    # speech is already present, repeatedly
                                    # overshooting into the Compressor/Limiter
                                    # in quick succession — three reactive
                                    # gain stages all changing at once rather
                                    # than the Leveler settling first. Slowing
                                    # the ramp trades a slightly longer
                                    # quiet-start period for less startup
                                    # overshoot into the stages downstream.
$RxLevelerMaxGainDb       = 8.0     # dB — ceiling on how much RX can boost
                                    # (cut down hard from 14 — a recording came
                                    # back with 19+ seconds pinned flat at
                                    # -5..-7dB with essentially zero variability,
                                    # which only happens if the Leveler is sitting
                                    # at its gain ceiling continuously rather than
                                    # making the small, occasional correction it
                                    # was designed for. At full ceiling, whatever
                                    # noise/grain/artifacts exist in the raw
                                    # signal get amplified by that same amount,
                                    # which reads as "boosted and distorted" even
                                    # without hard 0dBFS clipping. RX keeps a
                                    # tight ceiling because receiver band noise
                                    # is the thing we specifically don't want
                                    # over-boosted — if it's still pinning at
                                    # 8dB for extended stretches, the real fix
                                    # is raising gain at Thetis's own RX AF
                                    # output, not asking this stage to make up
                                    # the difference.
$TxLevelerMaxGainDb       = 14.0    # dB — ceiling on how much TX (mic) can
                                    # boost. Kept separate from RX's ceiling —
                                    # a mic chain has a much cleaner noise
                                    # floor than an HF receiver, so there's
                                    # far less risk in giving it more headroom
                                    # to reach target. If TX still needs more
                                    # than this to hit target, or starts
                                    # sounding noisy/hissy once boosted, that's
                                    # the sign to raise gain at the actual mic
                                    # input (Windows recording level / NVIDIA
                                    # Broadcast input gain) instead of pushing
                                    # this ceiling even higher.
$LevelerMinGainDb         = -6.0    # dB — floor on how much it can cut (kept modest so a
                                    # long sustained-loud passage can't get gradually
                                    # tapered all the way down — that's the Compressor
                                    # and Limiter's job, not the Leveler's)
$LevelerNoiseHoldDb       = -22.0   # dB — below this smoothed RMS, gain is held steady
                                    # instead of chasing the target. This has to sit
                                    # ABOVE your actual RX noise floor, or the Leveler
                                    # boosts noise-only gaps toward -18dB right along
                                    # with voice, which sounds like pumping/swelling
                                    # hiss between words — or, worse, a solid wall of
                                    # hiss during longer stretches of real dead air
                                    # (confirmed on a recording where a 9-second
                                    # no-signal stretch got leveled+compressed up to
                                    # a steady -15dB instead of staying quiet).
                                    # History: gaps between words first measured
                                    # around -22 to -35dB (median ~-28), so this
                                    # started at -26; a later dead-air segment on
                                    # this same system came in hotter than that
                                    # (backing out to a raw floor near -24 to -25dB),
                                    # so this was raised again to -22. If you raise
                                    # RX/TX input gain going forward, the raw noise
                                    # floor rises right along with it — this value
                                    # may need to keep moving up in step, or you'll
                                    # see the same "runaway on dead air" symptom
                                    # again. If genuine quiet speech starts sounding
                                    # flat/held, that's the sign to lower it back down.

# ── Limiter (brick-wall — catches any residual peaks/clipping) ───────────────
# Runs LAST in the chain, after the Leveler and Compressor. Its only job is to
# guarantee nothing exceeds the ceiling, regardless of what gain the two
# stages ahead of it added (Leveler up to +8dB, Compressor +1dB makeup — that
# stacked headroom demand is what causes clipping on already-hot passages).
# Uses a short lookahead so gain reduction arrives just before the peak does,
# rather than reacting after the fact. Independent RX/TX instances.
$LimiterEnabled      = $true
$LimiterCeilingDb    = -3.0    # dB — hard output ceiling (extra margin below 0dBFS
                                # to absorb MP3 encode/decode true-peak overshoot,
                                # which can push reconstructed peaks above the PCM
                                # ceiling we actually limited to)
$LimiterReleaseMs    = 100.0   # ms — how fast gain recovers after a peak
$LimiterLookaheadMs  = 5.0     # ms — small, just enough to catch the peak

# ── Dynamics compression (balances RX vs TX recording levels) ────────────────
# Applied independently to RX and TX (separate compressor instances/envelope
# state per source, same settings) right before each stream is written to the
# MP3 encoder. Set $CompressorEnabled = $false to bypass and record raw levels.
$CompressorEnabled  = $true
$CompThresholdDb    = -12.0   # dB — level above which compression engages
                                # (raised from -20 — that sat BELOW the
                                # Leveler's -18dB target, meaning almost
                                # anything the Leveler successfully corrected
                                # to target was already past this threshold,
                                # so the Compressor engaged on essentially
                                # every leveled passage and stacked its fixed
                                # makeup gain on top of normal audio, not just
                                # genuine loud excursions. -12dB sits clearly
                                # above the target, so this only engages when
                                # something is actually running hot.)
$CompRatio          = 3.0     # e.g. 3.0 = 3:1
$CompAttackMs       = 200.0   # 0.2s
$CompReleaseMs      = 1000.0  # 1s
$CompMakeupGainDb   = 1.0     # dB (cut from 3 — with the threshold raised
                                # above target, this stage should now be an
                                # occasional peak-taming correction, not a
                                # second blanket boost stacked on the Leveler's)
$CompKneeWidthDb    = 6.0     # dB — soft-knee width around the threshold
$CompLookaheadMs    = 15.0    # ms

# Logging — a dated session log is written here every run (created if missing).
# Stored in a "logs" subfolder next to this script (falls back to the current
# directory if the script root can't be determined).
$ScriptDir          = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogFolder          = Join-Path $ScriptDir "logs"
$TciDebug           = $false        # verbose TCI/diagnostic logging; set $true to debug

# NAudio bootstrap
$LibDir             = "$env:APPDATA\ThetisQSORecorder\lib"
# NAudio 2.x is split into separate NuGet packages — all three required
$NAudioCoreVersion   = "2.2.1"   # NAudio.Core   — base DSP and wave types
$NAudioWasapiVersion = "2.2.1"   # NAudio.Wasapi — MMDeviceEnumerator, WasapiLoopbackCapture
$NAudioLameVersion   = "2.1.0"   # NAudio.Lame   — MP3 encoding via libmp3lame

# Saved setup (TX device choice, output folder, TCI host/port) — same parent
# folder the level meter uses for its own config, so everything for this
# toolkit lives under one place per Windows user profile. Kept as a separate
# file from the meter's config since the two scripts have different settings.
$ConfigDir  = "$env:APPDATA\ThetisQSORecorder"
$ConfigFile = Join-Path $ConfigDir "Recorder.config.json"
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging ───────────────────────────────────────────────────────────────────
# Every run writes a timestamped log to $LogFolder. Write-Log mirrors to console
# (with color) and appends to the session log file. Used for everything.
# If the script-dir "logs" folder can't be created or written (e.g. C:\Scripts
# needs elevation), fall back to %APPDATA% so logging never silently dies.
$logOk = $false
try {
    New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null
    $probe = Join-Path $LogFolder ".write_test"
    [System.IO.File]::WriteAllText($probe, "ok"); Remove-Item $probe -Force
    $logOk = $true
} catch { $logOk = $false }

if (-not $logOk) {
    $LogFolder = Join-Path $env:APPDATA "ThetisQSORecorder\logs"
    try { New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null } catch {}
    Write-Host "[Log] Script folder not writable; logging to $LogFolder instead." -ForegroundColor Yellow
}
$script:SessionLog = Join-Path $LogFolder ("session_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "Gray",
        [switch]$NoConsole,        # write only to file (for high-rate TCI traffic)
        [switch]$Verbose           # only write if $TciDebug is on
    )
    if ($Verbose -and -not $TciDebug) { return }
    $line = "{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $Message
    if (-not $NoConsole) { Write-Host $Message -ForegroundColor $Color }
    try { Add-Content -Path $script:SessionLog -Value $line -ErrorAction SilentlyContinue } catch {}
}

# Capture any unhandled terminating error to the log before the window closes
trap {
    try {
        Add-Content -Path $script:SessionLog -Value ("{0:HH:mm:ss.fff}  [FATAL] {1}`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace) -ErrorAction SilentlyContinue
    } catch {}
    Write-Host "[FATAL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $script:SessionLog" -ForegroundColor Yellow
    # Re-throw so the existing pause/handling still applies
    throw
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    Thetis QSO Recorder  •  W4ORS / HAL1                 ║" -ForegroundColor Cyan
Write-Host "║    RX: TCI audio stream  |  TX: WASAPI loopback  |  MP3 ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Bootstrap NAudio + NAudio.Lame ────────────────────────────────────────────
function Expand-NuGet {
    param([string]$PackageId, [string]$Version, [string]$DestDir)

    $nupkg = "$DestDir\$PackageId.nupkg"
    $url   = "https://www.nuget.org/api/v2/package/$PackageId/$Version"

    Write-Host "  Downloading $PackageId $Version..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
    foreach ($entry in $zip.Entries) {
        $extract = $false

        # Managed DLLs: lib/netstandard2.0/, lib/net472/, lib/net48/
        if ($entry.FullName -match "lib/(net472|net48|netstandard2\.0)/.*\.dll$") {
            $extract = $true
        }
        # NAudio.Lame native LAME DLLs live in build/ : build/libmp3lame.64.dll
        if ($entry.FullName -match "build/.*\.dll$") {
            $extract = $true
        }
        # Some packages use runtimes/win-x64/native/ for native DLLs
        if ($entry.FullName -match "runtimes/win-(x64|x86)/native/.*\.dll$") {
            $extract = $true
        }

        if ($extract) {
            $dest = Join-Path $DestDir ([System.IO.Path]::GetFileName($entry.FullName))
            if (-not (Test-Path $dest)) {
                Write-Host "    Extracting: $([System.IO.Path]::GetFileName($entry.FullName))" -ForegroundColor Gray
                $s = $entry.Open()
                $f = [System.IO.File]::Create($dest)
                $s.CopyTo($f); $f.Close(); $s.Close()
            }
        }
    }
    $zip.Dispose()
    Remove-Item $nupkg -Force
}

function Install-Dependencies {
    New-Item -ItemType Directory -Force -Path $LibDir | Out-Null

    $hasCore  = (Test-Path "$LibDir\NAudio.Core.dll")
    $hasWasapi= (Test-Path "$LibDir\NAudio.Wasapi.dll")
    $hasLame  = (Test-Path "$LibDir\NAudio.Lame.dll") -and (Test-Path "$LibDir\libmp3lame.64.dll")

    # Clean up any stale/partial nupkg files from a previous failed download
    Get-ChildItem -Path $LibDir -Filter "*.nupkg" -ErrorAction SilentlyContinue | Remove-Item -Force

    if ($hasCore -and $hasWasapi -and $hasLame) {
        Write-Host "[Libs] All dependencies already installed." -ForegroundColor Green
        return
    }

    Write-Host "[Libs] Bootstrapping dependencies from NuGet..." -ForegroundColor Yellow
    if (-not $hasCore)  { Expand-NuGet "NAudio.Core"   $NAudioCoreVersion   $LibDir }
    if (-not $hasWasapi){ Expand-NuGet "NAudio.Wasapi" $NAudioWasapiVersion $LibDir }
    if (-not $hasLame)  { Expand-NuGet "NAudio.Lame"   $NAudioLameVersion   $LibDir }

    Write-Host "[Libs] Bootstrap complete." -ForegroundColor Green
}

Install-Dependencies

# Load assemblies
$loaded = $false
foreach ($dll in @("NAudio.Core.dll","NAudio.Wasapi.dll","NAudio.Lame.dll")) {
    $p = Join-Path $LibDir $dll
    if (Test-Path $p) {
        try {
            Add-Type -Path $p
            $loaded = $true
            Write-Host "[Libs] Loaded: $dll" -ForegroundColor Green
        } catch { <# already loaded or dependency not yet present — continue #> }
    }
}
if (-not $loaded) {
    Write-Error "Could not load NAudio assemblies from $LibDir"
    exit 1
}

# ── First-run setup wizard ─────────────────────────────────────────────────────
# Lets this script be handed to someone else (different PC, different audio
# devices, different folder layout) without them having to open and edit the
# source. On first launch — or any time you run with -Reconfigure — this
# walks through picking the TX capture device, confirming the recording
# folder, and confirming the TCI host/port, then remembers the answers in
# $ConfigFile so every future launch is silent. Note: Get-TciCandidateHosts
# and Test-TciPort are defined further down in this file, but PowerShell
# resolves all top-level function definitions in a script before executing
# any of its statements, so calling them here (textually earlier) is fine.
function Invoke-SetupWizard {
    Write-Host ""
    Write-Host "=== Thetis QSO Recorder -- first-time setup ===" -ForegroundColor Cyan
    Write-Host "(Run this script with -Reconfigure any time to redo this.)" -ForegroundColor DarkGray
    Write-Host ""

    $chosenDeviceName = $null
    if ($TxAudioSource -eq "wasapi") {
        $enum = [NAudio.CoreAudioApi.MMDeviceEnumerator]::new()
        $devs = @($enum.EnumerateAudioEndPoints([NAudio.CoreAudioApi.DataFlow]::Capture, [NAudio.CoreAudioApi.DeviceState]::Active))
        if ($devs.Count -eq 0) {
            Write-Warning "No active recording devices were found on this PC. Setup can't continue -- check Windows Sound settings and re-run."
            Write-Log "Setup wizard: no active capture devices found" -Color Red
            return $null
        }

        Write-Host "Which device carries your mic audio into Thetis? (this is what gets recorded for TX)"
        for ($i = 0; $i -lt $devs.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $devs[$i].FriendlyName)
        }
        $choice = $null
        while ($null -eq $choice) {
            $raw = Read-Host "Enter a number"
            if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le $devs.Count) { $choice = [int]$raw - 1 }
            else { Write-Host "  Enter a number between 1 and $($devs.Count)." -ForegroundColor Yellow }
        }
        $chosenDeviceName = $devs[$choice].FriendlyName
        Write-Host "Using: $chosenDeviceName" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Where should recordings be saved?" -ForegroundColor Cyan
    $defaultFolder = if ($OutputFolder) { $OutputFolder } else { Join-Path $env:USERPROFILE "Documents\ThetisQSORecorder" }
    $folderIn = Read-Host "Folder path [$defaultFolder]"
    $chosenFolder = if ([string]::IsNullOrWhiteSpace($folderIn)) { $defaultFolder } else { $folderIn.Trim().Trim('"').Trim("'") }
    try {
        if (-not (Test-Path -LiteralPath $chosenFolder)) {
            New-Item -ItemType Directory -Force -Path $chosenFolder -ErrorAction Stop | Out-Null
        }
        $chosenFolder = (Resolve-Path -LiteralPath $chosenFolder).Path
        Write-Host "Using: $chosenFolder" -ForegroundColor Green
    } catch {
        Write-Warning "Couldn't create/access '$chosenFolder' ($($_.Exception.Message)) -- falling back to $defaultFolder"
        $chosenFolder = $defaultFolder
        try { New-Item -ItemType Directory -Force -Path $chosenFolder -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    Write-Host ""
    $hostIn = Read-Host "Thetis TCI host -- press Enter to auto-detect, or type an IP (e.g. 127.0.0.1)"
    $tciHostVal = if ([string]::IsNullOrWhiteSpace($hostIn)) { "auto" } else { $hostIn.Trim() }

    $portIn = Read-Host "Thetis TCI port [50001]"
    $tciPortVal = if ([string]::IsNullOrWhiteSpace($portIn)) { 50001 } elseif ($portIn -match '^\d+$') { [int]$portIn } else {
        Write-Host "  Not a valid port number, using default 50001." -ForegroundColor Yellow
        50001
    }

    # Live-test right now, using the values just entered, so a typo or a
    # "TCI Server" that isn't enabled yet in Thetis gets caught during setup
    # instead of on every future launch.
    Write-Host ""
    Write-Host "Testing TCI connection..." -ForegroundColor Cyan
    $savedTciHost = $script:TciHost; $savedTciPort = $script:TciPort
    $script:TciHost = $tciHostVal; $script:TciPort = $tciPortVal
    $found = $null
    foreach ($candidate in (Get-TciCandidateHosts)) {
        if (Test-TciPort -IPHost $candidate -Port $tciPortVal) { $found = $candidate; break }
    }
    $script:TciHost = $savedTciHost; $script:TciPort = $savedTciPort
    if ($found) {
        Write-Host "TCI server found at ${found}:${tciPortVal}" -ForegroundColor Green
        Write-Log "Setup wizard: TCI test succeeded at ${found}:${tciPortVal}"
    } else {
        Write-Warning "Couldn't reach a TCI server on port $tciPortVal right now. Saving the setting anyway -- just make sure Thetis's TCI Server is running (Setup -> Serial/Network/Midi CAT -> Network -> TCI Server) before you launch this again."
        Write-Log "Setup wizard: TCI test found nothing on port $tciPortVal (host setting '$tciHostVal')" -Color Yellow
    }

    $config = [ordered]@{
        TxDeviceFriendlyName = $chosenDeviceName
        OutputFolder         = $chosenFolder
        TciHost              = $tciHostVal
        TciPort              = $tciPortVal
        SavedAt              = (Get-Date).ToString("s")
    }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $config | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding utf8
    Write-Host ""
    Write-Host "Saved -- this won't ask again unless you run with -Reconfigure." -ForegroundColor Green
    Write-Host ""
    Write-Log "Setup wizard complete: TxDevice='$chosenDeviceName' OutputFolder='$chosenFolder' TciHost=$tciHostVal TciPort=$tciPortVal"
    return $config
}

$script:setupConfig = $null
if ($Reconfigure -or -not (Test-Path $ConfigFile)) {
    $script:setupConfig = Invoke-SetupWizard
} else {
    try {
        $script:setupConfig = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        Write-Host "[Config] Loaded from $ConfigFile (run with -Reconfigure to change)" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Existing config at $ConfigFile couldn't be read ($($_.Exception.Message)) -- running setup again."
        Write-Log "Config load failed ($($_.Exception.Message)) -- re-running setup wizard" -Color Yellow
        $script:setupConfig = Invoke-SetupWizard
    }
}

if ($script:setupConfig) {
    if ($script:setupConfig.TxDeviceFriendlyName) { $TxDeviceSubstr = $script:setupConfig.TxDeviceFriendlyName }
    if ($script:setupConfig.OutputFolder)         { $OutputFolder   = $script:setupConfig.OutputFolder }
    $TciHost = $script:setupConfig.TciHost
    $TciPort = [int]$script:setupConfig.TciPort
    Write-Log "Active config: TxDevice='$TxDeviceSubstr' OutputFolder='$OutputFolder' TciHost=$TciHost TciPort=$TciPort"
} else {
    Write-Warning "No configuration available -- falling back to the built-in defaults (TxDeviceSubstr='$TxDeviceSubstr', TciHost='$TciHost', TciPort=$TciPort)."
    Write-Log "No config available -- using built-in script defaults" -Color Yellow
}

# ── Find TX Capture Device (Voicemeeter B1 — a recording endpoint) ────────────
# Voicemeeter exposes its B1/B2/B3 buses as Windows *capture* (recording)
# devices. We capture B1 directly as an input rather than via render-side
# loopback (which returns silence for Voicemeeter bus outputs).
function Find-WasapiDevice {
    param([string]$Substr, [string]$Flow = "Capture")
    $dataFlow = if ($Flow -eq "Render") {
        [NAudio.CoreAudioApi.DataFlow]::Render
    } else {
        [NAudio.CoreAudioApi.DataFlow]::Capture
    }
    $enum = [NAudio.CoreAudioApi.MMDeviceEnumerator]::new()
    $devs = $enum.EnumerateAudioEndPoints($dataFlow, [NAudio.CoreAudioApi.DeviceState]::Active)
    foreach ($d in $devs) {
        if ($d.FriendlyName -ilike "*$Substr*") {
            Write-Host "  Found TX device: '$($d.FriendlyName)'" -ForegroundColor Green
            return $d
        }
    }
    Write-Warning "  TX device not found matching: '$Substr' (flow: $Flow)"
    Write-Host "  Available $Flow devices:" -ForegroundColor Gray
    foreach ($d in $devs) { Write-Host "    - $($d.FriendlyName)" -ForegroundColor Gray }
    return $null
}

Write-Host ""
$txDevice = $null
if ($TxAudioSource -eq "wasapi") {
    Write-Host "[Devices] Locating TX capture device (B1)..." -ForegroundColor Cyan
    $txDevice = Find-WasapiDevice -Substr $TxDeviceSubstr -Flow "Capture"
    if (-not $txDevice) {
        Write-Error "TX device not found. Update `$TxDeviceSubstr in config section."
        exit 1
    }

    # Create the WASAPI capture object now (rather than later) so we can read
    # its native format up front — specifically the channel count, which
    # drives the mono/stereo auto-detect below. Recording doesn't actually
    # start here; StartRecording() is still called later once the MP3 writer
    # and event plumbing are ready.
    try {
        $script:txCapture = [NAudio.CoreAudioApi.WasapiCapture]::new($txDevice)
    } catch {
        # Common real-world causes on a machine we've never seen: Windows
        # Privacy settings blocking desktop-app mic access, or the device
        # already held exclusively by another app. The recorder genuinely
        # can't proceed without TX audio in wasapi mode, so this still exits
        # -- but with an actionable reason instead of a raw stack trace.
        Write-Host ""
        Write-Host "[FATAL] Could not open TX capture device '$($txDevice.FriendlyName)': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        Check Windows Settings -> Privacy & security -> Microphone -> 'Let desktop apps access your microphone'," -ForegroundColor Yellow
        Write-Host "        and make sure no other app has this device open exclusively." -ForegroundColor Yellow
        Write-Log "TX capture open failed for '$($txDevice.FriendlyName)': $($_.Exception.Message)" -Color Red
        exit 1
    }
    $txFmt            = $script:txCapture.WaveFormat
    $script:txIsFloat = ($txFmt.Encoding -eq [NAudio.Wave.WaveFormatEncoding]::IeeeFloat)
    $script:txBits    = $txFmt.BitsPerSample
    Write-Host "  TX capture format: $($txFmt.SampleRate)Hz, $($txFmt.Channels)ch, $($txFmt.BitsPerSample)-bit, $($txFmt.Encoding)" -ForegroundColor DarkCyan
    $script:txNativeChannels = $txFmt.Channels

    if ($ForceMono) {
        if ($Channels -ne 1) {
            Write-Host "  [Force Mono] Recording forced to MONO (TX device native format is $($txFmt.Channels)ch — was configured for ${Channels}ch)." -ForegroundColor Cyan
        } else {
            Write-Host "  [Force Mono] Recording forced to MONO." -ForegroundColor Cyan
        }
        $Channels = 1
        if ($txFmt.Channels -eq 2) {
            Write-Host "  [Force Mono] TX device still delivers 2ch natively — TX audio will be downmixed (L+R averaged) to mono." -ForegroundColor DarkCyan
        }
    } elseif ($AutoDetectChannels) {
        if ($txFmt.Channels -eq 1 -or $txFmt.Channels -eq 2) {
            if ($txFmt.Channels -ne $Channels) {
                Write-Host "  [Auto-detect] TX device is $($txFmt.Channels)ch — recording will be $(if ($txFmt.Channels -eq 1) {'MONO'} else {'STEREO'}) (was configured for ${Channels}ch)." -ForegroundColor Yellow
            } else {
                Write-Host "  [Auto-detect] TX device is $($txFmt.Channels)ch — matches configured ${Channels}ch." -ForegroundColor DarkCyan
            }
            $Channels = $txFmt.Channels
        } else {
            Write-Host "  [Auto-detect] TX device reports $($txFmt.Channels)ch (unsupported) — falling back to configured ${Channels}ch." -ForegroundColor Yellow
        }
    }

    if ($txFmt.SampleRate -ne $SampleRate) {
        Write-Host "  [WARNING] TX device sample rate ($($txFmt.SampleRate)Hz) differs from MP3 target (${SampleRate}Hz)." -ForegroundColor Yellow
        Write-Host "            TX audio may sound wrong. In Voicemeeter or Windows Sound, set ${SampleRate}Hz." -ForegroundColor Yellow
    }
} else {
    Write-Host "[Devices] TX audio source = TCI stream (no WASAPI capture)." -ForegroundColor DarkCyan
}

# ── Prepare Output File ───────────────────────────────────────────────────────
# Prompt for the output folder, defaulting to the configured path.
# Press Enter to accept the default, or type/paste a different folder path.
Write-Host ""
Write-Host "Recording folder [$OutputFolder]" -ForegroundColor Cyan
$userPath = Read-Host "  Press Enter to accept, or type a different folder"
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    # Strip surrounding quotes if the user pasted a quoted path
    $OutputFolder = $userPath.Trim().Trim('"').Trim("'")
}

try {
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Force -Path $OutputFolder -ErrorAction Stop | Out-Null
    }
    # Verify it really exists and resolve to a full absolute path
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        throw "Folder does not exist after creation attempt."
    }
    $OutputFolder = (Resolve-Path -LiteralPath $OutputFolder).Path
} catch {
    Write-Error "Could not create or access folder: $OutputFolder`n$_"
    exit 1
}

$timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = [System.IO.Path]::Combine($OutputFolder, "QSO_W4ORS_$timestamp.mp3")
$waveFormat = [NAudio.Wave.WaveFormat]::new($SampleRate, 16, $Channels)

Write-Host ""
Write-Host "[Output] $outputFile" -ForegroundColor Cyan
Write-Host "         $Mp3BitRate kbps $(if ($Channels -eq 1) {'mono'} else {'stereo'}) MP3 @ ${SampleRate}Hz" -ForegroundColor DarkCyan

# ── Shared State ──────────────────────────────────────────────────────────────
$script:activeSource  = 0       # 0 = RX (TCI), 1 = TX (WASAPI)
$script:currentMox    = 0
$script:isRecording   = $true
$script:writeLock     = [System.Object]::new()
$script:mp3Writer     = $null
$script:mp3Stream     = $null
$script:tciReady      = $false
$script:lastFreqHz    = 0       # last-known VFO-A frequency in Hz (from TCI vfo: msgs)

# CAT MOX poll-thread handles (set when the poll thread is started)
$script:catPSRef  = $null
$script:catHandle = $null


# Pre-compute silence buffer (int16 samples, stereo, for gap insertion)
$silenceSampleCount   = [int]($SampleRate * $Channels * ($SwitchSilenceMs / 1000.0))
$silenceInt16Bytes    = New-Object byte[] ($silenceSampleCount * 2)   # 2 bytes per int16

# ── System Tray Icon ──────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:trayStopRequested = $false

# Build a 16x16 colored-dot icon for a given state color
function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    # Subtle dark outline for contrast on light/dark taskbars
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    $brush.Dispose(); $pen.Dispose(); $g.Dispose()
    $hicon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hicon)
    return $icon
}

$script:iconRX = New-DotIcon ([System.Drawing.Color]::FromArgb(40, 200, 60))    # green
$script:iconTX = New-DotIcon ([System.Drawing.Color]::FromArgb(230, 50, 50))    # red

$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:trayIcon.Icon    = $script:iconRX
$script:trayIcon.Visible = $true
$script:trayIcon.Text    = "Thetis QSO Recorder — starting…"   # tooltip (max 63 chars)

# Right-click context menu with Stop
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miStatus = $trayMenu.Items.Add("Thetis QSO Recorder — W4ORS")
$miStatus.Enabled = $false
$trayMenu.Items.Add("-") | Out-Null
$miStop   = $trayMenu.Items.Add("Stop && Save Recording")
$miStop.Add_Click({ $script:trayStopRequested = $true })
$script:trayIcon.ContextMenuStrip = $trayMenu

# Double-click also stops
$script:trayIcon.Add_DoubleClick({ $script:trayStopRequested = $true })

# Update tray icon + tooltip for current state
function Update-TrayIcon {
    param([int]$Mox, [string]$Tooltip)
    if (-not $script:trayIcon) { return }
    if ($Mox -eq 1) { $script:trayIcon.Icon = $script:iconTX }
    else            { $script:trayIcon.Icon = $script:iconRX }
    if ($Tooltip) {
        # NotifyIcon.Text has a 63-char hard limit
        if ($Tooltip.Length -gt 63) { $Tooltip = $Tooltip.Substring(0, 63) }
        $script:trayIcon.Text = $Tooltip
    }
}

# ── MP3 Writer ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[Encoder] Opening MP3 writer..." -ForegroundColor Cyan

# Explicitly load the native libmp3lame.64.dll (extracted from build/ during bootstrap)
# into the process so the LameDLLWrap p/invoke resolves it
$lameNativePath = Join-Path $LibDir "libmp3lame.64.dll"

if (-not (Test-Path $lameNativePath)) {
    Write-Error "[Encoder] libmp3lame.64.dll not found in $LibDir — delete the lib folder and re-run to re-bootstrap."
    exit 1
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NativeLoader {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr LoadLibrary(string lpFileName);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetDllDirectory(string lpPathName);
}
"@
# Add LibDir to the native DLL search path so the LameDLLWrap p/invoke resolves it
[NativeLoader]::SetDllDirectory($LibDir) | Out-Null
$handle = [NativeLoader]::LoadLibrary($lameNativePath)
if ($handle -eq [IntPtr]::Zero) {
    Write-Error "[Encoder] LoadLibrary failed for libmp3lame.64.dll."
    exit 1
}
Write-Host "[Encoder] libmp3lame.64.dll loaded (handle: $handle)." -ForegroundColor Green

try {
    # Open the output file ourselves so any path/permission error is clear here,
    # then hand the stream to LAME. This avoids LAME's opaque "Could not find file".
    $script:mp3Stream = [System.IO.File]::Open(
        $outputFile,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read)
    $script:mp3Writer = [NAudio.Lame.LameMP3FileWriter]::new(
        $script:mp3Stream,
        $waveFormat,
        $Mp3BitRate)
} catch {
    Write-Error "[Encoder] Could not open MP3 output file:`n  $outputFile`n$_"
    exit 1
}
Write-Host "[Encoder] LAME MP3 encoder ready." -ForegroundColor Green

# ── Helper: float32 stereo bytes → int16 bytes ────────────────────────────────
# TCI and WASAPI both deliver float32 internally; LAME expects int16 via WaveFormat.
# The conversion is per-sample, so doing it in a PowerShell loop is far too slow
# to keep pace with the ~48kHz capture (it backed the TX queue up into multi-second
# silence and stalled the loop). Compile a tiny C# helper once at startup so the
# tight loop runs in native .NET instead of interpreted PowerShell — ~100x faster.
if (-not ('ThetisAudio.FastConvert' -as [type])) {
    Add-Type -TypeDefinition @"
namespace ThetisAudio {
    public static class FastConvert {
        public static byte[] Float32ToInt16(byte[] floatBytes, int byteCount) {
            int sampleCount = byteCount / 4;
            byte[] outBytes = new byte[sampleCount * 2];
            for (int i = 0; i < sampleCount; i++) {
                float f = System.BitConverter.ToSingle(floatBytes, i * 4);
                if (f > 1.0f)  f = 1.0f;
                if (f < -1.0f) f = -1.0f;
                short s16 = (short)(f * 32767.0f);
                outBytes[i * 2]     = (byte)(s16 & 0xFF);
                outBytes[i * 2 + 1] = (byte)((s16 >> 8) & 0xFF);
            }
            return outBytes;
        }

        // RMS level of an int16 PCM buffer, returned in dBFS (0 = full scale,
        // negative = quieter; returns -120 for silence). Used by the live level
        // meter to compare RX vs TX loudness. Cheap: one pass, no allocation.
        public static double Int16RmsDbfs(byte[] pcmBytes, int byteCount) {
            int n = byteCount / 2;
            if (n <= 0) return -120.0;
            double sumSq = 0.0;
            for (int i = 0; i < n; i++) {
                short s = (short)(pcmBytes[i * 2] | (pcmBytes[i * 2 + 1] << 8));
                double v = s / 32768.0;
                sumSq += v * v;
            }
            double rms = System.Math.Sqrt(sumSq / n);
            if (rms < 0.0000001) return -120.0;
            double db = 20.0 * System.Math.Log10(rms);
            if (db < -120.0) db = -120.0;
            return db;
        }

        // Downmixes interleaved 2-channel int16 PCM to mono by averaging L+R
        // per frame. Used when a capture device (e.g. Voicemeeter B1) always
        // reports 2 channels natively, but the recording as a whole is being
        // forced to mono — this collapses the duplicated/near-duplicated
        // stereo pair down to a single real channel before it reaches the
        // Leveler/Compressor/Limiter (which are configured for 1 channel).
        public static byte[] DownmixStereoInt16ToMono(byte[] pcmBytes, int byteCount) {
            int frameCount = (byteCount / 2) / 2;   // 2 bytes/sample, 2 channels/frame
            byte[] outBytes = new byte[frameCount * 2];
            for (int f = 0; f < frameCount; f++) {
                int li = f * 4;
                int ri = f * 4 + 2;
                short l = (short)(pcmBytes[li] | (pcmBytes[li + 1] << 8));
                short r = (short)(pcmBytes[ri] | (pcmBytes[ri + 1] << 8));
                int avg = (l + r) / 2;
                if (avg > 32767)  avg = 32767;
                if (avg < -32768) avg = -32768;
                short outS = (short)avg;
                int oi = f * 2;
                outBytes[oi]     = (byte)(outS & 0xFF);
                outBytes[oi + 1] = (byte)((outS >> 8) & 0xFF);
            }
            return outBytes;
        }
    }

    // Short linear fade-in, armed on demand (Trigger()) and consumed sample by
    // sample across subsequent Process() calls. Used at RX<->TX switches: the
    // very first moment of audio after a switch can start at full loudness
    // instantly, before the Leveler/Compressor have had any time to react —
    // this ramp prevents that instantaneous edge from ever reaching them, so
    // the Limiter isn't left to absorb the whole transient alone. One instance
    // per source (RX, TX), independent state.
    public class FadeRamp {
        private readonly int _channels;
        private readonly int _fadeSamples;
        private int _remaining;   // frames left in the current fade; 0 = inactive

        public FadeRamp(double fadeMs, int sampleRate, int channels) {
            _channels    = channels;
            _fadeSamples = System.Math.Max(1, (int)(sampleRate * (fadeMs / 1000.0)));
            _remaining   = 0;
        }

        // Arms a fresh fade-in, to be applied starting with the next audio
        // this instance processes. Call this at the moment a switch occurs.
        public void Trigger() {
            _remaining = _fadeSamples;
        }

        public byte[] Process(byte[] pcmBytes, int byteCount) {
            if (_remaining <= 0) return pcmBytes;   // fast path — no fade active, no copy

            int frameCount = (byteCount / 2) / _channels;
            byte[] outBytes = new byte[byteCount];

            for (int f = 0; f < frameCount; f++) {
                double gain = 1.0;
                if (_remaining > 0) {
                    int elapsed = _fadeSamples - _remaining;
                    gain = (double)elapsed / _fadeSamples;
                    if (gain < 0.0) gain = 0.0;
                    if (gain > 1.0) gain = 1.0;
                    _remaining--;
                }
                for (int c = 0; c < _channels; c++) {
                    int idx = (f * _channels + c) * 2;
                    short s = (short)(pcmBytes[idx] | (pcmBytes[idx + 1] << 8));
                    double outSample = s * gain;
                    if (outSample > 32767.0)  outSample = 32767.0;
                    if (outSample < -32768.0) outSample = -32768.0;
                    short outS = (short)outSample;
                    outBytes[idx]     = (byte)(outS & 0xFF);
                    outBytes[idx + 1] = (byte)((outS >> 8) & 0xFF);
                }
            }
            return outBytes;
        }
    }

    // Feed-forward soft-knee compressor with true lookahead, operating directly
    // on interleaved int16 PCM. One instance = one independent envelope/gain
    // history — create a separate instance per audio source (RX, TX) so leveling
    // one stream never reacts to the other stream's transients.
    //
    // Lookahead is implemented as an internal delay line: the gain for "now" is
    // computed from the incoming (not-yet-delayed) sample, but the sample that
    // actually gets written out is the one from `lookaheadMs` ago — so the gain
    // reduction arrives just before the loud transient does, same as a hardware
    // lookahead compressor. This runs continuously across calls (state persists
    // between Process() calls), it does not reset per buffer.
    public class DynamicsCompressor {
        private readonly double _thresholdDb, _ratio, _kneeDb, _makeupDb;
        private readonly double _attackCoeff, _releaseCoeff;
        private readonly int _channels, _lookaheadFrames;
        private readonly short[] _delayBuffer;
        private int _delayPos;
        private int _delayFilled;
        private double _envelopeDb;   // current smoothed gain reduction, 0 = none

        public DynamicsCompressor(double thresholdDb, double ratio, double attackMs,
                                   double releaseMs, double makeupDb, double kneeDb,
                                   double lookaheadMs, int sampleRate, int channels) {
            _thresholdDb = thresholdDb;
            _ratio       = ratio;
            _kneeDb      = kneeDb;
            _makeupDb    = makeupDb;
            _channels    = channels;

            _attackCoeff  = System.Math.Exp(-1.0 / (sampleRate * (attackMs  / 1000.0)));
            _releaseCoeff = System.Math.Exp(-1.0 / (sampleRate * (releaseMs / 1000.0)));

            _lookaheadFrames = (int)(sampleRate * (lookaheadMs / 1000.0));
            if (_lookaheadFrames < 1) _lookaheadFrames = 1;
            _delayBuffer = new short[_lookaheadFrames * _channels];
            _delayPos    = 0;
            _delayFilled = 0;
            _envelopeDb  = 0.0;
        }

        // Static soft-knee gain-reduction curve (returns dB, <= 0). Standard
        // quadratic-knee formula: flat below knee, quadratic through the knee,
        // linear (1/ratio slope) above it.
        private double GainReductionDb(double levelDb) {
            double over = levelDb - _thresholdDb;
            if (_kneeDb <= 0.0001) {
                return over > 0 ? over * (1.0 / _ratio - 1.0) : 0.0;
            }
            double half = _kneeDb / 2.0;
            if (over <= -half) return 0.0;
            if (over >= half)  return over * (1.0 / _ratio - 1.0);
            double x = over + half;
            return (1.0 / _ratio - 1.0) * (x * x) / (2.0 * _kneeDb);
        }

        // Processes interleaved int16 PCM in place-equivalent fashion (returns a
        // new same-length byte array). Call once per captured buffer, in order,
        // for a given source — do not share one instance between RX and TX.
        public byte[] Process(byte[] pcmBytes, int byteCount) {
            int frameCount = (byteCount / 2) / _channels;
            byte[] outBytes = new byte[byteCount];
            short[] cur = new short[_channels];

            for (int f = 0; f < frameCount; f++) {
                double peak = 0.0;
                for (int c = 0; c < _channels; c++) {
                    int idx = (f * _channels + c) * 2;
                    short s = (short)(pcmBytes[idx] | (pcmBytes[idx + 1] << 8));
                    cur[c] = s;
                    double v = System.Math.Abs(s / 32768.0);
                    if (v > peak) peak = v;
                }

                double levelDb  = peak > 0.0000001 ? 20.0 * System.Math.Log10(peak) : -120.0;
                double targetDb = GainReductionDb(levelDb);

                // Attack when more reduction is needed (envelope going down),
                // release when reduction is easing off (envelope going up).
                if (targetDb < _envelopeDb)
                    _envelopeDb = _attackCoeff * _envelopeDb + (1.0 - _attackCoeff) * targetDb;
                else
                    _envelopeDb = _releaseCoeff * _envelopeDb + (1.0 - _releaseCoeff) * targetDb;

                double gainLinear = System.Math.Pow(10.0, (_envelopeDb + _makeupDb) / 20.0);

                // Write current (undelayed) frame into the ring buffer, read back
                // the frame from `lookaheadFrames` ago to emit now.
                short[] delayed = new short[_channels];
                for (int c = 0; c < _channels; c++) {
                    int bufIdx = _delayPos * _channels + c;
                    delayed[c] = _delayFilled >= _lookaheadFrames ? _delayBuffer[bufIdx] : (short)0;
                    _delayBuffer[bufIdx] = cur[c];
                }
                _delayPos = (_delayPos + 1) % _lookaheadFrames;
                if (_delayFilled < _lookaheadFrames) _delayFilled++;

                for (int c = 0; c < _channels; c++) {
                    double outSample = delayed[c] * gainLinear;
                    if (outSample > 32767.0)  outSample = 32767.0;
                    if (outSample < -32768.0) outSample = -32768.0;
                    short outS = (short)outSample;
                    int idx = (f * _channels + c) * 2;
                    outBytes[idx]     = (byte)(outS & 0xFF);
                    outBytes[idx + 1] = (byte)((outS >> 8) & 0xFF);
                }
            }
            return outBytes;
        }
    }

    // Slow AGC / leveler: tracks long-term average (RMS) loudness over a
    // multi-second window and gently nudges gain toward a target, at a capped
    // dB/sec rate so it never audibly "pumps." This is what corrects a
    // persistent, static loudness offset between two sources (e.g. TX
    // consistently hotter than RX) — something a fast compressor alone won't
    // fully fix, since a static offset that never crosses the compressor's
    // threshold just passes straight through unchanged.
    //
    // Intended to run BEFORE the DynamicsCompressor in the chain: Leveler
    // evens out the average, Compressor catches whatever peaks remain.
    public class Leveler {
        private readonly double _targetDb, _maxGainDb, _minGainDb, _maxStepDbPerFrame;
        private readonly double _windowCoeff, _noiseHoldDb;
        private readonly int _channels;
        private double _emaMeanSq;
        private double _currentGainDb;

        public Leveler(double targetDb, double windowSeconds, double maxAdjustDbPerSec,
                        double maxGainDb, double minGainDb, double noiseHoldDb,
                        int sampleRate, int channels) {
            _targetDb          = targetDb;
            _maxGainDb         = maxGainDb;
            _minGainDb         = minGainDb;
            _noiseHoldDb       = noiseHoldDb;
            _channels          = channels;
            _windowCoeff       = System.Math.Exp(-1.0 / (sampleRate * windowSeconds));
            _maxStepDbPerFrame = maxAdjustDbPerSec / sampleRate;
            // Seed the running average at the target so it doesn't slam gain
            // at startup before it has real data to react to.
            _emaMeanSq    = System.Math.Pow(10.0, targetDb / 10.0);
            _currentGainDb = 0.0;
        }

        // Processes interleaved int16 PCM, returns a same-length byte array.
        // Call once per captured buffer, in order, for a given source — do not
        // share one instance between RX and TX.
        public byte[] Process(byte[] pcmBytes, int byteCount) {
            int frameCount = (byteCount / 2) / _channels;
            byte[] outBytes = new byte[byteCount];
            short[] cur = new short[_channels];

            for (int f = 0; f < frameCount; f++) {
                double sumSq = 0.0;
                for (int c = 0; c < _channels; c++) {
                    int idx = (f * _channels + c) * 2;
                    short s = (short)(pcmBytes[idx] | (pcmBytes[idx + 1] << 8));
                    cur[c] = s;
                    double v = s / 32768.0;
                    sumSq += v * v;
                }
                double meanSqFrame = sumSq / _channels;
                _emaMeanSq = _windowCoeff * _emaMeanSq + (1.0 - _windowCoeff) * meanSqFrame;

                double rmsDb = _emaMeanSq > 0.0000000001 ? 10.0 * System.Math.Log10(_emaMeanSq) : -120.0;

                // Near-silence: hold gain steady rather than chasing the noise
                // floor up to the target (which would just amplify hiss/hum
                // during gaps between transmissions or dead air). Threshold is
                // configurable ($LevelerNoiseHoldDb) — it must sit above the
                // real RX noise floor or this check never engages during
                // ordinary gaps between words, only during true dead air.
                double error = (rmsDb < _noiseHoldDb) ? 0.0 : (_targetDb - rmsDb);

                // desiredGainDb is the error itself (target - rawLevel), NOT
                // currentGainDb + error. The old "currentGainDb + error" form
                // has no stable equilibrium: if the output ever did sit right
                // at target (rawLevel + currentGainDb == target), error would
                // equal currentGainDb, making desiredGainDb = 2*currentGainDb
                // — always demanding double whatever gain it already has,
                // every single frame. Combined with the max-gain clamp, that
                // meant it never actually converged on the correct corrective
                // gain; it just raced to whichever ceiling was reachable and
                // pinned there. Using the error directly gives a real fixed
                // point: at rawLevel + gain == target, error == gain, so
                // desiredGainDb == currentGainDb and the loop actually holds
                // steady there instead of overshooting to the ceiling.
                double desiredGainDb = error;
                if (desiredGainDb > _maxGainDb) desiredGainDb = _maxGainDb;
                if (desiredGainDb < _minGainDb) desiredGainDb = _minGainDb;

                double step = desiredGainDb - _currentGainDb;
                if (step > _maxStepDbPerFrame)  step = _maxStepDbPerFrame;
                if (step < -_maxStepDbPerFrame) step = -_maxStepDbPerFrame;
                _currentGainDb += step;

                double gainLinear = System.Math.Pow(10.0, _currentGainDb / 20.0);

                for (int c = 0; c < _channels; c++) {
                    double outSample = cur[c] * gainLinear;
                    if (outSample > 32767.0)  outSample = 32767.0;
                    if (outSample < -32768.0) outSample = -32768.0;
                    short outS = (short)outSample;
                    int idx = (f * _channels + c) * 2;
                    outBytes[idx]     = (byte)(outS & 0xFF);
                    outBytes[idx + 1] = (byte)((outS >> 8) & 0xFF);
                }
            }
            return outBytes;
        }
    }

    // Brick-wall lookahead limiter — the last-line-of-defense stage. Unlike the
    // Compressor (which shapes dynamics with a moderate ratio and can still let
    // a peak through above threshold), this guarantees output never exceeds
    // the ceiling: gain is computed as ceiling/peak whenever peak exceeds it,
    // applied with a short lookahead so the reduction lands before the peak
    // does, and released slowly afterward so it doesn't audibly pump.
    public class Limiter {
        private readonly double _ceilingLinear;
        private readonly double _releaseCoeff;
        private readonly int _channels, _lookaheadFrames;
        private readonly short[] _delayBuffer;
        private int _delayPos;
        private int _delayFilled;
        private double _gainLinear;   // current applied linear gain, <= 1.0

        public Limiter(double ceilingDb, double releaseMs, double lookaheadMs,
                        int sampleRate, int channels) {
            _ceilingLinear = System.Math.Pow(10.0, ceilingDb / 20.0);
            _releaseCoeff  = System.Math.Exp(-1.0 / (sampleRate * (releaseMs / 1000.0)));
            _channels      = channels;

            _lookaheadFrames = (int)(sampleRate * (lookaheadMs / 1000.0));
            if (_lookaheadFrames < 1) _lookaheadFrames = 1;
            _delayBuffer = new short[_lookaheadFrames * _channels];
            _delayPos    = 0;
            _delayFilled = 0;
            _gainLinear  = 1.0;
        }

        // Processes interleaved int16 PCM, returns a same-length byte array.
        // Call once per captured buffer, in order, for a given source — do not
        // share one instance between RX and TX.
        public byte[] Process(byte[] pcmBytes, int byteCount) {
            int frameCount = (byteCount / 2) / _channels;
            byte[] outBytes = new byte[byteCount];
            short[] cur = new short[_channels];

            for (int f = 0; f < frameCount; f++) {
                double peak = 0.0;
                for (int c = 0; c < _channels; c++) {
                    int idx = (f * _channels + c) * 2;
                    short s = (short)(pcmBytes[idx] | (pcmBytes[idx + 1] << 8));
                    cur[c] = s;
                    double v = System.Math.Abs(s / 32768.0);
                    if (v > peak) peak = v;
                }

                double desiredGain = (peak > 0.0000001)
                    ? System.Math.Min(1.0, _ceilingLinear / peak)
                    : 1.0;

                // Instant attack (lookahead means we already know the peak is
                // coming before it reaches the output), slow release afterward.
                if (desiredGain < _gainLinear)
                    _gainLinear = desiredGain;
                else
                    _gainLinear = _releaseCoeff * _gainLinear + (1.0 - _releaseCoeff) * desiredGain;

                short[] delayed = new short[_channels];
                for (int c = 0; c < _channels; c++) {
                    int bufIdx = _delayPos * _channels + c;
                    delayed[c] = _delayFilled >= _lookaheadFrames ? _delayBuffer[bufIdx] : (short)0;
                    _delayBuffer[bufIdx] = cur[c];
                }
                _delayPos = (_delayPos + 1) % _lookaheadFrames;
                if (_delayFilled < _lookaheadFrames) _delayFilled++;

                for (int c = 0; c < _channels; c++) {
                    double outSample = delayed[c] * _gainLinear;
                    if (outSample > 32767.0)  outSample = 32767.0;
                    if (outSample < -32768.0) outSample = -32768.0;
                    short outS = (short)outSample;
                    int idx = (f * _channels + c) * 2;
                    outBytes[idx]     = (byte)(outS & 0xFF);
                    outBytes[idx + 1] = (byte)((outS >> 8) & 0xFF);
                }
            }
            return outBytes;
        }
    }
}
"@
}

function Convert-Float32ToInt16Bytes {
    param([byte[]]$FloatBytes, [int]$ByteCount)
    return [ThetisAudio.FastConvert]::Float32ToInt16($FloatBytes, $ByteCount)
}

# ── Fade Ramps (RX / TX independent instances) ────────────────────────────────
# Armed (Trigger()) from Switch-Source at every RX<->TX toggle; consumed here.
$script:rxFade = [ThetisAudio.FadeRamp]::new($FadeInMs, $SampleRate, $Channels)
$script:txFade = [ThetisAudio.FadeRamp]::new($FadeInMs, $SampleRate, $Channels)
Write-Host "[Fade-In] ${FadeInMs}ms ramp armed at every RX<->TX switch." -ForegroundColor Cyan

# ── Levelers (RX / TX independent instances) ──────────────────────────────────
# Runs before the compressor — see class comment for why. Independent
# instances per source, same reasoning as the compressors above.
if ($LevelerEnabled) {
    $script:rxLeveler = [ThetisAudio.Leveler]::new(
        $LevelerTargetDb, $LevelerWindowSeconds, $LevelerMaxAdjustDbPerSec,
        $RxLevelerMaxGainDb, $LevelerMinGainDb, $LevelerNoiseHoldDb, $SampleRate, $Channels)
    $script:txLeveler = [ThetisAudio.Leveler]::new(
        $LevelerTargetDb, $LevelerWindowSeconds, $LevelerMaxAdjustDbPerSec,
        $TxLevelerMaxGainDb, $LevelerMinGainDb, $LevelerNoiseHoldDb, $SampleRate, $Channels)
    Write-Host "[Leveler] Enabled — Target ${LevelerTargetDb}dB, Window ${LevelerWindowSeconds}s, Rate ${LevelerMaxAdjustDbPerSec}dB/s, RX gain range ${LevelerMinGainDb}..${RxLevelerMaxGainDb}dB, TX gain range ${LevelerMinGainDb}..${TxLevelerMaxGainDb}dB, NoiseHold ${LevelerNoiseHoldDb}dB" -ForegroundColor Cyan
} else {
    Write-Host "[Leveler] Disabled." -ForegroundColor DarkYellow
}

# ── Limiters (RX / TX independent instances) ──────────────────────────────────
# Runs last in the chain, after the Compressor — see class comment for why.
if ($LimiterEnabled) {
    $script:rxLimiter = [ThetisAudio.Limiter]::new(
        $LimiterCeilingDb, $LimiterReleaseMs, $LimiterLookaheadMs, $SampleRate, $Channels)
    $script:txLimiter = [ThetisAudio.Limiter]::new(
        $LimiterCeilingDb, $LimiterReleaseMs, $LimiterLookaheadMs, $SampleRate, $Channels)
    Write-Host "[Limiter] Enabled — Ceiling ${LimiterCeilingDb}dB, Release ${LimiterReleaseMs}ms, Lookahead ${LimiterLookaheadMs}ms" -ForegroundColor Cyan
} else {
    Write-Host "[Limiter] Disabled." -ForegroundColor DarkYellow
}

# ── Dynamics Compressors (RX / TX independent instances) ─────────────────────
# Same settings on both, but separate envelope/lookahead state so leveling one
# stream never reacts to the other stream's transients. Applied right before
# each stream is written to the MP3 encoder.
if ($CompressorEnabled) {
    $script:rxComp = [ThetisAudio.DynamicsCompressor]::new(
        $CompThresholdDb, $CompRatio, $CompAttackMs, $CompReleaseMs,
        $CompMakeupGainDb, $CompKneeWidthDb, $CompLookaheadMs, $SampleRate, $Channels)
    $script:txComp = [ThetisAudio.DynamicsCompressor]::new(
        $CompThresholdDb, $CompRatio, $CompAttackMs, $CompReleaseMs,
        $CompMakeupGainDb, $CompKneeWidthDb, $CompLookaheadMs, $SampleRate, $Channels)
    Write-Host "[Compressor] Enabled — Threshold ${CompThresholdDb}dB, Ratio ${CompRatio}:1, Attack ${CompAttackMs}ms, Release ${CompReleaseMs}ms, Makeup ${CompMakeupGainDb}dB, Knee ${CompKneeWidthDb}dB, Lookahead ${CompLookaheadMs}ms" -ForegroundColor Cyan
} else {
    Write-Host "[Compressor] Disabled — recording raw levels." -ForegroundColor DarkYellow
}

# ── Source Switch ─────────────────────────────────────────────────────────────
function Switch-Source {
    param([int]$NewMox)
    if ($NewMox -eq $script:currentMox) { return }

    $now   = Get-Date -Format "HH:mm:ss"
    $label = if ($NewMox -eq 1) { "TX ►" } else { "◄ RX" }
    $color = if ($NewMox -eq 1) { "Red" } else { "Green" }
    Write-Log "[$now]  $label" -Color $color

    [System.Threading.Monitor]::Enter($script:writeLock)
    try {
        # In wasapi mode, insert a short silence gap at the switch to avoid a LAME
        # encoder state artifact between the two source streams. In tci mode the
        # stream is continuous (same source), so no gap is needed.
        if ($TxAudioSource -eq "wasapi") {
            $script:mp3Writer.Write($silenceInt16Bytes, 0, $silenceInt16Bytes.Length)
        }
        $script:activeSource = $NewMox
    } finally {
        [System.Threading.Monitor]::Exit($script:writeLock)
    }
    $script:currentMox = $NewMox

    # Arm a short fade-in on whichever source is about to become active, so
    # the first instant of audio after this switch doesn't hit the Leveler/
    # Compressor/Limiter as a hard, instantaneous edge.
    if ($NewMox -eq 1) { $script:txFade.Trigger() } else { $script:rxFade.Trigger() }

    # Update tray icon color (green=RX, red=TX)
    Update-TrayIcon -Mox $NewMox -Tooltip $null
}

# ── WASAPI TX Capture (Voicemeeter B1 — recording input device) ───────────────
# NOTE: $script:txCapture itself is NOT reset here — it was already created
# during device detection (above) so its native format could be read for the
# mono/stereo auto-detect before the MP3 writer's format was fixed. Resetting
# it to $null here would wipe that out and break Register-ObjectEvent below.
$script:txQueue         = $null
$script:txEventSub      = $null
$script:txCallbackCount = 0
$script:txWriteCount    = 0
$script:txLastError     = ""

# ── Live level meter (for comparing RX vs TX loudness) ────────────────────────
# Smoothed RMS level in dBFS for each source, updated as audio is written and
# shown in the tray tooltip. Read-only measurement — does NOT change the audio.
$script:rxLevelDb = -120.0
$script:txLevelDb = -120.0
$script:LevelSmoothing = 0.2   # 0..1; higher = snappier, lower = smoother

if ($TxAudioSource -eq "wasapi") {
    Write-Host ""
    Write-Host "[TX] Starting WASAPI capture on B1 input..." -ForegroundColor Cyan

    # $script:txCapture, $script:txIsFloat, $script:txBits were already set up
    # earlier (right after device detection) so the mono/stereo auto-detect
    # could run before the MP3 writer's format was fixed. Just wire up the
    # event queue and start capturing here.
    #
    # PowerShell does not pump NAudio's DataAvailable event via add_DataAvailable
    # (no synchronization context), so the callback never fires. Instead we use
    # Register-ObjectEvent, which enqueues the event into PowerShell's own event
    # queue. The action runs in its own scope, so it cannot touch our $script:
    # state or the LAME writer directly — it just copies the captured bytes into
    # a thread-safe queue. The MAIN LOOP drains that queue and writes the MP3,
    # keeping all encoding on the one thread we know works.
    $script:txQueue = [System.Collections.Concurrent.ConcurrentQueue[byte[]]]::new()

    $txAction = {
        $ea = $Event.SourceEventArgs
        $n  = $ea.BytesRecorded
        if ($n -gt 0) {
            $copy = New-Object byte[] $n
            [System.Array]::Copy($ea.Buffer, 0, $copy, 0, $n)
            $Event.MessageData.Enqueue($copy)
        }
    }

    $script:txEventSub = Register-ObjectEvent -InputObject $script:txCapture `
        -EventName DataAvailable -Action $txAction -MessageData $script:txQueue

    try {
        $script:txCapture.StartRecording()
    } catch {
        Write-Host ""
        Write-Host "[FATAL] Could not start TX capture: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        Check Windows Settings -> Privacy & security -> Microphone -> 'Let desktop apps access your microphone'," -ForegroundColor Yellow
        Write-Host "        and make sure no other app has this device open exclusively." -ForegroundColor Yellow
        Write-Log "TX capture StartRecording failed: $($_.Exception.Message)" -Color Red
        exit 1
    }
    Write-Host "[TX] WASAPI capture running (event-queued)." -ForegroundColor Green
}

# Drain the TX capture queue and write any TX audio to the MP3. Called from the
# main loop. Runs on the main thread, so MP3 writes stay single-threaded.
function Drain-TxQueue {
    if ($TxAudioSource -ne "wasapi" -or -not $script:txQueue) { return }
    $bytes = $null
    $localRef = ([ref]$bytes)
    # Cap items per call so a continuous TX stream can't trap the loop. With the
    # fast compiled conversion, each item is cheap, so 100/call at ~50 loop
    # iterations/sec gives ~5000 buffers/sec drain capacity — far above the
    # ~75-90/sec capture rate — keeping the queue near empty while each call stays
    # short enough never to stall MOX/unkey handling.
    $maxPerCall = 100
    $processed  = 0
    while ($processed -lt $maxPerCall -and $script:txQueue.TryDequeue($localRef)) {
        $processed++
        $script:txCallbackCount++
        # Only write captured TX audio while actually transmitting
        if (-not $script:isRecording -or $script:activeSource -ne 1) { continue }
        $buf = $localRef.Value
        if (-not $buf -or $buf.Length -eq 0) { continue }
        try {
            if ($script:txIsFloat) {
                $int16Bytes = Convert-Float32ToInt16Bytes -FloatBytes $buf -ByteCount $buf.Length
            } elseif ($script:txBits -eq 16) {
                $int16Bytes = $buf
            } else {
                continue
            }
            # The TX device may still deliver 2ch natively even though the
            # recording as a whole is mono. Downmix here so the
            # Leveler/Compressor/Limiter — all configured for $Channels —
            # receive the right frame layout.
            if ($Channels -eq 1 -and $script:txNativeChannels -eq 2) {
                $int16Bytes = [ThetisAudio.FastConvert]::DownmixStereoInt16ToMono($int16Bytes, $int16Bytes.Length)
            }
            $int16Bytes = $script:txFade.Process($int16Bytes, $int16Bytes.Length)
            if ($LevelerEnabled) {
                $int16Bytes = $script:txLeveler.Process($int16Bytes, $int16Bytes.Length)
            }
            if ($CompressorEnabled) {
                $int16Bytes = $script:txComp.Process($int16Bytes, $int16Bytes.Length)
            }
            if ($LimiterEnabled) {
                $int16Bytes = $script:txLimiter.Process($int16Bytes, $int16Bytes.Length)
            }
            [System.Threading.Monitor]::Enter($script:writeLock)
            try   { $script:mp3Writer.Write($int16Bytes, 0, $int16Bytes.Length) }
            finally { [System.Threading.Monitor]::Exit($script:writeLock) }
            $script:txWriteCount++
            # Update smoothed TX level meter (measurement only)
            $db = [ThetisAudio.FastConvert]::Int16RmsDbfs($int16Bytes, $int16Bytes.Length)
            $script:txLevelDb = ($script:LevelSmoothing * $db) + ((1 - $script:LevelSmoothing) * $script:txLevelDb)
        } catch {
            $script:txLastError = $_.Exception.Message
        }
    }
}

# ── TCI WebSocket Connection (with auto-discovery of bind address) ────────────
Write-Host ""
Write-Host "[TCI] Discovering TCI server address on port $TciPort..." -ForegroundColor Cyan

# Build an ordered list of candidate hosts to try.
# Thetis may bind TCI to loopback OR to a specific NIC IP. We probe each.
function Get-TciCandidateHosts {
    $candidates = [System.Collections.Generic.List[string]]::new()

    # 1. The configured host first (if user set one explicitly)
    if ($TciHost -and $TciHost -ne "auto") { $candidates.Add($TciHost) }

    # 2. Loopback
    $candidates.Add("127.0.0.1")

    # 3. Any local IPv4 that currently has a listener on $TciPort
    #    Get-NetTCPConnection shows what Thetis is actually bound to.
    try {
        $listening = Get-NetTCPConnection -State Listen -LocalPort $TciPort -ErrorAction SilentlyContinue
        foreach ($conn in $listening) {
            $addr = $conn.LocalAddress
            # 0.0.0.0 means "all interfaces" — loopback already covers it
            if ($addr -and $addr -ne "0.0.0.0" -and $addr -ne "::") {
                $candidates.Add($addr)
            }
        }
    } catch {}

    # 4. All active local IPv4 addresses as a fallback
    try {
        $localIPs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike "169.254.*" } |
                    Select-Object -ExpandProperty IPAddress
        foreach ($ip in $localIPs) { $candidates.Add($ip) }
    } catch {}

    # De-duplicate while preserving order
    $seen = @{}
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $candidates) {
        if (-not $seen.ContainsKey($c)) { $seen[$c] = $true; $ordered.Add($c) }
    }
    return $ordered
}

function Test-TciPort {
    param([string]$IPHost, [int]$Port, [int]$TimeoutMs = 600)
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar    = $client.BeginConnect($IPHost, $Port, $null, $null)
        $ok     = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) {
            $client.EndConnect($iar)
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Connect-Tci {
    $candidates = Get-TciCandidateHosts
    foreach ($candidate in $candidates) {
        if (-not (Test-TciPort -IPHost $candidate -Port $TciPort)) {
            Write-Host "  $candidate`:$TciPort — no listener" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  $candidate`:$TciPort — trying WebSocket..." -ForegroundColor Yellow
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        # Thetis TCI expects the "tci" subprotocol. The working version negotiated it;
        # without it Thetis streams audio but appears not to push trx/MOX state changes.
        $ws.Options.AddSubProtocol("tci")
        $uri = [System.Uri]::new("ws://${candidate}:${TciPort}")
        try {
            $ct = [System.Threading.CancellationTokenSource]::new(2000)  # 2s timeout
            $ws.ConnectAsync($uri, $ct.Token).GetAwaiter().GetResult()
            $script:tciWs      = $ws
            $script:connectedTo = $candidate
            $script:recvTask   = $null
            $script:tciReady   = $false
            return $true
        } catch {
            try { $ws.Dispose() } catch {}
        }
    }
    return $false
}

$script:tciWs        = $null
$script:connectedTo  = $null

if (-not (Connect-Tci)) {
    Write-Error @"
[TCI] Could not connect to a TCI server on port $TciPort at any local address.

Checked: $((Get-TciCandidateHosts) -join ', ')

Ensure in Thetis: Setup → Serial/Network/Midi CAT → Network
  • 'TCI Server Running' is checked
  • Note the Bind IP:Port shown there

If it works, you can hardcode that address by setting `$TciHost` at the top of this script.
"@
    exit 1
}
$tciWs       = $script:tciWs
$connectedTo = $script:connectedTo

# Update host var so the rest of the script (reconnect logic etc.) uses the right one
$TciHost = $connectedTo
Write-Log "[TCI] Connected to ws://${connectedTo}:${TciPort}" -Color Green
Write-Log "[TCI] Session log: $script:SessionLog" -Color DarkGray

# Reconnect state — used by the main loop if the socket drops mid-session
# (network blip, Thetis restart, radio USB hiccup). Backoff: 3s, 6s, 12s,
# 24s, 48s, capped at 60s; resets to the base delay as soon as a reconnect
# succeeds. TX audio (WASAPI) and MOX detection (CAT) run on independent
# threads, so recording continues uninterrupted on those sides the whole
# time RX is trying to reconnect — only the RX audio has a gap.
$script:tciReconnectBaseMs = 3000
$script:tciReconnectMaxMs  = 60000
$script:tciReconnectIntervalMs = $script:tciReconnectBaseMs
$script:lastTciReconnectAttempt = [DateTime]::MinValue

# ── TCI Helpers ───────────────────────────────────────────────────────────────
function Send-TciText {
    param([string]$Msg)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Msg)
    $seg   = [System.ArraySegment[byte]]::new($bytes)
    $tciWs.SendAsync($seg,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

# ── CAT MOX detection (port 13013) ────────────────────────────────────────────
# MOX is detected by polling the CAT TCP server with "ZZTX;" on a dedicated
# thread (see below). This works for ALL keying methods (hardware PTT, on-screen
# MOX, CAT), unlike TCI's trx push which this Thetis build does not emit on
# hardware PTT. The proven-working poll logic lives in the poll-thread script.

# ── CAT MOX poll on a DEDICATED THREAD ────────────────────────────────────────
# The standalone test proved ZZTX polling tracks key AND unkey perfectly. The
# only failure was the TCI receive on the main loop wedging on TX and starving
# the poll. Fix: run the poll on its own thread with its OWN socket, completely
# independent of TCI. It pushes detected MOX values into a thread-safe queue;
# the main loop drains the queue and calls Switch-Source (same proven pattern as
# the WASAPI TX capture). Nothing TCI does can block this.
$script:moxQueue = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
$script:catCtl   = [hashtable]::Synchronized(@{ Run = $true; PollCount = 0; LastRaw = -99; LastErr = "" })

if ($CatMoxEnabled) {
    $catRunspace = [runspacefactory]::CreateRunspace()
    $catRunspace.Open()
    $catRunspace.SessionStateProxy.SetVariable('moxQueue',     $script:moxQueue)
    $catRunspace.SessionStateProxy.SetVariable('CatHost',      $CatHost)
    $catRunspace.SessionStateProxy.SetVariable('CatPort',      $CatPort)
    $catRunspace.SessionStateProxy.SetVariable('CatPollMs',    $CatPollMs)
    $catRunspace.SessionStateProxy.SetVariable('catCtl',       $script:catCtl)

    $catPS = [powershell]::Create()
    $catPS.Runspace = $catRunspace
    [void]$catPS.AddScript({
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect($CatHost, $CatPort)
            $client.ReceiveTimeout = 300
            $client.SendTimeout    = 300
            $stream = $client.GetStream()
        } catch {
            $moxQueue.Enqueue(-2)   # -2 = connect failed
            return
        }
        $moxQueue.Enqueue(-3)       # -3 = connected OK (signal for main thread log)

        $last = -99
        $pollCount = 0
        while ($catCtl.Run) {
            try {
                while ($stream.DataAvailable) {
                    $junk = New-Object byte[] 256
                    [void]$stream.Read($junk, 0, 256)
                }
                $q = [System.Text.Encoding]::ASCII.GetBytes("ZZTX;")
                $stream.Write($q, 0, $q.Length); $stream.Flush()

                $resp = ""
                $deadline = [Environment]::TickCount64 + 150
                while ([Environment]::TickCount64 -lt $deadline) {
                    if ($stream.DataAvailable) {
                        $buf = New-Object byte[] 64
                        $n = $stream.Read($buf, 0, 64)
                        if ($n -gt 0) {
                            $resp += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                            if ($resp.Contains(";")) { break }
                        }
                    } else { Start-Sleep -Milliseconds 5 }
                }

                $pollCount++
                $catCtl.PollCount = $pollCount          # liveness counter (read by DIAG)
                if (-not [string]::IsNullOrEmpty($resp)) {
                    $m = [regex]::Matches($resp, "ZZTX([01])")
                    if ($m.Count -gt 0) {
                        $mox = [int]$m[$m.Count-1].Groups[1].Value
                        $catCtl.LastRaw = $mox          # last raw value (read by DIAG)
                        if ($mox -ne $last) {
                            $moxQueue.Enqueue($mox)   # 0 or 1
                            $last = $mox
                        }
                    } else {
                        $catCtl.LastRaw = -1
                    }
                } else {
                    $catCtl.LastRaw = -9                # -9 = no reply this poll
                }
            } catch {
                $catCtl.LastErr = "$_"
            }
            Start-Sleep -Milliseconds $CatPollMs
        }
        try { $stream.Close() } catch {}
        try { $client.Close() } catch {}
    })
    $script:catHandle = $catPS.BeginInvoke()
    $script:catPSRef  = $catPS
    Write-Log "[CAT] MOX poll thread started (ZZTX on ${CatHost}:${CatPort})" -Color Green
}

# ── Main Receive Loop (single-threaded — no cross-runspace scoping issues) ────
# ReceiveAsync blocks until data arrives or the per-call timeout elapses, so the
# status ticker can run in the same loop. MOX events and audio frames are both
# handled here as they arrive — near-instant, no polling.
$script:tciRunning = $true
$sw    = [System.Diagnostics.Stopwatch]::StartNew()
$swTip = [System.Diagnostics.Stopwatch]::StartNew()
$swDiag = [System.Diagnostics.Stopwatch]::StartNew()
$script:textCount = 0
$script:binCount  = 0

# Reusable receive buffer (64KB — large enough for audio frames)
$recvBuffer = New-Object byte[] 65536
$script:recvTask = $null   # single outstanding ReceiveAsync task (never abandoned)

try {
    while ($script:isRecording) {

        # Process tray icon clicks/menu events
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:trayStopRequested) {
            Write-Host "[Recorder] Stop requested from tray icon." -ForegroundColor Yellow
            break
        }

        # ── TCI reconnect (if the socket dropped) ─────────────────────────────
        # TX audio (WASAPI) and MOX detection (CAT) run on independent threads
        # and keep working the whole time RX is down, so a TCI drop no longer
        # ends the recording — just the RX side has a gap until this reconnects.
        # Backoff: 3s, 6s, 12s, 24s, 48s, capped at 60s; resets once reconnected.
        if (-not $script:tciWs -or $script:tciWs.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            if (((Get-Date) - $script:lastTciReconnectAttempt).TotalMilliseconds -ge $script:tciReconnectIntervalMs) {
                $script:lastTciReconnectAttempt = Get-Date
                Write-Log ("[TCI] Attempting reconnect (next retry in {0}s if this fails)..." -f [int]($script:tciReconnectIntervalMs/1000)) -Color Yellow
                if (Connect-Tci) {
                    $tciWs = $script:tciWs
                    Write-Log "[TCI] Reconnected to ws://${script:connectedTo}:${TciPort} — RX audio will resume once the handshake completes" -Color Green
                    $script:tciReconnectIntervalMs = $script:tciReconnectBaseMs
                } else {
                    $script:tciReconnectIntervalMs = [System.Math]::Min($script:tciReconnectIntervalMs * 2, $script:tciReconnectMaxMs)
                }
            }
        }

        # ── Drain MOX changes from the CAT poll thread ─────────────────────────
        if ($CatMoxEnabled) {
            $moxVal = 0
            while ($script:moxQueue.TryDequeue([ref]$moxVal)) {
                switch ($moxVal) {
                    -2 { Write-Log "[CAT] Poll thread could not connect — TX detection off, RX still records" -Color Yellow; $CatMoxEnabled = $false }
                    -3 { } # connected OK (already logged at startup)
                    default {
                        if ($moxVal -eq 0 -or $moxVal -eq 1) {
                            if ($moxVal -ne $script:currentMox) {
                                try {
                                    Switch-Source -NewMox $moxVal
                                } catch {
                                    Write-Log "[CAT] Switch-Source error: $_" -Color Yellow
                                }
                            }
                        }
                    }
                }
            }
        }

        # ── Non-blocking TCI receive ──────────────────────────────────────────
        # ClientWebSocket does NOT allow a new ReceiveAsync while a prior one is
        # still pending. A per-call cancellation token does NOT abort the socket
        # read — it only abandons our wait, leaving a pending op that wedges the
        # next call. That froze the whole loop on TX (RX stream stops → receive
        # never completes → loop stuck → CAT poll never runs → never sees unkey).
        # Fix: keep ONE outstanding receive task; only consume it when complete,
        # never abandon it. The loop stays responsive (CAT poll keeps running)
        # whether or not TCI data is flowing.
        $frame = $null
        if ($script:tciWs -and $script:tciWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try {
                # Start a receive if none is outstanding
                if ($null -eq $script:recvTask) {
                    $seg = [System.ArraySegment[byte]]::new($recvBuffer, 0, $recvBuffer.Length)
                    $script:recvTask = $tciWs.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
                }

                # Wait briefly for the receive to complete; if not, loop on. The loop
                # stays responsive (~50/sec) so the TX drain keeps the queue empty and
                # MOX changes are acted on promptly, without busy-spinning the CPU.
                if ($script:recvTask.Wait(20)) {
                    $result = $script:recvTask.GetAwaiter().GetResult()
                    $script:recvTask = $null   # consumed; next iteration starts a new one

                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        Write-Log "[TCI] Server closed the connection -- will attempt to reconnect." -Color Yellow
                        try { $script:tciWs.Dispose() } catch {}
                        $script:tciWs = $null
                        $script:recvTask = $null
                        $script:tciReady = $false
                    } else {
                        # Single-frame read (64KB buffer holds a full audio frame). If a
                        # message ever exceeds the buffer, EndOfMessage handles the tail
                        # on subsequent iterations; for TCI audio/text this is sufficient.
                        $frame = @{ Type = $result.MessageType; Count = $result.Count; Data = $recvBuffer }
                    }
                }
                # else: still pending — fall through, loop, poll CAT, try again
            } catch {
                if ($script:isRecording) { Write-Log "[TCI] Receive error: $_ -- will attempt to reconnect." -Color Yellow }
                try { if ($script:tciWs) { $script:tciWs.Dispose() } } catch {}
                $script:tciWs = $null
                $script:recvTask = $null
                $script:tciReady = $false
            }
        }

        if ($frame) {
            # ── Text frame: control messages ──────────────────────────────────
            if ($frame.Type -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                $script:textCount++
                $msg = [System.Text.Encoding]::UTF8.GetString($frame.Data, 0, $frame.Count)

                # Log raw traffic to file (skip the high-rate sensor/vfo spam)
                if ($msg -notmatch "^(rx_sensor|tx_sensor|vfo)") {
                    Write-Log "[TCI<] $msg" -NoConsole -Verbose
                }

                foreach ($cmd in ($msg -split ';' | Where-Object { $_.Trim() -ne '' })) {
                    $cmd = $cmd.Trim()

                    # Debug: show every command Thetis sends (except high-rate ones)
                    if ($TciDebug -and $cmd -notmatch "^(rx_sensor|tx_sensor|vfo)") {
                        Write-Host "  [TCI<] $cmd" -ForegroundColor DarkGray
                    }

                    if ($cmd -eq 'ready') {
                        Write-Host "[TCI] Handshake complete — starting RX audio stream..." -ForegroundColor Green
                        Send-TciText "audio_stream_sample_type:float32;"
                        Send-TciText "audio_stream_channels:$Channels;"
                        Send-TciText "audio_stream_samples:$TciFrameSamples;"
                        Send-TciText "audio_samplerate:$SampleRate;"
                        Send-TciText "audio_start:$TciTrxIndex;"
                        Send-TciText "trx:$TciTrxIndex;"
                        $script:tciReady = $true
                    }
                    # trx:<idx>,true/false[,...]  — MOX state. When CAT MOX polling
                    # is active, CAT is authoritative; ignore TCI trx to avoid conflict.
                    elseif ($cmd -match "(?i)^trx:\s*$TciTrxIndex\s*,\s*(true|false)") {
                        if (-not $CatMoxEnabled) {
                            $isTx = ($Matches[1].ToLower() -eq 'true')
                            Switch-Source -NewMox ([int]$isTx)
                        }
                    }
                    # vfo:<trx>,<vfo>,<freqHz> — capture VFO-A (vfo index 0) frequency
                    elseif ($cmd -match "^vfo:$TciTrxIndex,0,(\d+)") {
                        $script:lastFreqHz = [int64]$Matches[1]
                    }
                    elseif ($cmd -match "^audio_start:$TciTrxIndex") {
                        Write-Host "[TCI] RX audio stream confirmed by Thetis." -ForegroundColor Green
                        Write-Host ""
                        Write-Host "[Recorder] Running. Right-click tray icon or Ctrl+C to stop." -ForegroundColor Yellow
                        Write-Host ""
                        Update-TrayIcon -Mox $script:currentMox -Tooltip "Thetis QSO Recorder — recording"
                    }
                    elseif ($cmd -eq 'keepalive') {
                        Send-TciText "keepalive;"
                    }
                }
            }

            # ── Binary frame: TCI audio data ──────────────────────────────────
            elseif ($frame.Type -eq [System.Net.WebSockets.WebSocketMessageType]::Binary) {
                $script:binCount++

                # NOTE: RX-stream-resume unkey detection was removed. Measured
                # behavior on this Thetis build: the RX binary stream goes silent
                # for only ~3 seconds after keying, then RESUMES even while still
                # transmitting — so a returning frame is NOT a reliable unkey
                # signal and caused premature unkeys on overs longer than ~3s.
                # MOX state is now detected solely by CAT polling (authoritative).

                # In "tci" TX mode, record the TCI stream continuously (RX and TX).
                # In "wasapi" mode, record TCI only during RX (TX comes from B1 capture).
                $recordThis = if ($TxAudioSource -eq "tci") {
                    $script:isRecording
                } else {
                    $script:isRecording -and $script:activeSource -eq 0
                }
                if ($recordThis -and $frame.Count -gt $TciHeaderBytes) {
                    # TCI binary audio frame: 64-byte header + interleaved float32 L/R samples
                    $audioByteCount = $frame.Count - $TciHeaderBytes
                    $audioBytes     = New-Object byte[] $audioByteCount
                    [System.Array]::Copy($frame.Data, $TciHeaderBytes, $audioBytes, 0, $audioByteCount)

                    $int16Bytes = Convert-Float32ToInt16Bytes -FloatBytes $audioBytes -ByteCount $audioByteCount

                    # In "tci" TX mode this same stream carries both RX and TX audio,
                    # distinguished by activeSource — route each through its own
                    # leveler/compressor instances so their state stays independent.
                    $isTxInTciStream = ($TxAudioSource -eq "tci" -and $script:activeSource -eq 1)

                    if ($isTxInTciStream) {
                        $int16Bytes = $script:txFade.Process($int16Bytes, $int16Bytes.Length)
                    } else {
                        $int16Bytes = $script:rxFade.Process($int16Bytes, $int16Bytes.Length)
                    }
                    if ($LevelerEnabled) {
                        if ($isTxInTciStream) {
                            $int16Bytes = $script:txLeveler.Process($int16Bytes, $int16Bytes.Length)
                        } else {
                            $int16Bytes = $script:rxLeveler.Process($int16Bytes, $int16Bytes.Length)
                        }
                    }
                    if ($CompressorEnabled) {
                        if ($isTxInTciStream) {
                            $int16Bytes = $script:txComp.Process($int16Bytes, $int16Bytes.Length)
                        } else {
                            $int16Bytes = $script:rxComp.Process($int16Bytes, $int16Bytes.Length)
                        }
                    }
                    if ($LimiterEnabled) {
                        if ($isTxInTciStream) {
                            $int16Bytes = $script:txLimiter.Process($int16Bytes, $int16Bytes.Length)
                        } else {
                            $int16Bytes = $script:rxLimiter.Process($int16Bytes, $int16Bytes.Length)
                        }
                    }

                    [System.Threading.Monitor]::Enter($script:writeLock)
                    try   { $script:mp3Writer.Write($int16Bytes, 0, $int16Bytes.Length) }
                    finally { [System.Threading.Monitor]::Exit($script:writeLock) }
                    # Update smoothed RX level meter (measurement only)
                    $db = [ThetisAudio.FastConvert]::Int16RmsDbfs($int16Bytes, $int16Bytes.Length)
                    $script:rxLevelDb = ($script:LevelSmoothing * $db) + ((1 - $script:LevelSmoothing) * $script:rxLevelDb)
                }
            }
        }

        # Drain any captured TX (B1) audio into the MP3 (wasapi mode only)
        Drain-TxQueue

        # ── Diagnostic heartbeat (every 5s) — logs what the loop is seeing ────
        if ($swDiag.Elapsed.TotalSeconds -ge 3) {
            Write-Log ("[DIAG] text={0} bin={1} src={2} mox={3} | txCb={4} txWr={5} | catPolls={6} catRaw={7} catErr='{8}'" -f $script:textCount, $script:binCount, $script:activeSource, $script:currentMox, $script:txCallbackCount, $script:txWriteCount, $script:catCtl.PollCount, $script:catCtl.LastRaw, $script:catCtl.LastErr) -NoConsole -Verbose
            $swDiag.Restart()
        }

        # ── Tray tooltip update (every ~1s) — includes live RX/TX levels ──────
        if ($swTip.Elapsed.TotalSeconds -ge 1) {
            try {
                $fileSizeMb  = [math]::Round((New-Object System.IO.FileInfo($outputFile)).Length / 1MB, 1)
                $stateNow    = if ($script:currentMox -eq 1) { "TX" } else { "RX" }
                $durationSec = [int](($fileSizeMb * 1MB * 8) / ($Mp3BitRate * 1000))
                $elapsed     = [System.TimeSpan]::FromSeconds($durationSec)
                $rxDb        = [math]::Round($script:rxLevelDb, 1)
                $txDb        = [math]::Round($script:txLevelDb, 1)
                $diff        = [math]::Round($script:txLevelDb - $script:rxLevelDb, 1)
                $diffSign    = if ($diff -ge 0) { "+" } else { "" }
                # Keep under NotifyIcon's 63-char limit; levels are the priority.
                $tip = "[$stateNow] $($elapsed.ToString('mm\:ss')) RX${rxDb} TX${txDb} d${diffSign}${diff}"
                Update-TrayIcon -Mox $script:currentMox -Tooltip $tip
            } catch {}
            $swTip.Restart()
        }

        # ── Status ticker (every 30s) ─────────────────────────────────────────
        if ($sw.Elapsed.TotalSeconds -ge 30) {
            try {
                $fileSizeMb  = [math]::Round((New-Object System.IO.FileInfo($outputFile)).Length / 1MB, 1)
                $stateNow    = if ($script:currentMox -eq 1) { "TX" } else { "RX" }
                $durationSec = [int](($fileSizeMb * 1MB * 8) / ($Mp3BitRate * 1000))
                $elapsed     = [System.TimeSpan]::FromSeconds($durationSec)
                Write-Host "[Status] $stateNow | $($elapsed.ToString('hh\:mm\:ss')) | ${fileSizeMb} MB" -ForegroundColor DarkCyan
            } catch {}
            $sw.Restart()
        }
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C — expected, fall through to cleanup
} finally {
    Write-Host ""
    Write-Host "[Recorder] Shutting down..." -ForegroundColor Yellow

    $script:isRecording = $false
    $script:tciRunning  = $false

    # Remove tray icon
    try {
        if ($script:trayIcon) {
            $script:trayIcon.Visible = $false
            $script:trayIcon.Dispose()
        }
        if ($script:iconRX) { $script:iconRX.Dispose() }
        if ($script:iconTX) { $script:iconTX.Dispose() }
    } catch {}

    # Stop TCI audio stream cleanly
    try {
        if ($tciWs -and $tciWs.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            Send-TciText "audio_stop:$TciTrxIndex;"
            $tciWs.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                "Recorder stopped",
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        }
    } catch {}
    try { if ($tciWs) { $tciWs.Dispose() } } catch {}

    # Stop CAT MOX poll thread
    try {
        if ($script:catCtl) { $script:catCtl.Run = $false }
        if ($script:catPSRef -and $script:catHandle) {
            [void]$script:catPSRef.EndInvoke($script:catHandle)
            $script:catPSRef.Dispose()
        }
    } catch {}

    # Stop WASAPI TX capture
    try { if ($script:txCapture) { $script:txCapture.StopRecording(); $script:txCapture.Dispose() } } catch {}
    try { if ($script:txEventSub) { Unregister-Event -SourceIdentifier $script:txEventSub.Name -ErrorAction SilentlyContinue } } catch {}

    # Flush and close MP3 — finalizes ID3 tags and trailing frames
    try { $script:mp3Writer.Flush(); $script:mp3Writer.Dispose() } catch {}
    try { if ($script:mp3Stream) { $script:mp3Stream.Dispose() } } catch {}

    # Clean up empty/aborted recordings: if the file is missing or below the
    # minimum-audio threshold (header/ID3 tags only), delete it so the folder
    # isn't littered with 0-byte files from crashed or immediately-stopped runs.
    $MinKeepBytes = 2KB
    if ((Get-Variable -Name outputFile -Scope Local -ErrorAction SilentlyContinue) -and (Test-Path $outputFile)) {
        $finalBytes = (Get-Item $outputFile).Length
        if ($finalBytes -lt $MinKeepBytes) {
            try {
                Remove-Item $outputFile -Force
                Write-Host "[Recorder] No audio recorded — removed empty file." -ForegroundColor DarkYellow
            } catch {
                Write-Host "[Recorder] Empty file left in place (could not delete): $outputFile" -ForegroundColor DarkYellow
            }
        } else {
            $finalMb = [math]::Round($finalBytes / 1MB, 2)

            # Append last-known frequency to the filename, e.g. ..._14.250MHz.mp3
            $savedPath = $outputFile
            if ($script:lastFreqHz -gt 0) {
                $mhz      = [math]::Round($script:lastFreqHz / 1000000.0, 3)
                $freqTag  = ("{0:0.000}MHz" -f $mhz)
                $dir      = [System.IO.Path]::GetDirectoryName($outputFile)
                $base     = [System.IO.Path]::GetFileNameWithoutExtension($outputFile)
                $ext      = [System.IO.Path]::GetExtension($outputFile)
                $newPath  = Join-Path $dir "${base}_${freqTag}${ext}"
                try {
                    Rename-Item -Path $outputFile -NewName ([System.IO.Path]::GetFileName($newPath)) -Force
                    $savedPath = $newPath
                } catch {
                    Write-Host "[Recorder] Could not rename with frequency — keeping original name." -ForegroundColor DarkYellow
                }
            }
            Write-Log "[Recorder] Saved: $savedPath (${finalMb} MB)" -Color Green
        }
    } else {
        Write-Host "[Recorder] No recording was created." -ForegroundColor DarkYellow
    }
    Write-Host "[Recorder] Done. 73 de W4ORS" -ForegroundColor Cyan
}
