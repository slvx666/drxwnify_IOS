import SwiftUI

/// Временные экраны вкладок (этап 0). Каждый заменяется на своём этапе.
struct StagePlaceholder: View {
    let systemImage: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(L("stage_placeholder"))
                .font(.headline)
            Text(note)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .miniPlayerInset()
    }
}

struct TogetherScreen: View {
    var body: some View {
        StagePlaceholder(systemImage: "person.2", note: "")
            .navigationTitle(L("together"))
    }
}
