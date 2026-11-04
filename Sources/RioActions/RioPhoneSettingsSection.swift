import SwiftUI

/// Settings for texting Rio from your iPhone (builder S). Embedded in `RioIntegrationsSettingsSection`.
struct RioPhoneSettingsSection: View {
    @AppStorage(RioOutsideSettings.phoneEnabledKey) private var enabled = false
    @AppStorage(RioOutsideSettings.phoneHandlesKey) private var handles = ""
    @ObservedObject private var texting = RioPhoneTexting.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text Rio from your iPhone")
                .font(.headline)
            Toggle("Let me text Rio from my iPhone", isOn: $enabled)
                .onChange(of: enabled) { _ in texting.applySettings() }
            Text("Off by default. When on, Rio looks at new messages in the Messages database on this Mac (read-only, locally). It acts only on a text you send to yourself that starts with \"Rio\", like \"Rio what's due on Canvas\". It ignores everyone else, groups, and your texts to other people, and it replies only to your own number or email. Anything that needs a confirmation on this Mac, like sending a message or quitting an app, is refused from your phone. Nothing is stored or sent anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("My phone number and Apple ID email, separated by commas", text: $handles)
                .textFieldStyle(.roundedBorder)
                .onSubmit { texting.applySettings() }
            Text("Type them the way Messages shows them, for example +15551234567, me@icloud.com. Then press Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
            statusView
            if enabled {
                Text("Full Disk Access setup")
                    .font(.subheadline.weight(.semibold))
                Text(RioPhoneAccess.setupSteps)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Then, on your iPhone, open Messages, start a conversation with yourself, and send \"Rio open Safari\". Rio answers with a bear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") { texting.applySettings() }
            }
        }
        .onAppear { texting.applySettings() }
    }

    @ViewBuilder private var statusView: some View {
        switch texting.status {
        case .off: EmptyView()
        case .listening: Label("Listening for your texts", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .needsHandle: Label("Add your phone number or email above.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .needsFullDiskAccess: Label("Rio needs Full Disk Access to read Messages. See the steps below.", systemImage: "lock").font(.caption).foregroundStyle(.orange)
        case .messagesMissing: Label("I can't find the Messages database. Sign in to Messages on this Mac first.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}
