import Foundation
import Combine
import PulseDeckCore

/// One UI-side polling owner per AppState. All visible consumers read the same immutable frame.
/// Neither subscribing nor reading a cached snapshot installs an audio tap.
@MainActor
public final class AudioMeterSnapshotDistributor: ObservableObject {
    private final class WeakEntry {
        weak var value: AudioMeterSnapshotDistributor?
        weak var appState: AppState?
        init(_ value: AudioMeterSnapshotDistributor, appState: AppState) {
            self.value = value
            self.appState = appState
        }
    }
    private static var instances: [ObjectIdentifier: WeakEntry] = [:]

    public static func shared(for appState: AppState) -> AudioMeterSnapshotDistributor {
        instances = instances.filter { $0.value.value != nil && $0.value.appState != nil }
        let key = ObjectIdentifier(appState)
        if let existing = instances[key]?.value { return existing }
        let distributor = AudioMeterSnapshotDistributor { [weak appState] role in
            appState?.meterSnapshot(for: role)
        }
        instances[key] = WeakEntry(distributor, appState: appState)
        return distributor
    }

    @Published public private(set) var master: AudioMeterSnapshot?
    @Published public private(set) var cue: AudioMeterSnapshot?
    private let readSnapshot: (AudioEngineRole) -> AudioMeterSnapshot?
    private var pollingTask: Task<Void, Never>?
    private var consumers = 0

    // The reader is injectable for deterministic destructive-queue regression tests.
    init(readSnapshot: @escaping (AudioEngineRole) -> AudioMeterSnapshot?) {
        self.readSnapshot = readSnapshot
    }

    deinit { pollingTask?.cancel() }

    /// A view's cancellable task holds a subscription for its visible lifetime.
    public func observe() async {
        guard !Task.isCancelled else { return }
        consumers += 1
        if consumers == 1 {
            poll()
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1.0 / 30.0)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    self?.poll()
                }
            }
        }
        defer {
            consumers -= 1
            if consumers == 0 {
                pollingTask?.cancel()
                pollingTask = nil
                master = nil
                cue = nil
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3600)) }
            catch { break } // View disappearance cancels the subscription.
        }
    }

    private func poll() {
        let latestMaster = readSnapshot(.master)
        let latestCue = readSnapshot(.cue)
        if master != latestMaster { master = latestMaster }
        if cue != latestCue { cue = latestCue }
    }
}
