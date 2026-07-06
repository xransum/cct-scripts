# AE2 Material Usage Monitor (CC:Tweaked)

A live dashboard for an Applied Energistics 2 network, built on CC:Tweaked
computers and monitors. It shows a top movers view across every item in
your ME network, a curated priority watchlist, an automatic depletion
alarm with a speaker, and it all persists across restarts and power
outages.

This project has no hard dependency on a specific modpack version. It
only depends on:

- CC:Tweaked (any recent version with the `monitor_touch` event and
  `textutils.serialize` / `unserialize`)
- An AE2-compatible ME Bridge peripheral exposing `getItem`, and one of
  `listItems`, `getItems`, or `items` for a full network scan
- An Advanced Computer and Advanced Monitor (touch events require the
  advanced/gold tier, not the basic gray monitor)
- A Speaker peripheral (optional, only needed for the depletion alarm
  sound)

If your pack's AE2 fork names its bridge peripheral or methods
differently, see "Peripheral method names" below before opening an
issue, it is almost always a one line fix.

## Files

| File                          | Purpose                                                         |
| ----------------------------- | --------------------------------------------------------------- |
| `material_usage_monitor.lua`  | The main script. Run this on the computer with the monitor.     |
| `usage_config.lua`            | CLI tool to edit the watchlist and auto-scan settings.          |
| `usage_watchlist.cfg`         | Generated on first run. Your curated priority items.            |
| `autoscan.cfg`                | Generated on first run. Depletion alarm and scan settings.      |
| `usage_state.cfg`             | Generated automatically. Tracked counts, timestamps, last view. |

The three `.cfg` files are generated automatically the first time
`material_usage_monitor.lua` runs. You do not need to create them by
hand, and you should not commit your live copies to the repo -- they are
per-server runtime state, not source.

## Installation

1. Copy `material_usage_monitor.lua` and `usage_config.lua` onto the
   target computer, in the same directory. The easiest way is via the
   repo's `deploy.sh` script (see root of repo).
2. Run `material_usage_monitor.lua` once. It will create the three
   config files with sane defaults on first launch.
3. To run it in the background instead of taking over the terminal
   (recommended so you can still use `usage_config` interactively), use
   the built-in multishell background launcher:

   ```
   bg material_usage_monitor
   ```

   This only works on an Advanced Computer, where multishell is active
   by default. Background scripts keep running and keep responding to
   monitor touch events even while another tab has focus.

## Using usage_config.lua

```
usage_config list
usage_config add                        (guided, validated prompts)
usage_config add item_id label threshold priority
usage_config remove item_id
usage_config priority item_id new_priority
usage_config threshold item_id new_threshold
usage_config autoscan on
usage_config autoscan off
usage_config autoscan minqty 1000
usage_config autoscan percent 15
usage_config autoscan interval 30
usage_config autoscan topn 8            (optional cap, default fills the screen)
usage_config reset
```

## How it works

The script runs three loops in parallel:

- **pollLoop**: cycles through your curated watchlist, one item queried
  per tick, spread across a configurable window so it never bursts many
  calls at once.
- **autoScanLoop**: does one bulk network scan every `scanInterval`
  seconds. This single call powers both the top movers view and the
  depletion alarm, so tracking everything costs the same one call as
  tracking nothing.
- **touchLoop**: listens for monitor taps, handles the add/watch/help
  buttons, pagination, and alert dismissal.

State (last known counts, timestamps, and which view was open) is saved
to `usage_state.cfg` periodically, not on every single poll, and
reloaded on startup, so a restart or power outage does not reset your
tracked rates to zero.

## Peripheral method names

Different AE2 forks and versions name the ME Bridge's methods slightly
differently. Before assuming something is broken, check what your
version actually exposes:

```lua
peripheral.getNames()
```

to confirm the bridge is attached at all, then inspect its methods
directly if `getItem` or the bulk list methods are not being found. The
script already tries a few common alternates (`listItems`, `getItems`,
`items`) and fails silently to an empty scan if none match, so a version
mismatch here will not crash the script, it will just show no data on
the top movers view or alarm.

## Lua version note

CC:Tweaked runs on a Lua 5.1/5.2 base. Do not use the `//` floor
division operator anywhere in this codebase, it is Lua 5.3+ only and
will throw a syntax error. Use `math.floor(a / b)` instead.