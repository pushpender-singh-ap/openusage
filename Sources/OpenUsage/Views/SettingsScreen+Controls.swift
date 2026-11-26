import SwiftUI

extension SettingsScreen {
    var automaticRefreshSection: some View {
        let store = container.dataStore
        var seen: Set<String> = []
        let families = container.registry.providers.map { ProviderAccountID.family(of: $0.id) }
            .filter { seen.insert($0).inserted }
        let selectedProvider = families.contains(refreshProvider) ? refreshProvider : (families.first ?? refreshProvider)
        return section("Automatic Refresh") {
            row("Provider") {
                picker(Binding(
                    get: { selectedProvider },
                    set: { refreshProvider = $0 }
                ), options: families) { id in
                    if ProviderAccountID.families.contains(id) { return id.capitalized }
                    return container.registry.provider(id: id)?.displayName ?? id
                }
                .accessibilityLabel("Refresh Provider")
            }
            row("Check Every") {
                picker(Binding(
                    get: { store.refreshSetting.minutes(for: selectedProvider) },
                    set: { store.refreshSetting.setMinutes($0, for: selectedProvider) }
                ), options: RefreshSetting.options(for: selectedProvider)) { "\($0) min" }
                    .id(selectedProvider)
                    .accessibilityLabel("Check Every")
            }
        }
    }

    /// A caption header over a rounded card of rows — the Customize block shape. The header is
    /// inset 8pt so it aligns with the rows' content, matching how Customize lines its provider
    /// headers up with the card rows.
    func section(
        _ title: String,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                rows()
            }
            .cardSurface()
        }
    }

    /// One settings row: label on the leading edge, the control on the trailing edge. Same insets
    /// as a Customize metric row so the cards share one rhythm.
    func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// An inline orange caption under a row — the single definition of the notice idiom shared by the
    /// General/Advanced error lines and the "this setting is paused" captions (Increase Transparency
    /// paused by a system accessibility setting, or by Party mode taking over the look).
    func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A trailing popup picker that hugs its selection — segmented controls don't fit the 320pt
    /// popover once options have real words in them.
    func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
