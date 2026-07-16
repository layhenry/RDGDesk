import AppKit
import RdcCore
import SwiftUI

@MainActor
struct RemoteDesktopSurface: NSViewRepresentable {
    let frame: RemoteFrame?
    let resizesWithWindow: Bool
    let onResize: (Int, Int) -> Void
    let onPointer: (RemotePointerEvent) -> Void
    let onKey: (RemoteKeyEvent) -> Void
    let onUnicode: (RemoteUnicodeKeyEvent) -> Void

    init(
        frame: RemoteFrame?,
        resizesWithWindow: Bool,
        onResize: @escaping (Int, Int) -> Void,
        onPointer: @escaping (RemotePointerEvent) -> Void,
        onKey: @escaping (RemoteKeyEvent) -> Void,
        onUnicode: @escaping (RemoteUnicodeKeyEvent) -> Void
    ) {
        self.frame = frame
        self.resizesWithWindow = resizesWithWindow
        self.onResize = onResize
        self.onPointer = onPointer
        self.onKey = onKey
        self.onUnicode = onUnicode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            resizesWithWindow: resizesWithWindow,
            onResize: onResize,
            onPointer: onPointer,
            onKey: onKey,
            onUnicode: onUnicode
        )
    }

    func makeNSView(context: Context) -> RemoteDesktopSurfaceView {
        let view = RemoteDesktopSurfaceView()
        let coordinator = context.coordinator
        view.onResize = { [weak coordinator] width, height in
            coordinator?.handleResize(width: width, height: height)
        }
        view.onPointer = { [weak coordinator] event in
            coordinator?.onPointer(event)
        }
        view.onKey = { [weak coordinator] event in
            coordinator?.onKey(event)
        }
        view.onUnicode = { [weak coordinator] event in
            coordinator?.onUnicode(event)
        }
        updateFrame(on: view, coordinator: coordinator)
        return view
    }

    func updateNSView(_ view: RemoteDesktopSurfaceView, context: Context) {
        context.coordinator.resizesWithWindow = resizesWithWindow
        context.coordinator.onResize = onResize
        context.coordinator.onPointer = onPointer
        context.coordinator.onKey = onKey
        context.coordinator.onUnicode = onUnicode
        updateFrame(on: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ view: RemoteDesktopSurfaceView,
        coordinator: Coordinator
    ) {
        view.tearDown()
    }

    private func updateFrame(
        on view: RemoteDesktopSurfaceView,
        coordinator: Coordinator
    ) {
        guard frame?.identity != coordinator.displayedFrameIdentity else { return }
        coordinator.displayedFrameIdentity = frame?.identity
        view.frameImage = frame.flatMap(Self.makeImage)
    }

    private static func makeImage(from frame: RemoteFrame) -> CGImage? {
        let copiedData = Data(frame.bgraBytes) as CFData
        guard let provider = CGDataProvider(data: copiedData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var resizesWithWindow: Bool
        var onResize: (Int, Int) -> Void
        var onPointer: (RemotePointerEvent) -> Void
        var onKey: (RemoteKeyEvent) -> Void
        var onUnicode: (RemoteUnicodeKeyEvent) -> Void
        var displayedFrameIdentity: UInt64?

        init(
            resizesWithWindow: Bool,
            onResize: @escaping (Int, Int) -> Void,
            onPointer: @escaping (RemotePointerEvent) -> Void,
            onKey: @escaping (RemoteKeyEvent) -> Void,
            onUnicode: @escaping (RemoteUnicodeKeyEvent) -> Void
        ) {
            self.resizesWithWindow = resizesWithWindow
            self.onResize = onResize
            self.onPointer = onPointer
            self.onKey = onKey
            self.onUnicode = onUnicode
        }

        func handleResize(width: Int, height: Int) {
            guard resizesWithWindow else { return }
            onResize(width, height)
        }
    }
}
