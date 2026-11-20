# PeanutButter Full Feature Guide

A plain-English walkthrough of every feature in **[PeanutButter](https://github.com/rghapro/PeanutButter)**.

> Links: [Overview (README)](README.md) · [Latest Release](https://github.com/rghapro/PeanutButter/releases/latest) · [Report an Issue](https://github.com/rghapro/PeanutButter/issues)

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
11. [Mid-Song Time Signature & Tempo Changes (DAW Tempo Curve)](#11-mid-song-time-signature--tempo-changes-daw-tempo-curve)
12. [Click Track Engine, Subdivisions & Custom Click Packs](#12-click-track-engine-subdivisions--custom-click-packs)
13. [Spoken Guide, Custom Voices & Directional Cues](#13-spoken-guide-custom-voices--directional-cues)
14. [Ambient Pad Player (`LINK` Mode & Custom Pads)](#14-ambient-pad-player-link-mode--custom-pads)
15. [Mixer Console, 16 Sub-Mix Buses & Hardware Routing](#15-mixer-console-16-sub-mix-buses--hardware-routing)
16. [MIDI Cues, Auto-Velocity Paste, ProPresenter & MIDI Clock](#16-midi-cues-auto-velocity-paste-propresenter--midi-clock)
17. [Beat-Synced Mix & Pad Automation](#17-beat-synced-mix--pad-automation)
18. [SMPTE LTC Timecode & 1 kHz Redundancy Pilot Tone](#18-smpte-ltc-timecode--1-khz-redundancy-pilot-tone)
19. [Offline Bounce Engine (Reference & Practice Tracks)](#19-offline-bounce-engine-reference--practice-tracks)
20. [PeanutButter Remote, MIDI/Keyboard Mapping, Hotkeys & Updates](#20-peanutbutter-remote-midikeyboard-mapping-hotkeys--updates)

---

## 1. The 4-Tier Console Layout

Everything in PeanutButter lives on one single-screen stage console:

- The **Top Transport Bar** shows live **BPM / Time Signature** (updating dynamically in amber during mid-song tempo changes), elapsed `MM:SS` + Bar/Beat counter, a quick **PAD** button, center **Return to Zero / Play-Pause / Fade** controls, and top-right **Edit / Done**, **Setlists**, and **Settings (`≡`)** buttons.
- The **Setlist Carousel** is a horizontal row of song cards with artwork, title, active transposed `(Key)` badge, interactive transition connectors between songs, and `+ Add a Song` at the end.
- The **Waveform & Cue Timeline** has a fixed center playhead with fast **tiled on-demand GPU waveforms** (supporting solo-mix preview), color-coded section headers, Time Signature and Tempo Change badges/ribbons, and a unified cue roadway for MIDI, Directional, Automation, and SMPTE cues.
- The **Bottom Mixer & Right Action Bar** holds scrollable track faders (including expandable **Click** and **Guide** sub-channel trays), 16 Sub-Mix Buses, or the Pad Player, a pinned Master strip, and right-hand quick switches (when tracks/buses are soloed, **`CLEAR SOLOS`** appears at the top of the action bar alongside Mix View, Buses, Pad Player, Mute MIDI, 1x Loop, and ∞ Loop).

If a USB or Thunderbolt audio interface is connected or disconnected, a banner appears at the top of the screen and available outputs refresh right away.

---

## 2. Setlists & Song Library (`.pbsession` & `.pbsong`)

PeanutButter stores songs (`.pbsong`) and setlists (`.pbsession`) locally at:
- `~/Library/Application Support/PeanutButter/Songs/`
- `~/Library/Application Support/PeanutButter/Setlists/`

### Key Actions (Top-Right Setlists Button)
- **New Setlist:** Name your set, pick a service date/time and service type, and start fresh.
- **Open Setlist:** Search and filter Local and Cloud setlists, preview song lists, duplicate or copy between Local and Cloud, or load a set with full-setlist RAM hydration.
- **Save / Save As New / Restore From Previous Save:** Saves your session asynchronously without audio glitches, and keeps an automatic local crash-recovery backup in `AutoSaveSession.pbsession`.
- **Song Card 3-Dots Menu (`...`):** Open the **Song Menu** (Key, Tempo, Arrangements, Pad, **SONG END** options for **5 Second Fade Out** or **Fade End**, ProPresenter, Save/Refresh MIDI Cues, Export Practice Tracks), **Edit Song**, or remove and reorder songs by dragging cards left or right.
  - **5 Second Fade Out:** Smoothly cosine-fades music stems out over the final 5 seconds of the song while keeping Click and Guide clean.
  - **Fade End:** Smoothly cosine-fades music stems out over the exact duration of the section labeled `"End"` / `"Ending"` (mutually exclusive with 5 Second Fade Out), restoring stem volumes cleanly if stopped, handed over, or scrubbed back earlier.

A red dot on the Setlists icon means there are unsaved local changes. A cyan dot means a teammate published a newer Cloud version of your currently open setlist (or an app update is ready).

---

## 3. Cloud Library Sync (Bring Your Own Cloud)

Sync across laptops using iCloud Drive, Google Drive, Dropbox, or OneDrive without proprietary cloud subscriptions.

### How to Set It Up
1. Open **Settings (`≡`) → Cloud Library Sync → Choose Cloud Folder...** and select a synced folder.
2. PeanutButter creates `Songs/`, `Setlists/`, `Stems/`, `Pads/`, `Clicks/`, and `Guides/` folders inside it.

### How It Works
- Audio stems are packed per song into `<songId>.pbstems` archives so already-uploaded stems are skipped on future setlist saves, preventing missing-file links across computers.
- When you click **Save** or **Save to Cloud Setlists**, you can enter an optional short note (e.g., *"Dropped Praise to Bb, fixed lyric cues"*).
- Teammates with the same Cloud setlist open see **Update Available** in the Setlists menu and can read your note before clicking **Download Update**.

---

## 4. Importing from MultiTracks Playback

Use **Setlists Menu → Import from Playback...** to migrate your existing library:

1. Pick a single playlist, all upcoming playlists, or everything in Playback's local `AppData.storedata`.
2. Drag and drop your parent stems folder (or skip if your tracks only use built-in Click & Pad or Playback `.m4a` stems).
3. Inspect auto-matched song folders and manually pick folders or map individual stems if needed.
4. Click Import to convert setlists, saved arrangements, section trims, keys, tempos, fader levels, MIDI cues, ProPresenter triggers, and automation points into `.pbsession` files.

Only unprotected/user-owned `.wav` or `.m4a` stems are imported; encrypted `.pmt` store stems remain untouched inside Playback.

---

## 5. Building & Editing Songs From Stems

Turn any folder of audio stems into a playable `.pbsong`:

- Open **`+ Add a Song → Build Song From Stems`** and drag stems onto the builder window or choose files. Stems decode asynchronously with non-blocking progress feedback, detect file BPM (`ClickTempoDetector`), assign track categories (`Drum`, `Bass`, `EG`, `AG`, `Keys`, `Vocals`, etc.) to matching buses, and build your song package.
- Click **Confirm** (or press `Return` in the BPM field) inside **Build Song / Edit Song** to apply tempo and time signature changes immediately, update the beat grid, recalculate bar counts (while keeping existing stem section timestamps pinned to the audio stems), and regenerate Click and Guide without closing the dialog.
- After saving a new song, PeanutButter opens **Edit → Song Sections** so you can label your chart right away.
- Open **Settings (`≡`) → Auto-Label Song Sections (From Guide)** to transcribe spoken vocal cues in your guide stem (`Intro`, `Verse 1`, `Chorus`, `Bridge`, etc.) and place section markers on the following downbeats (filtering out dynamic cues like *"build"* or *"all in"*).
- Open **Song Card `...` → Edit Song** anytime to update title, artist, album art, stems, routing, or tempo.

---

## 6. Standalone Click & Pad Tracks

For open vamps, Scripture underscores, or bumpers between songs with no backing stems:

- Open **`+ Add a Song → Click & Pad`** (available on an empty slot or at the end of the setlist).
- Set an optional custom **Name** (or leave blank to auto-title like `"120 BPM 4/4"`), dial or type the exact **BPM** (`20.0–300.0`, supporting decimals like `72.5`) and **Time Signature** (`2/4`, `3/4`, `4/4`, `6/4`, `6/8`, `5/4`, `12/8`).
- Toggle **Ambient Pad** (choose pack and **Key**) and choose **Infinite Loop** (`∞` auto-armed on a 4-bar Click loop) or a fixed **Measure** count.
- PeanutButter generates a `Count Off (2 bars) → Click → Ending (1 bar)` track with active Click and Guide channels.

---

## 7. Transport, Quantized Section Jumps, Pre-Roll & Looping

- Single-click any section header (or scrub the timeline) while stopped to snap the playhead.
- Double-click any section header while playing to queue it in amber. Playback stays locked to the grid, switches on the next measure/beat boundary, and updates the live spoken Guide cue ahead of the jump.
- Enable **Settings (`≡`) → Song Section Pre-Roll** (`1`, `2`, `4`, `8`, or `Custom` measures) to automatically roll in before a jumped section so players hear the count-in.
- Toggle **1x Loop** to repeat the current section once (amber loop indicator), or **∞ Loop** to hold it indefinitely until toggled off or another section is queued.
- Click **Fade** (or press `F`) to fade music stems out over a configurable `1s–10s` duration (right-click the Fade button to adjust Fade Out and Fade In times) while keeping Click and Guide clean.

---

## 8. Song Transitions & Overlap Clash Guard

Click the transition icon between any two setlist cards (or on the last card) to pick how each song ends:

- **Cue Next Song / Cue First Song:** Stops at the end of the song and advances/cues ready for your next trigger.
- **Stay In Song:** Holds on the current song after it finishes instead of advancing.
- **Continue Pad (Toggle):** Keeps the Ambient Pad sustaining across the transition gap and crossfades to the next song's key.
- **Continue Click (Toggle):** For manual-stop transitions (**Cue Next Song**, **Stay In Song**, **Cue First Song**, or the final song), keeps a sample-accurate 1-bar looping Click and **24 PPQN MIDI Beat Clock** running on `Out 3/4` after the song finishes, matching either the outgoing song's ending BPM/meter (`Stay In Song` / final song) or the newly cued song's BPM/meter (`Cue Next Song` / `Cue First Song`), with live flashing Click meters and mute/solo control.
- **AutoLink:** Starts the next song automatically the instant the current song ends, cleanly restoring any outgoing Fade End volumes and resetting previous-song VU meters to zero on handover.
- **Overlap & Crossfade:** Starts the next song over the outgoing tail (`End` / `Outro`). On the downbeat where an Overlap begins, PeanutButter mutes the outgoing song's Click and Guide tracks while letting music stems ring out so two clicks or guide voices never collide.
- **Cue Next Song Section (Toggle):** Available on automatic transitions (**AutoLink**, **Overlap**, and **Crossfade**) so the Guide speaks and counts into the next song's opening section across seamless song medleys (including overlaying cues onto an Uploaded Guide track).

---

## 9. Key Transposition & Tempo Shifting

Open **Song Card `...` → Key / Tempo** (or **Song Menu**) to adjust a song live:

- On-device Rubber Band R3 processing shifts key by semitones with **Preserve Vocal Formants** enabled, and dials tempo within `±20 BPM` (`0.75x–1.50x`).
- Click and Guide regenerate natively at the new tempo without pitch/time-stretch artifacts, while transformed stems cache on disk so switching back later is instant. Any song currently processing shows a progress bar directly on its setlist card without locking the UI.

---

## 10. Song Map, Non-Destructive Trimming, Click Sections & Saved Arrangements

Click **Edit** (top-right button, toggling to **Done**) to open the bottom **Edit Drawer** without altering your original audio files:

- In **Song Sections**, click `+` at the playhead to slice and label sections using presets or custom names. Removing a section divider merges the region back cleanly into the previous section while keeping all audio intact.
- Open a section's options popover (`Trim Section`) and drag handles to shorten a section in bars while keeping waveforms, cues, and transitions synchronized.
- In **Setlist / Song Map**, insert, duplicate, reorder, or remove sections, and reset anytime with **Reset to Default Song Map**.
- Insert a **Click Section** in the Song Map in either mode:
  - **Default Click:** A variable-bar vamp with Click, Guide, and Pad only (stems muted).
  - **Based on Section:** Mirrors an existing section's exact bar map, meter, and guide cues with backing stems silenced.
- Save multiple named arrangements (`Sunday Acoustic`, `Short Set`) per song in **Song Menu → Arrangement**, while keeping the original `Default` chart untouched.

---

## 11. Mid-Song Time Signature & Tempo Changes (DAW Tempo Curve)

### Mid-Song Time Signature Changes
Handle `2/4` turnarounds, `3/4` verses, or `6/8` bridges inside any song:

1. Enter **Edit → Song Sections** and park the playhead at the target bar (or click `+` on a section).
2. Click `+` on the timeline and select **Change Time Signature...**.
3. Pick a preset (`2/4`, `3/4`, `4/4`, `5/4`, `6/8`, `7/8`, `9/8`, `12/8`) or enter any custom meter.

PeanutButter updates the beat grid, measure numbering (including across multiple meter changes), Click subdivision/accent patterns, Guide count-ins, and the live Time Signature badge in the transport bar. Click any cyan meter pill on the timeline to edit or delete it directly from its anchored popover.

### Mid-Song Tempo Changes & Gradual Ritardando / Accelerando
Program instant tempo jumps or smooth musical ritardandos and accelerandos (driving the Beat Grid, Click, Guide, Transport BPM readout, 24 PPQN MIDI Beat Clock, PeanutButter Remote BPM, and Continue Click ending BPM):

1. In **Edit → Song Sections**, click `+` on the timeline and select **Change Tempo...**.
2. Choose **Instant** (with `Half-Time` / `Double` presets or exact BPM entry) or **Ramp (Rit / Acc)**:
   - **Bars / Beats mode:** Solves ramp duration mathematically so Bar 1 / Beat 1 after the ramp lands cleanly on the grid with zero fractional-beat drift.
   - **Audio End mode:** Anchors the end of the ramp to a specific audio timestamp on the waveform, with optional **Lock Beats to Audio End** (auto-solving ending BPM) or explicit target BPM.
   - **5 Curve Shapes:** **Linear**, **Ease In**, **Ease Out**, **S-Curve**, and **Custom**.
3. **Draw Tempo Curve on Waveform:** Click **Draw Tempo Curve on Waveform** inside **Change Tempo...** (or click **Tempo Curve** in the top-right of the timeline while in Song Sections, or **Draw / Edit on Waveform** on any amber tempo pill):
   - The waveform dims behind a 1:1 aligned **Tempo Curve** automation overlay with a pinned BPM Y-axis ruler.
   - Use **Pointer** mode to click the curve to add points, drag instant diamonds, ramp start/end handles, midpoint curve-tension bend handles, or custom curve waypoints.
   - Switch to **Draw** mode to sketch freehand DAW-style tempo automation curves directly over transients and barlines, with **Beat Snap** (hold `Option` to bypass), **Clear**, and **Done** (or top-right **DONE**).

---

## 12. Click Track Engine, Subdivisions & Custom Click Packs

Click tracks are generated at sample accuracy (or swapped for an uploaded click stem):

- Click the `>` arrow on the **Click** channel strip to expand dedicated **Accent**, **1/4**, **1/8**, and **1/16** faders, Solo (`S`) buttons, track-name Mute toggles, and V-synced VU meters. Subdivision toggles sync bidirectionally between the tray and Click Options.
- Built-in Playback-style subdivisions automatically adapt to song meter (including mid-song meter changes):
  - **`3/4`:** Beat 1 plays Accent (when enabled) + `1/4`, Beats 2 & 3 play `1/8`, and `"&"` midpoints play `1/16`.
  - **`6/8`:** Beat 1 plays Accent + `1/4`, Beat 4 plays `1/4`, Beats `2, 3, 5, 6` play `1/8`, and `"&"` midpoints play `1/16`.
- Choose from 7 built-in engines (*Classic (Synth)*, *Woodblock (Synth)*, *Beep / Synth*, *Sticks / Rimshot*, *Cowbell (Synth)*, *Shaker*, *Tambourine*), plus optional *Uploaded Click* stem support.
- Open **Click Options** or **Settings (`≡`) → Upload / Manage Click Samples...** to import custom `.wav`/`.m4a`/`.aiff`/`.mp3`/`.flac` files per subdivision (automatically normalized for stage headroom).

---

## 13. Spoken Guide, Custom Voices & Directional Cues

Guide cues are aligned by perceptual vowel onset with consonant-safe tails so numbers and section names lock onto the groove (and count-ins never misfire while an opening section is already playing):

- **Guide Sub-Channel Mixer Tray:** Click `>` on the **Guide** channel strip (in Tracks or Buses view) to expand per-song level faders, Mutes, Solos, and live VU meters:
  - In **App Generated** guide mode: **Sections** (including count-ins), **Directions**, and **Fallback** faders.
  - In **Uploaded Guide** mode: **Guide** and **Fallback** faders.
- **7 Bundled Human Voices + Siri/System Fallback:** Includes **Sam (Male)** (default), **Caleb (Male)**, **Claire (Female)**, **Daniel (Male)**, **Hannah (Female)**, **Marcus (Male)**, and **Maya (Female)**, plus macOS Siri/system voices if a phrase isn't pre-recorded.
- **Upload Custom Guide Voice Packs & Cue Kind Labeling:** In **Settings (`≡`) → Upload / Manage Guide Samples...**, import a folder of recordings (auto-mapped across standard cues and labeled as **Section** or **Direction**) or record/upload one phrase at a time, and switch any custom sample between **Section** and **Direction** per cue so the Guide tray routes levels accurately.
- **Toggle Numbers in Section Names:** Turn **Include Numbers in Guide** on/off globally in Settings or per section (`"Verse 2"` vs. `"Verse"`).
- **Custom Spoken Directional Cues (`Edit → Directional Cues`):** Click `+` at the playhead to drop preset cues (*Build, Breakdown, All In, Band Out, Drums In, Softly, Hits, Hold, A Cappella*, etc.) or type any custom phrase (`"Pastor Speaks"`, `"Modulate to G"`). Drag directional cues on the timeline to snap to beats, click to edit text, or nudge in `1/16`-note increments. Directional cues can also speak over an Uploaded Guide track (toggleable per song).

---

## 14. Ambient Pad Player (`LINK` Mode & Custom Pads)

Keep ambient drones running between songs or beneath prayers:

- **Full-Screen Pad Grid (`PAD PLAYER`):** Displays all 12 chromatic keys (`Db, Eb, Gb, Ab, Bb, B` / `C, D, E, F, G, A`), dedicated **Pad VU meter**, Solo (`S`), and click-title **Mute** toggle.
- **LINK ON:** Locks pad key and pack automatically to the active song (starts on playback if **Start Pad Player With Song** is enabled, and crossfades across key changes and transitions).
- **LINK OFF (Pad Key Lock):** Detaches the pad from the setlist so you can tap any key manually and lock that key across playback, scrubbing, song switches, or stopping — synced cleanly with PeanutButter Remote. Tapping `LINK` back on crossfades into the active song's key.
- **Bundled & Custom Pads:** Ships with royalty-free **Simple** and **Soft** pads across all 12 keys, plus **Custom Fade Times** (`1s–10s`, defaulting to `2.5s` in / `3.0s` out), right-click delete, and 12-key folder upload with automatic RMS loudness normalization.

---

## 15. Mixer Console, 16 Sub-Mix Buses & Hardware Routing

- Reorder stems by dragging strips, double-click faders or adjust Pan dials, and toggle Solo (`S`), Mute (`M`), and **Solo Safe** (so Click and Guide never mute when you solo an instrument).
- **Solo-Aware Waveform Preview & `CLEAR SOLOS`:** Soloing one or more stems or buses immediately updates the timeline waveform to preview only the soloed mix (always excluding Click and Guide) while preserving the full-mix waveform cache so un-soloing snaps right back. Whenever any track or bus is soloed, a **`CLEAR SOLOS`** button appears at the top of the master action bar.
- Switch the bottom view between **Faders** and **Buses** (`Click, Guide, Drums, Percussion, Loops, Bass, Piano, Keys, Electric Guitars, Acoustic Guitars, Strings, Horns, Pad, Vocals, FX, Aux`).
- Open **Settings → Configure Buses, Routing, & MIDI...** to pick your CoreAudio interface, inspect detected hardware output channels, route each of the 16 buses to any Stereo Pair (`Out 1/2`, `Out 3/4`, etc.) or Mono output (`Out 1`, `Out 2`, etc.), and reassign any stem's bus.

---

## 16. MIDI Cues, Auto-Velocity Paste, ProPresenter & MIDI Clock

Automate lighting, lyric slides, patch changes, and external gear across **8 color-coded MIDI Buses** (*Lyrics, Lights 1, Lights 2, Patches 1, Patches 2, Guitar, Aux 1, Aux 2*, defaulting to Channels `1–8`):

- In **Edit → MIDI Cues**, add **Note**, **Control Change (`CC`)**, or **Program Change (`PC`)** events on the timeline, drag them along the beat grid, nudge in `1/16`-note steps, test cues live, or set **Disable Loop** on any cue so it fires even during active loops.
- Click a section's cue menu to **Copy MIDI Cues**, then jump to another section (e.g., `Chorus 2`) and choose **Paste & Auto-Adjust Velocity** (increments Note velocities `N+1, N+2...` continuing from the previous cue on the same bus for ProPresenter slide triggers) or **Paste Original Velocities**.
- Push updated MIDI cues and ProPresenter settings back to the master `.pbsong` (Local or Cloud) or pull updates from the library via **Song Menu**.
- Configure **Playlist** (`F-1`, Note `17`) and **Playlist Item** (`F#-1`, Note `18`) in **Song Menu** to trigger ProPresenter slides when a song starts.
- In **Configure Buses, Routing, & MIDI... → MIDI Buses**, output **24 PPQN MIDI Beat Clock** (Start / Clock / Stop) synchronized continuously with song tempo, mid-song meter/tempo changes, and post-song Continue Click.
- Use **Mute MIDI** in the right sidebar to silence all outgoing MIDI cues.

---

## 17. Beat-Synced Mix & Pad Automation

Open **Edit → Automation** to record dynamic mix moves:

- Drop an **Automation Point** (`+`) at any beat or bar, drag existing points along the grid, or choose a **Transition Length** from **Instant** up to **4 Bars** (`1...4 * beatsPerBar`).
- While editing an automation point, adjusting stem faders/mutes, bus faders/mutes, **MIDI Mute**, or toggling **Pad Active / LINK** records those targets into the point.
- Gains ramp and states switch during playback, and your baseline mix is restored when stopping or jumping back.

---

## 18. SMPTE LTC Timecode & 1 kHz Redundancy Pilot Tone

- **SMPTE LTC Timecode:** Enable in **Settings (`≡`) → SMPTE**, select your frame rate and any free mono output channel, then drop, drag, or edit **SMPTE Cues** (`Edit → SMPTE`) with configurable hours/minutes/seconds offsets (`01h 00m`, `02h 00m`, etc.) and exact timeline/frame coordinates.
- **1 kHz Redundancy Tone:** Enable **Settings (`≡`) → Redundancy** and pick a free mono output channel to broadcast a continuous `1 kHz` reference sine wave for automated A/B failover hardware switchers.

---

## 19. Offline Bounce Engine (Reference & Practice Tracks)

Render full mixes offline faster than real time:

- **Session Reference Track (`Setlists Menu → Current Setlist → Export Reference Track...`):** Pick which songs from the current setlist to include (with Select All / None and per-song checkboxes) and render into **MP3 (256 kbps), M4A (AAC), or WAV (PCM)** with separate checkboxes for **Include Click Track** and **Include Guide Track**. Inserts **5-second pauses** between songs set to manual stop/cue transitions while honoring AutoLink, Overlap, and Crossfade transitions.
- **Song Practice Tracks (`Song Card ... → Export Practice Tracks...`):** Batch-renders part-dominant rehearsal files named `[Song Title] - [Instrument] - Key of [Key].[ext]`. Toggle any combination of **Electric Guitars (All), Bass, Drums, Acoustic, Piano, and Vocals**. Click/Guide and the target instrument sit at `0 dB`, other core band parts at `-10 dB`, and background tracks (synths, loops, FX, BGVs) at `-20 dB`.

---

## 20. PeanutButter Remote, MIDI/Keyboard Mapping, Hotkeys & Updates

### PeanutButter Remote (Browser Web Controller)
1. Enable **Settings (`≡`) → PeanutButter Remote**.
2. Toggle **Require Password** if you want a passcode.
3. Open the shown local URL (or Bonjour `_peanutbutter._tcp`) from any phone, tablet, or laptop on the same Wi-Fi to run Transport, **1x Loop**, **∞ Loop**, Quantized Section Jumps, Setlist Switching (showing active transposed keys and live mid-song BPM), Pad Player (`LINK` & Key Lock), and **Tracks / Buses** mixer strips with short names, pan controls, live VU meters, and stage-safe cap-only faders.
4. Switch the Remote **Timeline Display** dropdown (saved per device) between **Waveform** (live color-banded canvas with tap-to-seek when stopped and tap-to-queue while playing), **Progress Bar**, or **None** for compact screens.

### Visual MIDI & Keyboard Mapping (`Edit → MIDI Mapping` / `Keyboard Mapping`)
Click any highlighted control on screen (Transport buttons, Song cards `1–10`, Next/Prev Section, Pad toggle, Mute MIDI, Track/Bus Faders, Mutes, Solos), then press a keyboard key or send a MIDI Note/CC to bind it. Mapping a key or MIDI input already used elsewhere prompts you with **Keep Current** or **Reassign**. Use **Reset to Defaults** or **Delete All** anytime from the Keyboard Mapping panel.

### Software Updates & Builds
- Open **Settings (`≡`) → Check for Updates...** (or let the automatic startup check notify you) to download, verify (`Developer ID` + notarization), and install new GitHub Releases in place. If launched from `Downloads`, PeanutButter also offers to move itself into `/Applications`.
- Developer builds run with `./build.sh --dev` automatically stamp `-dev.N` build numbers (`1.2.0-dev.1`), while GitHub Releases ship as universal notarized `.dmg` and `.zip` packages.

### Default Keyboard Shortcuts Reference

| Shortcut | Action |
| :--- | :--- |
| **`Space`** | Play / Pause (auto-closes Edit drawer on Play) |
| **`R`** | Return to Zero |
| **`F`** | Fade Out / Fade In music stems |
| **`P`** | Toggle Ambient Pad Player |
| **`Cmd + P`** | Stop Ambient Pad immediately |
| **`←` / `→`** | Previous / Next Section |
| **`Enter`** | Select / Fire queued action |
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
