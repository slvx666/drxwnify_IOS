import SwiftUI

/// Эквалайзер (Android `EqScreen` + `GraphicEq`): вкл/выкл, пресеты, 10 вертикальных полос ±12 дБ.
struct EqualizerSheet: View {
    @ObservedObject private var eq = Equalizer.shared
    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("", selection: Binding(get: { eq.enabled }, set: { on in
                        eq.enabled = on
                        if on { player.applyEqualizer() }
                    })) {
                        Text(L("eq_off")).tag(false)
                        Text(L("eq_on")).tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Equalizer.Preset.allCases, id: \.self) { p in
                                Button(action: { select(p) }) {
                                    Text(p.title)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14).frame(height: 34)
                                        .foregroundColor(eq.matchingPreset == p ? Color(.systemBackground) : .primary)
                                        .background(Capsule().fill(eq.matchingPreset == p ? Color.accentColor : Color.secondary.opacity(0.2)))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }

                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Equalizer.frequencies.indices, id: \.self) { i in band(i).frame(maxWidth: .infinity) }
                    }
                    .frame(height: 260)
                    .opacity(eq.enabled ? 1 : 0.45)

                    Button(L("eq_reset")) { eq.gains = Equalizer.Preset.flat.gains }
                        .disabled(eq.gains == Equalizer.Preset.flat.gains)
                }
                .padding(16)
            }
            .navigationTitle(L("equalizer_header"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
    }

    private func select(_ p: Equalizer.Preset) {
        eq.gains = p.gains
        if !eq.enabled {
            eq.enabled = true
            player.applyEqualizer()
        }
    }

    /// Полоса: подпись усиления, вертикальный ползунок (шаг 0,5 дБ), частота.
    private func band(_ i: Int) -> some View {
        let g = eq.gains[i]
        return VStack(spacing: 6) {
            Text((g > 0 ? "+" : "") + String(format: "%.0f", g)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            GeometryReader { geo in
                Slider(value: Binding(get: { Double(eq.gains[i]) }, set: { v in
                    var gains = eq.gains
                    gains[i] = Float((v * 2).rounded() / 2)
                    eq.gains = gains
                    if !eq.enabled { eq.enabled = true; player.applyEqualizer() }
                }), in: Double(-Equalizer.maxDb)...Double(Equalizer.maxDb))
                .frame(width: geo.size.height)
                .rotationEffect(.degrees(-90))
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text(Equalizer.labels[i]).font(.caption2).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Equalizer.labels[i]) Hz")
    }
}
