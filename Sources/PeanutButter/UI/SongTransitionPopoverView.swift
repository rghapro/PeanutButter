import SwiftUI

/// Popover menu for configuring transitions between songs or at the end of the setlist
public struct SongTransitionPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let songIndex: Int
    let onDismiss: () -> Void
    
    @State private var hoveredRow: String? = nil
    
    private var isLastSong: Bool {
        songIndex >= engine.currentSetlist.songs.count - 1
    }
    
    private var currentSong: Song? {
        guard songIndex >= 0 && songIndex < engine.currentSetlist.songs.count else { return nil }
        return engine.currentSetlist.songs[songIndex]
    }
    
    private var currentTransition: SongTransitionType {
        currentSong?.transitionType ?? .cueNextSong
    }
    
    /// Continue Pad is only available when one of the transitions physically above it is selected
    /// (Cue Next Song, Cue First Song, or Stay In Song). It is not available for AutoLink, Overlap, or Crossfade.
    private var isContinuePadAvailable: Bool {
        if isLastSong {
            return true
        } else {
            return currentTransition == .cueNextSong || currentTransition == .stayInSong
        }
    }
    
    private var continuePadBinding: Binding<Bool> {
        Binding(
            get: {
                if !isContinuePadAvailable { return false }
                return currentSong?.continuePad ?? false
            },
            set: { newValue in
                guard isContinuePadAvailable else { return }
                engine.updateSongContinuePad(at: songIndex, continuePad: newValue)
            }
        )
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isLastSong {
                // Last Song Menu (Screenshot #3)
                transitionOptionRow(
                    id: "cueFirstSong",
                    icon: "arrow.uturn.backward",
                    title: "Cue First Song",
                    isSelected: currentTransition != .stayInSong
                ) {
                    engine.updateSongTransition(at: songIndex, type: .cueFirstSong)
                    onDismiss()
                }
                
                transitionOptionRow(
                    id: "stayInSong",
                    icon: "arrow.right.to.line",
                    title: "Stay In Song",
                    isSelected: currentTransition == .stayInSong
                ) {
                    engine.updateSongTransition(at: songIndex, type: .stayInSong)
                    onDismiss()
                }
                
                Divider()
                    .background(Color.white.opacity(0.12))
                    .padding(.vertical, 4)
                
                continuePadRow
            } else {
                // Inter-Song Transition Menu (Screenshot #2)
                transitionOptionRow(
                    id: "cueNextSong",
                    icon: "arrow.right",
                    title: "Cue Next Song",
                    isSelected: currentTransition == .cueNextSong
                ) {
                    engine.updateSongTransition(at: songIndex, type: .cueNextSong)
                    onDismiss()
                }
                
                transitionOptionRow(
                    id: "stayInSong",
                    icon: "arrow.right.to.line",
                    title: "Stay In Song",
                    isSelected: currentTransition == .stayInSong
                ) {
                    engine.updateSongTransition(at: songIndex, type: .stayInSong)
                    onDismiss()
                }
                
                Divider()
                    .background(Color.white.opacity(0.12))
                    .padding(.vertical, 4)
                
                continuePadRow
                
                Divider()
                    .background(Color.white.opacity(0.12))
                    .padding(.vertical, 4)
                
                transitionOptionRow(
                    id: "autoLink",
                    icon: "link",
                    title: "AutoLink",
                    isSelected: currentTransition == .autoLink
                ) {
                    engine.updateSongTransition(at: songIndex, type: .autoLink)
                    engine.updateSongContinuePad(at: songIndex, continuePad: false)
                    onDismiss()
                }
                
                transitionOptionRow(
                    id: "overlap",
                    icon: "rectangle.on.rectangle",
                    title: "Overlap",
                    isSelected: currentTransition == .overlap
                ) {
                    engine.updateSongTransition(at: songIndex, type: .overlap)
                    engine.updateSongContinuePad(at: songIndex, continuePad: false)
                    onDismiss()
                }
                
                transitionOptionRow(
                    id: "crossfade",
                    icon: "shuffle",
                    title: "Crossfade",
                    isSelected: currentTransition == .crossfade
                ) {
                    engine.updateSongTransition(at: songIndex, type: .crossfade)
                    engine.updateSongContinuePad(at: songIndex, continuePad: false)
                    onDismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 215)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }
    
    // MARK: - Row Components
    
    private func transitionOptionRow(
        id: String,
        icon: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .frame(width: 18, alignment: .center)
                
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.28, green: 0.58, blue: 0.98))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hoveredRow == id ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            if isHovered {
                hoveredRow = id
            } else if hoveredRow == id {
                hoveredRow = nil
            }
        }
    }
    
    private var continuePadRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isContinuePadAvailable ? Color(red: 0.25, green: 0.88, blue: 0.45) : Color.white.opacity(0.25))
                .frame(width: 18, alignment: .center)
            
            Text("Continue Pad")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(isContinuePadAvailable ? .white : .white.opacity(0.35))
            
            Spacer()
            
            Toggle("", isOn: continuePadBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.75)
                .disabled(!isContinuePadAvailable)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(isContinuePadAvailable ? 1.0 : 0.45)
    }
}
