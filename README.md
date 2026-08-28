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
then the bag reshuffles and the theme you're currently wearing is pushed to the
back so you don't see it twice in a row.

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

## Requirements

- **Omarchy 4** with its Quickshell-based shell
- **`python3`** — the only dependency beyond Omarchy itself. Used once at startup
  to read this plugin's own small state file safely (see *Notes for reviewers*).
  It's present on a normal Omarchy install.

No network access. No elevated privileges. No package management.

## Install

```bash
omarchy plugin add https://github.com/Deunnis/OmaShuffle.git --enable
omarchy restart shell
```

That's it — it starts working from the next boot. Until you pick at least one
theme it does nothing but show a one-line reminder on boot.

## Opening the picker

Three ways, pick whichever you like:

**1. A keybind** (fastest). Add one to `~/.config/hypr/bindings.lua`, on any
combo that's free for you:

```lua
o.bind("SUPER + SHIFT + S", "Theme shuffle", "omarchy-shell shell toggle io.github.omashuffle")
```

**2. The Omarchy menu** (Super + Space). Open the picker once via the keybind or
`omarchy-shell shell toggle io.github.omashuffle`, go to the gear → **Omarchy
menu → Add menu entry**. That adds a **Style → Theme Shuffle** row. You can
remove it again from the same place. If you'd rather add it by hand, drop this
into `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"style.omashuffle": {"icon":"󰔎","label":"Theme Shuffle","aliases":["shuffle"],"action":"omarchy-shell shell toggle io.github.omashuffle"},
```

**3. IPC**, for scripts: `omarchy-shell shell toggle io.github.omashuffle`

## Using the picker

<img src="screenshots/settings.png" alt="The OmaShuffle settings pane: boot-shuffle and notification toggles, transparency / corner / outline sliders, and Add / Remove menu entry buttons" width="640">

| Action | What it does |
|---|---|
| **Click** a theme (or **Enter**) | apply it right now |
| **Right-click** a theme (or **Space**) | add / remove it from the rotation |
| Arrow keys | move the highlight |
| **Shuffle now** | jump straight to the next deck theme |
| **Reshuffle deck** | throw out the current order and draw a fresh shuffle |
| **Select all / none** | bulk-edit the rotation |
| **Boot shuffle: on / off** | the master switch for the once-per-boot behaviour |
| **Filter themes…** | narrow the grid by name |
| gear icon | notifications, card transparency / corners / outline, menu entry |
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
  its own two helper scripts in `bin/`. It makes no network requests, needs no
  elevated privileges, manages no packages or services, and installs nothing.
- **Theme slugs are validated** in `ThemeDeck.js` (`^[a-z0-9][a-z0-9._-]*$`, no
  `/`, no `..`, length-capped) before they are ever passed to
  `omarchy theme set`, on top of that command's own checks.
- **The state file is read defensively.** It sits under `~/.local/state`, so
  `OmaShuffle.qml`'s `stateReaderScript` opens the path exactly once with
  `O_NOFOLLOW | O_NONBLOCK`, `fstat`s that same descriptor to require a regular
  file, and reads at most `limit + 1` bytes — the amount read is bounded by the
  read call itself, not by anything the path claims. Writes go through
  `FileView` with `atomicWrites`.
- **`bin/omashuffle-scan-themes`** only reads `colors.toml` files from the two
  standard theme directories and extracts hex values. It never executes
  anything a theme ships.
- **`bin/omashuffle-menu-entry`** is only ever run when you press *Add menu
  entry* / *Remove menu entry* in the settings pane. It adds or removes one row
  in `~/.config/omarchy/extensions/omarchy-menu.jsonc` (backed up next to it as
  `omarchy-menu.jsonc.omashuffle.bak`, rewritten in place so permissions are
  kept), only ever touches a row it owns, and bails without writing if the file
  layout is unfamiliar. The plugin never edits that file on its own.
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

Your last theme stays applied. If you added the menu row, remove it first from
the settings pane, or delete the `style.omashuffle` line from
`~/.config/omarchy/extensions/omarchy-menu.jsonc`. Delete
`~/.local/state/omarchy/io.github.omashuffle/` to clear the rotation and history.

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.omashuffle
bash -n bin/omashuffle-menu-entry bin/omashuffle-scan-themes
node --check <(tail -n +2 ThemeDeck.js)   # strip the .pragma line
omarchy restart shell                     # plugin QML is cached by URL
```

`ThemeDeck.js` is pure logic with no QML or I/O dependencies — the easy place to
reason about shuffling, the no-immediate-repeat rule, and slug validation.

## License

MIT — see [LICENSE](LICENSE).
