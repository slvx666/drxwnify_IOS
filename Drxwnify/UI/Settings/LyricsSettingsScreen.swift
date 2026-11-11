import SwiftUI

/// Источники текстов (LYR-003, LYR-004): включение и порядок перетаскиванием; выше — раньше спрашивается.
struct LyricsSettingsScreen: View {
    @ObservedObject var settings: TypedStore
    @State private var order: [String] = []

    var body: some View {
        List {
            Section(header: Text(L("lyrics_provider_selection")), footer: Text(L("lyrics_provider_selection_desc"))) {
                ForEach(LyricsProviders.all, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { LyricsProviders.isEnabled(name, settings) },
                        set: { on in if let (key, _) = LyricsProviders.enableKey(name) { settings.set(key, on) } }))
                }
            }
            Section(header: Text(L("lyrics_provider_priority")), footer: Text(L("lyrics_provider_priority_desc"))) {
                ForEach(order, id: \.self) { name in
                    Text(name).foregroundColor(LyricsProviders.isEnabled(name, settings) ? .primary : .secondary)
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    settings.set(PK.lyricsProviderOrder, order.joined(separator: ","))
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .environment(\.editMode, .constant(.active))
        .navigationTitle(L("lyrics"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { order = LyricsProviders.order(settings) }
    }
}
