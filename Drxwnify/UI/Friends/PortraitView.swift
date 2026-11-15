import SwiftUI

/// Жанры-теги профиля под именем (Android: три точки-тега под ником).
struct PortraitTags: View {
    let tags: [String]

    var body: some View {
        FlowChips(items: tags, centered: true) { g in
            HStack(spacing: 6) {
                Circle().fill(GenreChips.dot(g)).frame(width: 7, height: 7)
                Text(g).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(GenreChips.dot(g).opacity(0.22)))
        }
    }
}

/// «Портрет» (Android `PortraitCard`): неделя / месяц / год или месяц из календаря — слушал, треков, новых лайков;
/// кого слушает больше всего; полоса жанров с легендой; любимые треки.
struct PortraitSection: View {
    let portrait: ProfilePortrait
    let queueTitle: String
    @State private var period = 1
    @State private var monthKey: String?

    private var current: Portrait? {
        if let k = monthKey { return portrait.months[k] }
        switch period {
        case 0: return portrait.week
        case 2: return portrait.year
        default: return portrait.month
        }
    }

    private var monthKeys: [String] { portrait.months.keys.sorted(by: >) }

    private func monthTitle(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: key) else { return key }
        f.dateFormat = "LLLL yyyy"
        return f.string(from: d).capitalized
    }

    var body: some View {
        Section(header: header, footer: Text(L("portrait_footer"))) {
            Picker("", selection: Binding(get: { monthKey == nil ? period : -1 }, set: { period = $0; monthKey = nil })) {
                Text(L("portrait_week")).tag(0)
                Text(L("portrait_month")).tag(1)
                Text(L("portrait_year")).tag(2)
                if let k = monthKey { Text(monthTitle(k)).tag(-1) }
            }
            .pickerStyle(SegmentedPickerStyle())
            if let p = current {
                if p.byLikes { Text(L("portrait_by_likes")).font(.caption).foregroundColor(.secondary) }
                HStack(spacing: 8) {
                    tile(L("portrait_listened"), p.minutes >= 60 ? L("portrait_hours_value", String(format: "%.1f", Double(p.minutes) / 60)) : L("portrait_minutes_value", p.minutes))
                    tile(L("portrait_tracks"), "\(p.tracks)")
                    tile(L("portrait_new_likes"), "\(p.newLikes)")
                }
                if !p.artists.isEmpty {
                    Text(L(p.byLikes ? "portrait_top_artists_likes" : "portrait_top_artists")).font(.subheadline.weight(.semibold))
                    let maxMin = max(1, p.artists.map { $0.minutes }.max() ?? 1)
                    ForEach(Array(p.artists.enumerated()), id: \.offset) { i, a in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 14)
                            ArtworkView(url: a.cover, size: 34, circle: true, placeholderSymbol: "person.fill")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.name).font(.subheadline).lineLimit(1)
                                GeometryReader { g in
                                    Capsule().fill(Color.secondary.opacity(0.2))
                                        .overlay(Capsule().fill(Color.accentColor).frame(width: g.size.width * CGFloat(a.minutes) / CGFloat(maxMin)), alignment: .leading)
                                }
                                .frame(height: 4)
                            }
                            Text(String(format: "%.1f ч", Double(a.minutes) / 60) + (a.likes > 0 ? " · ♥ \(a.likes)" : ""))
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                    }
                }
                if !p.genres.isEmpty { genres(p.genres) }
                if !p.topTracks.isEmpty {
                    Text(L(p.byLikes ? "portrait_new_liked_tracks" : "portrait_top_tracks")).font(.subheadline.weight(.semibold))
                    let refs = p.topTracks.map { $0.track }
                    ForEach(Array(p.topTracks.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t.track.track, context: refs.map { $0.track }, index: i, queueTitle: queueTitle,
                                 subtitle: t.plays > 0 ? "\(t.track.artist) · \(LPlural("portrait_plays", t.plays))" : t.track.artist)
                            .overlay(t.liked ? Image(systemName: "heart.fill").foregroundColor(.red).padding(.trailing, 36) : nil, alignment: .trailing)
                    }
                }
            } else {
                Text(L("portrait_not_enough")).foregroundColor(.secondary)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("portrait_title"))
            Spacer()
            if !monthKeys.isEmpty {
                Menu {
                    ForEach(monthKeys, id: \.self) { k in
                        Button(action: { monthKey = k }) { Text(monthTitle(k)) }
                    }
                } label: {
                    Image(systemName: "calendar").font(.body)
                }
                .accessibilityLabel(L("portrait_calendar"))
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.14)))
    }

    private func legend(_ g: (String, Int)) -> String { "\(g.0.isEmpty ? L("portrait_other") : g.0) \(g.1)%" }

    private func color(_ g: String) -> Color { g.isEmpty ? Color.secondary.opacity(0.5) : GenreChips.dot(g) }

    /// Полоса жанров по процентам и легенда.
    private func genres(_ list: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("portrait_genres")).font(.subheadline.weight(.semibold))
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, g in
                        color(g.0).frame(width: geo.size.width * CGFloat(g.1) / 100)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            FlowChips(items: list.map { legend($0) }) { label in
                HStack(spacing: 5) {
                    Circle().fill(color(list.first { legend($0) == label }?.0 ?? "")).frame(width: 7, height: 7)
                    Text(label).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
