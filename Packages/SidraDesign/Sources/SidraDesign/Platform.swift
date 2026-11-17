import SwiftUI
#if canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
public typealias PlatformColor = UIColor
public typealias PlatformViewRepresentable = UIViewRepresentable
#else
import AppKit
public typealias PlatformView = NSView
public typealias PlatformColor = NSColor
public typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// The few system services that differ between iOS and macOS, behind one name.
@MainActor public enum Platform {
    public static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    public static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    /// "iPad", "iPhone" or "Mac", for copy that names the device.
    public static var deviceName: String { isMac ? "Mac" : isPhone ? "iPhone" : "iPad" }

    /// The general pasteboard's text.
    public static var pasteString: String? {
        get {
            #if os(iOS)
            UIPasteboard.general.string
            #else
            NSPasteboard.general.string(forType: .string)
            #endif
        }
        set {
            #if os(iOS)
            UIPasteboard.general.string = newValue
            #else
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
            #endif
        }
    }

    public static var pasteboardHasImage: Bool {
        #if os(iOS)
        UIPasteboard.general.hasImages
        #else
        NSImage.canInit(with: .general)
        #endif
    }

    /// The pasteboard's image as PNG data.
    public static var pasteImagePNG: Data? {
        #if os(iOS)
        UIPasteboard.general.image?.pngData()
        #else
        NSImage(pasteboard: .general)?.pngData
        #endif
    }

    /// The app is frontmost (iOS: active scene; macOS: the active app).
    public static var isAppActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApp?.isActive ?? false
        #endif
    }

    /// iOS lets a backgrounded app finish briefly; a Mac app keeps running, so there this is a no-op.
    public static func beginBackgroundTask(_ name: String, expired: (@MainActor @Sendable () -> Void)? = nil) -> Int {
        #if os(iOS)
        UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expired?() } }.rawValue
        #else
        0
        #endif
    }
    public static func endBackgroundTask(_ id: Int) {
        #if os(iOS)
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
        #endif
    }

    public static func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

public extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

#if os(macOS)
public extension NSImage {
    var pngData: Data? {
        tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
    }
}
#endif

public extension View {
    /// Plain text entry (hosts, paths, tokens): no capitals or keyboard tricks on iOS; a no-op on the Mac.
    func plainTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
    /// The URL keyboard on iOS; a no-op on the Mac.
    func urlKeyboard(_ on: Bool = true) -> some View {
        #if os(iOS)
        keyboardType(on ? .URL : .default)
        #else
        self
        #endif
    }
}

public extension View {
    /// Hides the iOS navigation bar; a Mac NavigationStack shows none to begin with.
    func hiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

public extension View {
    /// A full-screen cover on iOS; a sheet on the Mac, which has no full-screen presentation.
    func fullScreenSheet<Item: Identifiable, C: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item) { content($0).frame(minWidth: 720, minHeight: 520) }
        #endif
    }
}

public extension View {
    /// Swipeable pages on iOS. ponytail: the Mac keeps TabView's own style; add arrow keys if the image viewer needs paging there.
    func pagedTabs(showIndex: Bool) -> some View {
        #if os(iOS)
        tabViewStyle(.page(indexDisplayMode: showIndex ? .always : .never))
        #else
        self
        #endif
    }
}
