# Canvas — a personal macOS paint app

Build plan: what the app does, how it's built, what goes in each file, and the order to build it in.
Written so you can work through it by hand in Xcode or give one milestone at a time to an AI agent in Antigravity.

---

## 1. Goals and scope

**What it is:** A fast, simple raster paint app for macOS, like a cleaner MS Paint with layers. It's for personal use, so there's no App Store polish, accounts or sync.

**v1 features**
- Brush and eraser with adjustable size, opacity and hardness, plus pen-pressure support
- Color picker, recent colors and an eyedropper
- Layers: add, delete, reorder, hide/show, opacity, rename
- Shapes (line, rectangle, ellipse), paint bucket fill and a text tool
- Undo and redo
- Zoom and pan
- Open PNG/JPEG, export PNG/JPEG, and save/reopen a native `.canvas` file that keeps layers

**Not in v1** (ideas for later): selections and transform, filters, blend modes, custom brushes, iCloud.

---

## 2. Tech decisions

| Area | Choice | Why |
|---|---|---|
| Language | Swift 5.9+ | Native, works in both Xcode and Antigravity |
| Minimum OS | macOS 14 Sonoma | Allows the `@Observable` macro and modern SwiftUI |
| UI shell | SwiftUI (`DocumentGroup`) | Gives windows, tabs, Save/Open and recent files for free |
| Canvas | AppKit `NSView` wrapped in `NSViewRepresentable` | Precise mouse and tablet events (pressure, coalesced events, cursors). SwiftUI `Canvas` is too limited here. |
| Pixels | One `CGContext` bitmap per layer (premultiplied RGBA, 8-bit) | Simple, fast enough at 4K, easy to export |
| Undo | `UndoManager` + dirty-rect snapshots | Stores only the changed region, not whole layers |
| Project file | XcodeGen `project.yml` (optional but recommended) | The `.xcodeproj` is generated from text, which AI agents can edit safely |
| Tests | XCTest | Covers flood fill, file format and history logic |

**Possible later upgrade:** if very large canvases or big brushes get slow, the bitmap layer can move to Metal. Keep all rendering behind `Compositor` and `StrokeRenderer` so that swap stays contained.

---

## 3. File structure

```
Canvas/
├── project.yml                     # XcodeGen spec (generates Canvas.xcodeproj)
├── PLAN.md                         # this file
├── Canvas/
│   ├── App/
│   │   ├── CanvasApp.swift         # @main, DocumentGroup, window setup
│   │   └── AppCommands.swift       # Menu bar commands + keyboard shortcuts
│   │
│   ├── Document/
│   │   ├── CanvasDocument.swift    # ReferenceFileDocument: read/write, owns CanvasModel
│   │   └── DocumentFormat.swift    # .canvas package layout (manifest.json + layer PNGs)
│   │
│   ├── Model/
│   │   ├── CanvasModel.swift       # @Observable: size, layers, activeLayerID, background
│   │   ├── Layer.swift             # id, name, isVisible, opacity, bitmap
│   │   ├── Bitmap.swift            # CGContext wrapper: create, copy region, read pixel, makeImage
│   │   ├── EditorState.swift       # @Observable: current tool, color, brush settings, zoom
│   │   ├── BrushSettings.swift     # size, opacity, hardness, spacing, pressure toggles
│   │   └── ToolKind.swift          # enum: brush, eraser, line, rect, ellipse, fill, text, eyedropper, hand
│   │
│   ├── Tools/
│   │   ├── Tool.swift              # protocol: mouseDown/Dragged/Up, cursor, preview drawing
│   │   ├── BrushTool.swift         # Stamps dabs along an interpolated, smoothed path
│   │   ├── EraserTool.swift        # BrushTool with .clear blend mode
│   │   ├── ShapeTool.swift         # Line/rect/ellipse with live preview; Shift constrains
│   │   ├── FillTool.swift          # Calls FloodFill with a tolerance setting
│   │   ├── TextTool.swift          # Click to place a text field, commit rasterizes to the layer
│   │   ├── EyedropperTool.swift    # Samples the composited color under the cursor
│   │   └── HandTool.swift          # Pan (also Space + drag from any tool)
│   │
│   ├── Rendering/
│   │   ├── CanvasView.swift        # NSViewRepresentable bridge to SwiftUI
│   │   ├── CanvasNSView.swift      # Event handling, coordinate transforms, draw(_:)
│   │   ├── Compositor.swift        # Composites visible layers + checkerboard + tool preview
│   │   ├── StrokeRenderer.swift    # Dab generation, spacing, pressure → size/opacity
│   │   └── FloodFill.swift         # Scanline flood fill with color tolerance
│   │
│   ├── History/
│   │   ├── HistoryManager.swift    # beginEdit(rect, layer) / commit() → registers undo
│   │   └── BitmapSnapshot.swift    # Before/after pixel data for a rect on one layer
│   │
│   ├── UI/
│   │   ├── ContentView.swift       # Main layout: toolbar | canvas | right sidebar
│   │   ├── ToolPalette.swift       # Vertical tool buttons (left)
│   │   ├── ToolOptionsBar.swift    # Top bar: size/opacity/hardness sliders, fill tolerance, font
│   │   ├── ColorPanel.swift        # ColorPicker, primary/secondary swatches, recent colors
│   │   ├── LayersPanel.swift       # Layer list, + / – / duplicate, drag to reorder
│   │   ├── LayerRow.swift          # Thumbnail, name (editable), eye toggle, opacity
│   │   ├── CanvasSizeSheet.swift   # Image ▸ Canvas Size: presets, resize/crop, background, default
│   │   └── StatusBar.swift         # Zoom %, cursor position, canvas size
│   │
│   ├── IO/
│   │   ├── ImageImporter.swift     # Open PNG/JPEG → new document with one layer
│   │   └── ImageExporter.swift     # Flatten → PNG/JPEG (NSSavePanel, JPEG quality)
│   │
│   ├── Utilities/
│   │   ├── CGGeometry+Ext.swift    # Point math, rect union/clamp, distance, lerp
│   │   └── Color+Ext.swift         # NSColor/CGColor/SwiftUI Color conversions, RGBA8
│   │
│   └── Resources/
│       ├── Assets.xcassets         # App icon, tool icons (or use SF Symbols)
│       ├── Info.plist              # Declares the .canvas document type + UTType export
│       └── Canvas.entitlements     # Sandbox + user-selected read/write files
│
└── CanvasTests/
    ├── FloodFillTests.swift
    ├── DocumentFormatTests.swift
    ├── BitmapTests.swift
    └── HistoryTests.swift
```

---

## 4. How the pieces fit

```
SwiftUI (ContentView, panels)
      │ reads/writes
      ▼
EditorState ──── current Tool ────┐
CanvasModel (layers) ◄────────────┤
      ▲                           │
      │ redraw                    │ mouse/tablet events
CanvasNSView ── Compositor        │
      └──────── forwards events ──┘
                     │
               HistoryManager → UndoManager
```

**What happens during a brush stroke**
1. `CanvasNSView.mouseDown` converts the view point to a canvas point (accounting for zoom and pan) and calls `tool.begin`.
2. `BrushTool` calls `history.beginEdit(on: layer)`.
3. On `mouseDragged`, the tool reads `event.pressure` and interpolates dabs at `spacing × size` intervals. `StrokeRenderer` stamps them into the layer bitmap, and the tool sends back the dirty rect.
4. The view calls `setNeedsDisplay(dirtyRect)`, and `Compositor` redraws only that region.
5. On `mouseUp`, `history.commit()` snapshots the union of dirty rects (before and after) and registers undo.

**Coordinate rule:** every tool works in **canvas pixel coordinates**. Only `CanvasNSView` knows about zoom and pan.

---

## 5. Native file format (`.canvas`)

It's a package (a folder that Finder shows as one file):

```
MyDrawing.canvas/
├── manifest.json     # { version, width, height, layers: [{id, name, visible, opacity, file}] }
├── layers/
│   ├── <uuid>.png
│   └── ...
└── thumbnail.png     # Flattened preview for Finder/QuickLook
```

- Declare `com.yourname.canvas` as an exported UTType in Info.plist (conforms to `com.apple.package`).
- Read and write through `FileWrapper` in `CanvasDocument`.
- Include `version` from day one so the format can change later without breaking old files.

---

## 6. Keyboard shortcuts

| Action | Key |
|---|---|
| Brush / Eraser | B / E |
| Line / Rectangle / Ellipse | L / R / O |
| Fill / Text / Eyedropper | G / T / I |
| Hand (temporary) | hold Space |
| Eyedropper (temporary) | hold ⌥ while brushing |
| Brush size − / + | [ / ] |
| Swap primary/secondary color | X |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| New layer | ⇧⌘N |
| Zoom in / out / fit / 100% | ⌘+ / ⌘− / ⌘0 / ⌘1 |
| Export | ⇧⌘E |

---

## 7. Build milestones

Every milestone ends with an app that builds and runs. Give an AI agent one milestone at a time.

### M0 — Project setup
- [ ] Install XcodeGen (`brew install xcodegen`), write `project.yml`, run `xcodegen`
- [ ] App target with macOS 14 deployment, sandbox entitlements, and an empty `DocumentGroup` window
- [ ] Confirm it builds with `xcodebuild -scheme Canvas build` (Antigravity can run this in its terminal)

### M1 — Draw something
- [ ] `Bitmap`, `Layer`, `CanvasModel` (single layer, white background)
- [ ] `CanvasNSView` + `CanvasView`, `Compositor` (one layer)
- [ ] `BrushTool` + `StrokeRenderer` with interpolation, so fast strokes don't leave gaps
- [ ] `ColorPanel` with SwiftUI `ColorPicker`, plus a size slider
- **Done when:** you can draw smooth colored lines.

### M2 — Undo, eraser, import/export
- [ ] `HistoryManager` + `BitmapSnapshot` wired to `UndoManager`
- [ ] `EraserTool`
- [ ] `ImageExporter` (PNG/JPEG) and `ImageImporter`
- **Done when:** you can draw, undo and export a PNG that opens in Preview.

### M3 — Layers
- [ ] Multiple layers in `CanvasModel`, with `Compositor` handling visibility and opacity
- [ ] `LayersPanel` + `LayerRow` (thumbnails, rename, reorder, eye toggle, opacity)
- [ ] Undo support for layer add, delete and reorder
- **Done when:** you can paint on separate layers and hide or reorder them.

### M4 — More tools
- [ ] `ShapeTool` (live preview; Shift for straight lines and squares/circles; stroke or fill)
- [ ] `FloodFill` + `FillTool` with tolerance, tested in `FloodFillTests`
- [ ] `EyedropperTool`, `TextTool`
- [ ] `ToolPalette` + `ToolOptionsBar`, and keyboard shortcuts in `AppCommands`

### M5 — Navigation and native files
- [ ] Zoom (pinch, ⌘+/−, fit) and pan (scroll, Space+drag, trackpad)
- [ ] `.canvas` package read/write in `DocumentFormat` + `CanvasDocument`, tested in `DocumentFormatTests`
- [ ] `NewCanvasSheet` (sizes: 1920×1080, 2048×2048, A4 @ 300dpi, custom) — later replaced: new documents open on a default canvas; `CanvasSizeSheet` (Image ▸ Canvas Size…, ⌥⌘C) changes size/background afterwards and can save the default
- [ ] `StatusBar`

### M6 — Polish
- [ ] Pen pressure mapped to size and/or opacity (toggles in `BrushSettings`)
- [ ] Brush hardness (soft round dab via radial gradient)
- [ ] Custom cursors showing brush outline at current size and zoom
- [ ] Recent colors, primary/secondary swatches with X to swap
- [ ] App icon

### v2 — the "Not in v1" list

iCloud is left out: real iCloud sync needs an iCloud entitlement signed with a paid Apple Developer team. Saving `.canvas` files into the iCloud Drive folder already syncs them.

### M7 — Blend modes
- [ ] `Layer.blendMode` (normal, multiply, screen, overlay, darken, lighten, color dodge/burn, soft/hard light, difference, exclusion, hue, saturation, color, luminosity)
- [ ] `Compositor`, export, eyedropper and file thumbnail honor it
- [ ] Blend-mode picker in `LayersPanel`; duplicate copies it
- [ ] `.canvas` format version 2 stores it (version 1 files still open)

### M8 — Selections
- [ ] `Selection` (8-bit mask + bounds + outline path), marching ants
- [ ] Tools: Select (M; rectangle, ellipse or lasso, picked in the options bar) and Magic Wand (W); Shift adds, ⌥ subtracts, both intersect
- [ ] Select All ⌘A, Deselect ⌘D, Invert ⇧⌘I
- [ ] Painting, erasing, shapes, fill and text stay inside the selection
- [ ] Delete clears the selection; Cut / Copy / Paste (paste as a new layer, also from other apps)

### M9 — Transform
- [ ] Move tool (V): drag the selected pixels, or the whole layer when nothing is selected
- [ ] Free Transform (⌘T): scale and rotate with handles; Shift keeps proportions; Return applies, Esc cancels
- [ ] One undo step per move or transform

### M10 — Filters
- [ ] Filter menu: Invert, Grayscale, Brightness/Contrast, Hue/Saturation, Gaussian Blur, Sharpen, Pixelate, Posterize
- [ ] Settings sheet with live preview; applies to the selection if there is one; undoable

### M11 — Custom brushes
- [ ] Brush tips: round, square, flat (calligraphy), chalk, spray, and image tips defined from a selection
- [ ] Dynamics: scatter, size jitter, angle (fixed or follows the stroke)
- [ ] Brush presets: built-in set plus saved custom presets

---

## 8. Working in Antigravity vs. Xcode

- **Antigravity:** good for writing and refactoring Swift across many files. Builds still need Apple's toolchain, so install Xcode and run `xcodebuild` from Antigravity's terminal. Regenerate the project with `xcodegen` whenever you add or remove files, so the agent never has to edit `.pbxproj` by hand.
- **Xcode:** use it for running, debugging, the view debugger and Instruments (Time Profiler, if brushing feels laggy).
- **Prompt tip:** "Read PLAN.md. Implement milestone M1 only. Follow the file structure in section 3 and the canvas-coordinate rule in section 4. Make sure `xcodebuild` succeeds."

---

## 9. Known tricky parts

- **Smooth strokes:** interpolate between mouse events and enable `NSEvent` coalesced events, or fast strokes will look dotted.
- **Retina:** keep layer bitmaps at canvas pixel size. Scale only when compositing to the view, and turn off interpolation at high zoom so pixels stay crisp.
- **Premultiplied alpha:** eyedropper and flood fill must un-premultiply before comparing colors.
- **Undo memory:** snapshot only dirty rects, and cap history (for example, 50 steps).
- **Sandbox:** export and import must go through `NSSavePanel` / `NSOpenPanel` (or the document system) to get file access.

## Performance and shipping

- [x] Canvas display on the GPU: layers are flattened into one canvas-size composite, updated
      only in changed rects at 1:1; Core Animation zooms and pans it (`CanvasImageView`).
      Selection outline, previews, transform handles and guides draw in `CanvasOverlayView`.
      Before: ~100 ms per full redraw (pan/zoom/transform) with 5 layers at 1920×1080.
- [x] Transform steps report only the area they changed.
- [x] Xcode's Run uses the Release configuration (Swift pixel loops 3–20× faster); tests stay Debug.
- [x] `scripts/install.sh` installs a Release build in /Applications (`--dmg` also makes a disk image).
- [x] Free, open-source distribution without the Apple Developer Program: MIT license,
      version 1.0.0, `scripts/build-release.sh` (universal app + drag-to-install DMG),
      GitHub Actions CI (tests on push) and release (tag `v<version>` → GitHub Release).
      Ad-hoc signed, so first launch needs Privacy & Security ▸ Open Anyway (documented).
