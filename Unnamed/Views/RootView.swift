import SwiftUI
import UnnamedKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let store = model.store {
                MainView(store: store)
            } else if model.isOpening {
                ProgressView("Opening library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OnboardingView()
            }
        }
        .task { await model.start() }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("Welcome to Unnamed")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 18)
            Text("A home for your music ideas. Your library is a plain folder you own — put it in iCloud Drive and it syncs to your other devices through your own iCloud account. No servers, no subscriptions, no training on your music.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.top, 12)

            if let path = model.reconnectPath {
                Label {
                    Text("Couldn't reopen the library at \(path). Choose the folder again to reconnect.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.system(size: 13))
                .padding(12)
                .frame(maxWidth: 520)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 20)
            }

            VStack(spacing: 10) {
                Button {
                    model.createLibraryInICloud()
                } label: {
                    Label("Create Library in iCloud Drive…", systemImage: "icloud")
                        .frame(width: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    model.chooseExistingLibrary()
                } label: {
                    Text(model.reconnectPath == nil ? "Open Existing Library…" : "Reconnect Library…")
                        .frame(width: 280)
                }
                .controlSize(.large)
            }
            .padding(.top, 28)

            Text("Not using iCloud? Choose any folder — it just won't sync.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct IdentifiedID: Identifiable, Hashable {
    let id: UUID
}
