<div align="center">

<img src="icon.png" alt="OmaShuffle" width="128">

# OmaShuffle

**A fresh [Omarchy](https://omarchy.org/) theme every time you boot.**

Pick the themes you like once. From then on, every real boot deals you the next
one from a shuffled deck — no repeats until you've seen them all.

<img src="https://img.shields.io/badge/Omarchy-4.x-a855f7?style=flat-square" alt="Omarchy 4.x">
<img src="https://img.shields.io/badge/kind-overlay-22d3ee?style=flat-square" alt="overlay plugin">
<img src="https://img.shields.io/badge/network-none-16a34a?style=flat-square" alt="no network">
<img src="https://img.shields.io/badge/license-MIT-64748b?style=flat-square" alt="MIT">

<br><br>

<img src="screenshots/picker.png" alt="The OmaShuffle picker: a grid of every installed theme with palette swatches, some ticked into the rotation" width="860">

</div>

## Is this for you?

- You installed six themes, loved the third one for a week, and now you're bored again.
- You keep `omarchy theme set`-ing around at 1am instead of sleeping.
- You genuinely can't decide, and honestly you'd rather your computer just surprised you.
- You like your desk to feel a little different on a Monday than it did on Friday.

If any of that landed: this is for you. OmaShuffle turns "ugh, which theme
today" into a decision you already made, once, in a nice grid.

## How it works

You open the picker and tick the themes you want in the rotation. That's the
whole setup.

After that, **every real boot** OmaShuffle quietly applies the next theme in the
deck. The deck is a shuffled bag: every theme you picked comes up exactly once,
then the bag reshuffles and the theme you're currently wearing gets pushed to
the back so you don't see it twice in a row.

"Real boot" means a genuine power-on or reboot — the kind where you had to type
your disk-unlock passphrase. It reads `/proc/sys/kernel/random/boot_id`, a value
the kernel regenerates on every boot and keeps stable within one. So:

| This happens | Theme switches? |
|---|---|
| You reboot / power on | **yes** |
| `omarchy restart shell`, or the shell reloads | no |
| You log out and back in | no |
| Suspend / resume, closing the lid | no |

Nothing here is a one-way door. It's a normal `omarchy theme set` under the
hood — grab any theme by hand from the picker (or the usual `omarchy theme`
command) whenever the deck deals you something you're not in the mood for.

## Install

```bash
omarchy plugin add https://github.com/Deunnis/OmaShuffle.git --enable
omarchy restart shell
```

Then open the picker from the Omarchy menu — **Super + Space → Style → Theme
Shuffle**. The menu row installs itself the first time the plugin loads, and
takes itself back out if you ever disable the plugin.

Prefer a keybinding? Add one to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER SHIFT", "T", "omarchy-shell shell toggle io.github.omashuffle")
```

Until you've picked at least one theme, nothing switches — you just get a
one-time nudge on boot pointing you at the menu.

## Using the picker

<img src="screenshots/settings.png" alt="The OmaShuffle settings pane: boot-shuffle and notification toggles, plus transparency, corner and outline sliders" width="640">

| Action | What it does |
|---|---|
| **Left-click a theme** | apply it right now |
| **Right-click a theme** | add / remove it from the rotation (the checkmark) |
| **Shuffle now** | jump straight to the next deck theme |
| **Reshuffle deck** | throw out the current order and draw a fresh shuffle |
| **Select all / none** | bulk-edit the rotation |
| **Boot shuffle: on / off** | the master switch for the once-per-boot behaviour |
| **Filter themes…** | narrow the grid by name |
| gear icon | notification on/off, plus transparency / corner / outline sliders for the card |
| `Esc` | close (or leave settings) |

The header always tells you what you're wearing now and what's queued for next
boot. The strip along the bottom is your recent history.

## Where it keeps things

Everything lives in one file:
`~/.local/state/omarchy/io.github.omashuffle/state.json`

- `pool` — the theme slugs you put in the rotation
- `deck` — the remaining shuffled order for the current bag; when it empties, a
  fresh shuffle of `pool` is drawn
- `history` — the last 40 themes OmaShuffle applied, with timestamps
- `lastBootId` — the `boot_id` at the last switch, i.e. the "was this a real
  boot" marker
- a few UI prefs (notifications, card transparency / corners / outline)

Delete the file to start over; disable the plugin to stop entirely.

## Notes for reviewers

- **No network. No privileged calls.** The plugin runs `omarchy theme set`,
  `omarchy-shell`, `omarchy-notification-send`, `cat` on two fixed paths, and
  its own two helper scripts in `bin/`. There is no `curl`, no package
  management, no elevation of any kind.
- **Theme slugs are validated** in `ThemeDeck.js` (`^[a-z0-9][a-z0-9._-]*$`, no
  `/`, no `..`, length-capped) before they are ever passed to
  `omarchy theme set`, on top of that command's own checks.
- **The state file is read defensively.** It sits under `~/.local/state`, so
  `OmaShuffle.qml`'s `stateReaderScript` opens the path exactly once with
  `O_NOFOLLOW | O_NONBLOCK`, `fstat`s that same descriptor to require a regular
  file, and reads at most `limit + 1` bytes — the amount read is bounded by the
  read call itself, not by anything the path claims. Writes go through
  `FileView` with `atomicWrites`. (Same approach the marketplace review settled
  on for `io.github.comapilot`.)
- **`bin/omashuffle-scan-themes`** only reads `colors.toml` files from the two
  standard theme directories and extracts hex values. It never executes
  anything a theme ships.
- **`bin/omashuffle-menu-entry`** adds or removes a single row in
  `~/.config/omarchy/extensions/omarchy-menu.jsonc` (backed up next to it as
  `omarchy-menu.jsonc.omashuffle.bak` before each edit, and rewritten in place
  so the file keeps its permissions). It only ever reclaims a row it owns —
  same pattern as the `taxin.cursor-style` plugin.
- **`python3`** is the only non-Omarchy dependency, used solely for the state
  reader above.

## Not included (by design)

- No theme creation or editing — OmaShuffle only rotates themes that already
  exist. Use `omarchy theme` or a theme-designer plugin for that.
- No schedule other than "once per real boot" — no hourly or daily rotation, no
  time-of-day themes.
- No wallpaper-only shuffle — it switches whole themes via `omarchy theme set`.
- No background blur behind the picker card (transparency / corners / outline
  only, for now).

## Remove

```bash
omarchy plugin remove io.github.omashuffle
omarchy restart shell
```

Your last theme stays applied. The menu row removes itself. Delete
`~/.local/state/omarchy/io.github.omashuffle/` if you want the rotation and
history gone too.

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.omashuffle
bash -n bin/omashuffle-menu-entry bin/omashuffle-scan-themes
omarchy restart shell   # plugin QML is cached by URL; edits need a restart
```

Deck logic (`ThemeDeck.js`) is pure and has no QML or I/O dependencies, so it's
the easy place to reason about shuffling, the no-immediate-repeat rule, and slug
validation.

## License

MIT — see [LICENSE](LICENSE).
