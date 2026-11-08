import SwiftUI

/// Anmeldung am eigenen PinePods-Server (statt Apple Account)
struct LoginView: View {
    @Environment(LibraryStore.self) private var library
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var retrying = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case server, user, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 110, height: 110)
                        .background(LinearGradient(colors: [Color(red: 0.62, green: 0.32, blue: 0.95), Color(red: 0.42, green: 0.16, blue: 0.78)],
                                                   startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .padding(.top, 40)
                    VStack(spacing: 6) {
                        Text("Willkommen bei HomeCast").font(.title.bold())
                        Text("Deine Podcasts, synchronisiert über deinen eigenen PinePods-Server.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 12) {
                        TextField("Serveradresse (z. B. http://192.168.1.10:8040)", text: $server)
                            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .server).submitLabel(.next).onSubmit { focus = .user }
                            .accessibilityIdentifier("login-server")
                        TextField("Benutzername", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .password }
                            .accessibilityIdentifier("login-user")
                        SecureField("Passwort", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password).submitLabel(.go).onSubmit { Task { await login() } }
                            .accessibilityIdentifier("login-password")
                    }
                    .textFieldStyle(.plain)
                    .padding()
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                    if retrying { Text("Verbindung wird hergestellt …").font(.footnote).foregroundStyle(.secondary) }

                    Button { Task { await login() } } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) } else { Text("Anmelden").font(.headline).frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("login-button")

                    Text("Noch kein Server? Eine Anleitung zum Einrichten von PinePods mit Docker steht in der Dokumentation (docs/SETUP.md).")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
    }

    private func login() async {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = (s.first?.isNumber == true ? "http://" : "https://") + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host() != nil else { error = String(localized: "Ungültige Serveradresse."); return }
        busy = true
        error = nil
        defer { busy = false; retrying = false }
        let user = username.trimmingCharacters(in: .whitespaces), pw = password
        do {
            // Verbindungsfehler (z. B. während iOS nach dem lokalen Netzwerk fragt) nach 2, 5, 15 s wiederholen;
            // falsches Passwort kommt sofort als Fehler zurück.
            let acc = try await ConnectionRetry.run(onRetry: { _ in retrying = true }) {
                try await PinePodsClient.login(server: url, username: user, password: pw)
            }
            password = ""
            library.login(acc)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
