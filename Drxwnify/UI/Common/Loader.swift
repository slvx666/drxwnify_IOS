import SwiftUI
import Combine

/// Состояние однократной загрузки для экрана.
final class Loader<Value>: ObservableObject {
    enum State {
        case idle, loading, loaded(Value), failed(String)
    }

    @Published private(set) var state = State.idle
    private var task: Task<Void, Never>?

    var value: Value? {
        if case .loaded(let v) = state { return v }
        return nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// Загружает один раз; `force` — заново (кнопка «Повторить», смена аккаунта).
    func load(force: Bool = false, _ operation: @escaping () async throws -> Value) {
        if !force {
            switch state {
            case .loading, .loaded: return
            default: break
            }
        }
        task?.cancel()
        if value == nil { state = .loading }
        task = Task { [weak self] in
            do {
                let value = try await operation()
                if Task.isCancelled { return }
                await MainActor.run { self?.state = .loaded(value) }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.state = .failed(message) }
            }
        }
    }

    func reset() {
        task?.cancel()
        state = .idle
    }
}

/// Постраничная загрузка длинного списка: страницы подтягиваются подряд и дописываются.
final class PagedLoader<Item>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var started = false

    func load(force: Bool = false, pageSize: Int, _ page: @escaping (_ offset: Int, _ limit: Int) async throws -> (items: [Item], total: Int)) {
        if started && !force { return }
        started = true
        task?.cancel()
        isLoading = true
        error = nil
        if force { items = []; total = 0 }
        task = Task { [weak self] in
            var offset = 0
            var first = true
            while !Task.isCancelled {
                do {
                    let result = try await page(offset, pageSize)
                    if Task.isCancelled { return }
                    let isFirst = first
                    await MainActor.run {
                        guard let self = self else { return }
                        if isFirst { self.items = result.items } else { self.items.append(contentsOf: result.items) }
                        self.total = result.total
                    }
                    first = false
                    offset += pageSize
                    if result.items.isEmpty || offset >= result.total { break }
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run { self?.error = message }
                    break
                }
            }
            await MainActor.run { self?.isLoading = false }
        }
    }
}

/// Индикатор, ошибка с «Повторить» или пустое состояние для списка.
struct LoadStatusRow: View {
    let isLoading: Bool
    let error: String?
    let retry: () -> Void

    var body: some View {
        if let error = error {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.footnote).foregroundColor(.secondary)
                Button(L("retry"), action: retry)
            }
            .padding(.vertical, 6)
        } else if isLoading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }
}
