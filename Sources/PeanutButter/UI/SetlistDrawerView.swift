import SwiftUI

/// Slide-in setlist drawer modeled directly on MultiTracks Playback
public struct SetlistDrawerView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let onClose: () -> Void
    let onOpenSongBuilder: () -> Void
    
    @State private var isCreatingNewSong: Bool = false
    @State private var newSongTitle: String = ""
    @State private var newSongArtist: String = ""
    
    public init(engine: MultitrackAudioEngine, onClose: @escaping () -> Void, onOpenSongBuilder: @escaping () -> Void) {
        self.engine = engine
        self.onClose = onClose
        self.onOpenSongBuilder = onOpenSongBuilder
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.blue)
                        Text(engine.currentSetlist.name.uppercased())
                            .font(.system(size: 13, weight: .black))
                            .foregroundColor(.white)
                    }
                    
                    Text("\(engine.currentSetlist.totalSongsCount) SONGS • \(engine.currentSetlist.totalDurationFormatted)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                }
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(white: 0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color(white: 0.13))
            
            Divider()
                .background(Color(white: 0.22))
            
            // Songs List
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(engine.currentSetlist.songs.enumerated()), id: \.element.id) { index, song in
                        let isSelected = index == engine.currentSongIndex
                        
                        Button(action: {
                            engine.selectSongInSetlist(at: index)
                        }) {
                            HStack(spacing: 10) {
                                // Playing Indicator or Number
                                ZStack {
                                    if isSelected {
                                        Circle()
                                            .fill(Color.blue)
                                            .frame(width: 22, height: 22)
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                    } else {
                                        Circle()
                                            .fill(Color(white: 0.18))
                                            .frame(width: 22, height: 22)
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .black, design: .monospaced))
                                            .foregroundColor(Color(white: 0.6))
                                    }
                                }
                                
                                // Song Title & Artist
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.system(size: 13, weight: isSelected ? .black : .bold))
                                        .foregroundColor(isSelected ? .white : Color(white: 0.85))
                                        .lineLimit(1)
                                    
                                    Text(song.artist)
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                
                                Spacer()
                                
                                // Key & Tempo Badges
                                HStack(spacing: 4) {
                                    Text(song.musicalKey)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(white: 0.8))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color(white: 0.16))
                                        .cornerRadius(3)
                                    
                                    Text(String(format: "%.0f", song.bpm))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.yellow.opacity(0.85))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color(white: 0.16))
                                        .cornerRadius(3)
                                }
                                
                                // Action Menu (Edit / Remove)
                                Menu {
                                    Button("Edit Song & Sections...") {
                                        engine.selectSongInSetlist(at: index)
                                        onOpenSongBuilder()
                                    }
                                    if index > 0 {
                                        Button("Move Up") {
                                            var songs = engine.currentSetlist.songs
                                            songs.swapAt(index, index - 1)
                                            engine.currentSetlist.songs = songs
                                            engine.markSessionChanged()
                                        }
                                    }
                                    if index < engine.currentSetlist.songs.count - 1 {
                                        Button("Move Down") {
                                            var songs = engine.currentSetlist.songs
                                            songs.swapAt(index, index + 1)
                                            engine.currentSetlist.songs = songs
                                            engine.markSessionChanged()
                                        }
                                    }
                                    Divider()
                                    Button("Remove from Setlist", role: .destructive) {
                                        engine.currentSetlist.songs.remove(at: index)
                                        engine.markSessionChanged()
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Color(white: 0.4))
                                        .frame(width: 16, height: 16)
                                }
                                .menuStyle(.borderlessButton)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color(white: 0.16) : Color(white: 0.10))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? Color.blue.opacity(0.8) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            
            Divider()
                .background(Color(white: 0.22))
            
            // Footer: Add Song to Setlist Button
            HStack {
                Button(action: {
                    _ = engine.beginBuildingNewSong()
                    onOpenSongBuilder()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Song to Setlist")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(white: 0.11))
        }
        .frame(width: 320)
        .background(Color(white: 0.09))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(white: 0.22)),
            alignment: .trailing
        )
    }
}
