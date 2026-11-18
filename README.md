# PeanutButter

### A free, open-source macOS multitrack workstation built for live worship and stage performance.

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-111827?style=for-the-badge&logo=apple)
![Swift](https://img.shields.io/badge/Built%20With-Swift%20%26%20CoreAudio-0ea5e9?style=for-the-badge&logo=swift)
![Offline Ready](https://img.shields.io/badge/Stage%20Mode-100%25%20Offline%20Ready-10b981?style=for-the-badge)
![License GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-f59e0b?style=for-the-badge)

**PeanutButter** gives worship teams, music directors, and touring bands every pro live-performance tool out of the box—multi-channel audio routing, 16 sub-mix buses, 8 MIDI automation buses, ProPresenter triggers, SMPTE LTC timecode, formant-preserving key/tempo shifting, wireless browser remote control, team cloud sync, and offline rehearsal mix bouncing—**completely local-ready, open-source (`GPL-3.0`), and $0/month forever.**

> **Built for Sunday morning—and every stage in between:** While PeanutButter is designed first with churches and worship teams in mind, it is just as at home with touring acts, gigging cover bands, theater pits, and solo artists who need rock-solid backing tracks, clicks, spoken cues, and MIDI/timecode automation without DAW complexity or monthly fees.

No account login walls at soundcheck. No per-seat cloud fees. No "Pro" tier paywalls.

![PeanutButter Home Screen — no login, ready to build or load a setlist.](assets/peanutbutter-console.png)

---

## Why Teams Switch to PeanutButter

### Free, Open Source & Unlocked on Day 1
Every capability ships unlocked under the **GNU General Public License v3.0 (`GPL-3.0`)**. Whether you run a portable volunteer laptop or a multi-output FOH/IEM rig, you never hit a subscription check or locked feature.

### 100% Local-First — Or Bring Your Own Cloud (`BYOC`)
- **Offline by Default:** Your songs (`.pbsong`) and setlists (`.pbsession`) live cleanly on your Mac with zero internet or sign-in required.
- **Bring Your Own Cloud Sync:** Point PeanutButter at any folder in **iCloud Drive, Google Drive, Dropbox, or OneDrive** to share your library with your band.
- **Smart Team Syncing:** Audio stems are bundled into atomic `<songId>.pbstems` packs for reliable cloud transfers, **Save** prompts for optional release notes, and teammate Macs automatically display a **cyan Update badge** with a preview of what changed before downloading.

### Bring Your Own Stems, Pads, Click Sounds & Guide Voices
PeanutButter never locks your audio library into a closed store:
- **Any Multitrack Stems:** Load `.wav`, `.m4a`, `.mp3`, `.aiff`, or `.flac` stems from anywhere (loop vendors, studio bounces, user-owned libraries). `Auto-Sort Stems` and role detection organize stems into your mix buses automatically.
- **Upload Custom Ambient Pads:** Ships with stock 12-key pads (`Simple` and `Soft`) and lets you import any 12-key custom pad folder—automatically **RMS loudness-normalized** so switching pad packs never spikes your stage volume.
- **Upload Custom Click Sounds (or Use 7 Built-In Synth Clicks):** Ships with 7 distinct synthesized click engines (*Classic*, *Woodblock*, *Beep / Synth*, *Sticks / Rimshot*, *Cowbell*, *Shaker*, *Tambourine*), or upload your own Accent / 1/4 / 1/8 / 1/16 samples.
- **Upload Custom Guide Voices (or Use 7 Bundled Human Voices + Siri/System TTS):** Includes 7 bundled human guide packs (**Sam**, **Caleb**, **Claire**, **Daniel**, **Hannah**, **Marcus**, and **Maya**), supports uploading your own recorded voice packs, and automatically falls back to macOS system/Siri TTS so *any* custom phrase can be spoken.

### Faster-Than-Real-Time Rehearsal & Practice Track Bouncing
Skip recording real-time reference tracks in an external DAW:
- **Session Reference Tracks:** Export an entire setlist run-through as **MP3, M4A, or WAV** in seconds, with independent **Include Click Track** and **Include Guide Track** toggles and automatic **5-second gaps** after manual-stop songs.
- **Part-Dominant Musician Practice Tracks:** Batch-export custom mixes (`[Song] - [Instrument] - Key of [Key]`) for **Electric Guitars (All), Bass, Drums, Acoustic, Piano, and Vocals**—keeping Click/Guide and the player's instrument front-and-center (`0 dB`), core instruments clear (`-10 dB`), and background beds tucked behind (`-20 dB`).

### Zero-Install Wireless Stage Remote (`PeanutButter Remote`)
Turn on the built-in local Wi-Fi server (**_peanutbutter._tcp** via Bonjour, with optional passcode lock) so MDs, worship leaders, or FOH can open a responsive web controller in any phone, iPad, or laptop browser:
- Play/Pause, Return to Zero, Fade Out, and Tap Tempo
- Click sections to cue **quantized amber jumps** while playing
- Switch setlist songs, toggle/link the Ambient Pad Player, and tweak mixer faders, mutes, and solos live

### Switch From MultiTracks Playback in Minutes
Use the built-in 4-step **Import from Playback...** wizard to read your local MultiTracks Playback database and migrate setlists, saved arrangements, section trims, keys, tempos, mixes, MIDI cues, ProPresenter triggers, and automation—automatically matching your unprotected/user-owned `.wav` or `.m4a` stem folders on disk. *(Encrypted `.pmt` store stems are never decrypted or imported.)*

### Apple Silicon Speed & Live Reliability
- **Formant-Preserving Transposition & Tempo Shifting:** On-device **Rubber Band R3** processing pre-renders key and BPM changes to disk cache so vocals stay natural and sets stay dropout-free.
- **Full-Setlist RAM Hydration:** Loads your active setlist into RAM for instant zero-latency song switching (with automatic macOS memory-pressure safeguards on lower-RAM Macs).
- **120 Hz V-Synced Visuals:** `CADisplayLink` metering and GPU-cached waveforms keep scrolling and live fader drags buttery smooth.

---

## Everyday Workflow Features (The Little Things That Save Rehearsals)

- **`Cmd+Z` / `Shift+Cmd+Z` Undo & Redo:** Step backward and forward across arrangement edits, section trims, cue moves, MIDI/keyboard mappings, tempo/key changes, and mixer faders, mutes, solos, pans, and routing.
- **Custom Spoken Directional Cues:** Drop instant preset cues (*Build, Breakdown, All In, Band Out, Hits, Hold, A Cappella*, etc.) or type *any* custom phrase and hear it spoken in time—even over an uploaded guide stem.
- **Drag-and-Drop Timeline Cues + `1/16`-Note Nudge:** Drag MIDI, Directional, Automation, and SMPTE cues right on the waveform with beat-grid snapping, or step them in crisp `1/16`-note increments.
- **Smart MIDI Cue Paste with Optional Velocity Auto-Adjust:** Copy MIDI cues from one section (`Chorus 1`) and choose **Paste & Auto-Adjust Velocity** to continue sequential cue numbering (`N+1, N+2...` per bus—ideal for ProPresenter lyric slides) or **Paste Original Velocities**.
- **Easy Mid-Song Time Signature Changes:** Drop `2/4`, `3/4`, `5/4`, `6/8`, `7/8`, `9/8`, `12/8`, or custom meter changes onto any bar in **Song Sections** without splitting audio—updating click accents, beat grid lines, measure numbers, and live transport badges automatically.
- **Standalone Click & Pad Items + Spontaneous Click Sections:** Add stemless **Click & Pad** items directly to a setlist, or insert **Blank Click Sections** and **Section-Mirrored Click Sections** (stems muted, Click + Guide + Pad active) mid-song in two clicks.
- **Non-Destructive Section Trimming & Saved Arrangements:** Drag section handles to trim bars, reorder or repeat sections in **Setlist / Song Map**, and save multiple named arrangements per song without touching audio files.
- **Overlap Click & Guide Clash Protection:** On Overlap/Crossfade transitions, outgoing Click and Guide automatically mute on the overlap downbeat so two clicks and two voices never collide.
- **Auto-Detect Tempo & Auto-Label Sections From Guide:** Drop raw stems into **Song Builder**, detect BPM automatically, and let `GuideSectionDetector` analyze your guide track to place `Intro`, `Verse`, `Chorus`, and `Bridge` markers.
- **Visual MIDI & Keyboard Learn (with Collision Protection):** Click any transport button, section control, fader, mute, or solo to map MIDI notes/CCs or Mac keyboard keys—complete with conflict reassignment prompts and **Reset to Defaults**.
- **ProPresenter Triggers, MIDI Clock & Redundancy Tone:** Send `F-1` / `F#-1` ProPresenter playlist & item triggers on song start, broadcast **24 PPQN MIDI Beat Clock** per destination, output **SMPTE LTC** timecode (`24`–`30` fps), and run a continuous **1 kHz Redundancy** pilot tone on any free mono output.

---

## Documentation

Want a quick, easy-to-follow walkthrough of every button, menu, and hotkey in the app?
- Read the **[Full Feature Guide](FEATURE_GUIDE.md)** for short, step-by-step explanations of every feature in PeanutButter.
- Check **[Releases](https://github.com/rghapro/PeanutButter/releases/latest)** for prebuilt downloads or report bugs/requests on **[Issues](https://github.com/rghapro/PeanutButter/issues)**.

---

## Quick Start (Build from Source)

### Requirements
- **macOS 14.0+** (Sonoma or newer, Apple Silicon or Intel)
- **Swift 5.10+** (Xcode 15.3+ or Apple Command Line Tools)

### Build & Run
```bash
git clone https://github.com/rghapro/PeanutButter.git
cd PeanutButter
./build.sh
open "PeanutButter.app"
```

Or compile via Swift Package Manager directly:
```bash
swift build -c release
```

---

## Audio Assets & Third-Party Libraries

- **Stock Audio Assets:** Bundled royalty-free 12-key pads (`Simple`, `Soft`), 7 human guide voice packs, and 7 synthesized click engines work out of the box; third-party commercial samples are excluded via `.gitignore`.
- **Rubber Band Library (`Sources/CRubberBand`):** Used for pitch shifting and time stretching under GPLv2+ (`Sources/CRubberBand/vendor/COPYING`).

---

## License

PeanutButter is free, open-source software licensed under the **GNU General Public License v3.0 (`GPL-3.0`)**. See [LICENSE](LICENSE) for full details.
