.pragma library

// Pure deck logic for OmaShuffle. No QML, no I/O - just state in, state out,
// so it can be reasoned about and tested on its own.

var STATE_VERSION = 1
var MAX_HISTORY = 40
var MAX_POOL = 500      // far above any real installed-theme count; a sanity cap
var SLUG_RE = /^[a-z0-9][a-z0-9._-]*$/

// omarchy-theme-set's own rules: lowercase, no leading dot, no slash.
function sanitizeSlug(s) {
  if (typeof s !== "string") return ""
  if (s.length === 0 || s.length > 128) return ""
  if (s.indexOf("/") !== -1 || s.indexOf("..") !== -1) return ""
  return SLUG_RE.test(s) ? s : ""
}

function sanitizeSlugList(arr) {
  var out = []
  if (!Array.isArray(arr)) return out
  for (var i = 0; i < arr.length && out.length < MAX_POOL; i++) {
    var s = sanitizeSlug(arr[i])
    if (s && out.indexOf(s) === -1) out.push(s)
  }
  return out
}

// Fisher-Yates on a copy. Math.random is fine in the QML JS engine.
function shuffle(arr) {
  var a = arr.slice()
  for (var i = a.length - 1; i > 0; i--) {
    var j = Math.floor(Math.random() * (i + 1))
    var t = a[i]; a[i] = a[j]; a[j] = t
  }
  return a
}

// Normalize whatever came off disk into a known-good state object.
function normalizeState(raw) {
  var s = (raw && typeof raw === "object") ? raw : {}
  var pool = sanitizeSlugList(s.pool)
  var st = {
    version: STATE_VERSION,
    enabled: s.enabled !== false,
    notify: s.notify !== false,
    poolInitialized: s.poolInitialized === true,
    // "pick some themes" reminders left to show on an empty rotation
    nagsLeft: clampInt(s.nagsLeft, 0, 3, 3),
    pool: pool,
    deck: sanitizeSlugList(s.deck).filter(function (x) { return pool.indexOf(x) !== -1 }),
    lastAppliedSlug: sanitizeSlug(s.lastAppliedSlug),
    lastBootId: (typeof s.lastBootId === "string" && s.lastBootId.length <= 128) ? s.lastBootId : "",
    history: [],
    // card chrome, mirrored from OmaDeezer's ranges/defaults
    transparency: clampInt(s.transparency, 0, 100, 0),
    cornerRadius: clampInt(s.cornerRadius, 0, 20, 8),
    borderWidth: clampInt(s.borderWidth, 0, 6, 2)
  }
  if (Array.isArray(s.history)) {
    for (var i = 0; i < s.history.length && st.history.length < MAX_HISTORY; i++) {
      var h = s.history[i]
      if (!h || typeof h !== "object") continue
      var slug = sanitizeSlug(h.slug)
      if (!slug) continue
      st.history.push({
        slug: slug,
        display: (typeof h.display === "string") ? h.display.slice(0, 120) : slug,
        ts: (typeof h.ts === "number" && isFinite(h.ts)) ? Math.floor(h.ts) : 0,
        auto: h.auto === true
      })
    }
  }
  return st
}

function clampInt(v, lo, hi, dflt) {
  var n = Math.round(Number(v))
  if (!isFinite(n)) return dflt
  return Math.max(lo, Math.min(hi, n))
}

// Pick the next theme to apply. Returns { slug, deck } where deck is the
// remaining deck AFTER taking slug. slug is "" when the pool is empty.
// `pool` is the authoritative current selection (state.pool may lag a tick).
function drawNext(state, pool) {
  var live = sanitizeSlugList(pool)
  if (live.length === 0) return { slug: "", deck: [] }

  var deck = (state && Array.isArray(state.deck) ? state.deck : [])
    .filter(function (x) { return live.indexOf(x) !== -1 })

  if (deck.length === 0) {
    deck = shuffle(live)
    // Avoid repeating the theme we just came from when there's a choice.
    var last = state ? state.lastAppliedSlug : ""
    if (deck.length > 1 && deck[0] === last) {
      deck.push(deck.shift())
    }
  }

  var slug = deck[0]
  return { slug: slug, deck: deck.slice(1) }
}

// Fold an applied theme into state (used for both auto and manual applies).
function recordApplied(state, slug, display, nowSec, auto, newDeck) {
  var next = shallowClone(state)
  next.lastAppliedSlug = slug
  if (Array.isArray(newDeck)) next.deck = newDeck
  var entry = { slug: slug, display: display || slug, ts: Math.floor(nowSec) || 0, auto: auto === true }
  next.history = [entry].concat(state.history || []).slice(0, MAX_HISTORY)
  return next
}

function shallowClone(o) {
  var n = {}
  for (var k in o) n[k] = o[k]
  return n
}

// "3 boots ago" style label is unreliable (we don't track boot count), so
// history uses elapsed wall-clock time instead.
function relativeAge(tsSec, nowSec) {
  if (!tsSec) return ""
  var d = Math.max(0, Math.floor(nowSec - tsSec))
  if (d < 45) return "just now"
  if (d < 90) return "a minute ago"
  if (d < 3600) return Math.round(d / 60) + " min ago"
  if (d < 7200) return "an hour ago"
  if (d < 86400) return Math.round(d / 3600) + " hours ago"
  if (d < 172800) return "yesterday"
  return Math.round(d / 86400) + " days ago"
}
