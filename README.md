# Instant Snippets

Type a short trigger in any app and it is replaced with the text you saved for
it. `!em` becomes your email address, `!addr` your postal address, instantly
and wherever the cursor is.

![The list of snippets](preview.png)

It is an Omarchy shell plugin and nothing else: no daemon and no extra
package. Hyprland passes each key press to a small script the plugin loads
into Hyprland itself; no other program reads your keyboard.

## Install

```
omarchy plugin add https://github.com/MaNi4/omarchy-instant-snippets.git --enable
```

Open the panel from the bar, press **New**, enter a trigger and its
replacement, and save.

## Remove

```
omarchy plugin remove mani4.instant-snippets
```

Disabling or removing the plugin removes its hook from Hyprland as it is
unloaded. Your snippets stay in `~/.config/omarchy/extensions/instant-snippets.json`,
or in the folder you chose in the settings; delete that file if you do not
want to keep them.

## Features

- **Snippets**: a trigger of 2 to 32 characters and a replacement of up to
  1000 characters, on as many lines as it needs.
- **Search**: the field above the list searches triggers and replacements.
- **Case-sensitive triggers**: `!em` and `!EM` are different triggers, whether
  the capitals come from Shift or Caps Lock.
- **Undo**: Backspace as the first key within three seconds of an expansion
  removes the inserted text and restores the trigger. Can be turned off.
- **Line breaks with Shift+Enter**: on by default, so a multi-line snippet is
  not sent line by line in chat apps. Turn it off for multi-line shell
  commands, where a line break has to be Enter.
- **Excluded apps**: snippets never expand in the apps you exclude, and keys
  typed in them are ignored. Pick them from the running apps in the settings.
- **Placeholders**: `{date}` and `{time}` in a replacement are filled in when
  it is inserted, in the format chosen in the settings, and `{cursor}` marks
  where the cursor is left. A placeholder can also have a custom format, so
  that each snippet writes the date its way: `{date:yyMMdd}`,
  `{date:MM/dd/yyyy}`, `{time:HH:mm:ss}`. See
  [Date and time formats](#date-and-time-formats).
- **Word-start only**: on by default, a trigger expands only at the start of
  a word (after a space, Enter or Tab, or when you start typing), never in the
  middle of one. After you move the cursor or delete text, where it is no
  longer known what comes before, a trigger that begins with punctuation
  (`!em`) still expands and one that is itself a word (`adr`) waits for a
  space. Can be turned off.
- **Layouts**: triggers work on every keyboard layout that can type them, and
  follow layout switches. Digits and `+ - * / .` also count from the number pad.
- **Colored bar icon**: the bar icon takes the accent color while snippets
  expand. Can be turned off; the icon then keeps the bar's own color and is
  faded while snippets do not expand: when expansion is disabled, when there
  are no snippets, or when something went wrong.

## Date and time formats

`{date}` and `{time}` use the formats chosen in the settings. For a custom
format, write it after a colon: `{date:yyMMdd}`. The letters below are
replaced by a part of the date or time; the examples are for Friday,
6 March 2026, at 9:05:07 in the morning.

| Letters | Gives | Meaning | Espanso |
|---|---|---|---|
| `d` | `6` | day | `%-d` |
| `dd` | `06` | day, two digits | `%d` |
| `ddd` | `Fri` | day of the week, short | `%a` |
| `dddd` | `Friday` | day of the week | `%A` |
| `M` | `3` | month | `%-m` |
| `MM` | `03` | month, two digits | `%m` |
| `MMM` | `Mar` | month name, short | `%b` |
| `MMMM` | `March` | month name | `%B` |
| `yy` | `26` | year, two digits | `%y` |
| `yyyy` | `2026` | year | `%Y` |
| `H` | `9` | hour, 0 to 23 | `%-H` |
| `HH` | `09` | hour, 0 to 23, two digits | `%H` |
| `h` … `AP` | `9` … `AM` | hour, 1 to 12, with AM or PM (`ap` for `am`) | `%-I` … `%p` |
| `mm` | `05` | minutes | `%M` |
| `ss` | `07` | seconds | `%S` |

Both kinds of letters work in either placeholder: `{date:yyMMdd HH:mm}`
gives `260306 09:05`. Anything else, such as `.`, `/`, `-`, `:` or a space,
is typed as it is.

**Words go in single quotes.** Letters in a word would be replaced too:
`{date:dňa d.M.yyyy}` gives `6ňam 6.3.2026`, because `d` is the day and `a`
is "am". In quotes they are typed as they are: `{date:'dňa' d.M.yyyy}` gives
`dňa 6.3.2026`, and `{date:d.M.yyyy 'at' H:mm}` gives `6.3.2026 at 9:05`.

**A wrong format breaks nothing**, but it types something you did not mean:
`{date:hello}` gives `9ello`, as `h` is the hour. Try a new snippet once
before you rely on it.

**Coming from Espanso**: Espanso's `%` formats, such as `%y%m%d`, do not work
here; `{date:%y%m%d}` types `%y%5%6` (`m` is the minutes, `d` the day).
Use the letters in the first column of the table above, next to Espanso's
codes in the last one. Common ones:

| Espanso `format:` | Here |
|---|---|
| `%y%m%d` | `{date:yyMMdd}` |
| `%m/%d/%Y` | `{date:MM/dd/yyyy}` |
| `%d.%m.%Y` | `{date:dd.MM.yyyy}` |
| `%Y-%m-%d` | `{date:yyyy-MM-dd}` |
| `%H:%M` | `{time:HH:mm}` |
| `%H:%M:%S` | `{time:HH:mm:ss}` |
| `%I:%M %p` | `{time:hh:mm AP}` |
| `%A, %B %-d` | `{date:dddd, MMMM d}` |

The full list of letters is in Qt's documentation, for
[dates](https://doc.qt.io/qt-6/qdate.html#toString) and
[times](https://doc.qt.io/qt-6/qtime.html#toString).

## Screenshots

| Snippets | Editor | Settings |
|---|---|---|
| ![The list of snippets with search](screenshots/list.png) | ![Editing a snippet](screenshots/editor.png) | ![Settings, data location and excluded apps](screenshots/settings.png) |

## How it works

Hyprland already sees every key, because it is what delivers them to your
apps. Its Lua configuration can subscribe to key events
(`input.keyboard.key`), and that is the only place this plugin looks at keys:

1. The shell service works out which keys spell each trigger on your current
   layout, by asking `xkbcli`, which ships with the libxkbcommon Hyprland uses.
2. It writes those keys, as numbers, to a private file and has Hyprland load
   `engine.lua` with them through `hyprctl eval`.
3. The engine remembers the last few keys and, when they spell a trigger,
   reports "trigger number 3".
4. The shell checks that the session is not locked, then the engine erases
   the trigger and types the replacement, key by key, straight to the window
   through Hyprland. A replacement with a character your layout has no key
   for is typed with `wtype` instead, which is part of Omarchy.

Nothing is added to your Hyprland configuration files. The engine is loaded at
run time, and again after Hyprland reloads its configuration or you switch
layout.

## Privacy

What the plugin does with your keys, plainly:

- **Hyprland hands every key press to the engine**, a Lua script running
  inside Hyprland. That is how a trigger is noticed. Nothing outside Hyprland
  reads the keyboard.
- **What the engine keeps**: the last keys typed, as key numbers, one more
  than your longest trigger has characters. It forgets them when the focus
  moves to another window, within about ten seconds of the last key, and
  when a shortcut is pressed. For the few seconds in which Backspace can
  undo an expansion it also keeps the keys that led to it, to put them back.
  While it types a replacement it holds that replacement's keys, until they
  are typed or the focus moves. It writes nothing to disk and logs nothing.
- **Where it does not listen at all**: in excluded apps, and while a launcher,
  menu or panel has the keyboard.
- **The lock screen**: Hyprland cannot tell the engine that the session is
  locked, so keys typed there pass through it like any others, are kept only
  as described above, and can at most produce "trigger N was typed". Before
  anything is typed, and again before each piece of a long replacement, the
  plugin asks Hyprland whether the session is locked, and types nothing if it
  is or if that cannot be told.
- **What leaves Hyprland**: "trigger N was typed", "undo" or "the focus
  moved", as an event any program of yours can see. It carries the trigger's
  number and nothing of the trigger itself, not even its length.
- **Process arguments** never contain a trigger, a replacement, or their
  lengths. The keys that spell your triggers, and the keys of a replacement
  about to be typed, go to Hyprland in files only you can read, under
  `$XDG_RUNTIME_DIR`, which is gone at logout; the engine removes a
  replacement's file as soon as it has read it. Excluded apps are in the
  plan as numbers. The shell starts the same two commands for a snippet of
  any length. One of them has the engine type the keys 24 at a time, with a
  fixed `hyprctl eval` each time; how many of those run, like how long the
  typing takes, follows the replacement's length. A replacement typed with
  `wtype` reaches it on its standard input; for it, `{cursor}` and line
  breaks typed as Shift+Enter are fixed commands, counted the same way.
- **What can show in a process list**: the keyboard layout, and which scripts
  your triggers and replacements use beyond plain ASCII (accented Latin,
  Cyrillic, ...): the whole block of characters is looked up, never the ones
  you chose.
- **Notifications** use fixed wording and never contain a trigger or
  replacement.
- With expansion disabled, or with no snippets, nothing is loaded into
  Hyprland.

## The snippets file

Snippets and settings are stored as plain text in
`~/.config/omarchy/extensions/instant-snippets.json`, readable by your user
only:

```json
{
  "enabled": true,
  "lineBreaksWithShiftEnter": true,
  "undoWithBackspace": true,
  "expandOnlyAtWordStart": true,
  "coloredIcon": true,
  "dateFormat": "yyyy-MM-dd",
  "timeFormat": "HH:mm",
  "excludedApps": ["org.keepassxc.KeePassXC"],
  "snippets": [
    { "trigger": "!em", "replacement": "me@example.com" }
  ]
}
```

### Backing it up, or sharing it between computers

**Data location** in the settings keeps the file somewhere else: type a
folder, such as `~/Sync/snippets`, and press Enter or Apply. The file is then
`instant-snippets.json` in that folder; a path ending in `.json` names the
file itself. Leave the field empty to go back to the usual place.

- If there is no snippets file at the new location, yours is moved there
  (an empty one is made if you have none yet).
- If there is one already, as on a second computer pointed at a synced
  folder, that one is used. The file you had stays where it was, untouched
  and no longer used.

On a second computer, wait for the folder to finish syncing before pointing
the plugin at it, so that the file found there is the one that is used.

If the file is later not where it is kept, because a disk is not mounted or a
sync has not finished, the panel says so and nothing is written until it is
back; it is looked for again every few seconds. A new list is never started
in its place: to start one, change the location.

If the snippets are changed on two computers before they have synced, the
sync tool keeps one version. With Syncthing the other is left beside the file
as `instant-snippets.sync-conflict-….json`; a snippet that has gone missing
is in there.

Anyone who can write to that folder can change what your triggers type, so
keep the file in a folder that is yours alone.

The location itself is kept in
`~/.config/omarchy/extensions/instant-snippets.location`, a single line, on
each computer. Changes that arrive in the file from elsewhere are picked up
as they come. The file holds the settings too, so those are shared with it.

The panel manages this file for you. Editing it by hand also works; changes
are picked up immediately, and the file is closed to other users whenever it
is read. If it contains an entry the plugin cannot use, the panel says so and
stops saving until the file is fixed, so that nothing in it is lost. Because
it is plain text, do not store passwords in it.

There can be up to 500 snippets.

## Limitations

- Start triggers with a character you rarely type before a letter, such as
  `!` or `;`. A trigger that is an ordinary word, or the beginning of one,
  expands as soon as it is typed at the start of a word: `adr` would expand
  in "adrenaline".
- Straight after an expansion the next trigger needs a space before it, as
  anywhere else in the middle of text.
- Backspace removes the last key from what the engine has seen, so a corrected
  typo still matches. Moving the cursor with the mouse is not seen.
- A trigger can only use characters your layout types with one key press, with
  or without Shift or AltGr. Characters that need a dead key or Compose cannot
  be part of a trigger. The panel marks triggers the current layout cannot type.
- A replacement can contain any printable characters, line breaks and tabs,
  whatever your layout.
- Replacements are typed, not pasted, so the clipboard is left alone. The
  engine types them through Hyprland, with the keys of your keyboard's first
  layout, whichever layout is in use: Hyprland sends its keys that way. A few
  hundred characters take a fraction of a second.
- A replacement with a character the first layout has no key for (an emoji,
  or "á" when the first layout is US) is typed with `wtype`, as text, which
  takes a second or two for a few hundred characters, and half a second more for each line break typed as
  Shift+Enter and for moving the cursor to `{cursor}`. An input method such
  as fcitx5 can hold a key's release back until the window repeats the key,
  so while a replacement is typed the engine sends the window each key's
  release itself, through Hyprland, a moment after the press; that goes for
  the Backspaces that erase the trigger too. A key you hold down while a
  replacement is typed does not repeat until you press it again.
- Keys pressed while a replacement is typed are ignored by the engine, and if
  the focus moves to another window the rest is not typed.
- When a replacement has been typed, Ctrl is pressed and let go once by
  `wtype`. Hyprland leaves the window believing the first layout is in use
  and Caps Lock is off; that has it set right before your next key.
- A trigger that ends on a shifted character expands when Shift is released.
- An expansion that uses `{cursor}` cannot be undone with Backspace, nor can
  one with a tab in it, or with line breaks while Shift+Enter is turned off.
- Undo is withdrawn if you press a key or switch windows while the
  replacement is still being typed.
- Pasting into the panel reads no more of the clipboard than a replacement can
  hold.

## Opening the panel with a key

The panel has no shortcut of its own. This command toggles it, and can be
bound to any key in your Hyprland configuration:

```
omarchy-shell mani4.instant-snippets toggle
```

## Requirements

Omarchy with the Quickshell-based shell, and a Hyprland whose Lua
configuration has the `input.keyboard.key` event (0.56 has it).

It uses `wtype`, `wl-paste`, `xkbcli` and `notify-send`, all of which Omarchy
installs. There is nothing to set up.

## Tests

```
lua tests/engine.lua
node tests/run.js
```

The first drives the engine with a stand-in for Hyprland; the second checks
how triggers are turned into keys and that the Lua the shell writes starts the
engine. They need `lua` and `node`, and touch nothing outside a temporary
directory.

## License

MIT
