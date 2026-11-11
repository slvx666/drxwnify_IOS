import SwiftUI

/// «Предложка» (Android 2.1.2): тема, текст, отправка разработчику; ниже — что уйдёт вместе с текстом.
struct SuggestionsScreen: View {
    @ObservedObject private var box = Suggestions.shared
    @State private var topic = Suggestions.Topic.idea
    @State private var text = ""
    @State private var notice: String?

    private func title(_ t: Suggestions.Topic) -> String { L("suggest_topic_" + t.rawValue) }
    private var hint: String { L("suggest_hint_" + topic.rawValue) }

    var body: some View {
        List {
            Section {
                Text(L("suggest_intro")).font(.subheadline)
                Picker("", selection: $topic) {
                    ForEach(Suggestions.Topic.allCases, id: \.self) { Text(title($0)).tag($0) }
                }
                .pickerStyle(SegmentedPickerStyle())
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(hint).foregroundColor(.secondary).padding(.top, 8).padding(.leading, 5)
                    }
                    TextEditor(text: $text).frame(minHeight: UIMetrics.isShort ? 110 : 160)
                }
                HStack {
                    Text("\(text.count)/2000").font(.caption).foregroundColor(text.count > 2000 ? .red : .secondary)
                    Spacer()
                    Button(L("suggest_send"), action: send)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section(footer: Text(L("suggest_privacy"))) { EmptyView() }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("suggest_title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Alert(title: Text(notice ?? ""))
        }
    }

    private func send() {
        if box.limited { notice = L("suggest_limited"); return }
        if box.send(topic, text) {
            text = ""
            notice = L("suggest_sent")
        }
    }
}

/// Ответ разработчика на весь экран (как заметки к версии), по одному.
struct SuggestionReplySheet: View {
    let reply: Suggestions.Reply
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let q = reply.quote {
                        Text(q).font(.subheadline).foregroundColor(.secondary)
                            .padding(.leading, 10)
                            .overlay(Rectangle().fill(Color.accentColor).frame(width: 3), alignment: .leading)
                    }
                    Text(reply.text).font(.body)
                    Text(FriendsHub.developerName).font(.caption).foregroundColor(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L("suggest_reply_title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("OK") { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onDisappear { Suggestions.shared.markSeen(reply.id) }
    }
}
