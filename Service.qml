import QtQuick
import Quickshell

// Installs an app-launcher entry so the picker is reachable from SUPER+SPACE
// (and searchable as "OmaShuffle" / "theme shuffle") without the user first
// wiring up a keybind. Omarchy has no install hook and no manifest field for
// registering one, so it happens here instead - the same approach Omaland uses.
//
// The file work is done by bin/omashuffle-desktop-entry, which holds itself
// to the same discipline as bin/omashuffle-menu-entry: bounded O_NOFOLLOW
// reads, writes through a fresh O_EXCL temp inode that is atomically renamed
// over the target, and only ever a file that is absent or carries the
// X-OmaShuffle-Managed=true marker - never written through a symlink.
QtObject {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  property bool installed: false
  property string scriptPath: ""

  // The shell assigns `manifest` after createObject() has already run
  // Component.onCompleted, and a binding on it has not re-evaluated by the
  // time this fires, so the path is captured here rather than bound.
  onManifestChanged: {
    var dir = manifest && manifest.__sourceDir
    if (installed || !dir) return
    installed = true
    scriptPath = dir + "/bin/omashuffle-desktop-entry"
    Quickshell.execDetached([scriptPath, "--add"])
  }

  // Reached on disable and on remove alike: omarchy-plugin-remove disables
  // first, so the service is torn down while the entry is still ours.
  Component.onDestruction: {
    if (!installed || !scriptPath) return
    Quickshell.execDetached([scriptPath, "--remove"])
  }
}
