# Uno

Local, private file tools for macOS. Everything runs on your Mac, and nothing is uploaded.

**Design:** a soft neumorphic theme taken from the Uno logo: porcelain whites, taupe accents and muted sage, clay and lavender category colours. It adapts to light and dark mode. The colours and the raised/inset surfaces live in `Shared/Theme.swift`.

## Build & install

```bash
cd ~/Documents/B-Drive/Babar/Uno
bash build_app.sh --install
```

## Tools

**Image Editor:** a Photopea-style editor on one screen.
- **Canvas:** A4, A5, Letter, ID card, ID/passport photo, 10×15 photo, screen sizes or a custom size, at 150, 300 or 600 dpi. You can also open an existing image.
- **Images:** PNG, JPEG, HEIC, TIFF, WebP, GIF, BMP or a PDF page. Drag them in, add them from a file, or paste them.
- **Layers:** move, resize, rotate, skew, flip and set opacity, or distort by dragging four corners for perspective. You can also hide, duplicate and reorder layers.
- **Canvas edits:** crop with ratio presets (ID photo, ID card, A4…), rotate the canvas, set the background colour.
- **Filters:** Scanned document (colour or B&W), Photocopy, Scanned copy effect, B&W, Sepia, Vivid, Auto enhance. Also brightness, contrast, saturation and sharpness.
- **On-device AI:** Straighten Document, Remove Background.
- **Text:** text layers with a choice of font, size, colour and bold.
- **Output:** export PNG, JPEG or PDF at low to maximum resolution, or print at the exact physical size.
- **Undo:** ⌘Z / ⇧⌘Z. Arrow keys nudge the selected layer, ⌫ deletes it, Esc leaves the current mode.

**PDF:** Merge, Split, Organize (reorder/rotate/remove), Delete Pages, Extract Pages, Compress, Sign, Add Password, Remove Password, Images to PDF, PDF to Images

**On-device AI:** Make PDF Searchable (OCR using Apple Vision)

**Batch Resize:** resize many images by percentage, longest side, width, height, fit-in-box or exact size (crop to fill), with presets for social media, ID photos and A4.

**Batch Convert:** JPEG, PNG, HEIC, WebP, TIFF, GIF, BMP or PDF (the list comes from what this Mac can write). You can set the quality, fill transparency with a colour, and remove location and camera data. It can also **straighten documents** with on-device AI and apply any image editor filter (Scanned document, Photocopy, B&W…) with a live preview. PDF output can combine everything into one PDF. Quick setup turns phone photos into clean scans in one click.

Both batch tools can cap each file's size (e.g. under 500 KB) and process several images at once. They never overwrite your originals.

## Adding a new tool

1. Add a case to `ToolID` in `App/AppState.swift` with its title, subtitle, icon and category.
2. Create its screen in `Tools/<Category>/` using `ToolScaffold`.
3. Route it in `ToolView` (`Shared/Components.swift`).

The home grid, search and menu bar pick it up automatically.

## Project layout

```
Sources/Uno/
  App/      app entry, menus, tool registry, home screen
  Shared/   theme, PDF engine, models, reusable UI
  Tools/
    PDF/    one file per tool group
    Images/ canvas editor, batch resize/convert
```
