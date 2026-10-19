import SwiftUI
import UnnamedKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                if let store = model.store {
                    MainView(store: store)
                } else if !model.isOpening {
                    OnboardingView()
                }
            }
            // Shown at launch, and while switching to another library.
            if !model.launchScreenFinished || (model.isOpening && model.store == nil) {
                LaunchScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.5), value: model.isOpening)
        .task {
            guard !model.launchScreenFinished else { return }
            // Hold the launch screen briefly and until the library is open, then fade.
            let minimum: Duration = reduceMotion ? .zero : .milliseconds(1100)
            async let opened: Void = model.start()
            try? await Task.sleep(for: minimum)
            await opened
            withAnimation(.easeOut(duration: 0.6)) { model.launchScreenFinished = true }
        }
    }
}

/// A single spinning disc while the app starts.
private struct LaunchScreen: View {
    var body: some View {
        ZStack {
            SpinningDiscsView(arrangement: .single)
            VStack {
                Spacer()
                Text("Unnamed")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 64)
            }
        }
        .ignoresSafeArea()
    }
}

/// First launch: choose where the library lives, over a field of spinning CDs.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var timeOffset: TimeInterval = 0

    var body: some View {
        ZStack {
            SpinningDiscsView(arrangement: .scattered, timeOffset: timeOffset)
                .ignoresSafeArea()
            // A soft dark pool behind the text keeps it readable over the discs.
            Ellipse()
                .fill(.black.opacity(0.5))
                .frame(width: 760, height: 560)
                .blur(radius: 90)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                Text("Welcome to Unnamed")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 18)
                Text("A home for your music ideas. Your library is a plain folder you own. Put it in iCloud Drive and it syncs to your other devices through your own iCloud account. No servers, no subscriptions, no training on your music.")
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

                VStack(spacing: 10) {
                    Button {
                        model.createLibraryInICloud()
                    } label: {
                        Label("Create Library in iCloud Drive…", systemImage: "icloud")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 290, height: 44)
                            .background(Capsule().fill(.white))
                            .foregroundStyle(.black)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.chooseExistingLibrary()
                    } label: {
                        Text(model.reconnectPath == nil ? "Open Existing Library…" : "Reconnect Library…")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 290, height: 44)
                            .background(Capsule().fill(.white.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 30)

                Text("Not using iCloud? Choose any folder; it just won't sync.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 16)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

struct IdentifiedID: Identifiable, Hashable {
    let id: UUID
}
