# ScreenshotUtility

A tiny macOS menu bar utility for rectangular screenshots and full-length scrolling captures.

It is the app from the [Artie Fischal](https://artiefischal.com) channel. The recent-screenshot gallery was built with Codex from a design Claude mocked up, and scrolling capture was built with Claude.

This repository is source code only. There is no ready-made download: you build the app on your own Mac, which takes a couple of minutes. See [Build](#build).

## What It Does

- Runs in the menu bar.
- Captures immediately when you click the menu bar icon.
- Opens options when you right-click or Control-click the menu bar icon.
- Registers two global hotkeys: `Ctrl+Option+4` for a normal capture and `Ctrl+Option+5` for a scrolling capture.
- Lets you draw a rectangular capture area using macOS's native selection UI.
- Captures the full scrolling content of a window as one tall image (`Ctrl+Option+5`, Option-click the icon, or **Scrolling Capture…** in the menu).
- Saves PNG screenshots directly into a folder and copies them to the clipboard.
- Lets you choose and open the save folder from the menu.

By default, captures are saved to:

```text
~/Pictures/ScreenshotUtility
```

## Build

You need a Mac running macOS 13 or later (scrolling capture needs macOS 14 or later) and Apple's command line tools. If you do not have them, install them first:

```sh
xcode-select --install
```

Then download this repository, open Terminal in its folder, and run:

```sh
make app
```

The app bundle is created at:

```text
dist/ScreenshotUtility.app
```

## Run While Developing

```sh
make run
```

## Install For Daily Use

Build the app, then move `dist/ScreenshotUtility.app` to `/Applications` or `~/Applications` and open it. It is a menu bar app, so it does not show a Dock icon.

To start it automatically when you sign in:

1. Open System Settings.
2. Go to General > Login Items & Extensions.
3. Add `ScreenshotUtility.app` to Open at Login.

## First Run Permission

macOS may ask for Screen Recording permission the first time a screenshot is captured. If capture does not start, open:

```text
System Settings > Privacy & Security > Screen & System Audio Recording
```

Then allow `ScreenshotUtility` and reopen the app.

Scrolling capture also needs Accessibility permission, because it scrolls the other app's window for you. The first time you choose it, macOS shows its standard prompt; turn on `ScreenshotUtility` under:

```text
System Settings > Privacy & Security > Accessibility
```

Then choose Scrolling Capture again. Normal captures never need Accessibility.

macOS ties both permissions to the app's code signature. `make app` signs with an installed Apple Development certificate when there is one, so the permissions survive rebuilds. Without one it signs ad-hoc, and macOS asks again after every build. Set `CODESIGN_IDENTITY` to choose a certificate, or to `-` to force ad-hoc.

## Usage

Click the menu bar camera icon, draw a rectangle, and release. The PNG is saved automatically.

You can also press `Ctrl+Option+4`.

Option-click the camera icon, or press `Ctrl+Option+5`, to start a scrolling capture.

Right-click or Control-click the menu bar icon to:

- Capture immediately.
- Start a scrolling capture.
- Choose the save folder.
- Open the save folder.
- Show the last saved capture.
- Quit the app.

## Scrolling Capture

Press `Ctrl+Option+5`, Option-click the camera icon, or choose **Scrolling Capture…** from the menu. The screen dims and the area under the pointer is highlighted:

- **Click** to capture the highlighted area. Where the app describes its layout to macOS, that is the scrolling area under the pointer (a web page without the browser's toolbar, a note without the sidebar). Otherwise it is the whole window.
- **Drag** a box around exactly what you want. The drag can start anywhere, including outside the window; the box is trimmed to the window it covers.
- A click on the menu bar or the desktop, where there is no window, backs out.
- **Escape** cancels, here and at any point during the capture.

The app brings the window forward and captures from what is on screen now down to the bottom, waiting for each scroll to settle before taking the next section. It never scrolls up first: to capture a whole page, scroll to its top before starting. A small readout in the highlight colour, under the menu bar, shows progress and then confirms the copy in the same place. Each step glides rather than jumps. When it finishes it scrolls back to where you were, puts the pointer back, saves the PNG in the screenshot folder, copies the image, and adds it to the gallery exactly like a normal capture.

How the image is put together:

- Sections are captured at the display's native resolution and joined on exact pixel matches, never blended or scaled, so text stays as sharp as on screen. The PNG carries the display's resolution (144 dpi on Retina) and opens at its on-screen size.
- Consecutive sections overlap by about half. The distance moved is measured from the picture itself rather than assumed, so apps that scroll by lines or at a different rate still join correctly.
- Toolbars and sticky headers appear once at the top, a sticky footer once at the bottom, and a fixed sidebar once beside the first screenful, with its background continued below.
- Overlay scroll bars are waited out, so no scroll thumb is left in the image.

It stops when two scrolls in a row move nothing, or when the image reaches 30,000 pixels tall (about 15,000 points on a Retina display), whichever comes first. Past that an image is slow to open and many apps and upload forms refuse or shrink it. At the limit the image is saved and the readout says it stopped there. The limit is `maxHeight` in `ScrollCaptureEngine.swift`.

When a capture cannot be trusted, nothing is saved silently. An alert says what happened and, where there is something worth keeping, offers to save it:

- **The area didn't scroll.** Either it is already at the bottom or the app ignores scrolling at that spot.
- **Sections could not be lined up.** The content changed between sections: it loaded, animated or re-flowed, or the window was resized.
- **Another app came in front.** Scrolling only reaches the frontmost window under the pointer, so switching apps or clicking elsewhere mid-capture stops it.
- **The content repeats too regularly.** With identical rows or an empty grid, sections cannot be told apart from the picture, so their placement rests on the distance requested.

Every attempt is recorded as a few lines of text (no pictures) in `~/Library/Logs/ScreenshotUtility/scrolling-capture.log`, which is the place to look when a capture fails.

### Limitations

- Vertical scrolling only, one window at a time. The window has to be on screen, and macOS 14 or later is required.
- The pointer is moved over the window while capturing, and moving the mouse or typing during a capture can disturb it.
- Pages that keep loading as you scroll (endless feeds) run until the 30,000-pixel height limit. Content that loads after a section has been captured and changes the layout makes the sections impossible to line up, which is reported.
- Elements that float over the content and move independently (a chat bubble, a video that keeps playing) can appear more than once or be cut where two sections meet. Drag to outline an area that avoids them.
- A sticky header that only appears part-way down the page is treated as a header from then on; one that slides away when scrolling down is drawn only where it was showing.
- A sidebar inside the captured area is recognised only at the left or right edge of the area.
- A blank stretch taller than the window is crossed using the distance requested, so its height in the image can be a few pixels off. Blank space after the last content, beyond one window-height, is dropped.
- While an app's overlay scroll bars are flashing in the part of each section that is kept, every step waits about a second for them to fade, so the first half of a long capture is slower than the second.
- The scroll position is put back by scrolling to the same picture. If the content changed during the capture this cannot be confirmed and the view may be left slightly off.
- Apps that draw their own content without scrolling in whole pixels, or that ignore synthetic scroll events, cannot be captured; they produce one of the alerts above.
- A very tall image keeps its PNG on the clipboard; its TIFF copy is produced only if the receiving app asks for one. In the gallery it is shown as its top portion with a ↕ badge.

## Recent Screenshot Gallery

Right-click or Control-click the camera icon to open the native menu. The gallery shows captures from the selected save folder from the last 48 hours, newest first, in two columns. Previews preserve the full image proportions. Only the gallery scrolls; capture and folder controls stay visible. The gallery is capped at 330 points high and is reduced for smaller screens, with no fixed screenshot-count limit.

Click a thumbnail to copy the original PNG and a full-resolution TIFF representation, close the menu, and briefly show “Copied image.” The gallery refreshes every second while open and on opening. Expired screenshots disappear from the gallery only; files are never deleted. Its outer height stays fixed while the menu is open and is recalculated the next time it opens.

New captures store their absolute capture time in an extended file attribute. Existing app-named PNG captures use filesystem creation time, without requiring agreement with the timestamp in their filename. This preserves recent original captures across restarts and timezone changes. Copying an older legacy file onto a filesystem that resets its creation date can make that legacy file appear recent; newly captured files retain their precise time when their extended attributes are preserved. Unrelated PNG files are ignored.

The gallery supports mouse/trackpad scrolling and exposes thumbnails as accessibility buttons. AppKit custom menu views do not support normal arrow-key navigation between thumbnails; the standard menu actions retain their native keyboard behavior.

## Tests

Run `swift test` for age filtering, ordering without a count limit, persisted timestamps, legacy discovery, folder isolation, original-image clipboard data, corrupt-image rejection, and immediate scrolling/bounds tests. These tests require normal macOS pasteboard access; a restricted command sandbox may prevent the clipboard test from writing to its private test pasteboard.

The scrolling-capture tests drive the real capture engine against a simulated scrolling window and compare the stitched result with the source pixel for pixel: plain documents, sticky header and footer with a fixed sidebar, an overlay scroll thumb, apps that scroll by lines or at another rate, lists of near-identical rows, a blank stretch taller than the window, the height limit, an area that does not scroll, content too repetitive to verify, cancelling, and restoring the scroll position.

A debug build also has a self-test that needs Screen Recording but not Accessibility. It opens a window of its own, scrolls it programmatically, and runs a real capture through the normal save, clipboard and gallery steps, then reports the result next to the height the content says it should have:

```sh
swift build
.build/debug/ScreenshotUtility --scroll-selftest https://en.wikipedia.org/wiki/MacOS \
  --scroll-selftest-report /tmp/report.json -saveDirectoryPath /tmp/scroll-test
```

Give it a URL or an HTML file, or `native:text` / `native:table` for AppKit scroll views. `--scroll-selftest-start <offset>` starts part-way down to exercise scroll restoring. For a run against another app's window, `--scroll-capture-window <window id> --scroll-capture-report <file>` captures it without the picker (this does need Accessibility), and `--scroll-capture-pick` opens the picker. All of these are excluded from release builds.

For native UI validation, a debug build accepts `--gallery-validation` and displays a test window that opens the same menu. It skips registering the global hotkey so it can run alongside the installed app. Pass `-saveDirectoryPath /absolute/test/folder` to isolate its files. `python3 Scripts/make-gallery-fixtures.py` generates twelve synthetic screenshots under `.build/gallery-validation/captures`. The validation window is excluded from release builds.

## License

MIT. See [LICENSE](LICENSE).
