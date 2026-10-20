import SwiftUI
import UnnamedKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let launching = !model.launchScreenFinished
        // Switching to another library later shows the same screen.
        let switching = !launching && model.isOpening && model.store == nil
        ZStack {
            // Nothing is built under the launch screen, so nothing shows
            // through it; the app appears as it fades away.
            if !launching {
                if let store = model.store {
                    MainView(store: store)
                } else if !model.isOpening {
                    OnboardingView()
                }
            }
            if launching || switching {
                LaunchScreen()
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.08))))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.45), value: switching)
        // The dark screens run edge to edge, under the title bar.
        .toolbarBackgroundVisibility(model.store == nil || launching ? .hidden : .automatic, for: .windowToolbar)
        .task {
            guard launching else { return }
            // Hold the launch screen briefly and until the library is open, then fade.
            let minimum: Duration = reduceMotion ? .zero : .milliseconds(1200)
            async let opened: Void = model.start()
            try? await Task.sleep(for: minimum)
            await opened
            withAnimation(.easeOut(duration: 0.55)) { model.launchScreenFinished = true }
        }
    }
}

/// A spinning CD and the wordmark while the app starts.
struct LaunchScreen: View {
    /// Shows the "Opening your library…" line straight away (for snapshots).
    var alwaysShowsStatus = false
    @State private var showsStatus = false

    var body: some View {
        ZStack {
            Rectangle().fill(SpinningDiscsView.backdrop)
            VStack(spacing: 14) {
                ShaderDiscView(radius: 0.42, speed: 0.9)
                    .frame(width: 250, height: 250)
                Text("Unnamed")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                // Only if opening takes a while (a big library, or iCloud is slow).
                Text("Opening your library…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .opacity(showsStatus || alwaysShowsStatus ? 1 : 0)
            }
            .padding(.bottom, 20)
        }
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.4)) { showsStatus = true }
        }
    }
}

/// First launch: choose where the library lives, over a field of spinning CDs.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.liquidGlass) private var glass
    var timeOffset: TimeInterval = 0

    var body: some View {
        ZStack {
            SpinningDiscsView(timeOffset: timeOffset)
                .ignoresSafeArea()
            if !glass {
                // A soft dark pool behind the text keeps it readable over the discs.
                Ellipse()
                    .fill(.black.opacity(0.5))
                    .frame(width: 760, height: 560)
                    .blur(radius: 90)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                Text("Welcome to Unnamed")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 18)
                Text("A home for your music ideas. Your library is a plain folder you own: no servers, no subscriptions, no training on your music.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                    .padding(.top, 12)

                if let path = model.reconnectPath {
                    Label {
                        Text("Couldn't reopen the library at \(path). Choose the folder again to reconnect.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: 500)
                    .background(.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 20)
                }

                // iCloud Drive first: it syncs with nothing else to install.
                VStack(spacing: 10) {
                    Button {
                        model.createLibraryInICloud()
                    } label: {
                        Label("Create Library in iCloud Drive…", systemImage: "icloud")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 320, height: 46)
                            .background(Capsule().fill(.white))
                            .foregroundStyle(.black)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if iCloudDriveIsOn {
                        Text("Recommended. Syncs to your other Macs through your own iCloud account.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(glass ? 0.7 : 0.6))
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.icloud")
                            Text("iCloud Drive is off on this Mac.")
                            Button("Turn It On…") { model.openICloudSettings() }
                                .buttonStyle(.link)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.top, 30)

                HStack(spacing: 10) {
                    secondaryButton("Use Another Folder…") { model.createLibraryInAnotherFolder() }
                    secondaryButton(model.reconnectPath == nil ? "Open Existing Library…" : "Reconnect Library…") { model.chooseExistingLibrary() }
                }
                .padding(.top, 22)

                Text("Dropbox, Google Drive, OneDrive, Syncthing, Nextcloud: a library in a folder they keep syncs through them. Anywhere else, it stays on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(glass ? 0.6 : 0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 12)
            }
            .padding(40)
            // In Liquid Glass mode the welcome sits on a slab of glass, with
            // the CDs bending through its edges.
            .glassOr(glass, in: RoundedRectangle(cornerRadius: 40, style: .continuous), tint: .black.opacity(0.25), classic: Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private var iCloudDriveIsOn: Bool {
        LibraryLocation.iCloudDriveIsAvailable
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 205, height: 40)
                .background(Capsule().fill(.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(.white.opacity(glass ? 0.28 : 0.2)))
                .foregroundStyle(.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IdentifiedID: Identifiable, Hashable {
    let id: UUID
}
