import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ThemeDeck.js" as Deck

// OmaShuffle - applies a fresh theme on every real boot, drawn from a
// shuffled deck of themes the user curates, plus a fullscreen picker to
// manage that deck. Overlay-kind, keepLoaded so Component.onCompleted runs
// at shell startup - that is where the once-per-boot check lives.
Item {
  id: root

  property bool opened: false
  readonly property string moduleName: "io.github.omashuffle"

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: root.home + "/.config/omarchy/plugins/io.github.omashuffle"
  readonly property string stateDir: root.home + "/.local/state/omarchy/io.github.omashuffle"
  readonly property string scanBin: root.pluginDir + "/bin/omashuffle-scan-themes"
  readonly property string menuEntryBin: root.pluginDir + "/bin/omashuffle-menu-entry"
  readonly property string currentNamePath: root.home + "/.local/state/omarchy/current/theme.name"

  // ---------------------------------------------------------------- state
  property var st: Deck.normalizeState(null)
  property bool stateLoaded: false
  property string currentBootId: ""
  property bool bootChecked: false

  property var themes: []
  property var themeBySlug: ({})
  property string currentThemeSlug: ""

  property string pendingAutoSlug: ""
  property string applyingSlug: ""
  property bool applyingAuto: false
  property bool noPoolNoticeSent: false

  property bool settingsOpen: false
  property string filterText: ""

  // live mirrors, updated continuously while a chrome slider is dragged
  property int liveTransparency: st.transparency
  property int liveCornerRadius: st.cornerRadius
  property int liveBorderWidth: st.borderWidth

  readonly property color cardBackground: Util.alpha(Color.menu.background, 1 - root.liveTransparency / 100)
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent
  readonly property var borderSpec: Border.flat(Color.menu.border, Math.max(0, Style.space(root.liveBorderWidth)))
  readonly property int cardRadius: Style.space(root.liveCornerRadius)
  readonly property string fontFamily: Style.font.menuFamily

  // The theme queued for next boot: just the head of the persisted deck.
  // When the deck is empty it will be a fresh shuffle at boot, so there is
  // no honest single name to show.
  readonly property string nextSlug: (root.st.deck && root.st.deck.length > 0) ? root.st.deck[0] : ""

  // ============================================================ lifecycle

  Process {
    id: stateDirInitProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: {
      stateReadProc.command = ["python3", "-c", root.stateReaderScript, stateFile.path, String(root.maxStateBytes)]
      stateReadProc.running = true
    }
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    preload: false
    printErrors: false
    atomicWrites: true
  }

  // Bounded, descriptor-pinned reader for our own state file. It lives under
  // ~/.local/state where another local process could plant a symlink or an
  // oversized file at this path; this opens the path once with
  // O_NOFOLLOW|O_NONBLOCK, fstats that same descriptor to require a regular
  // file, and reads at most limit+1 bytes - so nothing is bounded by what the
  // path claims to be. Same shape cOMApilot's marketplace review settled on.
  // Exit codes: 2 missing/symlink/unopenable, 3 not a regular file, 4 too big.
  readonly property int maxStateBytes: 262144
  readonly property string stateReaderScript: [
    "import os,sys,stat",
    "path=sys.argv[1]; limit=int(sys.argv[2])",
    "try:",
    "    fd=os.open(path, os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)",
    "except OSError:",
    "    sys.exit(2)",
    "try:",
    "    if not stat.S_ISREG(os.fstat(fd).st_mode):",
    "        sys.exit(3)",
    "    chunks=[]; total=0",
    "    while total <= limit:",
    "        chunk=os.read(fd, (limit + 1) - total)",
    "        if not chunk: break",
    "        chunks.append(chunk); total += len(chunk)",
    "    if total > limit:",
    "        sys.exit(4)",
    "    sys.stdout.buffer.write(b''.join(chunks))",
    "finally:",
    "    os.close(fd)"
  ].join("\n")

  Process {
    id: stateReadProc
    stdout: StdioCollector { id: stateReadOut; waitForEnd: true }
    onExited: function (code) {
      if (code === 3) console.warn("OmaShuffle: state file is not a regular file - ignoring it")
      if (code === 4) console.warn("OmaShuffle: state file exceeds " + root.maxStateBytes + " bytes - ignoring it")
      root.loadState(code === 0 ? stateReadOut.text : "")
    }
  }

  Process {
    id: bootIdProc
    command: ["cat", "/proc/sys/kernel/random/boot_id"]
    stdout: StdioCollector { id: bootIdOut; waitForEnd: true }
    onExited: function () {
      root.currentBootId = String(bootIdOut.text || "").trim()
      root.maybeBootSwitch()
    }
  }

  Process {
    id: currentNameProc
    command: ["cat", root.currentNamePath]
    stdout: StdioCollector { id: currentNameOut; waitForEnd: true }
    onExited: function (code) {
      root.currentThemeSlug = code === 0 ? Deck.sanitizeSlug(String(currentNameOut.text || "").trim()) : ""
    }
  }

  Process {
    id: themeScanProc
    command: [root.scanBin]
    stdout: StdioCollector { id: themeScanOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) { console.warn("OmaShuffle: theme scan exited " + code); return }
      root.ingestThemes(themeScanOut.text)
    }
  }

  Process {
    id: menuInstallProc
    stdout: StdioCollector { }
    stderr: StdioCollector { }
  }
  Process {
    id: themeSetProc
    // `omarchy theme set` is chatty and also leaves a short-lived backgrounded
    // child on the stdout pipe; drain both streams so nothing blocks and the
    // exit signal is delivered.
    stdout: StdioCollector { }
    stderr: StdioCollector { }
    onExited: function (code) { root.onThemeSetDone(code) }
  }
  Process {
    id: notifyProc
    stdout: StdioCollector { }
    stderr: StdioCollector { }
  }

  Component.onCompleted: {
    stateDirInitProc.running = true
    bootIdProc.running = true
    themeScanProc.running = true
    currentNameProc.running = true
    menuInstallProc.command = [root.menuEntryBin, "--install"]
    menuInstallProc.running = true
  }

  function loadState(raw) {
    var parsed = null
    if (raw) { try { parsed = JSON.parse(raw) } catch (e) { parsed = null } }
    root.st = Deck.normalizeState(parsed)
    root.liveTransparency = root.st.transparency
    root.liveCornerRadius = root.st.cornerRadius
    root.liveBorderWidth = root.st.borderWidth
    root.stateLoaded = true
    root.maybeBootSwitch()
  }

  function persist() { stateFile.setText(JSON.stringify(root.st, null, 2) + "\n") }
  function setState(next) { root.st = next; root.persist() }

  // ============================================================ boot switch

  function maybeBootSwitch() {
    if (root.bootChecked) return
    if (!root.stateLoaded || root.currentBootId === "") return
    root.bootChecked = true

    // Same boot id as last run -> shell restart / relogin, not a fresh boot.
    if (root.st.lastBootId === root.currentBootId) return

    var next = Deck.shallowClone(root.st)
    next.lastBootId = root.currentBootId

    if (!root.st.enabled) { root.setState(next); return }

    var draw = Deck.drawNext(root.st, root.st.pool)
    if (!draw.slug) {
      root.setState(next)
      if (root.st.notify && !root.st.poolInitialized && !root.noPoolNoticeSent) {
        root.noPoolNoticeSent = true
        root.notify("OmaShuffle", "No themes picked yet - open it from the menu (Super + Space)")
      }
      return
    }

    next.deck = draw.deck
    root.setState(next)
    root.pendingAutoSlug = draw.slug
    bootSwitchTimer.restart()
  }

  // Short delay so the freshly-started desktop settles before the theme
  // transition runs.
  Timer {
    id: bootSwitchTimer
    interval: 2500
    repeat: false
    onTriggered: if (root.pendingAutoSlug) root.applyTheme(root.pendingAutoSlug, true)
  }

  // ============================================================ apply

  // The state update is done up front rather than waiting on the process exit:
  // `omarchy theme set` is idempotent, rarely fails, and its exit signal is not
  // dependable (it leaves a brief backgrounded child on the pipe). If it does
  // exit non-zero, onThemeSetDone() surfaces that.
  function applyTheme(slug, auto) {
    var clean = Deck.sanitizeSlug(slug)
    if (!clean) { console.warn("OmaShuffle: refusing invalid theme slug: " + slug); return }
    if (themeSetProc.running) return

    root.applyingSlug = clean
    root.applyingAuto = auto === true

    var disp = root.displayFor(clean)
    var newDeck = auto ? null : (root.st.deck || []).filter(function (x) { return x !== clean })
    root.setState(Deck.recordApplied(root.st, clean, disp, Date.now() / 1000, auto === true, newDeck))
    root.currentThemeSlug = clean

    themeSetProc.command = ["omarchy", "theme", "set", clean]
    themeSetProc.running = true

    if (root.st.notify) root.notify("OmaShuffle", (auto ? "This boot's theme: " : "Applied: ") + disp)
  }

  function onThemeSetDone(code) {
    var slug = root.applyingSlug
    root.applyingSlug = ""
    if (code !== 0) {
      console.warn("OmaShuffle: 'omarchy theme set " + slug + "' exited " + code)
      if (root.st.notify) root.notify("OmaShuffle", "Theme may not have applied cleanly: " + slug)
    }
  }

  function shuffleNow() {
    var draw = Deck.drawNext(root.st, root.st.pool)
    if (!draw.slug) { root.notify("OmaShuffle", "Pick at least one theme first"); return }
    var next = Deck.shallowClone(root.st)
    next.deck = draw.deck
    root.setState(next)
    root.applyTheme(draw.slug, false)
  }

  function reshuffleDeck() {
    var next = Deck.shallowClone(root.st)
    next.deck = []
    root.setState(next)
  }

  // ============================================================ pool editing

  function inPool(slug) { return (root.st.pool || []).indexOf(slug) !== -1 }

  function togglePool(slug) {
    var clean = Deck.sanitizeSlug(slug)
    if (!clean) return
    var pool = (root.st.pool || []).slice()
    var i = pool.indexOf(clean)
    if (i === -1) pool.push(clean); else pool.splice(i, 1)
    var next = Deck.shallowClone(root.st)
    next.pool = pool
    next.poolInitialized = true
    next.deck = (next.deck || []).filter(function (x) { return pool.indexOf(x) !== -1 })
    root.setState(next)
  }

  function selectAll() {
    var next = Deck.shallowClone(root.st)
    next.pool = root.themes.map(function (t) { return t.slug })
    next.poolInitialized = true
    root.setState(next)
  }

  function selectNone() {
    var next = Deck.shallowClone(root.st)
    next.pool = []
    next.deck = []
    next.poolInitialized = true
    root.setState(next)
  }

  function setEnabled(v) { var n = Deck.shallowClone(root.st); n.enabled = v === true; root.setState(n) }
  function setNotify(v) { var n = Deck.shallowClone(root.st); n.notify = v === true; root.setState(n) }
  function commitChrome(key, value) { var n = Deck.shallowClone(root.st); n[key] = Math.round(value); root.setState(n) }

  function liveChrome(key) {
    if (key === "transparency") return root.liveTransparency
    if (key === "cornerRadius") return root.liveCornerRadius
    return root.liveBorderWidth
  }
  function setLiveChrome(key, v) {
    if (key === "transparency") root.liveTransparency = Math.round(v)
    else if (key === "cornerRadius") root.liveCornerRadius = Math.round(v)
    else root.liveBorderWidth = Math.round(v)
  }

  // ============================================================ helpers

  function displayFor(slug) {
    var t = root.themeBySlug[slug]
    return (t && t.display) ? t.display : slug
  }
  function isHex(s) { return typeof s === "string" && /^#[0-9a-fA-F]{3,8}$/.test(s) }
  function hexOr(s, dflt) { return root.isHex(s) ? s : dflt }

  function ingestThemes(raw) {
    var arr = []
    try { arr = JSON.parse(raw) } catch (e) { arr = [] }
    if (!Array.isArray(arr)) arr = []
    var map = ({})
    var clean = []
    for (var i = 0; i < arr.length; i++) {
      var t = arr[i]
      var slug = Deck.sanitizeSlug(t && t.slug)
      if (!slug || map[slug]) continue
      var extra = Array.isArray(t.colors) ? t.colors.filter(root.isHex).slice(0, 8) : []
      var entry = {
        slug: slug,
        source: (t.source === "user") ? "user" : "system",
        display: (typeof t.display === "string" && t.display) ? String(t.display).slice(0, 120) : slug,
        accent: root.hexOr(t.accent, ""),
        background: root.hexOr(t.background, ""),
        foreground: root.hexOr(t.foreground, ""),
        colors: extra
      }
      // palette strip, precomputed so the delegate stays cheap
      var strip = []
      if (entry.background) strip.push(entry.background)
      if (entry.accent) strip.push(entry.accent)
      for (var k = 0; k < extra.length && strip.length < 6; k++) strip.push(extra[k])
      if (entry.foreground) strip.push(entry.foreground)
      if (strip.length === 0) strip = ["#5a5a5a", "#7a7a7a"]
      entry.strip = strip
      map[slug] = entry
      clean.push(entry)
    }
    clean.sort(function (a, b) {
      var x = a.display.toLowerCase(), y = b.display.toLowerCase()
      return x < y ? -1 : (x > y ? 1 : 0)
    })
    root.themes = clean
    root.themeBySlug = map
  }

  function filteredThemes() {
    var q = root.filterText.trim().toLowerCase()
    if (!q) return root.themes
    return root.themes.filter(function (t) {
      return t.display.toLowerCase().indexOf(q) !== -1 || t.slug.indexOf(q) !== -1
    })
  }

  function notify(title, body) {
    notifyProc.command = ["omarchy-notification-send", "-t", "4000", String(title), String(body)]
    notifyProc.running = true
  }

  // ============================================================ IPC surface

  function open(payloadJson) {
    root.opened = true
    root.settingsOpen = false
    root.filterText = ""
    themeScanProc.running = true
    currentNameProc.running = true
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }
  function close() { root.opened = false }
  function toggle() { if (root.opened) root.close(); else root.open("{}") }

  // Open straight to the settings pane (menu sub-entry / keybind convenience).
  function settings() {
    root.open("{}")
    root.settingsOpen = true
  }

  // ============================================================ UI

  PanelWindow {
    id: win
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omashuffle"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          if (root.settingsOpen) root.settingsOpen = false
          else root.close()
          event.accepted = true
        }
      }

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Math.min(Style.space(980), parent.width - Style.gapsOut * 2)
        height: Math.min(Style.space(700), parent.height - Style.gapsOut * 2)
        radius: root.cardRadius
        color: root.cardBackground
        borderSpec: root.borderSpec

        MouseArea { anchors.fill: parent }   // stop clicks reaching the scrim

        readonly property int pad: Style.spacing.panelPadding

        // -------------------------------------------------- header
        Column {
          id: header
          x: card.pad; y: card.pad
          width: card.width - card.pad * 2
          spacing: 2

          Item {
            width: parent.width
            height: card.settingsHeaderRowH

            Text {
              anchors.left: parent.left
              anchors.top: parent.top
              text: "OmaShuffle"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Row {
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: Style.spacing.sm

              Button {
                text: root.st.enabled ? "Boot shuffle: on" : "Boot shuffle: off"
                foreground: root.foreground; accent: root.accent
                bordered: true; selected: root.st.enabled
                onClicked: root.setEnabled(!root.st.enabled)
              }
              Button {
                iconText: String.fromCodePoint(0xF0493)
                tooltipText: root.settingsOpen ? "Back" : "Settings"
                foreground: root.foreground; accent: root.accent
                selected: root.settingsOpen
                onClicked: root.settingsOpen = !root.settingsOpen
              }
              Button {
                iconText: String.fromCodePoint(0xF0156)
                tooltipText: "Close"
                foreground: root.foreground; accent: root.accent
                onClicked: root.close()
              }
            }
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              var cur = root.currentThemeSlug ? root.displayFor(root.currentThemeSlug) : "-"
              var nxt = root.nextSlug ? root.displayFor(root.nextSlug)
                        : ((root.st.pool || []).length > 0 ? "a random pick from your rotation" : "nothing picked yet")
              return "Now: " + cur + "        Next boot: " + nxt
            }
          }
        }

        readonly property int settingsHeaderRowH: Style.font.heading + Style.spacing.xs

        // -------------------------------------------------- body
        Item {
          id: body
          x: card.pad
          y: card.pad + header.height + Style.spacing.md
          width: card.width - card.pad * 2
          height: card.height - y - card.pad

          // ---- settings view
          Flickable {
            id: settingsFlick
            anchors.fill: parent
            visible: root.settingsOpen
            clip: true
            contentWidth: width
            contentHeight: settingsCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: settingsCol
              width: settingsFlick.width
              spacing: Style.spacing.md

              PanelSectionHeader { text: "BEHAVIOUR" }

              Toggle {
                width: parent.width
                label: "Shuffle on every boot"
                description: "Apply the next deck theme when the machine actually reboots. Shell restarts and relogins don't count."
                checked: root.st.enabled
                onClicked: root.setEnabled(!root.st.enabled)
              }
              Toggle {
                width: parent.width
                label: "Show a notification on switch"
                checked: root.st.notify
                onClicked: root.setNotify(!root.st.notify)
              }

              PanelSectionHeader { text: "CARD APPEARANCE" }

              Repeater {
                model: [
                  { key: "transparency", label: "Transparency", lo: 0, hi: 100 },
                  { key: "cornerRadius", label: "Corner roundness", lo: 0, hi: 20 },
                  { key: "borderWidth", label: "Outline thickness", lo: 0, hi: 6 }
                ]

                Column {
                  width: settingsCol.width
                  spacing: Style.spacing.xs
                  required property var modelData

                  Text {
                    text: modelData.label + ":  " + root.liveChrome(modelData.key)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  PanelSlider {
                    width: parent.width
                    integer: true
                    minimum: modelData.lo
                    maximum: modelData.hi
                    step: 1
                    value: root.st[modelData.key]
                    trackColor: Util.alpha(root.foreground, 0.25)
                    fillColor: root.accent
                    knobColor: root.foreground
                    onMoved: function (v) { root.setLiveChrome(modelData.key, v) }
                    onReleased: function (v) { root.commitChrome(modelData.key, v) }
                  }
                }
              }

              PanelSectionHeader { text: "MENU ENTRY" }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "Open this picker from the Omarchy menu (Super + Space), under Style -> Theme Shuffle. " +
                      "The row is added automatically and removes itself if you disable the plugin."
              }
            }
          }

          // ---- picker view
          Item {
            anchors.fill: parent
            visible: !root.settingsOpen

            Flow {
              id: controls
              width: parent.width
              spacing: Style.spacing.sm

              TextField {
                id: search
                width: Math.min(Style.space(260), parent.width)
                placeholderText: "Filter themes..."
                text: root.filterText
                onTextChanged: root.filterText = text
              }
              Button {
                text: "Shuffle now"; iconText: String.fromCodePoint(0xF049C)
                foreground: root.foreground; accent: root.accent; bordered: true
                onClicked: root.shuffleNow()
              }
              Button {
                text: "Reshuffle deck"
                foreground: root.foreground; accent: root.accent; bordered: true
                onClicked: root.reshuffleDeck()
              }
              Button {
                text: "Select all"
                foreground: root.foreground; accent: root.accent; bordered: true
                onClicked: root.selectAll()
              }
              Button {
                text: "Select none"
                foreground: root.foreground; accent: root.accent; bordered: true
                onClicked: root.selectNone()
              }
            }

            Text {
              id: countLine
              anchors.top: controls.bottom
              anchors.topMargin: Style.spacing.sm
              width: parent.width
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: {
                var n = (root.st.pool || []).length
                return n + " of " + root.themes.length + " themes in rotation    -    " +
                       (root.st.deck || []).length + " left in this shuffle    -    " +
                       "left-click applies now, right-click adds/removes from rotation"
              }
            }

            GridView {
              id: grid
              anchors.top: countLine.bottom
              anchors.topMargin: Style.spacing.sm
              anchors.bottom: historyStrip.top
              anchors.bottomMargin: Style.spacing.sm
              width: parent.width
              clip: true
              cacheBuffer: Style.space(400)
              boundsBehavior: Flickable.StopAtBounds
              model: root.filteredThemes()

              readonly property int cols: Math.max(1, Math.floor(width / Style.space(220)))
              cellWidth: Math.floor(width / cols)
              cellHeight: Style.space(104)

              delegate: Item {
                id: cell
                width: grid.cellWidth
                height: grid.cellHeight
                required property var modelData
                readonly property bool picked: root.inPool(modelData.slug)
                readonly property bool isCurrent: modelData.slug === root.currentThemeSlug

                BorderSurface {
                  anchors.fill: parent
                  anchors.margins: Style.spacing.xs
                  radius: Math.max(2, Style.cornerRadius)
                  color: cellHover.containsMouse
                         ? Util.alpha(root.foreground, 0.12)
                         : Util.alpha(root.foreground, 0.04)
                  borderSpec: Border.flat(cell.picked ? root.accent : Color.menu.border,
                                          cell.picked ? Style.space(2) : 1)

                  Column {
                    anchors.fill: parent
                    anchors.margins: Style.spacing.sm
                    spacing: Style.spacing.xs

                    Row {
                      width: parent.width
                      height: Style.space(16)
                      Repeater {
                        model: cell.modelData.strip
                        Rectangle {
                          width: cell.width > 0 ? (parent.width / cell.modelData.strip.length) : 1
                          height: parent.height
                          color: modelData
                        }
                      }
                    }

                    Item {
                      width: parent.width
                      height: nameText.implicitHeight
                      Text {
                        id: nameText
                        anchors.left: parent.left
                        anchors.right: markText.left
                        anchors.rightMargin: Style.spacing.xs
                        text: cell.modelData.display
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: cell.isCurrent
                        elide: Text.ElideRight
                      }
                      Text {
                        id: markText
                        anchors.right: parent.right
                        text: cell.picked ? String.fromCodePoint(0xF012C) : String.fromCodePoint(0xF0131)
                        color: cell.picked ? root.accent : Qt.darker(root.foreground, 1.9)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }

                    Text {
                      text: cell.isCurrent ? "current" : (cell.modelData.source === "user" ? "custom" : "")
                      visible: text !== ""
                      color: Qt.darker(root.foreground, 1.6)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    id: cellHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function (mouse) {
                      if (mouse.button === Qt.RightButton) root.togglePool(cell.modelData.slug)
                      else root.applyTheme(cell.modelData.slug, false)
                    }
                  }
                }
              }
            }

            Text {
              id: historyStrip
              anchors.bottom: parent.bottom
              width: parent.width
              elide: Text.ElideRight
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: {
                var h = root.st.history || []
                if (h.length === 0) return ""
                var now = Date.now() / 1000
                var parts = []
                for (var i = 0; i < Math.min(h.length, 6); i++) {
                  var age = Deck.relativeAge(h[i].ts, now)
                  parts.push(h[i].display + (age ? " (" + age + ")" : ""))
                }
                return "Recent:  " + parts.join("    -    ")
              }
            }
          }
        }
      }
    }
  }
}
