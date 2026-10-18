# Testing Uno

## 1. Automated tests

```bash
cd ~/Documents/B-Drive/Babar/Uno
bash run_tests.sh
```

Needs Xcode (free on the App Store). The run takes about 1–2 minutes and saves a log to `build/test-results.txt`. Each test builds its own sample PDFs and images in a temporary folder and never touches your files.

| Area | File | What is checked |
|---|---|---|
| Models, registry | `ModelsAndRegistryTests.swift` | Page sizes, quality levels, file naming, page ranges ("1-3, 7"), every tool fully described, no duplicate shortcuts, no other companies named, recent tools, opening files |
| PDF tools | `PDFEngineTests.swift` | Merge (PDFs + images, order, locked files), images to PDF (A4, transparency), split (per page and chunks), organize (order + rotation), delete, extract, compress (light / strong), add and remove password, PDF to images (dpi), OCR on scans, signature placement, safe overwrite, never overwriting |
| Batch resize / convert | `BatchImageTests.swift` | All six resize modes, "don't enlarge", photo rotation, every output format, keep original format, transparency fill, file-size limit, removing location data, never overwriting, save next to originals, combined PDF order, broken files, filters, straighten fallback |
| Image editor | `CanvasEditorTests.swift` | Canvas presets (A4 = 2480×3508, ID photo = 413×531…), adding images, move/resize/rotate by dragging, undo/redo, crop, rotate canvas, distort, layer commands, fit/fill/centre/flip/nudge, text, rendering accuracy, PNG/JPEG/PDF export at the right size and dpi, filters, straighten document |
| Inputs | `InputsAndUITests.swift` | File lists (kinds, folders, sorting, removing), PDF loading and passwords |
| Screens | `InputsAndUITests.swift` | Every screen, the editor in each mode, sheets and dark mode render without crashing |

## 2. Click-through checklist

Automated tests can't click buttons in a running app, so run this checklist after big UI changes. Tick each box.

### Home
- [ ] Each sidebar category (Everything, Images, PDF, On-device AI) shows the right tools
- [ ] Search finds "merge", "ocr" and "passport"; "Clear search" works
- [ ] Clicking a tile opens the tool; the back arrow returns home
- [ ] "Jump back in" shows recently used tools
- [ ] Dropping a PDF on the home screen opens Merge with it
- [ ] Settings opens; "Open results when finished" is remembered

### Every PDF tool (Split, Organize, Delete, Extract, Compress, Sign, Add/Remove Password, PDF to Images, Make Searchable)
- [ ] **Choose PDF…** opens the file picker
- [ ] Clicking anywhere in the drop area also opens it
- [ ] Dragging a PDF onto the drop area loads it
- [ ] "Choose Another…" replaces the file
- [ ] A password-protected PDF asks for the password; a wrong one shows an error
- [ ] The main button runs the tool; the progress bar moves; "Show in Finder" works

### Merge / Images to PDF / Batch Resize / Batch Convert
- [ ] **Choose Files…** and **Add** open the picker; a folder can be added
- [ ] A selected row shows the soft mist-blue highlight (no strong blue)
- [ ] Rows can be dragged to reorder; ↑/↓ in the right-click menu work
- [ ] The × on a row removes it; Sort and Clear work
- [ ] A typed number (pixels, KB) is used even without pressing Return

### Organize / Delete / Extract
- [ ] Thumbnails appear; click, ⌘-click and drag-to-reorder work
- [ ] Rotate left/right and Delete work; Reset restores the original
- [ ] Extract: a typed range "1-3, 5" selects those pages

### Sign PDF
- [ ] Draw… opens the pad; drawing and Save work; "Use Image…" works
- [ ] Add to This Page places a signature; it can be dragged and resized; Remove works

### Image Editor
- [ ] Every canvas preset and Custom size creates the right canvas; "Open an Image Instead…" works
- [ ] Add Image, Text and Paste work; dropping images onto the canvas adds them
- [ ] Drag to move, corner to resize, round handle to rotate (Shift snaps)
- [ ] Crop with each ratio; ⌘↩ applies; Esc cancels
- [ ] Distort: corners move freely; Reset Corners works
- [ ] Sliders, flips, Fit/Fill/Centre/Reset, filters, Straighten Document and Remove Background all work
- [ ] ⌘Z / ⇧⌘Z, arrow-key nudging and ⌫ delete work
- [ ] Export PNG/JPEG/PDF at each resolution; Print shows the true size

### Look and feel
- [ ] Light and dark mode both look right
- [ ] Buttons press in when clicked and always run their action
