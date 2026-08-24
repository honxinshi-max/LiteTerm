import SwiftUI

enum HostKeyTrustKind {
    case firstUse
    case replacement
}

struct HostKeyTrustSheet: View {
    let hostLabel: String
    let presentedFingerprint: String
    let kind: HostKeyTrustKind
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label(title, systemImage: "checkmark.shield")
                    .font(.title2.bold())
                Text(explanation)
                    .foregroundStyle(.secondary)
                Text(presentedFingerprint)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text("Verify this SHA-256 fingerprint through a separate trusted channel before continuing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(kind == .firstUse ? "Trust and Continue" : "Replace Trusted Key", role: kind == .replacement ? .destructive : nil) {
                    onTrust()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle(hostLabel)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private var title: String {
        kind == .firstUse ? "Trust this host key?" : "Host key changed"
    }

    private var explanation: String {
        switch kind {
        case .firstUse:
            return "This is the first key presented for this host. LiteTerm will connect only after you explicitly trust it."
        case .replacement:
            return "The presented key does not match the trusted key. Connection is blocked unless you explicitly replace trust."
        }
    }
}
