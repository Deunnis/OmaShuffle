import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ThemeDeck.js" as Deck
import "SunTimes.js" as Sun

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
  // Omarchy's own weather-location file - reused (read-only) as the default
  // Day & Night location source so most people never have to type
  // coordinates by hand. Written by omarchy-weather-location; may not exist.
  readonly property string weatherLocationPath: root.home + "/.local/state/omarchy/settings/weather.json"

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

  // Which of the card's three views is showing. Kept as one string (rather
  // than two independent bools) so the views stay mutually exclusive by
  // construction.
  property string panel: "picker"   // "picker" | "settings" | "schedule"
  property string filterText: ""

  // Location auto-detected from Omarchy's weather settings at startup - not
  // persisted (re-read fresh every session); used whenever
  // schedule.locationMode is "auto". NaN means "nothing detected yet / no
  // usable coordinates there".
  property real detectedLat: NaN
  property real detectedLon: NaN
  property string detectedLocationLabel: ""

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

  // current/theme.name lives under ~/.local/state, so read it with the same
  // descriptor-pinned bounded reader as state.json rather than a bare `cat`.
  Process {
    id: currentNameProc
    command: ["python3", "-c", root.stateReaderScript, root.currentNamePath, "4096"]
    stdout: StdioCollector { id: currentNameOut; waitForEnd: true }
    onExited: function (code) {
      var live = code === 0 ? Deck.sanitizeSlug(String(currentNameOut.text || "").trim()) : ""
      root.currentThemeSlug = live
      if (root.verifying) {
        root.verifying = false
        if (root.applyingSlug && live && live !== root.applyingSlug && root.st.notify)
          root.notify("OmaShuffle", "Theme may not have applied: " + root.displayFor(root.applyingSlug))
        root.applyingSlug = ""
      }
    }
  }

  // Read-only, best-effort: Omarchy's weather-location file, reused as the
  // default Day & Night location source. Same bounded, descriptor-pinned
  // reader as state.json / theme.name - missing file (very likely; it's
  // optional and only written when the user sets a weather location) or an
  // unreadable/oversized one just means "nothing detected", handled the
  // same as any other exit code here.
  Process {
    id: weatherLocationProc
    command: ["python3", "-c", root.stateReaderScript, root.weatherLocationPath, "4096"]
    stdout: StdioCollector { id: weatherLocationOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      var parsed = null
      try { parsed = JSON.parse(weatherLocationOut.text) } catch (e) { parsed = null }
      if (!parsed || typeof parsed !== "object") return
      var lat = Number(parsed.latitude), lon = Number(parsed.longitude)
      if (isFinite(lat) && lat >= -90 && lat <= 90 && isFinite(lon) && lon >= -180 && lon <= 180) {
        root.detectedLat = lat
        root.detectedLon = lon
      }
      if (typeof parsed.name === "string") root.detectedLocationLabel = parsed.name.slice(0, 120)
      // This can resolve after the initial checkSchedule() call at startup
      // (independent process, no ordering guarantee) - re-check so an
      // auto-location schedule doesn't sit on the wrong slot until the next
      // 60s tick.
      root.checkSchedule()
    }
  }

  Process {
    id: themeScanProc
    // Outer hard deadline; the scanner also self-bounds output and read sizes.
    command: ["timeout", "-k", "2", "12", root.scanBin]
    stdout: StdioCollector { id: themeScanOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) { console.warn("OmaShuffle: theme scan exited " + code); return }
      root.ingestThemes(themeScanOut.text)
    }
  }

  // Fire-and-forget spawns. `omarchy theme set` is chatty and leaves a
  // short-lived backgrounded child on its stdout pipe, so a tracked
  // running=true/onExited Process is not dependable here - startDetached()
  // sidesteps exit tracking entirely, which is fine because the deck/history
  // update is done up front and applied themes are re-verified by re-reading
  // theme.name a few seconds later (verifyTimer).
  Process { id: themeSetProc }
  Process { id: menuEntryProc }
  Process { id: notifyProc }

  Component.onCompleted: {
    stateDirInitProc.running = true
    bootIdProc.running = true
    themeScanProc.running = true
    currentNameProc.running = true
    weatherLocationProc.running = true
  }

  // Live boundary-crossing check for Day & Night. A 60s cadence is simple,
  // needs no suspend/resume hooks, and comfortably covers "switch within a
  // minute of the boundary" and "catch up after the machine was asleep"
  // (the next tick after resume just sees whatever slot is current).
  Timer {
    id: scheduleTimer
    interval: 60000
    repeat: true
    running: root.stateLoaded && root.st.schedule.enabled
    triggeredOnStart: false
    onTriggered: root.checkSchedule()
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
    root.checkSchedule()
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

    // Boot-shuffle's own top-level draw is dormant while Day & Night is on -
    // checkSchedule() decides the applied theme in that case, and its own
    // per-slot decks are where the "shuffle" comes from instead.
    if (!root.st.enabled || root.st.schedule.enabled) { root.setState(next); return }

    var draw = Deck.drawNext(root.st, root.st.pool)
    if (!draw.slug) {
      // Empty rotation. Nudge the user a few times, then stay quiet.
      if (root.st.notify && !root.st.poolInitialized && next.nagsLeft > 0) {
        next.nagsLeft = next.nagsLeft - 1
        root.notify("OmaShuffle", "Pick some themes to shuffle - open OmaShuffle from your Omarchy menu or a keybind")
      }
      root.setState(next)
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

  // The deck/history update is done up front rather than waiting on the
  // process: `omarchy theme set` is idempotent and its exit is not dependable
  // (see the Process comment above). verifyTimer re-reads theme.name a few
  // seconds later so the UI self-corrects (and warns) if the switch didn't
  // actually land.
  property double lastApplyMs: 0

  // `quiet` suppresses the switch notification even when the notify setting
  // is on - used for Day & Night's own "instant + quiet" auto-switches; the
  // theme-may-not-have-applied safety warning (verifyTimer) is unaffected.
  function applyTheme(slug, auto, quiet) {
    var clean = Deck.sanitizeSlug(slug)
    if (!clean) { console.warn("OmaShuffle: refusing invalid theme slug: " + slug); return }

    // Ignore a repeat request for the theme already being applied (double
    // click, or clicking the current theme) - but never block switching to a
    // different one.
    var nowMs = Date.now()
    if (clean === root.st.lastAppliedSlug && nowMs - root.lastApplyMs < 3000) return
    root.lastApplyMs = nowMs

    root.applyingSlug = clean

    var disp = root.displayFor(clean)
    var newDeck = auto ? null : (root.st.deck || []).filter(function (x) { return x !== clean })
    var next = Deck.recordApplied(root.st, clean, disp, Date.now() / 1000, auto === true, newDeck)

    // A manual pick (from the grid, not an auto/scheduled apply) while Day &
    // Night is driving selection pauses its auto-switching until the next
    // boundary, rather than having the next tick immediately redraw over
    // the user's choice. Persisted, so the pause survives a shell restart.
    if (!auto && next.schedule.enabled) {
      var loc = root.effectiveLocation()
      var sched = Sun.computeSchedule(next.schedule.slots, loc.lat, loc.lon, new Date())
      next = Deck.shallowClone(next)
      next.schedule = Deck.shallowClone(next.schedule)
      next.schedule.override = { slug: clean, untilTs: sched.nextBoundaryTs || 0 }
    }

    root.setState(next)
    root.currentThemeSlug = clean

    themeSetProc.command = ["omarchy", "theme", "set", clean]
    themeSetProc.startDetached()

    if (root.st.notify && !quiet) root.notify("OmaShuffle", (auto ? "This boot's theme: " : "Applied: ") + disp)
    verifyTimer.restart()
  }

  Timer {
    id: verifyTimer
    interval: 5000
    repeat: false
    onTriggered: { root.verifying = true; if (!currentNameProc.running) currentNameProc.running = true }
  }
  property bool verifying: false

  // Both act on the currently-active Day & Night slot's deck instead of the
  // global boot-shuffle deck when the schedule is on.
  function shuffleNow() {
    if (root.st.schedule.enabled) {
      var active = root.activeSlot()
      if (!active) { root.notify("OmaShuffle", "No active Day & Night slot yet"); return }
      root.applyForSlot(active.id, true, false)
      return
    }
    var draw = Deck.drawNext(root.st, root.st.pool)
    if (!draw.slug) { root.notify("OmaShuffle", "Pick at least one theme first"); return }
    var next = Deck.shallowClone(root.st)
    next.deck = draw.deck
    root.setState(next)
    root.applyTheme(draw.slug, false)
  }

  function reshuffleDeck() {
    if (root.st.schedule.enabled) {
      var active = root.activeSlot()
      if (!active) return
      root.updateSlot(active.id, { deck: [] })
      return
    }
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
    if (root.themes.length === 0) return
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

  // Add every installed theme of one mode ("dark" / "light") to the rotation,
  // leaving anything already picked in place. Additive, so "All dark" then
  // "All light" ends up with everything.
  function selectByMode(mode) {
    if (root.themes.length === 0) return
    var pool = (root.st.pool || []).slice()
    var matched = 0, added = 0
    for (var i = 0; i < root.themes.length; i++) {
      var t = root.themes[i]
      if (t.mode !== mode) continue
      matched++
      if (pool.indexOf(t.slug) === -1) { pool.push(t.slug); added++ }
    }
    if (added === 0) {
      root.notify("OmaShuffle", matched === 0 ? "No " + mode + " themes installed"
                                              : "Every " + mode + " theme is already in the rotation")
      return
    }
    var next = Deck.shallowClone(root.st)
    next.pool = pool
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

  // ============================================================ day & night

  // Manual-mode coordinates take priority; otherwise whatever was detected
  // from Omarchy's weather location at startup (NaN if nothing was found -
  // SunTimes.js treats non-finite lat/lon as "no schedule").
  function effectiveLocation() {
    var sch = root.st.schedule
    if (sch.locationMode === "manual") {
      return {
        lat: (typeof sch.latitude === "number") ? sch.latitude : NaN,
        lon: (typeof sch.longitude === "number") ? sch.longitude : NaN
      }
    }
    return { lat: root.detectedLat, lon: root.detectedLon }
  }

  function poolForMode(mode) {
    return (root.st.pool || []).filter(function (slug) {
      var t = root.themeBySlug[slug]
      return t && t.mode === mode
    })
  }

  function findSlot(slots, id) {
    for (var i = 0; i < slots.length; i++) if (slots[i].id === id) return slots[i]
    return null
  }

  // The slot Sun.computeSchedule resolves as active right now, or null if
  // there are no slots at all (shouldn't happen - normalizeSlots never
  // empties the array - but keep callers safe).
  function activeSlot() {
    var sch = root.st.schedule
    var loc = root.effectiveLocation()
    return Sun.computeSchedule(sch.slots, loc.lat, loc.lon, new Date()).activeSlot
  }

  function updateSchedule(patch) {
    var next = Deck.shallowClone(root.st)
    next.schedule = Deck.shallowClone(root.st.schedule)
    for (var k in patch) next.schedule[k] = patch[k]
    root.setState(next)
  }

  function setScheduleEnabled(v) { root.updateSchedule({ enabled: v === true }) }
  function setLocationMode(mode) { root.updateSchedule({ locationMode: mode === "manual" ? "manual" : "auto" }) }

  function setManualLatitude(text) {
    var v = parseFloat(text)
    if (!isFinite(v)) return
    root.updateSchedule({ latitude: Math.max(-90, Math.min(90, v)) })
  }
  function setManualLongitude(text) {
    var v = parseFloat(text)
    if (!isFinite(v)) return
    root.updateSchedule({ longitude: Math.max(-180, Math.min(180, v)) })
  }

  function updateSlot(id, patch) {
    var next = Deck.shallowClone(root.st)
    next.schedule = Deck.shallowClone(root.st.schedule)
    next.schedule.slots = root.st.schedule.slots.map(function (s) {
      if (s.id !== id) return s
      var merged = Deck.shallowClone(s)
      for (var k in patch) merged[k] = patch[k]
      return merged
    })
    root.setState(next)
  }

  function addSlot() {
    var slots = root.st.schedule.slots
    if (slots.length >= 6) return
    var id = "slot-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1000)
    var next = Deck.shallowClone(root.st)
    next.schedule = Deck.shallowClone(root.st.schedule)
    next.schedule.slots = slots.concat([{
      id: id, label: "New slot", mode: "dark", anchor: "sunset", offsetMin: 0, deck: [], lastAppliedSlug: ""
    }])
    root.setState(next)
  }

  function removeSlot(id) {
    var slots = root.st.schedule.slots
    if (slots.length <= 1) return
    var next = Deck.shallowClone(root.st)
    next.schedule = Deck.shallowClone(root.st.schedule)
    next.schedule.slots = slots.filter(function (s) { return s.id !== id })
    if (next.schedule.lastAppliedSlotId === id) next.schedule.lastAppliedSlotId = ""
    root.setState(next)
  }

  // Draw (if needed) and apply the theme for one slot. `drawNew` forces a
  // fresh pull from that slot's own no-repeat deck - a real boundary
  // crossing, or an explicit Shuffle now / Reshuffle deck while that slot is
  // active; otherwise this just reasserts whatever the slot last drew, so a
  // plain shell restart mid-slot doesn't burn through its deck.
  function applyForSlot(slotId, drawNew, quiet) {
    var sch = root.st.schedule
    var slot = root.findSlot(sch.slots, slotId)
    if (!slot) return

    var slug = slot.lastAppliedSlug
    var newDeck = slot.deck

    if (drawNew || !slug) {
      var draw = Deck.drawNext({ deck: slot.deck, lastAppliedSlug: slot.lastAppliedSlug }, root.poolForMode(slot.mode))
      if (!draw.slug) {
        if (sch.notifiedEmptyModeFor !== slot.id) {
          root.notify("OmaShuffle", "No " + slot.mode + " themes in your rotation for the \"" + slot.label + "\" slot")
          root.updateSchedule({ notifiedEmptyModeFor: slot.id })
        }
        return
      }
      slug = draw.slug
      newDeck = draw.deck
    }

    var next = Deck.shallowClone(root.st)
    next.schedule = Deck.shallowClone(sch)
    next.schedule.slots = sch.slots.map(function (s) {
      if (s.id !== slot.id) return s
      var s2 = Deck.shallowClone(s); s2.lastAppliedSlug = slug; s2.deck = newDeck; return s2
    })
    next.schedule.lastAppliedSlotId = slot.id
    next.schedule.notifiedEmptyModeFor = ""   // the rotation produced a theme again - clear any stale warning
    root.st = next
    root.applyTheme(slug, true, quiet !== false)   // auto; quiet unless explicitly told otherwise
  }

  // Called at startup, whenever the weather-location read resolves, and
  // every 60s while enabled (scheduleTimer). No-ops unless Day & Night is on.
  function checkSchedule() {
    var sch = root.st.schedule
    if (!sch.enabled) return
    // The theme scan is async and populates themeBySlug (and thus the
    // per-mode pools). Until it lands there is nothing to reason about -
    // ingestThemes() calls back here once it does.
    if (root.themes.length === 0) return
    var loc = root.effectiveLocation()
    var result = Sun.computeSchedule(sch.slots, loc.lat, loc.lon, new Date())
    if (!result.activeSlot) return

    var now = Date.now()
    if (sch.override.untilTs > 0 && sch.override.untilTs <= now) {
      root.updateSchedule({ override: { slug: "", untilTs: 0 } })
      sch = root.st.schedule
    }
    if (sch.override.untilTs > now) return   // a manual pick is still holding

    var isNewActivation = sch.lastAppliedSlotId !== result.activeSlot.id
    var driftedSinceRestart = !isNewActivation && result.activeSlot.lastAppliedSlug &&
                               result.activeSlot.lastAppliedSlug !== root.currentThemeSlug
    if (isNewActivation || driftedSinceRestart) {
      root.applyForSlot(result.activeSlot.id, isNewActivation)
    }
  }

  // ============================================================ helpers

  function displayFor(slug) {
    var t = root.themeBySlug[slug]
    return (t && t.display) ? t.display : slug
  }
  function isHex(s) { return typeof s === "string" && /^#[0-9a-fA-F]{3,8}$/.test(s) }
  function hexOr(s, dflt) { return root.isHex(s) ? s : dflt }
  function pad2(n) { return (n < 10 ? "0" : "") + n }

  readonly property int maxThemes: 600
  readonly property int maxScanChars: 1048576

  function ingestThemes(raw) {
    if (typeof raw !== "string" || raw.length > root.maxScanChars) {
      console.warn("OmaShuffle: theme scan output missing or too large - ignoring")
      return
    }
    var arr = []
    try { arr = JSON.parse(raw) } catch (e) { arr = [] }
    if (!Array.isArray(arr)) arr = []
    var map = ({})
    var clean = []
    for (var i = 0; i < arr.length && clean.length < root.maxThemes; i++) {
      var t = arr[i]
      var slug = Deck.sanitizeSlug(t && t.slug)
      if (!slug || map[slug]) continue
      var extra = Array.isArray(t.colors) ? t.colors.filter(root.isHex).slice(0, 8) : []
      var entry = {
        slug: slug,
        source: (t.source === "user") ? "user" : "system",
        display: (typeof t.display === "string" && t.display) ? String(t.display).slice(0, 120) : slug,
        mode: (t.mode === "light") ? "light" : "dark",
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
    // The per-mode pools only become meaningful once this has run - re-check
    // in case a Day & Night schedule was waiting on it at startup.
    root.checkSchedule()
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
    notifyProc.startDetached()
  }

  // Menu row is opt-in: added / removed only when the user asks, from the
  // settings pane. The helper script is idempotent either way.
  function addMenuEntry() {
    menuEntryProc.command = [root.menuEntryBin, "--add"]
    menuEntryProc.startDetached()
    root.notify("OmaShuffle", "Added to the Omarchy menu under Style")
  }
  function removeMenuEntry() {
    menuEntryProc.command = [root.menuEntryBin, "--remove"]
    menuEntryProc.startDetached()
    root.notify("OmaShuffle", "Removed from the Omarchy menu")
  }

  // ============================================================ IPC surface

  function open(payloadJson) {
    root.opened = true
    root.panel = "picker"
    root.filterText = ""
    grid.currentIndex = 0
    if (!themeScanProc.running) themeScanProc.running = true
    if (!currentNameProc.running) currentNameProc.running = true
    Qt.callLater(function () { grid.forceActiveFocus() })
  }
  function close() { root.opened = false }
  function toggle() { if (root.opened) root.close(); else root.open("{}") }

  // Open straight to the settings pane (menu sub-entry / keybind convenience).
  function settings() {
    root.open("{}")
    root.panel = "settings"
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
      // Intercept Escape before any focused child; let every other key through.
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          if (root.panel !== "picker") root.panel = "picker"
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
        readonly property int headerRowH: Style.font.heading + Style.spacing.xs

        // -------------------------------------------------- header
        Column {
          id: header
          x: card.pad; y: card.pad
          width: card.width - card.pad * 2
          spacing: 2

          Item {
            width: parent.width
            height: card.headerRowH

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
                text: root.st.schedule.enabled ? "Day & Night: on" : "Day & Night: off"
                foreground: root.foreground; accent: root.accent
                bordered: true; selected: root.st.schedule.enabled
                onClicked: root.setScheduleEnabled(!root.st.schedule.enabled)
              }
              Button {
                text: "Schedule"
                tooltipText: root.panel === "schedule" ? "Back" : "Day & Night settings"
                foreground: root.foreground; accent: root.accent
                bordered: true; selected: root.panel === "schedule"
                onClicked: root.panel = root.panel === "schedule" ? "picker" : "schedule"
              }
              Button {
                iconText: String.fromCodePoint(0xF0493)
                tooltipText: root.panel === "settings" ? "Back" : "Settings"
                foreground: root.foreground; accent: root.accent
                selected: root.panel === "settings"
                onClicked: root.panel = root.panel === "settings" ? "picker" : "settings"
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
              if (root.st.schedule.enabled) {
                var loc = root.effectiveLocation()
                var sched = Sun.computeSchedule(root.st.schedule.slots, loc.lat, loc.lon, new Date())
                var activeLabel = sched.activeSlot ? sched.activeSlot.label : "-"
                var nextBit = "-"
                if (sched.nextSlot && sched.nextBoundaryTs) {
                  var d = new Date(sched.nextBoundaryTs)
                  nextBit = sched.nextSlot.label + " at " + root.pad2(d.getHours()) + ":" + root.pad2(d.getMinutes())
                }
                return "Now: " + cur + " (" + activeLabel + ")        Next: " + nextBit
              }
              var nxt = root.nextSlug ? root.displayFor(root.nextSlug)
                        : ((root.st.pool || []).length > 0 ? "a random pick from your rotation" : "nothing picked yet")
              return "Now: " + cur + "        Next boot: " + nxt
            }
          }
        }

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
            visible: root.panel === "settings"
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

              PanelSectionHeader { text: "OMARCHY MENU" }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "Add a row to the Omarchy menu (Super + Space) under Style, so you can open this " +
                      "picker without a keybind. It edits ~/.config/omarchy/extensions/omarchy-menu.jsonc " +
                      "(backed up first) and only ever touches its own row."
              }
              Row {
                width: parent.width
                spacing: Style.spacing.sm
                Button {
                  text: "Add menu entry"
                  foreground: root.foreground; accent: root.accent; bordered: true
                  onClicked: root.addMenuEntry()
                }
                Button {
                  text: "Remove menu entry"
                  foreground: root.foreground; accent: root.accent; bordered: true
                  onClicked: root.removeMenuEntry()
                }
              }
            }
          }

          // ---- Day & Night view
          Flickable {
            id: scheduleFlick
            anchors.fill: parent
            visible: root.panel === "schedule"
            clip: true
            contentWidth: width
            contentHeight: scheduleCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: scheduleCol
              width: scheduleFlick.width
              spacing: Style.spacing.md

              PanelSectionHeader { text: "DAY & NIGHT" }

              Toggle {
                width: parent.width
                label: "Switch themes by time of day"
                description: "Independent of boot shuffle - while this is on, each slot below applies a theme of its own from your rotation as its turn comes up."
                checked: root.st.schedule.enabled
                onClicked: root.setScheduleEnabled(!root.st.schedule.enabled)
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                visible: root.st.schedule.enabled
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: {
                  var loc = root.effectiveLocation()
                  if (!isFinite(loc.lat) || !isFinite(loc.lon)) return "No location yet - enter coordinates below."
                  var sched = Sun.computeSchedule(root.st.schedule.slots, loc.lat, loc.lon, new Date())
                  if (!sched.activeSlot) return ""
                  var line = sched.activeSlot.label + " is active now."
                  if (sched.nextSlot && sched.nextBoundaryTs) {
                    var d = new Date(sched.nextBoundaryTs)
                    line += "  Next: " + sched.nextSlot.label + " at " + root.pad2(d.getHours()) + ":" + root.pad2(d.getMinutes())
                  }
                  return line
                }
              }

              PanelSectionHeader { text: "LOCATION" }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: root.detectedLocationLabel || isFinite(root.detectedLat)
                      ? "Detected from your Omarchy weather location: " +
                        (root.detectedLocationLabel || (root.detectedLat.toFixed(2) + ", " + root.detectedLon.toFixed(2)))
                      : "No weather location set - set one with omarchy-weather-location, or enter coordinates manually below."
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm
                Button {
                  text: "Auto (detected)"
                  foreground: root.foreground; accent: root.accent; bordered: true
                  selected: root.st.schedule.locationMode === "auto"
                  onClicked: root.setLocationMode("auto")
                }
                Button {
                  text: "Manual"
                  foreground: root.foreground; accent: root.accent; bordered: true
                  selected: root.st.schedule.locationMode === "manual"
                  onClicked: root.setLocationMode("manual")
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.st.schedule.locationMode === "manual"

                TextField {
                  id: latField
                  width: Style.space(140)
                  placeholderText: "Latitude"
                  text: (typeof root.st.schedule.latitude === "number") ? String(root.st.schedule.latitude) : ""
                  onEditingFinished: root.setManualLatitude(text)
                }
                TextField {
                  id: lonField
                  width: Style.space(140)
                  placeholderText: "Longitude"
                  text: (typeof root.st.schedule.longitude === "number") ? String(root.st.schedule.longitude) : ""
                  onEditingFinished: root.setManualLongitude(text)
                }
              }

              PanelSectionHeader { text: "SLOTS" }

              Repeater {
                model: root.st.schedule.slots

                Column {
                  width: scheduleCol.width
                  spacing: Style.spacing.xs
                  required property var modelData

                  BorderSurface {
                    width: parent.width
                    height: slotRow.implicitHeight + Style.spacing.md * 2
                    radius: Style.cornerRadius
                    color: Util.alpha(root.foreground, 0.04)
                    borderSpec: Border.flat(Color.menu.border, 1)

                    Row {
                      id: slotRow
                      anchors.centerIn: parent
                      width: parent.width - Style.spacing.md * 2
                      spacing: Style.spacing.md

                      TextField {
                        width: Style.space(120)
                        text: modelData.label
                        onEditingFinished: root.updateSlot(modelData.id, { label: text.slice(0, 40) || modelData.id })
                      }
                      Dropdown {
                        label: "Mode"
                        options: [{ value: "light", label: "Light" }, { value: "dark", label: "Dark" }]
                        value: modelData.mode
                        onChanged: function (v) { root.updateSlot(modelData.id, { mode: v }) }
                      }
                      Dropdown {
                        label: "Anchor"
                        options: [{ value: "sunrise", label: "Sunrise" }, { value: "sunset", label: "Sunset" }]
                        value: modelData.anchor
                        onChanged: function (v) { root.updateSlot(modelData.id, { anchor: v }) }
                      }
                      NumberField {
                        label: "Offset (min)"
                        value: modelData.offsetMin
                        from: -180; to: 180; stepSize: 5
                        onModified: function (v) { root.updateSlot(modelData.id, { offsetMin: v }) }
                      }
                      Button {
                        text: "Remove"
                        foreground: root.foreground; accent: root.accent; bordered: true
                        enabled: root.st.schedule.slots.length > 1
                        onClicked: root.removeSlot(modelData.id)
                      }
                    }
                  }
                }
              }

              Button {
                text: "Add slot"
                foreground: root.foreground; accent: root.accent; bordered: true
                enabled: root.st.schedule.slots.length < 6
                onClicked: root.addSlot()
              }
            }
          }

          // ---- picker view
          Item {
            anchors.fill: parent
            visible: root.panel === "picker"

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
              Button {
                text: "All dark"
                tooltipText: "Add every dark theme to the rotation"
                foreground: root.foreground; accent: root.accent; bordered: true
                onClicked: root.selectByMode("dark")
              }
              Button {
                text: "All light"
                tooltipText: "Add every light theme to the rotation"
                foreground: root.foreground; accent: root.accent; bordered: true
                onClicked: root.selectByMode("light")
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
                return n + " of " + root.themes.length + " in rotation    -    " +
                       (root.st.deck || []).length + " left in this shuffle    -    " +
                       "click / Enter applies, right-click / Space adds to rotation"
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

              keyNavigationEnabled: true
              keyNavigationWraps: false
              highlightMoveDuration: 90
              Component.onCompleted: currentIndex = 0

              // Arrow keys move the highlight (GridView handles that natively);
              // Enter applies the highlighted theme, Space adds/removes it from
              // the rotation, Escape closes.
              Keys.onReturnPressed: if (currentItem) root.applyTheme(currentItem.modelData.slug, false)
              Keys.onEnterPressed: if (currentItem) root.applyTheme(currentItem.modelData.slug, false)
              Keys.onSpacePressed: if (currentItem) root.togglePool(currentItem.modelData.slug)
              Keys.onEscapePressed: root.close()

              highlight: Rectangle {
                color: "transparent"
                border.color: root.accent
                border.width: Math.max(2, Style.space(2))
                radius: Math.max(2, Style.cornerRadius)
                visible: grid.activeFocus
                z: 2
              }

              readonly property int cols: Math.max(1, Math.floor(width / Style.space(220)))
              cellWidth: Math.floor(width / cols)
              cellHeight: Style.space(104)

              delegate: Item {
                id: cell
                width: grid.cellWidth
                height: grid.cellHeight
                required property var modelData
                required property int index
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
                      id: paletteStrip
                      width: parent.width
                      height: Style.space(16)
                      clip: true
                      Repeater {
                        model: cell.modelData.strip
                        Rectangle {
                          width: Math.ceil(paletteStrip.width / Math.max(1, cell.modelData.strip.length))
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
                      grid.currentIndex = cell.index
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
              height: Style.font.caption + Style.spacing.xs   // fixed, so the grid anchor can't loop
              verticalAlignment: Text.AlignBottom
              elide: Text.ElideRight
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: {
                var h = root.st.history || []
                if (h.length === 0) return "your recent themes show up here"
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
