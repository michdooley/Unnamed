import SwiftUI
import UnnamedKit

/// The collection's songs, down the left. Drag one onto the board to place
/// it; click one that's already there to fly to it.
struct BoardTray: View {
    let model: BoardModel
    @Environment(AppModel.self) private var app
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        let songs = model.songs
        let unplaced = songs.filter { $0.item == nil }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Songs").font(.system(size: 13, weight: .semibold))
                    Text(unplaced == 0 ? "All on the board" : "\(unplaced) to place")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if unplaced > 0 {
                    Button("Place All") { model.placeAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassOr(glass, in: Capsule(), interactive: true, classic: Color.primary.opacity(0.08))
                        .help("Lay out the songs that aren't on the board yet")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.track.id) { index, song in
                        TrayRow(model: model, track: song.track, number: index + 1, placed: song.item != nil)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            Text(songs.isEmpty ? "This collection has no songs yet." : "Drag a song onto the board")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(width: 232)
        .glassOr(glass, in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                 classic: model.isDark ? Color(white: 0.1).opacity(0.88) : Color.white.opacity(0.9))
    }
}

private struct TrayRow: View {
    let model: BoardModel
    let track: Track
    let number: Int
    let placed: Bool
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let art = app.artwork(forTrack: track.id, in: model.collectionID)
        let playing = app.player.currentTrackID == track.id
        HStack(spacing: 10) {
            ArtworkView(url: art.url, seed: art.seed, cornerRadius: 15, pixelSize: 80)
                .frame(width: 30, height: 30)
                .overlay(Circle().fill(.background.opacity(0.85)).frame(width: 6, height: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12.5, weight: playing ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(number)  ·  \(Format.clock(track.duration))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if placed {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("On the board")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .opacity(placed ? 0.62 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(placed ? .link : .grabIdle)
        .onTapGesture {
            if placed, let item = model.placement(of: track.id) {
                model.selection = [item.id]
                model.fly(to: model.rect(item), maxZoom: 1.2)
            } else {
                model.place(track.id, cardCenteredAt: model.usableCenter)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(BoardSpace.name))
                .onChanged { model.trayDragChanged(track.id, location: $0.location) }
                .onEnded { model.trayDragEnded(track.id, location: $0.location) }
        )
        .help(placed ? "Show it on the board" : "Drag onto the board, or click to place it in the middle")
    }
}

enum BoardSpace {
    static let name = "moodboard"
}

/// What's being dragged out of the tray.
struct TrayDragGhost: View {
    let track: Track
    @Environment(AppModel.self) private var app
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        let art = app.artwork(forTrack: track.id, in: nil)
        HStack(spacing: 8) {
            ArtworkView(url: art.url, seed: art.seed, cornerRadius: 14, pixelSize: 80)
                .frame(width: 28, height: 28)
            Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 40)
        .glassOr(glass, in: Capsule(), classic: Color(white: 0.15).opacity(0.9))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .allowsHitTesting(false)
    }
}

/// The floating toolbar: tools, background, zoom, and the journey.
struct BoardToolbar: View {
    let model: BoardModel
    @Environment(\.liquidGlass) private var glass
    @State private var choosingBackground = false

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(model: model, tool: .select, systemImage: "cursorarrow", help: "Select and move (V)")
            ToolButton(model: model, tool: .draw, systemImage: "pencil.tip", help: "Draw (D)")
            ToolButton(model: model, tool: .text, systemImage: "textformat", help: "Text (T): click to place")
            BarButton(systemImage: "photo.on.rectangle.angled", help: "Add pictures or videos…") { model.chooseMedia() }
            if model.tool == .draw {
                HStack(spacing: 4) {
                    ForEach(BoardColor.inks, id: \.self) { ink in
                        Button { model.penColor = ink } label: {
                            Circle()
                                .fill(BoardColor.color(ink))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(model.penColor == ink ? 0.9 : 0.2), lineWidth: model.penColor == ink ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
            divider
            Button { choosingBackground.toggle() } label: {
                Circle()
                    .fill(BoardColor.color(model.background))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Background colour")
            .popover(isPresented: $choosingBackground, arrowEdge: .bottom) {
                BackgroundPicker(model: model)
            }
            BarButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
            divider
            BarButton(systemImage: "minus.magnifyingglass", help: "Zoom out (⌘−)") { model.zoomStep(0.8) }
            Button { model.fit() } label: {
                Text("\(model.zoomPercent)%")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit everything (⌘0)")
            BarButton(systemImage: "plus.magnifyingglass", help: "Zoom in (⌘=)") { model.zoomStep(1.25) }
            divider
            Button { model.playJourney() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.isJourneyPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(model.isJourneyPlaying ? "Pause" : "Play Journey")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassOr(glass, in: Capsule(), tint: Color.accentColor.opacity(0.75), interactive: true, classic: Color.accentColor)
            .foregroundStyle(.white)
            .disabled(model.journey.isEmpty)
            .help("Play the songs on the board in order, and travel along their threads")
            BarButton(systemImage: model.following ? "scope" : "location", help: model.following ? "Stop following the music" : "Follow the music") {
                model.following ? model.stopFollowing() : model.startFollowing()
            }
            .foregroundStyle(model.following ? Color.accentColor : .primary)
        }
        .padding(4)
        .glassOr(glass, in: Capsule(), classic: model.isDark ? Color(white: 0.1).opacity(0.9) : Color.white.opacity(0.92))
        .animation(.spring(duration: 0.3), value: model.tool)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 3)
    }
}

private struct ToolButton: View {
    let model: BoardModel
    let tool: BoardModel.Tool
    let systemImage: String
    let help: String

    var body: some View {
        let active = model.tool == tool
        Button { model.tool = tool } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .background(Capsule().fill(active ? Color.accentColor.opacity(0.9) : .clear))
                .foregroundStyle(active ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct BarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct BackgroundPicker: View {
    let model: BoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(BoardColor.presets, id: \.self) { hex in
                    Button { model.setBackground(hex) } label: {
                        Circle()
                            .fill(BoardColor.color(hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(model.background == hex ? 0.9 : 0.2), lineWidth: model.background == hex ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Any colour", selection: Binding(
                get: { BoardColor.color(model.background) },
                set: { model.setBackground(BoardColor.hex($0)) }
            ), supportsOpacity: false)
            .font(.system(size: 12))
        }
        .padding(16)
    }
}

/// Shown on an empty board.
struct BoardWelcome: View {
    let model: BoardModel
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("A moodboard for this collection")
                .font(.system(size: 19, weight: .semibold))
            Text("Drag songs from the left onto the board. Each one is a thread with its waveform along it: pull a thread to bend it, and lay the songs out like a journey. Drop in pictures and videos, write and draw around them. Then press Play Journey and travel along the threads as the music plays.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Place All Songs") { model.placeAll() }
                    .disabled(model.songs.isEmpty)
                Button("Add Pictures or Videos…") { model.chooseMedia() }
            }
            .controlSize(.large)
            Text("⌘-scroll or pinch to zoom · scroll to move around · drag with the middle button to pan")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(28)
        .glassOr(glass, in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                 classic: model.isDark ? Color(white: 0.1).opacity(0.9) : Color.white.opacity(0.92))
    }
}
