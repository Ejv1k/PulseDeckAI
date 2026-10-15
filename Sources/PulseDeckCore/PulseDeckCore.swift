import Foundation

/// Core constants and system configuration for PulseDeck AI.
public enum PulseDeckCoreConfig: Sendable {
    /// Semantic version of the PulseDeck AI core engine.
    public static let version = "0.1.0-phase0"

    /// Supported cache schema semantic version.
    public static let cacheSchemaVersion = "1.0.0"

    /// Default name of the audio library root directory.
    public static let defaultLibraryFolderName = "PulseDeck_Library"

    /// Default relative path to the cache file within the library root.
    public static let cacheFileName = ".pulsedeck_ai_cache.json"

    /// The 10 standard DJ library crate directories defined in the PulseDeck library layout.
    public static let standardCrates: [String] = [
        "00_Test_Tracks_Dev",
        "01_Warmup_Chill_Lounge",
        "02_Ceremony_Slow_Romantic",
        "03_Oldies_70s_80s_90s",
        "04_CZ_SK_Classics",
        "05_MainStage_Dance_120_128BPM",
        "06_2000s_Millennium_Hits",
        "07_Rock_PopPunk_LateNight",
        "08_Soundboard_SFX",
        "09_Visual_Backgrounds_Media"
    ]

    /// Target minimum hardware specification.
    public static let hardwareBaseline = "Apple Silicon M1 Pro, 16GB Unified Memory"
}
