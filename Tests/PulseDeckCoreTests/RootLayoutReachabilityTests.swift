import XCTest
import AppKit
import SwiftUI
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class RootLayoutReachabilityTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let state: AppState
        let projector = ProjectorViewModel()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RootLayout-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for index in 1...32 {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(String(format: "%02d_Private_Crate", index)),
                    withIntermediateDirectories: false)
            }
            state = AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                             cacheLoader: { _ in nil }, audioCoordinator: nil, startCoordinator: false)
            let summary = LibraryScanner().scan(libraryURL: root)
            state.scanSummary = summary
            state.selectedCrate = summary.crates.first
            state.setMasterSafetyLockEnabled(false)
        }

        func cleanup() {
            projector.teardown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func nextLayoutTurn(_ host: NSView) {
        let turn = expectation(description: "Native layout turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)
        host.layoutSubtreeIfNeeded()
    }

    private func mount(_ fixture: Fixture, size: NSSize) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let mounted = expectation(description: "Production root mounted")
        let root = ContentView().environmentObject(fixture.state).environmentObject(fixture.projector)
            .frame(minWidth: 1024, idealWidth: 1200, minHeight: 680, idealHeight: 760)
            .onAppear { mounted.fulfill() }
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.ignoresMouseEvents = true
        window.contentMinSize = NSSize(width: 1024, height: 680)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderBack(nil)
        controller.view.layoutSubtreeIfNeeded()
        wait(for: [mounted], timeout: 3)
        nextLayoutTurn(controller.view)
        return (window, controller.view)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        var result: [NSView] = []
        var pending = [root]
        while let view = pending.popLast(), result.count < 2048 {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private func fullyVisible(_ view: NSView, in root: NSView) -> Bool {
        let rect = view.convert(view.bounds, to: root)
        let intersection = view.visibleRect.intersection(view.bounds)
        return rect.minX >= root.bounds.minX - 0.5 && rect.maxX <= root.bounds.maxX + 0.5
            && rect.minY >= root.bounds.minY - 0.5 && rect.maxY <= root.bounds.maxY + 0.5
            && intersection.width >= view.bounds.width - 0.5
            && intersection.height >= view.bounds.height - 0.5
    }

    private func enclosingRootScroll(_ view: NSView, root: NSView) -> NSScrollView? {
        var ancestor = view.superview
        var result: NSScrollView?
        while let current = ancestor {
            if let scroll = current as? NSScrollView {
                let rect = scroll.convert(scroll.bounds, to: root)
                if rect.width >= root.bounds.width - 24 && rect.height >= root.bounds.height - 24 {
                    result = scroll
                }
            }
            ancestor = current.superview
        }
        return result
    }

    private func scroll(_ view: NSView, into scroll: NSScrollView, root: NSView) throws {
        let document = try XCTUnwrap(scroll.documentView)
        let rect = view.convert(view.bounds, to: document)
        let clip = scroll.contentView
        let maximumY = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        let targetY = max(document.bounds.minY, min(maximumY, rect.midY - clip.bounds.height / 2))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: targetY))
        scroll.reflectScrolledClipView(clip)
        nextLayoutTurn(root)
    }

    private func assertReachable(_ view: NSView, in root: NSView, context: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        if !fullyVisible(view, in: root) {
            guard let scrollView = enclosingRootScroll(view, root: root) else {
                return XCTFail("\(context): actual control is outside legal root bounds with no root scroll: \(view.convert(view.bounds, to: root))",
                               file: file, line: line)
            }
            try scroll(view, into: scrollView, root: root)
        }
        XCTAssertTrue(fullyVisible(view, in: root),
                      "\(context): actual control remains clipped after real root scrolling: \(view.convert(view.bounds, to: root))",
                      file: file, line: line)
    }

    func testProductionControlsAreVisibleOrReachableAtLegalViewports() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var sizes = [NSSize(width: 1024, height: 680), NSSize(width: 1200, height: 760)]
        if let visible = NSScreen.main?.visibleFrame.size, visible.width >= 1024, visible.height >= 680,
           !sizes.contains(visible) { sizes.append(visible) }
        for size in sizes {
            let (window, root) = mount(fixture, size: size)
            defer { window.contentViewController = nil; window.contentView = nil; window.close() }
            XCTAssertEqual(root.bounds.size.width, size.width, accuracy: 0.5)
            XCTAssertEqual(root.bounds.size.height, size.height, accuracy: 0.5)
            let views = descendants(root)
            let outputs = views.compactMap { $0 as? NSPopUpButton }.filter { $0.title == "No Output Devices Found" }
            XCTAssertEqual(outputs.count, 2, "Exercise the real Master and Cue selector controls")
            let controls = views.compactMap { $0 as? NSControl }.filter {
                !($0 is NSScroller) && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            XCTAssertGreaterThan(controls.count, outputs.count, "Include real transport/slider controls beyond the output selectors")
            for control in controls {
                try assertReachable(control, in: root, context: "\(size)")
            }
            if let output = outputs.first {
                try assertReachable(output, in: root, context: "Return to top at \(size)")
            }
            XCTAssertTrue(fixture.state.availableOutputDevices.isEmpty)
            XCTAssertNil(fixture.state.meterSnapshot(for: .master))
            XCTAssertFalse(fixture.state.isDeckAPlaying)
        }
    }

    func testCrateScrollMovesIndependentlyInsideReachableRootViewport() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (window, root) = mount(fixture, size: NSSize(width: 1024, height: 680))
        defer { window.contentViewController = nil; window.contentView = nil; window.close() }
        let nested = descendants(root).compactMap { $0 as? NSScrollView }.first { scroll in
            guard let document = scroll.documentView else { return false }
            return scroll.convert(scroll.bounds, to: root).width < root.bounds.width - 24
                && document.bounds.height > scroll.contentView.bounds.height + 1
        }
        let crateScroll = try XCTUnwrap(nested, "Private multi-crate fixture must have a genuine scroll range")
        try assertReachable(crateScroll, in: root, context: "Nested crate viewport")
        let outer = try XCTUnwrap(enclosingRootScroll(crateScroll, root: root))
        let rootOrigin = outer.contentView.bounds.origin
        let previous = crateScroll.contentView.bounds.origin
        let document = try XCTUnwrap(crateScroll.documentView)
        crateScroll.contentView.scroll(to: NSPoint(x: previous.x,
            y: max(document.bounds.minY, document.bounds.maxY - crateScroll.contentView.bounds.height)))
        crateScroll.reflectScrolledClipView(crateScroll.contentView)
        nextLayoutTurn(root)
        XCTAssertGreaterThan(abs(crateScroll.contentView.bounds.origin.y - previous.y), 1)
        XCTAssertEqual(outer.contentView.bounds.origin.y, rootOrigin.y, accuracy: 0.5,
                       "Scrolling the crate list must not scroll the entire control stack")
    }
}
