# omarchy-canva-infinite

An infinite visual canvas plugin for [Omarchy](https://omarchy.org/) — dark, desktop-native, and inspired by Miro and modern creative whiteboards.

Create an unbounded canvas and freely drag, drop, move, resize, rotate, and edit images, text boxes, sticky notes, shapes, and project ideas. Zoom and pan, multi-select, align, reorder layers, import images, undo/redo, and everything autosaves. Multiple independent canvases, one per project.

It is a real Omarchy **shell plugin**: it lives inside the long-running `omarchy-shell` process and is summoned over shell IPC, not a separate app.

## Features

- **Infinite canvas** — pan with Space or the mouse wheel; zoom with Ctrl+wheel, `+`/`-`, or zoom-to-fit. Coordinates are canvas-space, so panning and zooming never move the document.
- **Objects** — text boxes, sticky notes, titles/headings, rectangles, ellipses, lines, arrows, and images.
- **Manipulate** — drag to move, corner handles to resize, a rotate handle to spin, double-click to edit text in place.
- **Multi-select** — Shift+click to add to a selection, or drag a marquee. Arrow keys nudge.
- **Align** — left/center/right, top/middle/bottom across the selection.
- **Layers** — bring to front, send to back, and step up/down.
- **Images** — pick from the desktop file chooser, or drag image files in from a file manager.
- **Undo/redo** — snapshot-based, so it stays correct as object types grow.
- **Autosave** — debounced writes to disk; the status bar shows the save state.
- **Multiple canvases** — each project is an independent document with its own file.

## Install

```bash
omarchy plugin add https://github.com/femalejourney9-code/omarchy-canva-infinite.git --enable --yes
python3 ~/.config/omarchy/plugins/io.github.hermes.canvas/install.py
```

The second command puts `omarchy-canvas` and `omarchy-canvas-open` on `~/.local/bin` and adds the `SUPER + SHIFT + C` hotkey. It is not required for the plugin itself — the plugin works from the shell alone.

For a standalone install (no git):

```bash
git clone https://github.com/femalejourney9-code/omarchy-canva-infinite.git
cd omarchy-canva-infinite
python3 install.py
```

Undo everything with:

```bash
python3 install.py --uninstall
omarchy plugin remove io.github.hermes.canvas --yes
```

## Usage

Open the canvas:

```
SUPER + SHIFT + C          # hotkey (added by install.py)
omarchy-canvas-open        # same thing from a terminal
omarchy-canvas open        # open a specific canvas
omarchy-shell shell summon io.github.hermes.canvas '{"doc":"default"}'
```

Manage canvases:

```bash
omarchy-canvas list                 # list every canvas
omarchy-canvas new "Product roadmap" # create and open a new one
omarchy-canvas remove <id>          # delete one
```

### Keys

| Key | Action |
| --- | --- |
| `V` | Select tool |
| `T` | Text tool |
| `S` | Sticky note tool |
| `R` / `E` / `L` | Rectangle / ellipse / line |
| `Shift + L` | Arrow |
| `Space` (hold) | Pan |
| Mouse wheel | Pan |
| `Ctrl + wheel` | Zoom |
| `+` / `-` | Zoom in / out |
| `0` | Reset zoom to 100% |
| `F` | Zoom to fit |
| `G` | Toggle grid |
| `Ctrl + Z` / `Ctrl + Y` | Undo / redo |
| `Ctrl + Shift + Z` | Redo |
| `Ctrl + A` | Select all |
| `Ctrl + D` | Duplicate selection |
| `Ctrl + C` / `Ctrl + X` / `Ctrl + V` | Copy / cut / paste |
| `Ctrl + S` | Save now |
| `Ctrl + I` | Add image |
| `Delete` | Delete selection |
| Arrow keys | Nudge selection by one grid step |
| `Shift + drag` | Marquee multi-select |
| `Esc` | Deselect, then close |

## How it works

The plugin declares two kinds:

- **`panel`** — `CanvasPanel.qml`, a `FloatingWindow` (a genuine Hyprland client, so it is movable, resizable, and minimizable like any app). This is the editor.
- **`service`** — `CanvasService.qml`, a headless singleton that owns the project index and answers the `canvas` IPC target.

Both read and write the same files under `~/.local/state/omarchy/canvas/<id>.json`.

### Layout

```
CanvasPanel.qml      window, toolbar, canvas surface, status bar, key handling
lib/CanvasDoc.qml    document model: geometry, camera, selection, undo, persistence
lib/CanvasItem.qml   one object, as a QtObject with real properties
lib/CanvasObject.qml per-object rendering and pointer handling
```

Two design decisions worth knowing:

- **Objects are `QtObject`s, not plain JS objects.** A plain object in a bound array never notifies QML, so `obj.x` bindings would not update during a drag. `CanvasItem` declares real `property`s, which is what makes dragging update the screen.
- **The `objects` array is only ever reassigned.** `push`/`splice` mutate in place and the view never updates. Structural changes reassign; geometry changes mutate `CanvasItem` properties.

## Development

```bash
omarchy plugin validate .                 # check the manifest
omarchy-shell shell rescanPlugins         # pick up QML edits
omarchy-restart-shell                     # reliable reload (the shell caches QML)
omarchy-shell shell summon io.github.hermes.canvas '{}'
journalctl --user -n 60 --no-pager | grep -iE "WARN scene|canvas"
```

Read `~/.config/omarchy/shell/README.md` and the first-party plugins under `/usr/share/omarchy/shell/plugins/` — they are the contract, and they ship with Omarchy.

## Status

Working: window, toolbar, canvas, objects (all seven types), drag/resize/rotate, multi-select, alignment, layers, undo/redo, image import, autosave, multiple canvases, CLI, hotkey, install/uninstall.

Known rough edges: the toolbar glyphs are Nerd Font icons that depend on the installed icon font, and the selection marquee is a simple rectangle rather than a dashed outline.
