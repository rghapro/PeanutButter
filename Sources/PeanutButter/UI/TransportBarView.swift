import SwiftUI

/// Transport bar modeled directly on MultiTracks Playback's hardware-style controls
public struct TransportBarView: View {
    let playbackState: PlaybackState
    let position: TransportPosition
    let song: Song
    let isFadeActive: Bool
    let currentFadeGain: Float
    let isLoopActive: Bool
    let isPadActive: Bool
    let isSetlistOpen: Bool
    @Binding var masterVolume: Float
    
    let onPlay: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void
    let onReturnToZero: () -> Void
    let onPreviousSection: () -> Void
    let onNextSection: () -> Void
    let onToggleFade: () -> Void
    let onToggleLoop: () -> Void
    let onTogglePad: () -> Void
    let onToggleSetlist: () -> Void
    let onOpenSongBuilder: () -> Void
    let onLoadDemo: () -> Void
    let onClearSong: () -> Void
    
    public init(
        playbackState: PlaybackState,
        position: TransportPosition,
        song: Song,
        isFadeActive: Bool,
        currentFadeGain: Float,
        isLoopActive: Bool,
        isPadActive: Bool,
        isSetlistOpen: Bool,
        masterVolume: Binding<Float>,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onReturnToZero: @escaping () -> Void,
        onPreviousSection: @escaping () -> Void,
        onNextSection: @escaping () -> Void,
        onToggleFade: @escaping () -> Void,
        onToggleLoop: @escaping () -> Void,
        onTogglePad: @escaping () -> Void,
        onToggleSetlist: @escaping () -> Void,
        onOpenSongBuilder: @escaping () -> Void,
        onLoadDemo: @escaping () -> Void,
        onClearSong: @escaping () -> Void
    ) {
        self.playbackState = playbackState
        self.position = position
        self.song = song
        self.isFadeActive = isFadeActive
        self.currentFadeGain = currentFadeGain
        self.isLoopActive = isLoopActive
        self.isPadActive = isPadActive
        self.isSetlistOpen = isSetlistOpen
        self._masterVolume = masterVolume
        self.onPlay = onPlay
        self.onPause = onPause
        self.onStop = onStop
        self.onReturnToZero = onReturnToZero
        self.onPreviousSection = onPreviousSection
        self.onNextSection = onNextSection
        self.onToggleFade = onToggleFade
        self.onToggleLoop = onToggleLoop
        self.onTogglePad = onTogglePad
        self.onToggleSetlist = onToggleSetlist
        self.onOpenSongBuilder = onOpenSongBuilder
        self.onLoadDemo = onLoadDemo
        self.onClearSong = onClearSong
    }
    
    public var body: some View {
        HStack(spacing: 10) {
            // 1. Setlist Drawer Toggle (MultiTracks Style)
            Button(action: onToggleSetlist) {
                HStack(spacing: 4) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 13, weight: .bold))
                    Text("SETLIST")
                        .font(.system(size: 9, weight: .black))
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(isSetlistOpen ? Color.blue : Color(white: 0.18))
                .foregroundColor(.white)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help("Toggle Setlist Drawer (Shortcut: S)")
            
            Divider()
                .frame(height: 34)
                .background(Color(white: 0.22))
            
            // 2. Playback Transport Cluster
            HStack(spacing: 4) {
                // RTZ (Return to Zero)
                Button(action: onReturnToZero) {
                    VStack(spacing: 1) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("RTZ")
                            .font(.system(size: 7, weight: .black))
                    }
                    .frame(width: 38, height: 38)
                    .background(Color(white: 0.18))
                    .foregroundColor(Color(white: 0.85))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Return to Zero (Shortcut: R / Backspace)")
                
                // Previous Section
                Button(action: onPreviousSection) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 36, height: 38)
                        .background(Color(white: 0.18))
                        .foregroundColor(Color(white: 0.85))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Previous section (Left Arrow)")
                
                // Big Play / Pause Button (MultiTracks Signature Blue Button)
                Button(action: {
                    if playbackState == .playing {
                        onPause()
                    } else {
                        onPlay()
                    }
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        playbackState == .playing ? Color(red: 0.95, green: 0.55, blue: 0.15) : Color(red: 0.10, green: 0.55, blue: 0.95),
                                        playbackState == .playing ? Color(red: 0.85, green: 0.40, blue: 0.10) : Color(red: 0.05, green: 0.40, blue: 0.85)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color.black.opacity(0.4), radius: 3, y: 1)
                        
                        Image(systemName: playbackState == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(.white)
                    }
                    .frame(width: 52, height: 38)
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space bar)")
                
                // Stop Button
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 36, height: 38)
                        .background(Color(white: 0.18))
                        .foregroundColor(Color(white: 0.85))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Stop")
                
                // Next Section
                Button(action: onNextSection) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 36, height: 38)
                        .background(Color(white: 0.18))
                        .foregroundColor(Color(white: 0.85))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Next section (Right Arrow)")
            }
            
            // 3. Performance Action Buttons (FADE, LOOP, PAD)
            HStack(spacing: 4) {
                // MultiTracks Signature "FADE" Button
                Button(action: onToggleFade) {
                    VStack(spacing: 2) {
                        Image(systemName: "waveform.path.badge.minus")
                            .font(.system(size: 11, weight: .bold))
                        Text(isFadeActive ? "FADING" : "FADE")
                            .font(.system(size: 8, weight: .black))
                    }
                    .frame(width: 48, height: 38)
                    .background(isFadeActive ? Color(red: 0.92, green: 0.40, blue: 0.10) : Color(white: 0.18))
                    .foregroundColor(isFadeActive ? .white : Color(white: 0.85))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isFadeActive ? Color.yellow : Color.clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Fade Out tracks while keeping Click and Guide (Shortcut: F)")
                
                // Section Loop Button
                Button(action: onToggleLoop) {
                    VStack(spacing: 2) {
                        Image(systemName: "repeat")
                            .font(.system(size: 11, weight: .bold))
                        Text("LOOP")
                            .font(.system(size: 8, weight: .black))
                    }
                    .frame(width: 44, height: 38)
                    .background(isLoopActive ? Color(red: 0.96, green: 0.65, blue: 0.14) : Color(white: 0.18))
                    .foregroundColor(isLoopActive ? .black : Color(white: 0.85))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Loop current section (Shortcut: L)")
            }
            
            Divider()
                .frame(height: 34)
                .background(Color(white: 0.22))
            
            // 4. Digital Counters (Time & Bar.Beat)
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("TIME")
                        .font(.system(size: 7, weight: .black))
                        .foregroundColor(Color(white: 0.5))
                    Text(position.timeString)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.2, green: 0.95, blue: 0.45))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .cornerRadius(4)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("BAR.BEAT")
                        .font(.system(size: 7, weight: .black))
                        .foregroundColor(Color(white: 0.5))
                    Text(position.barBeatString)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.2, green: 0.85, blue: 1.0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .cornerRadius(4)
            }
            
            Spacer()
            
            // 5. Interactive Key & Tempo Badges (Clickable to Edit!)
            HStack(spacing: 6) {
                Button(action: onOpenSongBuilder) {
                    HStack(spacing: 6) {
                        Text("KEY: \(song.musicalKey)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%.0f BPM", song.bpm))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(.yellow)
                        
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.6))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color(white: 0.18))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Change Song Key & Tempo (Shortcut: E)")
                
                // Edit Song Builder Button
                Button(action: onOpenSongBuilder) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("Edit Song")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Open Song & Section Builder Submenu")
            }
            
            Divider()
                .frame(height: 34)
                .background(Color(white: 0.22))
            
            // 6. Demo & Clear Action Buttons
            HStack(spacing: 5) {
                Button(action: onLoadDemo) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                        Text("Demo")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(Color(red: 0.35, green: 0.25, blue: 0.65))
                    .foregroundColor(.white)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Load Demo multitrack audio")
                
                Button(action: onClearSong) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Color(white: 0.18))
                        .foregroundColor(Color(white: 0.65))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Clear all song audio stems")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(white: 0.11))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(white: 0.18)),
            alignment: .bottom
        )
    }
}
