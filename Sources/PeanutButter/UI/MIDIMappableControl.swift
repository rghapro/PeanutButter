import SwiftUI

/// Small white badge showing assigned MIDI channel and note (e.g. "16/C#-2")
public struct MIDIMappingBadgeView: View {
    let text: String
    
    public init(text: String) {
        self.text = text
    }
    
    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Color.white)
            .cornerRadius(3)
            .shadow(color: Color.black.opacity(0.85), radius: 2, x: 0, y: 1)
    }
}

/// Generic wrapper that gives any button or control the MultiTracks Playback Mapping style:
/// - Blue fill & outline in MIDI Mapping mode
/// - Orange fill & outline in Keyboard Mapping mode
/// - Bright white highlight when selected / awaiting input
/// - White bubble at top-right showing assigned MIDI note/CC or Keyboard key
/// - Intercepts clicks in mapping mode to select for MIDI/Keyboard learning
public struct MIDIMappableButton<Content: View>: View {
    @ObservedObject private var midiManager = MIDIMappingManager.shared
    @ObservedObject private var keyboardManager = KeyboardMappingManager.shared
    let targetId: String
    let isMappingMode: Bool
    var cornerRadius: CGFloat = 4
    var badgeOffset: CGPoint = CGPoint(x: 4, y: -6)
    var executeActionInMappingMode: Bool = false
    var normalAction: () -> Void
    @ViewBuilder let content: () -> Content
    
    public init(
        targetId: String,
        isMappingMode: Bool,
        cornerRadius: CGFloat = 4,
        badgeOffset: CGPoint = CGPoint(x: 4, y: -6),
        executeActionInMappingMode: Bool = false,
        action: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.targetId = targetId
        self.isMappingMode = isMappingMode
        self.cornerRadius = cornerRadius
        self.badgeOffset = badgeOffset
        self.executeActionInMappingMode = executeActionInMappingMode
        self.normalAction = action
        self.content = content
    }
    
    private var isKeyboardMode: Bool {
        if let eng = keyboardManager.engine {
            return eng.isEditKeyboardMappingMode
        }
        return false
    }
    
    private var isMIDIMode: Bool {
        if let eng = midiManager.engine {
            return eng.isEditMIDIMappingMode
        }
        return isMappingMode
    }
    
    private var activeMode: Bool {
        isKeyboardMode || isMIDIMode || isMappingMode
    }
    
    private var isSelected: Bool {
        if isKeyboardMode {
            return keyboardManager.selectedTargetId == targetId
        } else if isMIDIMode || isMappingMode {
            return midiManager.selectedTargetId == targetId
        }
        return false
    }
    
    private var badgeText: String? {
        if isKeyboardMode {
            return keyboardManager.mapping(for: targetId)?.displayString
        } else if isMIDIMode || isMappingMode {
            return midiManager.mapping(for: targetId)?.displayString
        }
        return nil
    }
    
    private var unselectedFillColor: Color {
        if isKeyboardMode {
            return Color(red: 0.50, green: 0.25, blue: 0.08) // Warm dark orange
        }
        return Color(red: 0.16, green: 0.28, blue: 0.42) // Dark blue
    }
    
    private var unselectedStrokeColor: Color {
        if isKeyboardMode {
            return Color(red: 0.95, green: 0.52, blue: 0.15) // Bright orange highlight
        }
        return Color(red: 0.28, green: 0.50, blue: 0.75) // Bright blue highlight
    }
    
    public var body: some View {
        Button(action: {
            if isKeyboardMode {
                keyboardManager.selectTarget(targetId)
                if executeActionInMappingMode {
                    normalAction()
                }
            } else if isMIDIMode || isMappingMode {
                midiManager.selectTarget(targetId)
                if executeActionInMappingMode {
                    normalAction()
                }
            } else {
                normalAction()
            }
        }) {
            content()
                .background(
                    Group {
                        if activeMode {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(isSelected ? Color.white : unselectedFillColor)
                        }
                    }
                )
                .overlay(
                    Group {
                        if activeMode {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(isSelected ? Color.white : unselectedStrokeColor, lineWidth: 1.5)
                        }
                    }
                )
                .foregroundColor(isSelected ? .black : nil)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // White assigned bubble badge (MIDI note/CC or Keyboard key) without distorting button layout bounds
            if activeMode, let text = badgeText, !isSelected {
                MIDIMappingBadgeView(text: text)
                    .offset(x: badgeOffset.x, y: badgeOffset.y)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Song card view used in MIDI mapping mode carousel
public struct MIDIMappingSongCardView: View {
    let index: Int
    let song: Song?
    let onSelect: () -> Void
    
    public init(index: Int, song: Song?, onSelect: @escaping () -> Void) {
        self.index = index
        self.song = song
        self.onSelect = onSelect
    }
    
    public var body: some View {
        MIDIMappableButton(
            targetId: "song_card_\(index)",
            isMappingMode: true,
            cornerRadius: 6,
            badgeOffset: CGPoint(x: 4, y: -6),
            executeActionInMappingMode: true,
            action: onSelect
        ) {
            VStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                
                if let s = song {
                    HStack(spacing: 3) {
                        Text(s.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(white: 0.90))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !s.musicalKey.isEmpty {
                            Text("(\(s.musicalKey))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.90))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.35))
                    .cornerRadius(3)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.25))
                        .frame(height: 18)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 8)
            .frame(width: 175, height: 62)
        }
    }
}
