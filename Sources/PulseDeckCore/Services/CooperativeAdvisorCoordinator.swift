import Foundation

/// Coordinates fast local provisional advice with optional background Gemini refinement.
/// Thread-safe actor isolation. Guarantees that local-only mode never accesses network endpoints.
public actor CooperativeAdvisorCoordinator {
    private var localProvider: any LocalAdvisorProvider
    private var cloudClient: GeminiAdvisorClient?
    private var activeGenerationID: UInt64 = 0
    private var inFlightRefinementTask: Task<Void, Never>?

    public init(
        localProvider: any LocalAdvisorProvider,
        cloudClient: GeminiAdvisorClient? = nil
    ) {
        self.localProvider = localProvider
        self.cloudClient = cloudClient
    }

    public func setLocalProvider(_ provider: any LocalAdvisorProvider) {
        self.localProvider = provider
    }

    public func setCloudClient(_ client: GeminiAdvisorClient?) {
        self.cloudClient = client
    }

    public func cancel() {
        inFlightRefinementTask?.cancel()
        inFlightRefinementTask = nil
        activeGenerationID &+= 1
    }

    public func currentGeneration() -> UInt64 {
        activeGenerationID
    }

    /// Evaluates current track and candidates, streaming provisional local advice first,
    /// followed by background cloud refinement if enabled in cooperative mode.
    public func streamRecommendation(
        currentTrack: TrackCacheEntry,
        candidates: [TrackCacheEntry],
        mode: AdvisorMode,
        generationID: UInt64
    ) -> AsyncThrowingStream<CooperativeRecommendation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.executeRequest(
                    currentTrack: currentTrack,
                    candidates: candidates,
                    mode: mode,
                    generationID: generationID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func executeRequest(
        currentTrack: TrackCacheEntry,
        candidates: [TrackCacheEntry],
        mode: AdvisorMode,
        generationID: UInt64,
        continuation: AsyncThrowingStream<CooperativeRecommendation, Error>.Continuation
    ) async {
        defer {
            continuation.finish()
        }
        inFlightRefinementTask?.cancel()
        inFlightRefinementTask = nil
        activeGenerationID = generationID

        guard mode != .disabled else {
            continuation.finish()
            return
        }

        guard currentTrack.isValid else {
            continuation.finish(throwing: AIAdvisorError.invalidRecommendation)
            return
        }

        let validCandidates = candidates
            .filter { $0.isValid && $0.relativePath != currentTrack.relativePath }
            .sorted { $0.relativePath < $1.relativePath }

        guard !validCandidates.isEmpty else {
            continuation.finish(throwing: AIAdvisorError.invalidRecommendation)
            return
        }

        guard !Task.isCancelled, activeGenerationID == generationID else {
            continuation.finish()
            return
        }

        // Phase 1: Local Provisional Inference
        let rawLocal: AdvisorRecommendation
        do {
            rawLocal = try await localProvider.recommend(
                currentTrack: currentTrack,
                candidates: validCandidates
            )
        } catch is CancellationError {
            continuation.finish()
            return
        } catch {
            guard !Task.isCancelled, activeGenerationID == generationID else {
                continuation.finish()
                return
            }
            continuation.finish(throwing: error)
            return
        }

        guard !Task.isCancelled, activeGenerationID == generationID else {
            continuation.finish()
            return
        }

        let validatedLocal: AdvisorRecommendation
        do {
            validatedLocal = try AdvisorRecommendationValidator.validate(
                rawLocal,
                currentTrack: currentTrack,
                availableTracks: validCandidates
            )
        } catch {
            continuation.finish(throwing: error)
            return
        }

        let hasValidCloudKey: Bool = {
            guard let client = cloudClient,
                  let key = client.apiKeyProvider(),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return true
        }()

        let shouldRefine = (mode == .cooperative) && hasValidCloudKey

        let provisional = CooperativeRecommendation(
            generationID: generationID,
            currentTrackPath: currentTrack.relativePath,
            provisional: validatedLocal,
            localModelLabel: localProvider.modelIdentifier,
            refinement: nil,
            cloudModelLabel: nil,
            isRefining: shouldRefine,
            timestamp: Date()
        )

        continuation.yield(provisional)

        // Strict boundary: local-only mode or no cloud key finishes immediately.
        guard shouldRefine, let client = cloudClient else {
            continuation.finish()
            return
        }

        // Phase 2: Background Cloud Refinement
        let localLabel = localProvider.modelIdentifier
        let cloudLabel = "Gemini: \(client.config.model)"
        let shortlist = Array(validCandidates.prefix(5))

        let refinementTask = Task { () -> Void in
            do {
                let rawCloud = try await client.recommend(
                    currentTrack: currentTrack,
                    availableTracks: shortlist
                )

                guard !Task.isCancelled else { return }

                let validatedCloud = try AdvisorRecommendationValidator.validate(
                    rawCloud,
                    currentTrack: currentTrack,
                    availableTracks: shortlist
                )

                guard !Task.isCancelled else { return }
                guard self.isCurrentGeneration(generationID) else { return }

                let refined = CooperativeRecommendation(
                    generationID: generationID,
                    currentTrackPath: currentTrack.relativePath,
                    provisional: validatedLocal,
                    localModelLabel: localLabel,
                    refinement: validatedCloud,
                    cloudModelLabel: cloudLabel,
                    isRefining: false,
                    timestamp: Date()
                )
                continuation.yield(refined)
                continuation.finish()
            } catch {
                guard !Task.isCancelled else { return }
                guard self.isCurrentGeneration(generationID) else { return }

                // Gracefully retain provisional output if cloud refinement fails.
                let settledProvisional = CooperativeRecommendation(
                    generationID: generationID,
                    currentTrackPath: currentTrack.relativePath,
                    provisional: validatedLocal,
                    localModelLabel: localLabel,
                    refinement: nil,
                    cloudModelLabel: nil,
                    isRefining: false,
                    timestamp: Date()
                )
                continuation.yield(settledProvisional)
                continuation.finish()
            }
        }

        self.inFlightRefinementTask = refinementTask
        await refinementTask.value
    }

    private func isCurrentGeneration(_ generationID: UInt64) -> Bool {
        activeGenerationID == generationID
    }
}
