# Canvas

A layered paint app for macOS, built with SwiftUI and AppKit. It's made for drawing with a
trackpad or mouse: brushes, layers with blend modes, selections, transforms, filters,
and a native file format that keeps every layer.

![Canvas with a four-layer sunset drawing](docs/screenshot.png)

## Features

- **Brushes:** hard and soft round, square, calligraphy, marker, chalk, spray and scatter
  presets, with size, opacity and hardness. You can also turn a selection into a custom
  brush (Edit ▸ Define Brush from Selection).
- **Tools:** eraser, line, rectangle and ellipse (stroke or fill), paint bucket with
  tolerance, text, eyedropper (or hold ⌥ while painting) and hand.
- **Layers:** add, duplicate, reorder by dragging, rename by double-clicking, show or
  hide, set opacity, and choose from 16 blend modes (Multiply, Screen, Overlay…).
- **Selections:** rectangle, ellipse, lasso and magic wand. ⇧ adds, ⌥ subtracts,
  ⇧⌥ intersects. Painting, filters and copy/paste stay inside the selection.
- **Move and Free Transform (⌘T):** move, scale, stretch, rotate, or ⌘-drag a corner to
  distort and add perspective. Edges and centres snap to the canvas (hold ⌃ to place
  freely).
- **Images:** paste (⌘V) or drag in images from Finder, a browser or a screenshot. They
  arrive as a new layer, ready to transform.
- **Filters:** Invert, Grayscale, Brightness/Contrast, Hue/Saturation, Gaussian Blur, Sharpen,
  Pixelate and Posterize, with a live preview.
- **Canvas:** opens on a default canvas; Image ▸ Canvas Size… (⌥⌘C) scales or crops it
  and changes the background. Zooming and panning run on the GPU (pinch, ⌘-scroll,
  Space-drag).
- **Files:** the `.canvas` format keeps layers, opacity and blend modes. You can open
  PNG/JPEG files and export PNG/JPEG (⇧⌘E). Autosave and versions come from macOS.
- **Undo:** up to 50 steps (⌘Z / ⇧⌘Z).

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later, to build it

## Install

Build an optimized copy and put it in `/Applications`:

```sh
scripts/install.sh          # build (Release) and install
scripts/install.sh --dmg    # also make build/Canvas.dmg to copy to another Mac
```

The app is ad-hoc signed rather than signed with an Apple Developer ID. It runs on the Mac
that built it. On another Mac, the first time, right-click the app and choose **Open**, or
use **System Settings ▸ Privacy & Security ▸ Open Anyway**.

## Build from source

Open `Canvas.xcodeproj` in Xcode and press **⌘R**. The Run action uses the Release
configuration, because the pixel code is several times faster with optimizations on.

```sh
# Run the tests (145 unit tests)
xcodebuild test -project Canvas.xcodeproj -scheme Canvas -destination 'platform=macOS'
```

The Xcode project is generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding or removing source files,
regenerate it:

```sh
brew install xcodegen
xcodegen generate
```

## Keyboard shortcuts

| Tool | Key | | Action | Keys |
|---|---|---|---|---|
| Brush | B | | Swap colors | X |
| Eraser | E | | Brush size | [ ] |
| Line | L | | Free Transform | ⌘T |
| Rectangle | R | | Apply / cancel transform | Return / Esc |
| Ellipse | O | | Deselect / inverse | ⌘D / ⇧⌘I |
| Paint bucket | G | | New layer | ⇧⌘N |
| Text | T | | Canvas size | ⌥⌘C |
| Eyedropper | I | | Zoom in / out / fit / 100% | ⌘+ / ⌘− / ⌘0 / ⌘1 |
| Hand | H | | Pan from any tool | hold Space |
| Select / Magic wand / Move | M / W / V | | Snap on/off | ⇧⌘; |

## How it's built

```
Canvas/
├── App/         app entry point, menus and commands
├── Document/    CanvasDocument (SwiftUI DocumentGroup) and the .canvas package format
├── Model/       CanvasModel, layers, bitmaps, selections, brushes, editor state
├── Tools/       one class per tool, plus transform and snapping
├── Rendering/   canvas view (AppKit), compositor, stroke renderer, flood fill, filters
├── History/     undo: dirty-rect pixel snapshots and layer-stack changes
├── IO/          image import and export
└── UI/          SwiftUI panels: tools, options bar, colors, layers, status bar, sheets
```

- Each layer is an 8-bit premultiplied RGBA `CGContext` with a top-left origin. Tools
  only ever see canvas pixel coordinates.
- The canvas view flattens the layers into one image, updating only the areas that
  change, and shows it through Core Animation. The GPU does the zooming and panning.
  Selection outlines, previews and transform handles are drawn on a separate overlay.
- Undo stores only the changed rectangle of a layer (before and after), so most steps
  cost kilobytes, not a full copy of the layer.
- A `.canvas` file is a package (a folder that Finder shows as one file): `manifest.json`,
  one PNG per layer in `layers/`, and a flattened `thumbnail.png`.

[`PLAN.md`](PLAN.md) has the full design notes and milestone history.
