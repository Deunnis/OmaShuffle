import QtQuick
import Quickshell

// Installs a launcher entry so the picker is reachable from SUPER+SPACE (and
// searchable as "OmaShuffle" / "theme shuffle") without the user first wiring
// up a keybind. Omarchy has no install hook and no manifest field for
// registering one, so it happens here instead - the same approach Omaland uses.
//
// Only a file carrying the X-OmaShuffle-Managed marker is ever written or
// deleted, so a launcher entry you wrote yourself at that path is left alone.
QtObject {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string dest: Quickshell.env("HOME") + "/.local/share/applications/omashuffle.desktop"
  readonly property string marker: "^X-OmaShuffle-Managed=true$"

  // $1 template, $2 dest, $3 marker, $4 icon path. Bail unless the dest is
  // absent or already ours; write through a temp file in the same dir and
  // only swap it in when the contents actually changed.
  readonly property string installScript:
      '[ -f "$1" ] || exit 0\n'
    + 'if [ -e "$2" ] && ! grep -q "$3" "$2"; then exit 0; fi\n'
    + 'mkdir -p "${2%/*}" || exit 0\n'
    + 'tmp=$2.omashuffle.new\n'
    + 'sed "s|@ICON@|$4|" "$1" > "$tmp" || exit 0\n'
    + 'if cmp -s "$tmp" "$2"; then rm -f "$tmp"; else mv -f "$tmp" "$2"; fi\n'

  readonly property string removeScript:
    'grep -q "$2" "$1" 2>/dev/null && rm -f "$1"\n'

  property bool installed: false

  // The shell assigns `manifest` after createObject() has already run
  // Component.onCompleted, and a binding on it has not re-evaluated by the
  // time this fires, so the paths are built here rather than bound.
  onManifestChanged: {
    var dir = manifest && manifest.__sourceDir
    if (installed || !dir) return
    installed = true
    Quickshell.execDetached(["sh", "-c", installScript, "sh",
                             dir + "/omashuffle.desktop", dest, marker, dir + "/icon.png"])
  }

  // Reached on disable and on remove alike: omarchy-plugin-remove disables
  // first, so the service is torn down while the entry is still ours.
  Component.onDestruction: {
    if (!installed) return
    Quickshell.execDetached(["sh", "-c", removeScript, "sh", dest, marker])
  }
}
