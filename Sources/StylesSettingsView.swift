import SwiftUI

/// Tone per kind of app, like casual texts and formal email.
struct StylesSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Styles", icon: "textformat") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pick how cleanup should sound in each kind of app. \(AppName.displayName) checks which app you're dictating into when you start recording. Standard leaves your cleanup prompt unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Styles only change tone, capitalization and punctuation. They don't apply in Edit Mode or when \"Preserve exact wording\" is on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(DictationStyleCategory.allCases) { category in
                    SettingsCard(category.title, icon: category.icon) {
                        categoryRow(category)
                    }
                }
            }
            .padding(24)
        }
    }

    private func categoryRow(_ category: DictationStyleCategory) -> some View {
        let selection = Binding<DictationStyle>(
            get: { appState.style(for: category) },
            set: { appState.dictationStyles[category] = $0 }
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text(category.examples)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Style", selection: selection) {
                ForEach(DictationStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selection.wrappedValue.sample)
                .font(.callout)
                .italic()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }
}
