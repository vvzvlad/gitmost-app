import AppKit
import WebKit
import DocmostCore

// A WKWebView subclass that intercepts drops of Markdown files anywhere over the web
// content and reports them, instead of letting the web editor swallow the drop.
// Non-Markdown drags are forwarded to WKWebView so normal web drag-and-drop (e.g.
// dropping an image into the editor) keeps working.
final class DragImportWebView: WKWebView {

    // Invoked on the main thread with the dropped Markdown file URLs.
    var onMarkdownFilesDropped: (([URL]) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // Ensure file drags reach this view (WKWebView already accepts them; be explicit).
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // Markdown file URLs carried by a drag, or [] when none / not a file drag.
    private func markdownURLs(_ sender: NSDraggingInfo?) -> [URL] {
        guard let sender else { return [] }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: options) as? [URL] ?? []
        return MarkdownImport.importableMarkdownFiles(from: urls)
    }

    // MARK: - NSDraggingDestination
    // For Markdown drags we deliberately DO NOT call super, so WKWebView never forwards
    // the drag to the web content — the editor can't claim it. Everything else falls
    // through to the default WKWebView behavior.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        markdownURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = markdownURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onMarkdownFilesDropped?(urls)
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if markdownURLs(sender).isEmpty { super.draggingExited(sender) }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if markdownURLs(sender).isEmpty { super.concludeDragOperation(sender) }
    }
}
