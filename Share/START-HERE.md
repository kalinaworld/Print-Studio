# Kalina Print Studio: setup for a new Mac

A small Mac app that replaces Photoshop's print dialog for the Epson SC-P900.
It is source code, so you build it once on your own Mac. That takes a few minutes.

## Requirements
- macOS 13 or newer
- Xcode command line tools. Run `xcode-select --install` in Terminal if you don't have them.
- An Epson SC-P900 set up as a printer on your Mac
- ICC profiles for your papers in `~/Library/ColorSync/Profiles` (the paper list is built from what is there)

## Build and install
    cd path/to/KalinaPrintStudio
    chmod +x build.sh
    ./build.sh --open

It installs to `~/Applications/Kalina Print Studio.app`. Because you build it yourself, macOS won't block it.

## From Photoshop (optional)
File > Scripts > Browse... and pick `Photoshop/SendToP900Print.jsx`. It sends a flattened copy of the open
document to the app. You can also drag a TIFF/JPEG/PNG onto the app window.

## Things you will probably want to change
- Printer: built for the SC-P900. Any other printer needs real code changes.
- Defaults: sheet size, theme (red "Safelight"), top-feeder only, and the app name are the original author's choices.
- Papers: only profiles you actually have installed will show up.

## Easiest way: let Claude do it
Open this folder in Claude Code or Cowork and paste the prompt from `PROMPT-FOR-CLAUDE.txt`.

See README.md for what every control does.
