# Tessera

**Pinch out of 100,000 photos until they become one picture.**

Tessera is a photo grid written directly against Metal. It scrolls and zooms at the
display's full refresh rate (120Hz on ProMotion iPhones). If you keep pinching out past the
densest grid, every photo flies to a new spot and the whole library forms a single image in
which each pixel is a real photo. Pinch into any part of that picture and you land on that
photo in the timeline. Tap **Color** and all 100,000 photos re-sort themselves into a rainbow.
Tap any tile, even a single pixel of the picture, and it grows into the whole photo at its true
shape; drag it away or pinch it shut to send it back to its cell.

<p align="center"><img src="docs/demo.gif" width="260" alt="Pinching out of a photo grid until 100,000 photos form a sunset, opening one photo, then re-sorting by color"></p>

A sharper, 60 fps recording is in [docs/demo.mp4](docs/demo.mp4). It was captured in the Simulator;
on a ProMotion iPhone the app runs at 120 fps.

Inspired by [Shannon Potter's Metal photo grid](https://x.com/cifilter/status/2070958334690168911).

## Run it

```bash
scripts/fetch-photos.sh   # downloads ~1,000 photos from picsum.photos into Photos/ (~235 MB, not committed)
xcodegen generate         # optional: Tessera.xcodeproj is already generated
open Tessera.xcodeproj
```

Pick your own signing team in the target settings, then run it on an iPhone. Smoothness
claims only mean something on a real device, ideally a Pro model with a 120Hz screen.

## How it works

**One draw call, zero per-tile CPU work.** All 100,000 tiles are drawn as one instanced quad.
Each frame the CPU writes only two small layout descriptions (columns, pitch, scroll offset)
and a ~1,000-entry texture-residency table. The vertex shader looks up each item's cell in an
*arrangement* buffer and computes its rectangle on the GPU.

**Zooming is two rigid grids, not 100,000 moving tiles.** Between n and n + 1 columns, both
grids are drawn at the same in-between cell size, each positioned so the photo under your
fingers stays under them and keeps its column, and one crossfades into the other through the
middle of the step. Only the cells on screen are submitted. Columns that fall past a grid's own
edge show the neighbouring rows' photos, so the screen edge stays filled mid-pinch.

**Re-sorting moves every tile.** Each item knows its cell in both arrangements. The change
spreads as a ripple from where it was triggered. Tiles on screen at both ends fly, lifting as
they cross; tiles that only leave or arrive drift a short way while fading. When every tile is
in the air at once (the overview), the two grids crossfade underneath so the screen never
empties.

**The photo view is the same zoom, one step further.** Tap a tile, or pinch in past one column,
and the full photo is decoded off the main thread, then grows from its cell on a spring. Its crop
opens from the cell's square to the whole photo without stretching. A drag or pinch moves it
directly; letting go either returns it to its cell or settles it back.

**No tile is ever blank.** A 128px copy of every photo lives in one mipmapped
`texture2d_array` from launch onwards. Sharper 384px and 1024px copies are decoded off the
main thread with ImageIO's downsampling decoder, uploaded into fixed pools of slots (least
recently used goes first, and never a slot an in-flight frame might still read), and faded in
on top. A hard fling at 40 columns shows thumbnails, never gray squares.

**The picture is honest.** Each of the 100,000 items lands in exactly one cell, so the morph
really is a rearrangement of the library. Cells are visited in random order, and each one takes
the closest-colored photo that still has unused copies. Before matching, the target image's
brightness is remapped to the library's own brightness distribution, so the image asks for
only as many dark, mid and light photos as exist. The target image is generated in code
(`Picture.swift`): a sunset over mountains, mirrored in a lake.

**Touch goes straight to the model.** The Metal view reads raw `UITouch`es instead of going
through gesture recognizers, so there's no recognition delay. Scrolling uses UIScrollView's
deceleration rate and rubber-band curve. Springs are critically damped and stepped with their
exact closed-form solution, so motion is identical at 60Hz, 120Hz or after a dropped frame.

## Layout

```
Sources/
  App/           scene setup, view controller, HUD, raw-touch MTKView
  Interaction/   zoom/scroll/morph state machine, photo view, layouts, springs
  Library/       mock library, the three arrangements, the generated picture
  Rendering/     renderer, texture tiers, shaders
scripts/fetch-photos.sh
```

## Credits

Photos come from [Unsplash](https://unsplash.com) via [Lorem Picsum](https://picsum.photos) under the
[Unsplash License](https://unsplash.com/license). `scripts/fetch-photos.sh` writes per-photo
credits to `Photos/CREDITS.md`. The photos are not redistributed in this repository.
