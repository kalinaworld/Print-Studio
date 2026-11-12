#target photoshop
// Send to P900 Print
// Saves a flattened copy of the open document (profile embedded) into the P900 Print inbox,
// and opens Kalina Print Studio (opened first, so it appears at once; it loads the photo when the save finishes). The document itself is not changed.

(function () {
    if (app.documents.length === 0) {
        alert("Open a document first.");
        return;
    }
    var doc = app.activeDocument;

    var base = new Folder(Folder.userData + "/P900Print");
    if (!base.exists) { base.create(); }
    var inbox = new Folder(base + "/Inbox");
    if (!inbox.exists) { inbox.create(); }

    var safe = doc.name.replace(/\.[^\.]+$/, "").replace(/[^A-Za-z0-9_\-]+/g, "_");
    var finalName = "ps-" + (new Date().getTime()) + "-" + safe + ".tif";
    // Saved under a hidden name first and renamed when complete, so the app never sees a half-written file.
    var file = new File(inbox + "/." + finalName);

    var appPath = Folder("~").fsName + "/Applications/Kalina Print Studio.app";
    var launched = false;
    try {
        if (typeof app.system === "function") {
            app.system('open "' + appPath + '"');
            launched = true;
        }
    } catch (e) {}
    if (!launched) {
        try { new File(appPath).execute(); launched = true; } catch (e2) {}
    }
    if (!launched) {
        alert("Could not open Kalina Print Studio. Open it yourself and the photo will load once Photoshop finishes saving it.");
    }

    var opts = new TiffSaveOptions();
    opts.imageCompression = TIFFEncoding.NONE;   // faster save; the inbox copy is temporary
    opts.embedColorProfile = true;
    opts.layers = false;
    opts.alphaChannels = false;
    opts.annotations = false;
    opts.transparency = false;
    opts.byteOrder = ByteOrder.MACOS;
    doc.saveAs(file, opts, true, Extension.LOWERCASE);   // true = save as a copy
    file.rename(finalName);
})();
