# Palma Sleep Screen

A KOReader plugin that composes a sleep screen image from the current book's
cover and your reading progress, and writes it where the device's system can
pick it up as a sleep screen.

<img src="screenshots/palma_sleepscreen.png" alt="Example sleep screen: cover full-bleed across the top, information panel below" width="330">

## Why

The Onyx Boox Palma 2 Pro has a 824 × 1648 screen — a 2:1 aspect ratio, which is
unusually tall. Book covers are roughly 2:3. Scaling a cover to fill a 2:1 screen
either distorts the art or wastes a quarter of the display, and getting other
sleep screen plugins to look right on that geometry was more trouble than it was
worth.

This plugin fills the space deliberately instead: the cover sits full-bleed
across the top, never cropped, and whatever height is left below it becomes a
solid information panel in the cover's own dominant colour.

Nothing here is actually Palma-specific — every dimension is derived from the
screen size reported by KOReader — but that display is what it was built and
tuned for.

## What it shows

- **Cover**, scaled to the full screen width and anchored to the top. Never
  cropped. If a cover is so tall that the panel would not fit, the cover is
  scaled down and centred instead.
- **Panel**, filling the remaining height in the cover's dominant colour. The
  colour is sampled from the cover, pulled toward mid-lightness (the Kaleido 3
  colour layer renders extremes as flat blocks), and then adjusted until it
  clears a WCAG contrast ratio of 6:1 against the black or white text drawn on
  it. Covers with no real colour fall back to a neutral dark grey.
- **Title**, up to two lines, then ellipsized.
- **Author** and series.
- **Progress bar**, with chapter boundaries notched along its lower edge.
- **Progress row**: percentage read, and the current chapter out of the total.
- **Secondary row**, smaller: estimated time left, battery level with a drawn
  icon, and a timestamp of when the image was last rendered — handy for telling
  at a glance how long ago you put the device down and whether it needs charging.

Anything unavailable is hidden rather than shown empty: no series, no chapter
name, no statistics, or no battery all degrade cleanly.

## Requirements

- KOReader (developed against v2026.03; also runs on v2024.11).
- A device whose system reads an image file as its sleep screen.
- The estimated time left comes from KOReader's **statistics** plugin. If that is
  disabled the field is simply omitted; everything else still works.

## Installing

Copy the `palmasleepscreen.koplugin` folder into KOReader's `plugins` directory:

```
koreader/plugins/palmasleepscreen.koplugin/
```

Restart KOReader.

## Where the settings are

The plugin only appears while a book is open — it does nothing in the file
manager, so that is the first thing to check if you cannot find it.

**Open a book → tap the top of the screen → ⚙ (Settings) → Screen → scroll to the
bottom → Palma sleep screen**

It sits at the *bottom* of the Screen section rather than next to "Cover image",
because KOReader hardcodes the order of that section and appends anything it does
not know about.

### Options

| Setting | Notes |
| --- | --- |
| **Enabled** | Turns the whole plugin on and off. |
| **Output file** | Full path to the image. Pick a folder, then confirm the filename. The extension always follows the output format. |
| **Check output path** | Performs a real test write and reports what happened. Start here if no file is appearing. |
| **Update** | `Every chapter` (default), `Every page`, or `Every N pages`. |
| **Also update when the device sleeps** | Off by default. See the caveat below. |
| **Text size** | Small / Medium / Large. |
| **Hide battery and date** | Drops the secondary row and moves the time left onto the progress line. For use with the Boox status bar, which draws its own clock and battery over the sleep screen. |
| **Cover enhancement** | Off by default. Adjusts the cover for the Kaleido 3 colour layer — see below. |
| **Preview** | Renders and shows the result full screen, exactly as written to disk. Tap anywhere to close. |
| **Refresh now** | Renders immediately and reports the result, timing, dimensions and file size. |
| **Output format** | Experimental — see below. |
| **Log render timings** | Writes render durations to the KOReader log. |

### Output format

The Boox screensaver does not show the file untouched. It re-renders it through
its own pipeline, which applies its own colour handling — which is why the same
image can look right in **Preview** and wrong once the device sleeps, with the
frontlight ruled out. Boox's *transparent* screensaver takes a different path
(it keeps what is already on the panel), which is why colours are correct there.

Painting the image directly at suspend was tried and does not work: Android
freezes the surface before the repaint reaches the panel, so the pre-suspend
screen is what stays up.

So these options exist to hunt for an encoding that pipeline leaves alone:

| Format | Notes |
| --- | --- |
| **PNG, with alpha** | The default, and what earlier versions always wrote. KOReader's RGB32 buffer encodes to a 4-channel PNG. |
| **PNG, no alpha** | The same image through the 3-channel encoder. The alpha channel is the main suspect — an image carrying alpha plausibly takes a compositing path an opaque one does not. |
| **JPEG** | Cannot carry alpha at all. Quality is adjustable (default 90). |
| **BMP** | Uncompressed, no alpha, no colour metadata. |

Two things will make every format look identical if you miss them:

- **Changing the format renames the output file.** Re-point the system sleep
  screen setting at the new path. The plugin reports the new and old paths when
  you switch.
- **The device may cache the sleep screen.** Reboot before concluding a format
  made no difference.

**Refresh now** reports the rendered dimensions. If they are not the panel's
native resolution, the system is rescaling the image before it ever reaches the
screen, and that alone would alter the colours.

### Cover enhancement

The Kaleido 3 screen is two layers at different resolutions: the monochrome
layer runs at the full 300 PPI, the colour filter array over it at 150. Colour
therefore resolves at half the detail of luminance, and the filter absorbs
enough light that an untouched sRGB cover reads dark and washed out.

There is a second artifact on top of that. The panel dithers to reach colours it
cannot render directly, and faint colour variation across a smooth gradient — a
dusk sky, water — dithers into visible magenta and green speckle. This is what
Boox's own "Image Smoothing" toggle suppresses in NeoReader; it does not reach
the sleep screen, so the plugin has to handle it itself.

So the enhancement takes **luminance sharp from the original and chroma from a
blurred copy**: detail lands on the layer that can resolve it, and colour reaches
the layer that cannot as a smooth wash with nothing for the dither to fleck.

| Parameter | Default | What it does |
| --- | --- | --- |
| **Saturation** | 1.60 | Scales the chroma offsets, compensating for the filter array. |
| **Brightness** | 1.05 | Gamma on luminance; above 1 lifts the midtones. |
| **Contrast** | 0.25 | Blends luminance toward a smoothstep S-curve. 0 is off. |
| **Sharpness** | 0.80 | Unsharp mask on luminance only, so edges pick up the full 300 PPI of the monochrome layer without colour fringing. |
| **Colour smoothing** | 2 | Radius of the chroma low-pass, in pixels. Raise if covers look speckled, lower if colour looks smeared. 0 is off. |
| **Neutral threshold** | 12 | Chroma below this fades to true grey, so near-neutral gradients render on the monochrome layer alone. 0 is off. |

Saturation is faded in across the neutral threshold rather than applied flat —
a flat multiplier amplifies precisely the near-neutral noise that speckles
worst, making the problem worse rather than better.

Defaults are a starting point, not a calibration — they were chosen from how the
panel behaves, not measured against one. Expect to tune them by eye.

The processed cover is cached under `cache/palmasleepscreen/` in the KOReader
data directory, keyed by the book, the cover geometry and all four parameters,
so the work happens once per book rather than on every update. Changing any
parameter clears the cache; **Rebuild cached covers** clears it by hand.

## Notes and gotchas

**PNG is the default output.** Other formats are selectable under **Output
format**, but not every device accepts them as a sleep screen — if the system
stops showing the image after a format change, that is the likely reason.

**The default is per-chapter, not per-page.** Encoding a full-screen PNG of
photographic cover art costs roughly 120–170 ms on a desktop and several times
that on-device, which is too much to spend on every page turn. Every-page still
works if you want a live progress bar — the render is scheduled off the page-turn
event and never blocks it — but it costs about a second of background CPU and a
1–2 MB flash write each turn. Per-chapter is the sane default.

**"Also update when the device sleeps" cannot fix a stale image.** The system
reads the sleep screen file as it goes to sleep and generally gets there before a
render finishes, so on its own this shows the *previous* image. It can only
freshen an image that is already current — leave a page or chapter trigger on as
well.

**The file exists but your system's sleep screen picker cannot see it.** Android
keeps a media index that gallery-style pickers query, and KOReader writes the file
directly without registering it there. Rebooting triggers a media scan, which is
the quickest way to confirm this is what is happening. KOReader exposes no
media-scanner binding, so the plugin cannot register the file itself.

**On Android, KOReader needs "All files access"** to write outside its sandbox.
*Check output path* will say so explicitly if that is the problem.

## Credits

Inspired by [customisablesleepscreen.koplugin](https://github.com/pxlflux/customisablesleepscreen.koplugin)
by pxlflux, which is well worth a look if you want something far more
configurable than this. Cover extraction and image writing follow the approach
taken by KOReader's bundled `coverimage.koplugin`.

## Disclaimer

This plugin was written mostly with [Claude Code](https://claude.com/claude-code),
directed and reviewed by a human. It has been tested against real covers and on a
real device, but it is a personal tool scratching a specific itch rather than a
polished release — treat it accordingly.

## Licence

[AGPL-3.0](LICENSE), matching KOReader itself and the plugin that inspired it. A
KOReader plugin is loaded into the KOReader process and uses its internal modules
directly, so it is a derivative work; a permissive licence was not really
available here.

Copyright (C) 2026 Nara Xian
