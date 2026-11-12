# Kalina Print Studio

A small Mac app that replaces Photoshop's print dialog for the Epson SC-P900.
Only the controls you use: paper (profile + media type paired), sheet size, orientation,
fit in margins / full bleed / custom size, rendering intent, black point compensation, copies.

Fixed on purpose: Max Quality, SuperPhoto 5760 dpi, High Speed, Finest Detail, driver color management Off.
The app does the color conversion itself (Little CMS), the same way Photoshop Manages Colors does.

## Build and install

    cd Print-Studio
    ./build.sh --open

Installs to ~/Applications/Kalina Print Studio.app.

## From Photoshop

1. Photoshop: File > Scripts > Browse... and pick Photoshop/SendToP900Print.jsx (or copy it into
   Photoshop's Presets/Scripts folder so it shows up in File > Scripts, then give it a shortcut under
   Edit > Keyboard Shortcuts).
2. Run it. It saves a flattened copy of the open document (profile embedded) and opens Kalina Print Studio.

You can also drop a TIFF/JPEG/PNG on the window or press Cmd-O.

## Layout options

- Fit / Full bleed / Custom / Half sheet (top, bottom, left or right, leaves the other half free, 0.5 in gap)
- Position buttons for Fit and Custom
- Crop marks (not available in Full bleed)

## Gamut warning and intent suggestion

- Under Color, "Show colors the paper can't print" paints the colors the chosen paper cannot reproduce magenta on the
  page preview, using the intent and black point setting you have selected. The line under the preview says how much
  of the photo that is.
- The app also checks every photo against the selected paper with Relative Colorimetric. When a lot of it is out of
  gamut it suggests Perceptual, but only if that paper's Perceptual table really renders those colors differently from
  Relative. If it doesn't, it says so instead of suggesting a switch that would change nothing. It also nudges you off
  Saturation and Absolute for photos, and off Perceptual when almost everything fits.
- The check runs on a reduced copy of the preview, so it is quick. It follows the Brightness slider.

## Brightness, contrast and saturation

Three sliders under Color, each -50 to +50, all applied to the print and the preview (and so to the soft proof).
Brightness lifts or darkens the midtones. Contrast adds (or removes) an S-curve. Brightness and contrast keep pure
black and white where they are, so nothing clips. Saturation scales color strength, +50 doubling it and -50 halving it.
They are saved with each print, so Print again restores them, and each photo starts at 0.

Under the gamut note, "Fit colors to paper" looks for the gentlest Saturation setting (never lower than -35) that
leaves 5% or less of the photo outside what the paper can print, then moves the slider there. It is a global change,
so for a photo with a few very vivid colors, easing just those in Photoshop will look better.

## Soft proof

Under Color, "Soft proof: show how it will print" shows the page preview as the chosen paper and intent will render
it. It runs the same photo-to-paper conversion the print uses, then shows those paper values on your screen, so it
follows the intent, black point compensation, brightness and paper you have selected.

"Simulate paper white and black" also keeps the paper's own white and black. Without it, paper white is shown as
screen white. With it, a matte paper looks flatter and slightly warmer, closer to the real print. A screen still can't
show everything about a print (surface, texture, light), so treat it as a guide and not a proof.

The gamut overlay works on top of the soft proof.

## Paper-free color check

    python3 check_color_pipeline.py

Pushes a patch chart through the same print filters a real job uses, writes the result to a file instead of
the printer, and compares the colors. Uses no ink or paper. Report goes to color-check.txt.

## Test without wasting paper

"Preview PDF" renders exactly what would be sent and opens it in Preview. Nothing is printed.

## Files

- Sources/P900Print: the app (SwiftUI)
- Sources/CLcms2: Little CMS (MIT license) plus a small shim
- EPSON_SC_P900_Series.ppd: reference dump from the installed Epson driver
