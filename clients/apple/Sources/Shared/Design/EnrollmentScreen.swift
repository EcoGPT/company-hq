import SwiftUI

/// Shared sign-in layout keeps both clients on the same palette and hierarchy.
struct EnrollmentScreen: View {
    @Environment(AppStore.self) private var store
    @State private var server = HQConfig.savedServer ?? ""
    @State private var key = ""
    @State private var name = ""
    @State private var isWorking = false
    @FocusState private var focus: Field?

    private enum Field { case server, key, name }

    private var canJoin: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Tokens.Space.x5) {
                    VStack(spacing: Tokens.Space.x3) {
                        Image("HQLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        Text("Welcome to HQ")
                            .font(.title.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.ink)
                        Text("Sign in with your team access key.")
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: Tokens.Space.x3) {
                        input("Server", text: $server, field: .server)
                        input("Access key", text: $key, field: .key)
                        input("Your name", text: $name, field: .name)
                        Text("The server is your team's HQ address, for example hq.example.com. Already joined? You can leave your name blank.")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .hqGlassContainer()
                    if let error = store.enrollmentError {
                        Text(error)
                            .font(Tokens.Typography.meta)
                            .foregroundStyle(Tokens.Palette.danger)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("enrollment-error")
                    }
                    Button(action: join) {
                        HStack(spacing: Tokens.Space.x2) {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(isWorking ? "Joining…" : "Join HQ")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .font(Tokens.Typography.button)
                        .foregroundStyle(Tokens.Palette.actionInk)
                        .hqGlass(in: RoundedRectangle(cornerRadius: 16),
                                 tint: Tokens.Palette.action, interactive: true)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canJoin)
                }
                .frame(maxWidth: 360)
                .padding(Tokens.Space.x5)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .background(Tokens.Palette.surface.ignoresSafeArea())
        .tint(Tokens.Palette.accent)
    }

    private func input(_ label: String, text: Binding<String>, field: Field) -> some View {
        TextField(label, text: text, prompt: Text(label).foregroundStyle(Tokens.Palette.inkSecondary))
            .textFieldStyle(.plain)
            .font(Tokens.Typography.row)
            .foregroundStyle(Tokens.Palette.ink)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(field == .name ? .words : .never)
            .submitLabel(field == .name ? .go : .next)
            .keyboardType(field == .server ? .URL : .default)
            #endif
            .focused($focus, equals: field)
            .onSubmit {
                switch field {
                case .server: focus = .key
                case .key: focus = .name
                case .name: if canJoin { join() }
                }
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
            .frame(minHeight: 48)
            .hqComposerGlass(in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(focus == field ? Tokens.Palette.accent : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(label)
            .disabled(isWorking)
    }

    private func join() {
        guard canJoin else { return }
        isWorking = true
        focus = nil
        Task {
            await store.enroll(server: server, key: key, personName: name)
            isWorking = false
        }
    }
}
