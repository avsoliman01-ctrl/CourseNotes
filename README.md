# CourseNotes

An iPad-only handwritten note app for university coursework, built with SwiftUI and PencilKit.
It targets iPad Air (M2) on iPadOS 17.5+ and uses Apple Pencil Pro hardware: squeeze, double-tap,
hover, barrel roll and Pencil haptics.

- **Semester → Course → Module → Note** hierarchy, with color coding, course icons and default
  modules (Lectures, Labs, Homework, Exam Prep).
- **Search and filter** by title, course (code, title or instructor) or `#tag`, plus a
  "Created" date filter and sort options. Grid and list layouts.
- **Canvas**: full-width `PKCanvasView` with pinch-zoom, a floating tool palette (pen, fountain pen,
  pencil, highlighter, monoline, object and pixel eraser, lasso), colors, stroke width, ruler and undo/redo.
- **Paper templates**: Blank, Graph Paper, College Ruled and Dot Grid. They scroll and zoom with the ink.
- **Apple Pencil Pro**:
  - Double-tap toggles the eraser.
  - Squeeze opens a radial palette under the pencil tip, or cycles colors or tools.
  - Hover shows a reticle for tilt and barrel roll.
  - Haptics play through the pencil. On iPad, `UICanvasFeedbackGenerator` is the feedback type
    Apple Pencil Pro plays. `UIImpactFeedbackGenerator` and `UISelectionFeedbackGenerator` are
    triggered too, and the system skips whatever the hardware can't play.
- **Lasso editing**: select strokes, then move, resize, recolor, duplicate or delete them. Edits change
  the real stroke geometry, so they save, undo and export like any other ink.
- **Pages**: every note opens with two pages of paper and grows as you scroll or write.
- **Floating palette**: drag it anywhere, pin it, or collapse it to a small button.
- **Shape correction**: draw a rough shape and hold the pencil still to snap it to a clean one.
- **Handwriting smoothing** (optional): evens out tremor and jagged curves without rewriting anything.
- **Storage**: `PKDrawing` binary data plus JSON metadata on disk. The library is visible in the
  Files app, and you can export a one-tap backup zip. Notes export as multi-page PDFs.

---

## Project layout

```
note_app/
├── project.yml                         XcodeGen spec (generates CourseNotes.xcodeproj)
├── .github/workflows/build-unsigned-ipa.yml   CI build for Windows users → unsigned .ipa
└── CourseNotes/
    ├── Info.plist
    ├── App/CourseNotesApp.swift        @main, environment injection, flush on background
    ├── Models/
    │   ├── LibraryModels.swift         Semester, Course, CourseModule, NoteDocument, tags, scopes
    │   └── PaperTemplate.swift         Templates + the one renderer used by canvas, thumbnails, PDF
    ├── Persistence/
    │   ├── CourseDataManager.swift     Observable store: CRUD, search/filter, ink I/O, backups
    │   └── NoteRenderer.swift          Thumbnails and multi-page PDF export (off the main thread)
    ├── Pencil/
    │   ├── ApplePencilManager.swift    Tool state machine, gesture → action mapping, preferences
    │   ├── DrawingTools.swift          Tool kinds, ink palettes, presets, PKTool construction
    │   └── HapticEngine.swift          Canvas (Pencil Pro), impact and selection feedback hooks
    ├── Canvas/
    │   ├── PencilCanvasView.swift      UIViewRepresentable + coordinator (PencilKit, pencil
    │   │                               interaction, hover, haptics) and CanvasController
    │   ├── CanvasViews.swift           Paper background, page allocation, canvas, hover reticle
    │   ├── LassoSelection.swift        Custom lasso: select, move, resize, recolor (with undo)
    │   ├── InkAssistant.swift          Hold detection, shape preview, smoothing scheduling
    │   ├── ShapeRecognizer.swift       Geometric classifier: line, ellipse, polygon, polyline
    │   └── StrokeProcessing.swift      Stroke smoothing and shape-to-ink conversion
    ├── Views/
    │   ├── SidebarView.swift           NavigationSplitView root + sidebar
    │   ├── DashboardView.swift         Course grid, module chips, searchable notes grid/list
    │   ├── LibraryCards.swift          Course/note cards, thumbnails
    │   ├── LibraryForms.swift          Semester/course/module forms, delete confirmation, sheet routing
    │   ├── NoteForms.swift             New note, note details, template picker
    │   ├── NoteEditorView.swift        Canvas workspace + view model (autosave, PDF export)
    │   ├── ToolPaletteView.swift       Tool palette contents (full, compact and vertical layouts)
    │   ├── FloatingPalette.swift       Draggable, pinnable, hideable palette container
    │   ├── SelectionToolbarView.swift  Lasso action bar + on-device text recognition
    │   ├── RadialPaletteView.swift     Squeeze palette + gesture toasts
    │   ├── SettingsView.swift          Pencil gestures, drawing, defaults, backup
    │   └── ActivityView.swift          Share sheet
    └── Resources/Assets.xcassets       App icon, accent color
```

### Architecture (MVVM)

| Layer | Types | Responsibility |
|---|---|---|
| Model | `Semester`, `Course`, `CourseModule`, `NoteDocument`, `PaperTemplate`, `ToolConfiguration` | Plain `Codable` value types |
| Store / view models | `CourseDataManager`, `ApplePencilManager`, `NoteEditorViewModel`, `CanvasController` | `@Observable` state on the `@MainActor`. All mutations go through methods. |
| Views | SwiftUI views + `PencilCanvasView` (UIKit bridge) | Render state and forward user intent |

Data flow for a stroke: `PKCanvasView` → the coordinator's `canvasViewDrawingDidChange` →
`NoteEditorViewModel.drawingChanged` (1.5 s debounce) → `CourseDataManager.saveDrawing`. That writes
the ink atomically on a serial I/O queue, regenerates the thumbnail, then bumps `modifiedAt` so the
dashboard refreshes.

Data flow for a pencil gesture: `UIPencilInteraction` → coordinator → `ApplePencilManager.handleDoubleTap/
handleSqueeze`, which returns an outcome. The coordinator then plays the matching haptic at the
pencil's hover location.

---

## Requirements

| | |
|---|---|
| Device | iPad Air (M2) or any iPad on **iPadOS 17.5+**. Hover needs an M2-or-later iPad. Squeeze, barrel roll and haptics need **Apple Pencil Pro**. Double-tap works on Pencil Pro and Pencil (2nd gen). |
| Build | A Mac with **Xcode 15.4 or later**: the squeeze and roll APIs first shipped in the iPadOS 17.5 SDK. On Windows, use the included **GitHub Actions** workflow instead. |
| Dependencies | None. PencilKit, SwiftUI and UIKit are system frameworks. |

---

## Option A: Generate the project with XcodeGen (Mac, recommended)

1. Install XcodeGen:

   ```bash
   brew install xcodegen
   ```

2. In `project.yml`, change `bundleIdPrefix: com.yourname` to something unique, such as `com.jdoe`.
   Free Apple IDs can't sign a bundle ID that someone else has already registered.

3. Generate and open the project:

   ```bash
   xcodegen generate
   ```

   ```bash
   open CourseNotes.xcodeproj
   ```

4. Select the **CourseNotes** target, open **Signing & Capabilities**, and set **Team** to your Apple ID
   (shown as "Personal Team" for a free account).

5. Plug in the iPad, select it as the run destination, and press **⌘R**. See
   [Install from Xcode](#install-from-xcode) for the one-time device setup.

## Option B: Create the Xcode project by hand

1. **File › New › Project › iOS › App.** Use Product Name `CourseNotes`, Interface **SwiftUI**,
   Language **Swift**, Storage **None**, and no tests.
2. Delete the generated `ContentView.swift`, `CourseNotesApp.swift` and `Assets.xcassets`.
   This repo provides its own `@main` and assets.
3. Drag the `App`, `Models`, `Persistence`, `Pencil`, `Canvas`, `Views` and `Resources` folders and
   `Info.plist` into the project navigator. Choose "Create groups" and tick the CourseNotes target.
4. In **General**:
   - **Supported Destinations**: remove iPhone, Mac (Designed for iPad) and Apple Vision. Keep **iPad**.
   - **Minimum Deployments**: iOS **17.5**.
   - **Frameworks, Libraries, and Embedded Content**: optionally add **PencilKit.framework**.
     `import PencilKit` already auto-links it.
5. In **Build Settings**:
   - **Info.plist File**: `CourseNotes/Info.plist`
   - **Generate Info.plist File**: `No`
   - **Swift Language Version**: `Swift 5`
   - **Strict Concurrency Checking**: `Minimal`
   - **Asset Catalog App Icon Set Name**: `AppIcon`
6. If Xcode added `Info.plist` to **Build Phases › Copy Bundle Resources**, remove it there.
   Otherwise you get "Multiple commands produce Info.plist".
7. Set up signing as in Option A, step 4.

### Info.plist

PencilKit, Apple Pencil gestures, hover and haptics need **no privacy permission keys**. The keys
this app sets are:

| Key | Value | Why |
|---|---|---|
| `UISupportedInterfaceOrientations` / `~ipad` | All four | Required for Split View, Slide Over and Stage Manager |
| `UILaunchScreen` | `{}` | Modern launch screen without a storyboard |
| `UIApplicationSupportsIndirectInputEvents` | `YES` | Trackpad and mouse pointer support |
| `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` | `YES` | Shows the library under **Files › On My iPad › CourseNotes**, for backups |
| `UIApplicationSceneManifest › UIApplicationSupportsMultipleScenes` | `NO` | One window, so the same note can't be open twice |
| `ITSAppUsesNonExemptEncryption` | `NO` | Skips the export-compliance question |

If you later add "Save Image to Photos", add `NSPhotoLibraryAddUsageDescription`.

---

## Install on your iPad

### Install from Xcode

1. Connect the iPad, trust the Mac, and select the iPad in Xcode once.
2. On the iPad, open **Settings › Privacy & Security › Developer Mode**, turn it on, and restart.
3. Run from Xcode. With a free Apple ID, also open **Settings › General › VPN & Device Management**,
   tap your Apple ID and choose **Trust**.
4. Free-account builds expire after **7 days**. Run from Xcode again to renew; your notes are kept.
   A paid Developer Program account signs for one year.

### Windows: GitHub Actions + AltStore or SideStore

You can't run Xcode on Windows, so the included workflow builds the app on a GitHub-hosted Mac. It
produces an **unsigned** `.ipa`, which AltStore or SideStore re-sign with your own Apple ID.

1. **Put the project on GitHub.** You can drag the folder into a new repo on github.com
   (**Add file › Upload files**), or use git:

   ```bash
   git init -b main
   ```

   ```bash
   git add .
   ```

   ```bash
   git commit -m "CourseNotes"
   ```

   ```bash
   git remote add origin https://github.com/<you>/CourseNotes.git
   ```

   ```bash
   git push -u origin main
   ```

   Private repositories work too, but macOS runner minutes count at a higher rate against the free
   Actions quota.

2. **Build.** Every push to `main` starts the workflow. You can also run it from
   **Actions › Build unsigned IPA › Run workflow**. When it finishes, download the
   `CourseNotes-unsigned-ipa` artifact and unzip it to get `CourseNotes-unsigned.ipa`.

3. **Sideload** with either tool:
   - **AltStore (classic).** Install AltServer on Windows from [altstore.io](https://altstore.io).
     Its guide lists the exact iTunes and iCloud builds AltServer needs. Use AltServer to install
     AltStore on the iPad, then enable **Developer Mode** and trust your Apple ID as above. Copy the
     `.ipa` to the iPad (for example through iCloud Drive), then open **AltStore › My Apps › +** and
     choose it. Apps refresh every 7 days while AltServer is running on the same Wi-Fi network.
   - **SideStore.** After a one-time setup with a computer (a pairing file, see
     [docs.sidestore.io](https://docs.sidestore.io)), SideStore signs and refreshes apps on the iPad
     itself. Install the `.ipa` from **My Apps › +**.

4. **Free Apple ID limits** apply to both tools:
   - Apps expire after 7 days unless refreshed.
   - You can have at most 3 sideloaded apps active at once, and the sideloading tool counts as one.
   - You can register at most 10 App IDs per week.

   Refreshing keeps your notes. **Deleting the app deletes them**, so use
   **Settings › Export Library Backup** regularly.

---

## Using the app

| Action | How |
|---|---|
| Toggle eraser | Double-tap Apple Pencil. You can change this in Settings: previous tool, palette, follow system or off. |
| Radial palette | Squeeze Apple Pencil Pro. The palette opens under the hovering tip: tools on the inner ring, colors and widths on the outer ring. Squeeze again or tap outside to close. |
| Quick-cycle instead | Settings › Squeeze › *Cycle Black → Blue → Red → Highlight* or *Cycle Pen → Highlighter → Lasso* |
| Tilt and barrel roll | Pencil and fountain pen shade with tilt. The fountain pen and highlighter follow Pencil Pro barrel roll. The hover reticle shows tilt and roll before you touch down. |
| Scroll and zoom | Use your finger by default. **Settings › Draw With** can let fingers draw too. |
| Eraser modes | Tap the eraser again: Object (whole strokes) or Pixel (adjustable width) |
| Ruler, paper, export | Use the editor toolbar. **More › Export PDF** produces US-Letter pages. |
| Undo / redo | Palette buttons, ⌘Z / ⇧⌘Z on a keyboard |
| Search | Type in the search bar and use the scopes (All, Title, Course, Tag). `#midterm` searches tags only. |
| Rename, tag or move a note | Long-press its card, or tap the title in the editor |
| New note while writing | Tap **+** in the editor's toolbar. The sheet starts on the current course and module, the open note is saved, and the new note opens. |
| Scroll ahead | Every note has at least two pages. Scroll down before writing; another page is added whenever you get near the end. Dashed lines mark where PDF pages break. |
| Move the palette | Drag it by the grip (≡) at its leading end. Against the left or right edge it turns vertical. |
| Pin or hide the palette | **Pin** locks it in place. The **chevron** collapses it to a small pencil button; tap that to bring it back. Position, pin and hidden state are remembered. |
| Select ink | Choose the lasso, then circle strokes with the pencil, or tap a single stroke. Tap empty paper or **Done** to deselect. |
| Move or resize a selection | Drag inside the box to move. Drag a corner handle to resize proportionally, or an edge handle to stretch one direction. |
| Recolor, duplicate, delete | Use the bar that appears at the bottom while ink is selected. |
| Read handwriting as text | Select ink, then tap **Recognize Text** in that bar. Review and correct the result, then copy it. |
| Correct a shape | Draw a rough line, circle, ellipse, rectangle, triangle or simple polygon, then hold the pencil still for half a second. A clean preview appears; keep holding and move to adjust it, then lift. |
| Smooth handwriting | Settings › Drawing Assistance › Handwriting Smoothing (Off, Subtle, Medium, Strong) |

### Notes on the drawing-assistance features

- **Undo order.** Shape correction and smoothing are applied as their own undo steps. The first Undo
  restores the stroke exactly as you drew it; the next removes it.
- **Shape correction only runs on a deliberate hold.** The stroke must fit a line, ellipse or
  polygon within a tight error bound. Anything uncertain is left as drawn. Turn it off in
  Settings › Drawing Assistance.
- **Smoothing is signal smoothing, not handwriting rewriting.** It filters tremor out of each
  stroke's path, pins stroke ends and sharp corners, and skips small marks such as dots and
  decimal points. It does not recognize, respell or restyle what you write.
- **Text recognition reads; it does not replace.** Apple's Vision framework recognizes the selected
  handwriting on the iPad so you can copy it. Notes store ink only, so there is no typed-text object
  to put in its place. Vision is not reliable for mathematical notation.
- **Apple's own Smart Script** (handwriting refinement in the Notes app) has no public API and
  cannot be enabled in third-party apps.

## Data and backups

```
On My iPad › CourseNotes › CourseNotes Library/
    library.json                metadata (semesters, courses, modules, notes, tags)
    Drawings/<note-id>.drawing  PKDrawing.dataRepresentation()
```

- Writes are atomic. If `library.json` can't be read, it is set aside, never overwritten.
- An ink file that fails to parse is renamed to `*.unreadable` instead of being replaced by an empty
  drawing.
- Ink files without metadata are re-attached under a "Recovered Notes" course at launch.
- **To restore a backup:** quit CourseNotes from the app switcher, unzip the backup, copy
  `CourseNotes Library` into **On My iPad › CourseNotes** (replacing the existing folder), then reopen
  the app.

## Troubleshooting

- **"Untrusted Developer"**: Settings › General › VPN & Device Management › your Apple ID › Trust.
- **App closes immediately after a week**: the free signature expired. Refresh it in AltStore or
  SideStore, or run it from Xcode again.
- **Squeeze does nothing**: check **Settings › Apple Pencil**. If squeeze is set to run a Shortcut and
  the app is set to *Follow System Setting*, the app deliberately does nothing.
- **Build errors mentioning `UIPencilInteraction.Squeeze` or `rollAngle`**: your Xcode is older than
  15.4. Update Xcode. The GitHub workflow always uses the latest stable version.
