# PeanutButter — Full Feature Guide

A quick, plain-English walkthrough of every feature in **[PeanutButter](https://github.com/rghapro/PeanutButter)**, broken down into short, easy-to-follow sections.

> **Links:** [Overview (README)](README.md) · [Latest Release](https://github.com/rghapro/PeanutButter/releases/latest) · [Report an Issue](https://github.com/rghapro/PeanutButter/issues)

---

## Table of Contents

1. [The 4-Tier Console Layout](#1-the-4-tier-console-layout)
2. [Setlists & Song Library (`.pbsession` & `.pbsong`)](#2-setlists--song-library-pbsession--pbsong)
3. [Cloud Library Sync (Bring Your Own Cloud)](#3-cloud-library-sync-bring-your-own-cloud)
4. [Importing from MultiTracks Playback](#4-importing-from-multitracks-playback)
5. [Building & Editing Songs From Stems](#5-building--editing-songs-from-stems)
6. [Standalone Click & Pad Tracks](#6-standalone-click--pad-tracks)
7. [Transport, Quantized Section Jumps, Pre-Roll & Looping](#7-transport-quantized-section-jumps-pre-roll--looping)
8. [Song Transitions & Overlap Clash Guard](#8-song-transitions--overlap-clash-guard)
9. [Key Transposition & Tempo Shifting](#9-key-transposition--tempo-shifting)
10. [Song Map, Non-Destructive Trimming, Click Sections & Saved Arrangements](#10-song-map-non-destructive-trimming-click-sections--saved-arrangements)
11. [Mid-Song Time Signature Changes](#11-mid-song-time-signature-changes)
12. [Click Track Engine, Subdivisions & Custom Click Packs](#12-click-track-engine-subdivisions--custom-click-packs)
13. [Spoken Guide, Custom Voices & Directional Cues](#13-spoken-guide-custom-voices--directional-cues)
14. [Ambient Pad Player (`LINK` Mode & Custom Pads)](#14-ambient-pad-player-link-mode--custom-pads)
15. [Mixer Console, 16 Sub-Mix Buses & Hardware Routing](#15-mixer-console-16-sub-mix-buses--hardware-routing)
16. [MIDI Cues, Auto-Velocity Paste, ProPresenter & MIDI Clock](#16-midi-cues-auto-velocity-paste-propresenter--midi-clock)
17. [Beat-Synced Mix & Pad Automation](#17-beat-synced-mix--pad-automation)
18. [SMPTE LTC Timecode & 1 kHz Redundancy Pilot Tone](#18-smpte-ltc-timecode--1-khz-redundancy-pilot-tone)
19. [Offline Bounce Engine (Reference & Practice Tracks)](#19-offline-bounce-engine-reference--practice-tracks)
20. [PeanutButter Remote, MIDI/Keyboard Mapping & Hotkeys](#20-peanutbutter-remote-midikeyboard-mapping--hotkeys)

---

## 1. The 4-Tier Console Layout

Everything in PeanutButter lives in one clean, single-screen stage console:

- **Top Transport Bar:** Displays **BPM / Time Signature**, elapsed **MM:SS + Bar/Beat counter**, quick **PAD** button, center **Return to Zero / Play-Pause / Fade**, and top-right **Edit**, **Setlists**, and **Settings (`≡`)** buttons.
- **Setlist Carousel:** Horizontal row of song cards with artwork, title, `(Key)` badge, and interactive **transition connectors** between songs—plus **`+ Add a Song`** at the end.
- **Waveform & Cue Timeline:** Fixed center playhead with GPU-cached waveforms, color-coded section headers, **Time Signature badges**, and a unified cue roadway for **MIDI**, **Directional**, **Automation**, and **SMPTE** cues.
- **Bottom Mixer & Right Action Bar:** Scrollable track faders (or **16 Sub-Mix Buses** or **Pad Player**), a pinned **Master** strip, and right-hand quick switches (**Mix View**, **Buses**, **Pad Player**, **Mute MIDI**, **1x Loop**, **∞ Loop**).

> **Stage Tip:** An audio interface hot-plug banner appears automatically at the top of the screen if a USB/Thunderbolt interface is connected or disconnected, refreshing your available outputs right away.

---

## 2. Setlists & Song Library (`.pbsession` & `.pbsong`)

PeanutButter packages songs (`.pbsong`) and setlists (`.pbsession`) locally at:
- `~/Library/Application Support/PeanutButter/Songs/`
- `~/Library/Application Support/PeanutButter/Setlists/`

### Key Actions (Top-Right Setlists Button)
- **New Setlist:** Name your set, pick a service date/time and service type, and start fresh.
- **Open Setlist:** Search and filter **Local** and **Cloud** setlists, preview song lists, duplicate/copy between Local and Cloud, or load a set with full-setlist RAM hydration.
- **Save / Save As New / Restore From Previous Save:** Saves your session asynchronously without audio glitches (plus maintains an automatic local crash-recovery backup in `AutoSaveSession.pbsession`).
- **Song Card 3-Dots Menu (`...`):** Jump straight into **Song Menu** (Key, Tempo, Arrangements, Pad, ProPresenter, Save/Refresh MIDI Cues, Export Practice Tracks), **Edit Song**, or remove/reorder songs by dragging cards left or right.

> **Status Dots on Setlists Icon:** A **red dot** means unsaved local changes; a **cyan dot** means a teammate published a newer Cloud version of your currently open setlist.

---

## 3. Cloud Library Sync (Bring Your Own Cloud)

Sync across laptops using **iCloud Drive, Google Drive, Dropbox, or OneDrive**—with zero proprietary cloud subscriptions.

### How to Set It Up
1. Open **Settings (`≡`) → Cloud Library Sync → Choose Cloud Folder...** and select a synced folder.
2. PeanutButter automatically creates `Songs/`, `Setlists/`, `Stems/`, `Pads/`, `Clicks/`, and `Guides/` folders inside it.

### How It Works in Practice
- **Atomic Stem Packs (`.pbstems`):** Audio stems are packed per song so already-uploaded stems are skipped on future setlist saves, preventing missing-file links across computers.
- **Change Notes on Save:** When you click **Save** or **Save to Cloud Setlists**, enter an optional short note (e.g., *"Dropped Praise to Bb, fixed lyric cues"*).
- **Live Update Alerts:** Teammates with the same Cloud setlist open see **Update Available** in the Setlists menu and can inspect your note before clicking **Download Update**.

---

## 4. Importing from MultiTracks Playback

Switch without rebuilding your library by hand (**Setlists Menu → Import from Playback...**):

1. **Choose Playlists:** Pick a single playlist, all upcoming playlists, or everything in Playback's local `AppData.storedata`.
2. **Point to Your Audio Folder:** Drag and drop your parent stems folder (or skip if your tracks only use built-in Click & Pad or Playback `.m4a` stems).
3. **Review Matches:** Inspect auto-matched song folders and manually pick folders or map individual stems if needed.
4. **Import:** Converts setlists, saved arrangements, section trims, keys, tempos, fader levels, MIDI cues, ProPresenter triggers, and automation points directly into `.pbsession` files.

> **Asset Note:** Only unprotected/user-owned `.wav` or `.m4a` stems are imported; encrypted `.pmt` store stems remain untouched inside Playback.

---

## 5. Building & Editing Songs From Stems

Turn any folder of audio stems into a playable `.pbsong` in seconds:

- **Creating a Song (`+ Add a Song → Build Song From Stems`):** Drag stems onto the builder window or choose files. PeanutButter detects file BPM (`ClickTempoDetector`), assigns track categories (`Drum`, `Bass`, `EG`, `AG`, `Keys`, `Vocals`, etc.) to matching buses, and builds your song package.
- **Immediate Section Editing:** After saving a new song, PeanutButter jumps straight into **Edit → Song Sections** so you can label your chart right away.
- **Auto-Label Song Sections (From Guide):** Open **Settings (`≡`) → Auto-Label Song Sections (From Guide)** to transcribe spoken vocal cues in your guide stem (`Intro`, `Verse 1`, `Chorus`, `Bridge`, etc.) and automatically drop section markers on the following downbeats (filtering out dynamic cues like *"build"* or *"all in"*).
- **Edit Song Later:** Open **Song Card `...` → Edit Song** anytime to update title, artist, album art, stems, routing, or tempo.

---

## 6. Standalone Click & Pad Tracks

Need an open vamp, Scripture underscore, or bumper between songs with zero backing stems?

- Open **`+ Add a Song → Click & Pad`** (accessible directly on an empty slot or the end of the setlist).
- Set an optional custom **Name** (leave blank to auto-title like `"120 BPM 4/4"`), dial or type the exact **BPM** (`20.0–300.0`, supporting decimals like `72.5`) and **Time Signature** (`2/4`, `3/4`, `4/4`, `6/4`, `6/8`, `5/4`, `12/8`).
- Toggle **Ambient Pad** (choose pack and **Key**) and choose **Infinite Loop** (`∞` auto-armed on a 4-bar Click loop) or a fixed **Measure** count.
- Generates a ready-to-play `Count Off (2 bars) → Click → Ending (1 bar)` track with active Click and Guide channels.

---

## 7. Transport, Quantized Section Jumps, Pre-Roll & Looping

- **Seek While Stopped:** Single-click any section header (or scrub the timeline) to snap the playhead cleanly.
- **Quantized Jump While Playing:** Double-click any section header while playing to **queue** it in **amber**. Playback stays locked to the grid, switches cleanly on the next measure/beat boundary, and updates the live spoken Guide cue ahead of the jump.
- **Song Section Pre-Roll:** Enable **Settings (`≡`) → Song Section Pre-Roll** (`1`, `2`, `4`, `8`, or `Custom` measures) to automatically roll in before a jumped section so players hear the count-in into the transition.
- **Single (`1x`) & Infinite (`∞`) Looping:** Toggle **1x Loop** to repeat the current section once (amber loop indicator), or **∞ Loop** to hold it indefinitely until toggled off or another section is queued (great for spontaneous chorus repeats or altar calls).
- **Smooth Master Fade:** Click **Fade** (or press `F`) to smoothly fade music stems out over a configurable `1s–10s` duration (right-click the Fade button to adjust Fade Out and Fade In times) while keeping Click and Guide clean.

---

## 8. Song Transitions & Overlap Clash Guard

Click the **transition icon between any two setlist cards** (or on the last card) to pick how each song ends:

- **Cue Next Song / Cue First Song:** Stops at the end of the song and advances/cues ready for your next trigger.
- **Stay In Song:** Holds on the current song after it finishes instead of advancing.
- **Continue Pad (Toggle):** Keeps the Ambient Pad sustaining seamlessly across the transition gap and crossfades to the next song's key.
- **AutoLink:** Starts the next song automatically the instant the current song ends.
- **Overlap & Crossfade:** Starts the next song over the outgoing tail (`End` / `Outro`).
  - **Built-In Overlap Clash Guard:** On the downbeat where an Overlap begins, PeanutButter automatically mutes the outgoing song's Click and Guide tracks while letting music stems ring out—so two metronomes or two guide voices **never talk over each other**.

---

## 9. Key Transposition & Tempo Shifting

Adjust any song live for your vocalists without leaving PeanutButter:

- Open **Song Card `...` → Key / Tempo** (or **Song Menu**).
- **On-Device Rubber Band R3 Processing:** Shift key by semitones with **Preserve Vocal Formants** enabled (preventing chipmunk vocals on BGVs), and dial tempo within clean musical bounds (`±20 BPM` / `0.75x–1.50x`).
- **Smart Disk & RAM Caching:** Click and Guide regenerate natively at the new tempo (without pitch/time-stretch artifacts), while transformed stems cache on disk so switching back later is instant.
- **Live Progress Feedback:** Any song currently processing shows a progress bar directly on its setlist card without locking the UI.

---

## 10. Song Map, Non-Destructive Trimming, Click Sections & Saved Arrangements

Click **Edit** (top-right sliders icon) to open the bottom **Edit Drawer** without ever altering your original audio files:

- **Song Sections (Label & Partition):** Click `+` at the playhead in **Song Sections** to slice and label sections using presets or custom names.
- **Non-Destructive Section Trimming:** Open a section's options popover (`Trim Section`) and drag handles to shorten a section in bars while keeping waveforms, cues, and transitions synchronized.
- **Setlist / Song Map (Arrange & Reorder):** Insert, duplicate, reorder, or remove sections in the map—and reset anytime with **Reset to Default Song Map**.
- **Click Sections (Blank & Section-Mirrored):** Insert a **Click Section** in the Song Map in either mode:
  - **Default Click:** A clean variable-bar vamp with Click + Guide + Pad only (stems muted).
  - **Based on Section:** Mirrors an existing section's exact bar map, meter, and guide cues (e.g., an instrumental/band-out *Chorus* vamp) with backing stems silenced.
- **Saved Arrangements:** Save multiple named arrangements (`Sunday Acoustic`, `Short Set`) per song in **Song Menu → Arrangement**, while keeping the original `Default` chart locked and untouched.

---

## 11. Mid-Song Time Signature Changes

Handle songs with `2/4` turnarounds or `6/8` bridges right inside the timeline:

1. Enter **Edit → Song Sections** and park the playhead at the target bar.
2. Click `+` on the timeline and select **Change Time Signature...**.
3. Pick a preset (`2/4`, `3/4`, `4/4`, `5/4`, `6/8`, `7/8`, `9/8`, `12/8`) or enter any custom meter.

PeanutButter immediately updates the beat grid, measure numbering, Click accent pattern, Guide count-ins, and the live **Time Signature badge** in the transport bar. Click any meter badge on the timeline to edit or remove it.

---

## 12. Click Track Engine, Subdivisions & Custom Click Packs

Click tracks are always generated cleanly at sample accuracy (or swapped for an uploaded click stem):

- **Subdivision Tray:** Click the `>` arrow on the **Click** channel strip to expand dedicated **Accent**, **1/4**, **1/8**, and **1/16** faders, Solo (`S`) buttons, track-name Mute toggles, and V-synced VU meters. *(Subdivision toggles sync bidirectionally between the tray and Click Options.)*
- **7 Built-In Acoustic Synth Engines:** Choose from *Classic (Synth)*, *Woodblock (Synth)*, *Beep / Synth*, *Sticks / Rimshot*, *Cowbell (Synth)*, *Shaker*, and *Tambourine*—plus optional *Uploaded Click* stem support.
- **Upload Custom Click Samples:** Open **Click Options** or **Settings (`≡`) → Upload / Manage Click Samples...** to import custom `.wav`/`.m4a`/`.aiff`/`.mp3`/`.flac` files per subdivision (automatically normalized for healthy stage headroom).

---

## 13. Spoken Guide, Custom Voices & Directional Cues

Guide cues are aligned by **perceptual vowel onset** (not clipped file starts) with consonant-safe tails so numbers and section names lock right onto the groove:

- **7 Bundled Human Voices + Siri/System Fallback:** Includes **Sam (Male)** (default), **Caleb (Male)**, **Claire (Female)**, **Daniel (Male)**, **Hannah (Female)**, **Marcus (Male)**, and **Maya (Female)**, plus macOS Siri/system voices if a phrase isn't pre-recorded.
- **Upload Custom Guide Voice Packs:** In **Settings (`≡`) → Upload / Manage Guide Samples...**, import a folder of recordings (auto-mapped by filename across 77 standard count-in, section, and directional cues) or record/upload one phrase at a time.
- **Toggle Numbers in Section Names:** Turn **Include Numbers in Guide** on/off globally in Settings or per section (`"Verse 2"` vs. `"Verse"`).
- **Custom Spoken Directional Cues (`Edit → Directional Cues`):**
  - Click `+` at the playhead to drop preset cues (*Build, Breakdown, All In, Band Out, Drums In, Softly, Hits, Hold, A Cappella*, etc.) or type **any custom phrase** (`"Pastor Speaks"`, `"Modulate to G"`) and hear it spoken in the band's in-ears.
  - Drag directional cues directly on the timeline to snap to beats, double-click/click to edit text, or nudge in **`1/16`-note** increments. Directional cues can even speak over an **Uploaded Guide** track (toggleable per song).

---

## 14. Ambient Pad Player (`LINK` Mode & Custom Pads)

Keep seamless worship drones running between songs or beneath prayers:

- **Full-Screen Pad Grid (`PAD PLAYER`):** Displays all 12 chromatic keys (`Db, Eb, Gb, Ab, Bb, B` / `C, D, E, F, G, A`), dedicated **Pad VU meter**, Solo (`S`), and click-title **Mute** toggle.
- **`LINK` Mode vs. Manual Mode:**
  - **LINK ON:** Locks pad key and pack automatically to the active song (starts on playback if **Start Pad Player With Song** is enabled, and crossfades smoothly across key changes/transitions).
  - **LINK OFF:** Detaches the pad from the setlist so you can tap any key manually and let it sustain continuously even while loading or stopping songs. Tapping `LINK` back on crossfades into the active song's key.
- **Custom Fade Times & Loudness Matching:** Adjust independent **Fade-In** (default `2.5s`) and **Fade-Out** (`3.0s`) times (`1s–10s`), right-click custom packs to delete them cleanly, and upload any 12-key pad folder—automatically RMS loudness-normalized so all packs play at consistent volume.

---

## 15. Mixer Console, 16 Sub-Mix Buses & Hardware Routing

- **Channel Strips:** Reorder stems by dragging strips, double-click faders or adjust Pan dials with decoupled zero-lag dragging, and toggle Solo (`S`), Mute (`M`), and **Solo Safe** (so Click/Guide never mute when you solo an instrument!).
- **16 Standard Sub-Mix Buses:** Switch the bottom view between **Faders** and **Buses** (`Click, Guide, Drums, Percussion, Loops, Bass, Piano, Keys, Electric Guitars, Acoustic Guitars, Strings, Horns, Pad, Vocals, FX, Aux`). Note: tracks named *Synth Pad* automatically route to the **Keys** bus.
- **Hardware Output Routing (`Settings → Configure Buses, Routing, & MIDI...`):**
  - Pick your CoreAudio interface and inspect detected hardware output channels.
  - Route each of the 16 buses to any **Stereo Pair** (`Out 1/2`, `Out 3/4`, etc.) or **Mono** output (`Out 1`, `Out 2`, etc.) and reassign any stem's bus cleanly from one tray.

---

## 16. MIDI Cues, Auto-Velocity Paste, ProPresenter & MIDI Clock

Automate lighting, lyric slides, patch changes, and external gear across **8 color-coded MIDI Buses** (*Lyrics, Lights 1, Lights 2, Patches 1, Patches 2, Guitar, Aux 1, Aux 2*, defaulting to Channels `1–8`):

- **Place & Drag MIDI Cues (`Edit → MIDI Cues`):** Add **Note**, **Control Change (`CC`)**, or **Program Change (`PC`)** events on the timeline, drag them along the beat grid, nudge in `1/16`-note steps, test cues live, or set **Disable Loop** on any cue so it fires even during active loops.
- **Copy & Paste with Auto-Adjust Velocity:** Click a section's cue menu to **Copy MIDI Cues**, then jump to another section (e.g., `Chorus 2`) and choose:
  - **Paste & Auto-Adjust Velocity:** Automatically increments Note velocities (`N+1, N+2...`) continuing seamlessly from the previous cue on the same bus—huge time-saver for ProPresenter slide triggers!
  - **Paste Original Velocities:** Duplicates the exact values unchanged.
- **Save / Refresh MIDI Cues:** Push updated MIDI cues & ProPresenter settings back to the master `.pbsong` (Local or Cloud) or pull updates from the library via **Song Menu**.
- **ProPresenter Triggers:** Configure **Playlist** (`F-1`, Note `17`) and **Playlist Item** (`F#-1`, Note `18`) in **Song Menu** to automatically cue slides whenever a song starts.
- **MIDI Clock (`Configure Buses, Routing, & MIDI... → MIDI Buses`):** Output **24 PPQN MIDI Beat Clock** (Start / Clock / Stop) synced to song tempo and mid-song meter/tempo changes to selected MIDI destinations.
- **Mute MIDI Toggle:** Silence all outgoing MIDI cues instantly from the right sidebar during rehearsals.

---

## 17. Beat-Synced Mix & Pad Automation

Open **Edit → Automation** to record dynamic mix moves that replay identically every service:

- Drop an **Automation Point** (`+`) at any beat or bar, drag existing points along the grid, or choose a **Transition Length** from **Instant** up to **4 Bars** (`1...4 * beatsPerBar`).
- **Live Parameter Capture:** While editing an automation point, adjusting stem faders/mutes, bus faders/mutes, **MIDI Mute**, or toggling **Pad Active / LINK** automatically records those targets into the point.
- Smoothly ramps gains and switches states during playback—and always restores your baseline mix when stopping or jumping back.

---

## 18. SMPTE LTC Timecode & 1 kHz Redundancy Pilot Tone

Built-in hardware outputs for lighting consoles, video desks, and failover switchers—no external boxes or WAV stems required:

- **SMPTE LTC Timecode:** Enable in **Settings (`≡`) → SMPTE**, select your frame rate and any free mono output channel, then drop/drag/edit **SMPTE Cues** (`Edit → SMPTE`) with configurable hours/minutes/seconds offsets (`01h 00m`, `02h 00m`, etc.) and exact timeline/frame coordinates.
- **1 kHz Redundancy Tone:** Enable **Settings (`≡`) → Redundancy** and pick a free mono output channel to broadcast a continuous `1 kHz` reference sine wave for automated A/B failover hardware switchers.

---

## 19. Offline Bounce Engine (Reference & Practice Tracks)

Render full mixes offline **faster than real time** without routing into a DAW:

- **Session Reference Track (`Setlists Menu → Current Setlist → Export Reference Track...`):**
  - Renders the entire current setlist sequentially into **MP3 (256 kbps), M4A (AAC), or WAV (PCM)**.
  - Separate checkboxes for **Include Click Track** and **Include Guide Track**.
  - Automatically inserts clean **5-second pauses** between songs set to manual stop/cue transitions while honoring Auto-Link, Overlap, and Crossfade transitions.
- **Song Practice Tracks (`Song Card ... → Export Practice Tracks...`):**
  - Batch-renders part-dominant rehearsal files named `[Song Title] - [Instrument] - Key of [Key].[ext]`.
  - Toggle any combination of **Electric Guitars (All), Bass, Drums, Acoustic, Piano, and Vocals**.
  - Mix rule: Click/Guide & target instrument at **`0 dB`**, other core band parts at **`-10 dB`**, and background tracks (synths, loops, FX, BGVs) at **`-20 dB`**.

---

## 20. PeanutButter Remote, MIDI/Keyboard Mapping & Hotkeys

### PeanutButter Remote (Browser Web Controller)
1. Enable **Settings (`≡`) → PeanutButter Remote**.
2. Toggle **Require Password** if you want a passcode.
3. Open the shown local URL (or Bonjour `_peanutbutter._tcp`) from any phone, tablet, or laptop on the same Wi-Fi to run **Transport, Tap Tempo, Quantized Section Jumps, Setlist Switching, Pad Player, and Mixer Faders/Mutes/Solos**.

### Visual MIDI & Keyboard Mapping (`Edit → MIDI Mapping` / `Keyboard Mapping`)
- Click any highlighted control on screen (Transport buttons, Song cards `1–10`, Next/Prev Section, Pad toggle, Mute MIDI, Track/Bus Faders, Mutes, Solos), then press a keyboard key or send a MIDI Note/CC to bind it.
- **Collision Detection:** Mapping a key or MIDI input already used elsewhere prompts you cleanly with **Keep Current** or **Reassign**.
- Use **Reset to Defaults** or **Delete All** anytime from the Keyboard Mapping panel.

### Default Keyboard Shortcuts Reference

| Shortcut | Action |
| :--- | :--- |
| **`Space`** | Play / Pause (auto-closes Edit drawer on Play) |
| **`R`** | Return to Zero |
| **`F`** | Fade Out / Fade In music stems |
| **`P`** | Toggle Ambient Pad Player |
| **`Cmd + P`** | Stop Ambient Pad immediately |
| **`←` / `→`** | Previous / Next Section |
| **`Enter`** | Select / Fire queued action *(via Keyboard Mapping)* |
| **`L`** | Toggle Single Section Loop (`1x`) |
| **`I`** | Toggle Infinite Section Loop (`∞`) |
| **`1` – `0`** | Select Setlist Song `1` through `10` |
| **`S`** | Open / Close Setlists Menu |
| **`E`** | Open Edit Song Dialog |
| **`B`** | Open Buses & Audio Routing Sheet |
| **`Cmd + Z`** | Undo |
| **`Shift + Cmd + Z`** | Redo |
| **`Cmd + =` / `Cmd + -`** | Zoom Waveform In / Out |
| **`Cmd + N`** | New Session |
| **`Cmd + O`** | Open Session... |
| **`Cmd + S`** | Save Session |
| **`Cmd + E`** | Export Song Package (`.pbsong`)... |
| **`Cmd + I`** | Import Song Package (`.pbsong`)... |
| **`Shift + Cmd + E`** | Add / Remove Song Sections |
