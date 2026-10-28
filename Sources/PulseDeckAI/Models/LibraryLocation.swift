import AppKit
import Foundation
import PulseDeckCore

/// Only an explicitly chosen library is remembered. Launch overrides never update this preference.
@MainActor
final class LibraryLocationStore {
    private let defaults: UserDefaults
    private static let key = "chosenLibraryRootPath"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func applicationStore() -> LibraryLocationStore {
        // A fixed, app-specific suite; no system/default-output preferences are involved.
        LibraryLocationStore(defaults: UserDefaults(suiteName: "com.pulsedeckai.library-location")!)
    }

    var chosenRoot: URL? {
        guard let path = defaults.string(forKey: Self.key), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func remember(_ root: URL) {
        defaults.set(root.standardizedFileURL.path, forKey: Self.key)
    }
}

struct LibraryLaunchLocation {
    let root: URL
    enum Issue {
        case malformedOverride(String)
        case unavailableRoot(String)

        var message: String {
            switch self {
            case .malformedOverride(let message), .unavailableRoot(let message): return message
            }
        }
    }

    let issue: Issue?
    var error: String? { issue?.message }
}

enum LibraryLocation {
    static func validate(_ root: URL) throws -> URL {
        guard root.isFileURL else {
            throw LocationError("Choose a local library folder, not a network URL.")
        }
        let root = root.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw LocationError("Library folder is unavailable: \(root.path). Reconnect it or use Open Library to choose its root folder.")
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            throw LocationError("Library folder cannot be read: \(root.path). Use Open Library to choose an accessible folder.")
        }
        return root
    }

    @MainActor
    static func resolve(arguments: [String], workingDirectory: URL, store: LibraryLocationStore) -> LibraryLaunchLocation {
        let legacyRoot = workingDirectory.appendingPathComponent(PulseDeckCoreConfig.defaultLibraryFolderName, isDirectory: true)
        let overrides = arguments.indices.filter { arguments[$0] == "--library-root" }
        let root: URL
        do {
            if let index = overrides.first {
                guard overrides.count == 1, index + 1 < arguments.count else {
                    throw LocationError("--library-root requires one absolute folder path or local file URL. Use Open Library to choose a library.")
                }
                root = try parseOverride(arguments[index + 1])
            } else {
                root = store.chosenRoot ?? legacyRoot
            }
        } catch {
            // Keep startup blocked rather than scanning a different fallback library after an invalid override.
            return LibraryLaunchLocation(root: legacyRoot, issue: .malformedOverride(error.localizedDescription))
        }
        do {
            return LibraryLaunchLocation(root: try validate(root), issue: nil)
        } catch {
            // Preserve the unavailable requested/remembered path for display and recovery.
            return LibraryLaunchLocation(root: root, issue: .unavailableRoot(error.localizedDescription))
        }
    }

    private static func parseOverride(_ text: String) throws -> URL {
        if text.hasPrefix("/") { return URL(fileURLWithPath: text, isDirectory: true) }
        if let components = URLComponents(string: text), components.scheme == "file",
           components.host == nil || components.host == "" || components.host == "localhost",
           components.query == nil, components.fragment == nil,
           let url = components.url, url.path.hasPrefix("/") { return url }
        throw LocationError("--library-root must be an absolute folder path or local file URL. Use Open Library to choose a library.")
    }

    private struct LocationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@MainActor
enum LibraryLocationPicker {
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Library"
        panel.prompt = "Open Library"
        panel.message = "Choose the library root containing your crate subfolders (usually PulseDeck_Library), not an individual crate. Opening does not create, move, or analyze your files."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
