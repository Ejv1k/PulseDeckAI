import XCTest
@testable import PulseDeckCore

final class AudioContractsTests: XCTestCase {

    func testLatencyCompensationMath() {
        // Zero offset: zero added delay
        let zero = LatencyCompensation(offsetMs: 0.0)
        XCTAssertEqual(zero.masterDelayMs, 0.0)
        XCTAssertEqual(zero.cueDelayMs, 0.0)

        // Positive offset (+150ms): Master lags Cue by 150ms -> inject 150ms into Cue path
        let positive = LatencyCompensation(offsetMs: 150.0)
        XCTAssertEqual(positive.cueDelayMs, 150.0)
        XCTAssertEqual(positive.masterDelayMs, 0.0)

        // Negative offset (-120ms): Cue lags Master by 120ms (e.g. Bluetooth) -> inject 120ms into Master path
        let negative = LatencyCompensation(offsetMs: -120.0)
        XCTAssertEqual(negative.masterDelayMs, 120.0)
        XCTAssertEqual(negative.cueDelayMs, 0.0)

        // Clamping to max bounds [-300ms, +300ms]
        let clampedPositive = LatencyCompensation(offsetMs: 500.0)
        XCTAssertEqual(clampedPositive.offsetMs, 300.0)
        XCTAssertEqual(clampedPositive.cueDelayMs, 300.0)

        let clampedNegative = LatencyCompensation(offsetMs: -450.0)
        XCTAssertEqual(clampedNegative.offsetMs, -300.0)
        XCTAssertEqual(clampedNegative.masterDelayMs, 300.0)
    }

    func testLatencyCompensationNonFiniteValuesDefaultToZero() {
        let nanComp = LatencyCompensation(offsetMs: .nan)
        XCTAssertEqual(nanComp.offsetMs, 0.0)
        XCTAssertEqual(nanComp.masterDelayMs, 0.0)
        XCTAssertEqual(nanComp.cueDelayMs, 0.0)

        let posInfComp = LatencyCompensation(offsetMs: .infinity)
        XCTAssertEqual(posInfComp.offsetMs, 0.0)
        XCTAssertEqual(posInfComp.masterDelayMs, 0.0)
        XCTAssertEqual(posInfComp.cueDelayMs, 0.0)

        let negInfComp = LatencyCompensation(offsetMs: -.infinity)
        XCTAssertEqual(negInfComp.offsetMs, 0.0)
        XCTAssertEqual(negInfComp.masterDelayMs, 0.0)
        XCTAssertEqual(negInfComp.cueDelayMs, 0.0)
    }

    func testAudioParametersDefaults() {
        let eq = EQ3BandParameters()
        XCTAssertEqual(eq.lowGainDB, 0.0)
        XCTAssertEqual(eq.midGainDB, 0.0)
        XCTAssertEqual(eq.highGainDB, 0.0)

        let filter = ResonantFilterParameters()
        XCTAssertEqual(filter.sweep, 0.0)
        XCTAssertEqual(filter.resonance, 1.0)

        let timePitch = TimePitchParameters()
        XCTAssertEqual(timePitch.rate, 1.0)
        XCTAssertEqual(timePitch.pitchCents, 0.0)
        XCTAssertTrue(timePitch.keyLockEnabled)
    }

    func testGeminiAdvisorRateLimitAndBackoff() {
        let config = GeminiAdvisorConfig()
        XCTAssertEqual(config.model, "gemini-2.5-flash")
        XCTAssertEqual(config.requestsPerMinute, 12)
        XCTAssertEqual(GeminiAdvisorConfig.minRequestIntervalSeconds, 5.0)

        // Capping test: cannot exceed 12 RPM
        let aggressiveConfig = GeminiAdvisorConfig(requestsPerMinute: 60)
        XCTAssertEqual(aggressiveConfig.requestsPerMinute, 12)

        // Deterministic bounded backoff supports hermetic Retry-After tests.
        let backoff0 = config.backoffDelaySeconds(forAttempt: 0)
        XCTAssertEqual(backoff0, 1.0)

        let backoff3 = config.backoffDelaySeconds(forAttempt: 3)
        XCTAssertEqual(backoff3, 8.0)

        XCTAssertEqual(config.backoffDelaySeconds(forAttempt: 10), 30.0)
    }
}
