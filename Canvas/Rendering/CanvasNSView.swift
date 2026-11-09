import AppKit
import Observation

/// Hosts the canvas: owns the view ⇄ canvas coordinate transform (zoom and pan), forwards
/// pointer events to the current tool, handles single-key shortcuts and hosts the text
/// tool's field.
///
/// Drawing is split in three, bottom to top:
/// - this view's `draw(_:)`: the backdrop, the canvas border and the transparency checkerboard;
/// - `imageView`: the layers flattened into `composite` at 1:1, shown through Core Animation,
///   which does the zooming on the GPU. Only changed rects are recomposited;
/// - `overlayView`: selection outline, tool previews, transform handles, snap guides.
///
/// This is the only type that knows about zoom and pan; tools see canvas pixels only.
final class CanvasNSView: NSView {
    var model: CanvasModel {
        didSet {
            guard model !== oldValue else { return }
            finishTextEntry(commit: false)
            cancelFreeTransform()
            composite = Bitmap(width: model.width, height: model.height)
            fitMode = .shrinkToFit
            updateTransform()
            compositeChanged(nil)
            observeCompositing()
            observeSelection()
        }
    }
    var editor: EditorState {
        didSet {
            guard editor !== oldValue else { return }
            observeEditor()
        }
    }
    var history: HistoryManager {
        didSet {
            guard history !== oldValue else { return }
            oldValue.onRestore = nil
            observeHistory()
        }
    }

    var viewport: Viewport {
        didSet {
            guard viewport !== oldValue else { return }
            viewport.view = self
            publishViewport()
        }
    }

    private var toolKind: ToolKind
    private var tool: Tool
    /// The tool handling the current mouse drag; a temporary eyedropper while ⌥ was held.
    private var dragTool: Tool?
    private var lastDragLocation: CGPoint?
    private lazy var temporaryEyedropper = EyedropperTool()
    private lazy var temporaryHand = HandTool()
    /// Free Transform in progress (⌘T): takes the mouse until applied or cancelled.
    private var freeTransform: FreeTransformTool? {
        didSet { viewport.isTransforming = freeTransform != nil }
    }
    /// Space is down: the next drag pans, whatever the tool.
    private var spaceHeld = false
    private var trackingArea: NSTrackingArea?
    private var savedMouseCoalescing = true
    private var keyMonitor: Any?

    // Rendering
    private let imageView = CanvasImageView()
    private let overlayView = CanvasOverlayView()
    /// All visible layers over the background, flattened at canvas size.
    private var composite: Bitmap
    /// Canvas area of `composite` that is out of date.
    private var staleComposite: CGRect = .null

    // Text tool
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private weak var textLayer: Layer?

    /// Canvas pixels → view points: `view = canvas * zoom + offset`.
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    private let fitPadding: CGFloat = 24

    private enum FitMode {
        /// Zoom and pan are under the user's control.
        case none
        /// Fit the window but never above 100% (new and opened documents).
        case shrinkToFit
        /// Fit the window, enlarging small canvases too (⌘0).
        case fit
    }
    private var fitMode: FitMode = .shrinkToFit

    init(model: CanvasModel, editor: EditorState, history: HistoryManager, viewport: Viewport) {
        self.model = model
        self.editor = editor
        self.history = history
        self.viewport = viewport
        self.toolKind = editor.tool
        self.tool = editor.tool.makeTool()
        self.composite = Bitmap(width: model.width, height: model.height)
        super.init(frame: .zero)
        // Since the macOS 14 SDK views don't clip by default and `draw(_:)` may be handed a
        // dirty rect reaching past the bounds; without this the backdrop paints over
        // the tool palette and options bar.
        clipsToBounds = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        imageView.canvas = self
        overlayView.canvas = self
        overlayView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        addSubview(overlayView)
        viewport.view = self
        compositeChanged(nil)
        observeHistory()
        observeCompositing()
        observeSelection()
        observeEditor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Observation

    /// Undo/redo change pixels outside of any tool event; redraw what they touched.
    private func observeHistory() {
        history.onRestore = { [weak self] layer, rect in
            guard let self, self.model.layers.contains(where: { $0 === layer }) else { return }
            self.invalidate(canvasRect: rect)
        }
    }

    /// Redraws when anything that affects the composite changes outside a tool event:
    /// layer order, visibility, opacity or blend mode, the background, or a layer's pixels
    /// (from the layers panel, an undo, a filter...).
    private func observeCompositing() {
        let model = self.model
        withObservationTracking {
            _ = model.background
            for layer in model.layers {
                _ = layer.isVisible
                _ = layer.opacity
                _ = layer.blendMode
                // Pixels changed outside a tool drag (filters, transforms, paste...).
                _ = layer.contentRevision
            }
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; react and re-arm on the next turn.
            DispatchQueue.main.async {
                guard let self, self.model === model else { return }
                self.compositeChanged(nil)
                self.needsDisplay = true // the checkerboard shows only without a background
                self.observeCompositing()
            }
        }
    }

    /// The selection only affects the overlay (outline), not the pixels.
    private func observeSelection() {
        let model = self.model
        withObservationTracking {
            _ = model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.model === model else { return }
                self.overlayView.needsDisplay = true
                self.updateMarchingAnts()
                self.observeSelection()
            }
        }
    }

    /// Follows tool changes (palette, shortcuts) and keeps the text field styled live.
    private func observeEditor() {
        let editor = self.editor
        withObservationTracking {
            _ = editor.tool
            _ = editor.primaryColor
            _ = editor.fontFamily
            _ = editor.fontSize
            _ = editor.brush.size
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.editor === editor else { return }
                if self.dragTool == nil { self.syncTool() }
                self.layoutTextField()
                self.refreshCursor() // brush outline follows size changes ([ ], slider)
                self.observeEditor()
            }
        }
    }

    private func syncTool() {
        guard editor.tool != toolKind else { return }
        finishTextEntry(commit: true)
        applyFreeTransform()
        toolKind = editor.tool
        tool = toolKind.makeTool()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Coordinate transform

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTransform()
    }

    /// Re-fits the canvas when in a fit mode; otherwise keeps the user's zoom and pan.
    private func updateTransform() {
        switch fitMode {
        case .none:
            break
        case .shrinkToFit, .fit:
            let w = CGFloat(model.width), h = CGFloat(model.height)
            let availableW = max(1, bounds.width - fitPadding * 2)
            let availableH = max(1, bounds.height - fitPadding * 2)
            var fitted = min(availableW / w, availableH / h)
            if fitMode == .shrinkToFit { fitted = min(1, fitted) }
            zoom = min(max(fitted, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
            offset = CGPoint(x: (bounds.width - w * zoom) / 2, y: (bounds.height - h * zoom) / 2)
        }
        transformDidChange()
    }

    /// Zooms so the canvas point under `anchor` (view coordinates; default: view center) stays put.
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let pinned = canvasPoint(fromView: anchor)
        fitMode = .none
        zoom = min(max(newZoom, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
        offset = anchor - pinned * zoom
        transformDidChange()
    }

    /// ⌘+ / ⌘−: the next preset level (100%, 150%, 200%...).
    func stepZoom(_ direction: Int) {
        setZoom(Viewport.nextLevel(after: zoom, direction: direction))
    }

    func zoomToFit() {
        fitMode = .fit
        updateTransform()
    }

    private func panBy(viewDelta delta: CGPoint) {
        fitMode = .none
        offset = offset + delta
        transformDidChange()
    }

    private func transformDidChange() {
        if fitMode == .none { clampOffset() }
        // Whole device pixels keep 100% crisp.
        let scale = window?.backingScaleFactor ?? 2
        offset = CGPoint(x: (offset.x * scale).rounded() / scale, y: (offset.y * scale).rounded() / scale)
        // Moving the image view is all panning and zooming take: the GPU rescales it.
        imageView.frame = viewRect(fromCanvas: model.bounds)
        imageView.layer?.magnificationFilter = zoom >= 2 ? .nearest : .linear
        overlayView.frame = bounds
        overlayView.needsDisplay = true
        needsDisplay = true
        layoutTextField()
        refreshCursor()
        publishViewport()
        refreshCursorLocation()
    }

    /// After zooming or panning the canvas moves under a still pointer; keep the status bar honest.
    private func refreshCursorLocation() {
        guard let window else { return }
        let inView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(inView) else { return }
        let p = canvasPoint(fromView: inView)
        let location = model.bounds.contains(p) ? CGPoint(x: p.x.rounded(.down), y: p.y.rounded(.down)) : nil
        if viewport.cursorLocation != location { viewport.cursorLocation = location }
    }

    /// Keeps at least a strip of the canvas on screen so it can't be lost off the edge.
    private func clampOffset() {
        let margin: CGFloat = 64
        let w = CGFloat(model.width) * zoom, h = CGFloat(model.height) * zoom
        offset.x = min(max(offset.x, min(margin, bounds.width / 2) - w), bounds.width - min(margin, bounds.width / 2))
        offset.y = min(max(offset.y, min(margin, bounds.height / 2) - h), bounds.height - min(margin, bounds.height / 2))
    }

    private func publishViewport() {
        if viewport.zoom != zoom { viewport.zoom = zoom }
    }

    func canvasPoint(fromView p: CGPoint) -> CGPoint {
        (p - offset) / zoom
    }

    func viewPoint(fromCanvas p: CGPoint) -> CGPoint {
        p * zoom + offset
    }

    func viewRect(fromCanvas r: CGRect) -> CGRect {
        CGRect(x: offset.x + r.minX * zoom, y: offset.y + r.minY * zoom,
               width: r.width * zoom, height: r.height * zoom)
    }

    func canvasRect(fromView r: CGRect) -> CGRect {
        CGRect(x: (r.minX - offset.x) / zoom, y: (r.minY - offset.y) / zoom,
               width: r.width / zoom, height: r.height / zoom)
    }

    // MARK: - Drawing

    /// Backdrop, canvas border and (for a transparent background) the checkerboard; the
    /// pixels themselves are `imageView`, on top.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(dirtyRect.intersection(bounds))

        let canvasFrame = viewRect(fromCanvas: model.bounds)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(canvasFrame.insetBy(dx: -0.5, dy: -0.5))

        if model.background == nil {
            // Squares a constant 8 points on screen, anchored to the canvas corner.
            let visible = canvasFrame.intersection(dirtyRect)
            guard !visible.isNull else { return }
            ctx.saveGState()
            ctx.translateBy(x: canvasFrame.minX, y: canvasFrame.minY)
            Compositor.drawCheckerboard(in: ctx, region: visible.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY),
                                        squareSize: 8)
            ctx.restoreGState()
        }
    }

    /// Called by `overlayView` (same coordinate space as this view).
    func drawOverlay(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: zoom, y: zoom)
        // During Free Transform the box replaces the (not yet moved) selection outline.
        if let selection = model.selection, freeTransform == nil {
            SelectionOutline.stroke(selection.outline, in: ctx, phase: antsPhase)
        }
        ctx.clip(to: model.bounds)
        (dragTool ?? freeTransform ?? tool).drawPreview(in: ctx, context: toolContext)
        ctx.restoreGState()
    }

    /// Marks part of the composite (nil: all of it) as out of date; it is rebuilt once per
    /// frame, when the image view next displays.
    private func compositeChanged(_ canvasRect: CGRect?) {
        staleComposite = staleComposite.union(canvasRect ?? model.bounds)
        imageView.needsDisplay = true
    }

    /// Brings the stale part of `composite` up to date (at 1:1, so it is cheap) and returns
    /// the image for the image view's layer.
    func flushComposite() -> CGImage? {
        let region = staleComposite.pixelAligned(clampedTo: model.bounds)
        staleComposite = .null
        if !region.isNull {
            let ctx = composite.context
            ctx.saveGState()
            ctx.clear(region)
            ctx.interpolationQuality = .none
            Compositor.draw(model, in: ctx, region: region, drawsCheckerboard: false)
            ctx.restoreGState()
        }
        return composite.makeImage()
    }

    // MARK: - Free Transform

    /// ⌘T: box with handles around the selection (or the layer's painted area).
    func beginFreeTransform() {
        guard freeTransform == nil else { return }
        finishTextEntry(commit: true)
        guard let session = TransformSession(model: model, history: history) else {
            NSSound.beep()
            return
        }
        freeTransform = FreeTransformTool(session: session)
        window?.makeFirstResponder(self)
        overlayView.needsDisplay = true
    }

    func applyFreeTransform() {
        guard let transform = freeTransform else { return }
        freeTransform = nil
        transform.session.commit(actionName: "Free Transform")
        compositeChanged(nil)
        overlayView.needsDisplay = true
    }

    func cancelFreeTransform() {
        guard let transform = freeTransform else { return }
        freeTransform = nil
        transform.session.cancel()
        compositeChanged(nil)
        overlayView.needsDisplay = true
    }

    private func arrowDelta(_ keyCode: UInt16, big: Bool) -> CGPoint? {
        let step: CGFloat = big ? 10 : 1
        switch keyCode {
        case 123: return CGPoint(x: -step, y: 0)
        case 124: return CGPoint(x: step, y: 0)
        case 125: return CGPoint(x: 0, y: step)
        case 126: return CGPoint(x: 0, y: -step)
        default: return nil
        }
    }

    // MARK: - Marching ants

    private var antsTimer: Timer?
    private var antsPhase: CGFloat = 0

    /// Animates the selection outline while there is a selection.
    private func updateMarchingAnts() {
        if model.selection == nil || window == nil {
            antsTimer?.invalidate()
            antsTimer = nil
            return
        }
        guard antsTimer == nil else { return }
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let selection = self.model.selection else { return }
            self.antsPhase = (self.antsPhase + 1).truncatingRemainder(dividingBy: 16)
            // Only the outline's area needs repainting.
            self.overlayView.setNeedsDisplay(self.viewRect(fromCanvas: selection.bounds).insetBy(dx: -3, dy: -3))
        }
    }

    private func invalidate(canvasRect r: CGRect) {
        guard !r.isNull else { return }
        if dragTool != nil { dragChangedPixels = true }
        compositeChanged(r)
        if freeTransform != nil || dragTool is MoveTool {
            // Handles and snap guides reach past the changed pixels.
            overlayView.needsDisplay = true
        } else {
            overlayView.setNeedsDisplay(viewRect(fromCanvas: r).insetBy(dx: -2, dy: -2))
        }
    }

    // MARK: - Mouse

    private var toolContext: ToolContext {
        ToolContext(model: model, editor: editor, history: history, host: self, zoom: zoom)
    }

    private func toolEvent(from event: NSEvent) -> ToolEvent {
        let p = convert(event.locationInWindow, from: nil)
        // Only pen tablets report real pressure; a mouse counts as full pressure.
        let pressure = event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
        return ToolEvent(location: canvasPoint(fromView: p),
                         pressure: pressure,
                         modifiers: event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        // A click while typing text just commits it.
        if textField != nil {
            finishTextEntry(commit: true)
            if toolKind == .text { return }
        }
        window?.makeFirstResponder(self)
        syncTool()

        // Double-click applies a free transform.
        if freeTransform != nil && event.clickCount == 2 {
            applyFreeTransform()
            return
        }
        let active: Tool
        if spaceHeld {
            active = temporaryHand
        } else if let freeTransform {
            active = freeTransform
        } else if event.modifierFlags.contains(.option) && toolKind.allowsTemporaryEyedropper {
            active = temporaryEyedropper
        } else {
            active = tool
        }
        let toolEvent = toolEvent(from: event)
        dragTool = active
        dragChangedPixels = false
        lastDragLocation = toolEvent.location
        // Deliver every drag sample instead of merging them, so fast strokes stay smooth.
        savedMouseCoalescing = NSEvent.isMouseCoalescingEnabled
        NSEvent.isMouseCoalescingEnabled = false
        invalidate(canvasRect: active.begin(toolEvent, context: toolContext))
    }

    /// Whether the current drag has painted anything (for recent colors).
    private var dragChangedPixels = false

    override func mouseDragged(with event: NSEvent) {
        updateCursorLocation(event)
        guard let dragTool else { return }
        let toolEvent = toolEvent(from: event)
        lastDragLocation = toolEvent.location
        invalidate(canvasRect: dragTool.drag(toolEvent, context: toolContext))
    }

    override func mouseUp(with event: NSEvent) {
        guard let active = dragTool else { return }
        dragTool = nil
        lastDragLocation = nil
        NSEvent.isMouseCoalescingEnabled = savedMouseCoalescing
        invalidate(canvasRect: active.end(toolEvent(from: event), context: toolContext))
        // Painting with the primary color adds it to the recent colors.
        let paintsWithColor = !(active is EraserTool) && (active is BrushTool || active is ShapeTool || active is FillTool)
        if paintsWithColor && dragChangedPixels { editor.noteColorUsed() }
        syncTool() // in case the tool was switched mid-drag
        currentCursor.set()
    }

    /// Pressing or releasing Shift mid-drag updates a shape preview without moving the mouse.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let dragTool = dragTool as? ShapeTool, let location = lastDragLocation else { return }
        let toolEvent = ToolEvent(location: location, pressure: 1, modifiers: event.modifierFlags)
        invalidate(canvasRect: dragTool.drag(toolEvent, context: toolContext))
    }

    private var isPanning: Bool { spaceHeld || toolKind == .hand }

    private var currentCursor: NSCursor {
        if isPanning { return .openHand }
        if toolKind == .brush || toolKind == .eraser {
            return BrushCursor.cursor(diameter: editor.brush.size * zoom)
        }
        return tool.cursor
    }

    /// Re-applies the cursor now (size or zoom changed while the pointer sat still).
    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
        guard dragTool == nil, let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if viewRect(fromCanvas: model.bounds).intersection(bounds).contains(p) || (isPanning && bounds.contains(p)) {
            currentCursor.set()
        }
    }

    override func resetCursorRects() {
        // Panning works anywhere in the view; drawing tools only over the canvas.
        let area = isPanning ? bounds : viewRect(fromCanvas: model.bounds).intersection(bounds)
        guard !area.isEmpty else { return }
        addCursorRect(area, cursor: currentCursor)
    }

    // MARK: - Pointer tracking (status bar)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursorLocation(event)
    }

    override func mouseExited(with event: NSEvent) {
        viewport.cursorLocation = nil
    }

    private func updateCursorLocation(_ event: NSEvent) {
        let p = canvasPoint(fromView: convert(event.locationInWindow, from: nil))
        let location = model.bounds.contains(p) ? CGPoint(x: p.x.rounded(.down), y: p.y.rounded(.down)) : nil
        if viewport.cursorLocation != location { viewport.cursorLocation = location }
    }

    // MARK: - Zoom & pan gestures

    /// Trackpad pinch, anchored under the fingers.
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double-tap: toggle between 100% and fit.
    override func smartMagnify(with event: NSEvent) {
        if abs(zoom - 1) < 0.001 {
            zoomToFit()
        } else {
            setZoom(1, anchor: convert(event.locationInWindow, from: nil))
        }
    }

    /// Scroll / two-finger swipe pans; with ⌘ or ⌥ held it zooms at the pointer.
    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if !event.modifierFlags.intersection([.command, .option]).isEmpty {
            let delta = event.scrollingDeltaY * (precise ? 1 : 8)
            setZoom(zoom * pow(1.01, delta), anchor: convert(event.locationInWindow, from: nil))
        } else {
            let factor: CGFloat = precise ? 1 : 10
            panBy(viewDelta: CGPoint(x: event.scrollingDeltaX * factor, y: event.scrollingDeltaY * factor))
        }
        updateCursorLocation(event)
    }

    // MARK: - Keyboard shortcuts

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMarchingAnts()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard window != nil else { return }
        // A window-level monitor, so shortcuts work whatever was clicked last (layers list,
        // sliders...), not only when the canvas itself has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.handleShortcut(event) else { return event }
            return nil
        }
    }

    /// Single-key shortcuts: tool letters (B, E, L, R, O, G, T, I, H), `[` / `]` for size,
    /// Space held for temporary panning, and ⌘= as a second Zoom In key.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        // Never steal typing from a text field (layer rename, text tool, ...).
        if window.firstResponder is NSText { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if event.keyCode == 49 /* space */ && modifiers.isEmpty {
            let held = event.type == .keyDown
            if held != spaceHeld {
                spaceHeld = held
                window.invalidateCursorRects(for: self)
                if dragTool == nil { currentCursor.set() }
            }
            return true
        }
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

        if modifiers == .command && key == "=" {
            stepZoom(1)
            return true
        }
        // ⌘Z / ⇧⌘Z while transforming just cancels the transform (a second ⌘Z then undoes
        // whatever came before, e.g. the paste), so undo never runs under an open session.
        if freeTransform != nil && key == "z" && (modifiers == .command || modifiers == [.command, .shift]) {
            cancelFreeTransform()
            return true
        }
        // Free Transform: Return / Enter apply, Esc cancels, arrows nudge.
        if freeTransform != nil && dragTool == nil && (modifiers.isEmpty || modifiers == .shift) {
            switch event.keyCode {
            case 36, 76: applyFreeTransform(); return true
            case 53: cancelFreeTransform(); return true
            default: break
            }
            if let delta = arrowDelta(event.keyCode, big: modifiers == .shift), let freeTransform {
                invalidate(canvasRect: freeTransform.nudge(by: delta))
                return true
            }
        }
        // Move tool: arrows nudge the selection (or the layer) by 1 px, Shift by 10.
        if toolKind == .move && freeTransform == nil && dragTool == nil && (modifiers.isEmpty || modifiers == .shift),
           let delta = arrowDelta(event.keyCode, big: modifiers == .shift) {
            if let session = TransformSession(model: model, history: history) {
                invalidate(canvasRect: session.apply(CGAffineTransform(translationX: delta.x, y: delta.y)))
                session.commit(actionName: "Nudge")
            } else {
                NSSound.beep()
            }
            return true
        }
        // Delete / Forward Delete clear the selected pixels; Esc deselects.
        if modifiers.isEmpty && model.selection != nil && dragTool == nil {
            switch event.keyCode {
            case 51, 117:
                PixelEdits.clearSelection(model: model, history: history)
                return true
            case 53:
                model.selection = nil
                return true
            default:
                break
            }
        }
        guard modifiers.isEmpty, dragTool == nil else { return false }

        if let kind = ToolKind.allCases.first(where: { $0.shortcut == key }) {
            editor.tool = kind
            return true
        }
        switch key {
        case "[": editor.stepSize(-1); return true
        case "]": editor.stepSize(1); return true
        case "x": editor.swapColors(); return true
        default: return false
        }
    }
}

// MARK: - Drag & drop images

extension CanvasNSView {
    private func droppedImage(_ info: NSDraggingInfo) -> (image: CGImage, name: String)? {
        guard let (image, name) = ImageImporter.image(from: info.draggingPasteboard) else { return nil }
        return (image, name ?? "Dropped Image")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageImporter.canRead(sender.draggingPasteboard) ? .copy : []
    }

    /// Dropping an image (file from Finder, or an image dragged from another app) adds it as a
    /// new layer centered where it was dropped.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (image, name) = droppedImage(sender) else { return false }
        finishTextEntry(commit: true)
        applyFreeTransform()
        let point = canvasPoint(fromView: convert(sender.draggingLocation, from: nil))
        PixelEdits.addImageLayer(image, centeredAt: point, name: name, model: model, history: history,
                                 actionName: "Drop Image")
        window?.makeKeyAndOrderFront(nil)
        // Handles straight away, to resize, rotate or distort the new image.
        beginFreeTransform()
        return true
    }
}

// MARK: - Text tool

extension CanvasNSView: ToolHost, NSTextFieldDelegate {
    func beginTextEntry(at canvasPoint: CGPoint) {
        finishTextEntry(commit: true)
        guard let layer = model.activeLayer, layer.isVisible, model.bounds.contains(canvasPoint) else {
            NSSound.beep()
            return
        }
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.delegate = self
        textField = field
        textOrigin = canvasPoint
        textLayer = layer
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
    }

    func pan(byCanvasDelta delta: CGPoint) {
        panBy(viewDelta: delta * zoom)
        NSCursor.closedHand.set()
    }

    /// Positions and styles the field to match how the text will be rasterized at this zoom.
    func layoutTextField() {
        guard let field = textField else { return }
        let font = TextTool.font(for: editor, scale: zoom)
        field.font = font
        field.textColor = NSColor(cgColor: editor.primaryColor) ?? .black
        // Measure what's being typed: while editing, the text lives in the field editor and
        // `sizeToFit()` would still measure the old (empty) value, so the field never grew.
        let text = field.currentEditor()?.string ?? field.stringValue
        let size = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font]).size()
        let p = viewPoint(fromCanvas: textOrigin)
        // A borderless field insets its text ~2 pt horizontally; shift so the glyphs line up.
        // Extra width leaves room for the caret after the last character.
        field.frame = CGRect(x: p.x - 2, y: p.y,
                             width: ceil(size.width) + 4 + max(8, font.pointSize * 0.5),
                             height: ceil(size.height) + 2)
    }

    func finishTextEntry(commit: Bool) {
        guard let field = textField else { return }
        textField = nil // first, so the end-editing callback below doesn't re-enter
        field.delegate = nil
        let text = field.stringValue
        if window?.firstResponder === field.currentEditor() {
            window?.makeFirstResponder(self)
        }
        field.removeFromSuperview()

        guard commit, !text.isEmpty, let layer = textLayer,
              model.layers.contains(where: { $0 === layer }) else { return }
        let dirty = TextTool.rasterize(text, at: textOrigin, font: TextTool.font(for: editor),
                                       color: editor.primaryColor, into: layer, history: history,
                                       clip: model.selection)
        invalidate(canvasRect: dirty)
        editor.noteColorUsed()
    }

    func controlTextDidChange(_ notification: Notification) {
        layoutTextField()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishTextEntry(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishTextEntry(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishTextEntry(commit: false)
            return true
        default:
            return false
        }
    }
}
