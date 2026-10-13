.pragma library

// Which keys spell a trigger, and the Lua that starts engine.lua with them.
// Pure: `hyprctl devices -j` and `xkbcli how-to-type` output in, answers out,
// so it runs under node in tests/run.js.
//
// Hyprland reports keys as keycodes, so a trigger has to be turned into the
// keycodes that type it on the layout in use. xkbcli, which comes with the
// libxkbcommon Hyprland itself uses, answers that for one character at a
// time; the answers are kept per layout in Service.qml.

var SHIFT = 1
var LEVEL3 = 2
var SHORTCUT = 4

var MAX_TRIGGER = 32
var MAX_TEXT = 1000
var MAX_SNIPPETS = 500

// Keys that are not text, asked of xkbcli by name.
var MODIFIERS = {
  Shift_L: SHIFT, Shift_R: SHIFT,
  ISO_Level3_Shift: LEVEL3,
  Control_L: SHORTCUT, Control_R: SHORTCUT, Alt_L: SHORTCUT, Alt_R: SHORTCUT,
  Meta_L: SHORTCUT, Meta_R: SHORTCUT, Super_L: SHORTCUT, Super_R: SHORTCUT,
  Hyper_L: SHORTCUT, Hyper_R: SHORTCUT,
  // Keys that type nothing and change nothing the engine follows: they are
  // passed over, where an unknown key would count as one typed.
  Caps_Lock: 0, Num_Lock: 0, Scroll_Lock: 0
}
// Keys that end a word, for triggers that expand only at the start of one.
var SEPARATORS = ["space", "Return", "KP_Enter", "Tab"]
// Keys that move the cursor or delete what is after it: once one is pressed
// it is no longer known what is in front of the cursor.
var MOVING = ["Left", "Right", "Up", "Down", "Home", "End", "Prior", "Next", "Delete",
  "KP_Left", "KP_Right", "KP_Up", "KP_Down", "KP_Home", "KP_End", "KP_Prior", "KP_Next", "KP_Delete"]
var NAMED = Object.keys(MODIFIERS).concat(["BackSpace", "Multi_key"]).concat(SEPARATORS).concat(MOVING)

// Characters the number pad types too, by the name of its key.
var KEYPAD = {
  "0": "KP_0", "1": "KP_1", "2": "KP_2", "3": "KP_3", "4": "KP_4", "5": "KP_5", "6": "KP_6", "7": "KP_7",
  "8": "KP_8", "9": "KP_9", ".": "KP_Decimal", "+": "KP_Add", "-": "KP_Subtract", "*": "KP_Multiply", "/": "KP_Divide"
}

// Whether a keyboard is one a program made for itself: wtype's while it
// types, an input method's for handing keys on.
function isVirtual(keyboard) {
  return String(keyboard.name || "").indexOf("hl-virtual-keyboard-") === 0
}

// The keyboard to go by for the layout. Hyprland marks the one used last as
// "main", but that is often a virtual one: an input method's, or wtype's for
// the moment it types, whose layout says nothing about what the user types
// on. So the real keyboards are asked, and the layout most of them are on is
// taken (they are switched together), from the main one if it is among them.
function typingKeyboard(keyboards, switched) {
  var real = keyboards.filter(function(keyboard) { return !isVirtual(keyboard) })
  if (real.length === 0) real = keyboards
  if (real.length === 0) return null
  // The main one, if it is real, is the one being typed on. Otherwise the
  // one that last reported a layout change, whose layout may be the only
  // one that was changed.
  for (var m = 0; m < real.length; m++) if (real[m].main && !isVirtual(real[m])) return real[m]
  for (var s = 0; s < real.length; s++) if (switched && real[s].name === switched) return real[s]
  var votes = {}
  var most = 0
  var mainIndex = -1
  for (var i = 0; i < real.length; i++) {
    var index = Number(real[i].active_layout_index) || 0
    votes[index] = (votes[index] || 0) + 1
    most = Math.max(most, votes[index])
    if (real[i].main) mainIndex = index
  }
  // When as many are on one layout as on another, the main one's counts.
  var chosen = -1
  if (mainIndex >= 0 && votes[mainIndex] === most) chosen = mainIndex
  else for (var index2 in votes) if (votes[index2] === most && chosen < 0) chosen = Number(index2)
  var first = null
  for (var j = 0; j < real.length; j++) {
    if ((Number(real[j].active_layout_index) || 0) !== chosen) continue
    if (real[j].main) return real[j]
    if (!first) first = real[j]
  }
  return first
}

// The layout the user types on, out of `hyprctl devices -j`.
//   { layout: "sk", variant: "qwerty", options: "...", name: "Slovak (QWERTY)", id: "..." }
// null when there is no keyboard to go by.
function activeLayout(devicesJson, switched) {
  var keyboards = []
  try { keyboards = JSON.parse(devicesJson).keyboards || [] } catch (e) { return null }
  var keyboard = typingKeyboard(keyboards, switched)
  if (!keyboard) return null

  var index = Number(keyboard.active_layout_index) || 0
  var layouts = String(keyboard.layout || "us").split(",")
  var variants = String(keyboard.variant || "").split(",")
  var active = {
    rules: String(keyboard.rules || ""),
    model: String(keyboard.model || ""),
    layout: (layouts[index] || layouts[0] || "us").trim(),
    variant: (variants[index] || "").trim(),
    options: String(keyboard.options || ""),
    name: String(keyboard.active_keymap || "")
  }
  active.id = [active.rules, active.model, active.layout, active.variant, active.options].join("|")
  return active
}

// "!em" -> ["!", "e", "m"], by character rather than UTF-16 unit.
function characters(text) {
  return Array.from(String(text || ""))
}

// What to ask xkbcli for a character: its code point, so that "1" and "-"
// are not read as a number or an option.
function codePoint(character) {
  var hex = character.codePointAt(0).toString(16).toUpperCase()
  return "U+" + ("0000" + hex).slice(-Math.max(4, hex.length))
}

// The command that asks xkbcli every question in one go: one process, since
// a process for each takes a shell minutes to get through. Nothing of the
// user's is in it but the layout; what is asked is a fixed set of characters
// (see questions()). The answers come out in the order asked, a record
// separator after each.
var ASKING = 'r=$1; m=$2; l=$3; v=$4; o=$5; shift 5\n'
  + 'ask() { xkbcli how-to-type --disable-compose ${r:+--rules "$r"} ${m:+--model "$m"} --layout "$l" '
  + '${v:+--variant "$v"} ${o:+--options "$o"} "$@" 2>/dev/null; }\n'
  + 'for q in "$@"; do\n'
  + '  case $q in k:*) ask --keysym "${q#k:}" ;; c:*) ask "${q#c:}" ;; esac\n'
  + "  printf '\\036\\n'\n"
  + 'done'

// How many questions go in one run: a few thousand, as triggers in several
// scripts make, would take one run past any sensible time limit.
var ASK_AT_ONCE = 400

function asking(layout, list) {
  var command = ["sh", "-c", ASKING, "sh", layout.rules, layout.model, layout.layout, layout.variant, layout.options]
  for (var i = 0; i < list.length; i++) command.push(list[i].named ? "k:" + list[i].what : "c:" + codePoint(list[i].what))
  return command
}

// What asking() printed, as { "char:!": ways, "name:Shift_L": ways }. Null
// when it is not an answer to every question: xkbcli is missing or failed.
function parseAnswers(text, list) {
  var records = String(text || "").split("\u001e\n")
  if (records.length < list.length + 1) return null
  var answers = {}
  for (var i = 0; i < list.length; i++) answers[slot(list[i].what, list[i].named)] = parseAnswer(records[i])
  return answers
}

// xkbcli's table of ways to type something:
//   KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS
//   10       AE01      1        English (US)         2       [ Shift ]
// -> [{ keycode: 10, modifiers: ["Shift"] }]
function parseAnswer(text) {
  var ways = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = /^(\d+)\s+\S+\s+\d+\s+.*\s+\d+\s+\[([^\]]*)\]\s*$/.exec(lines[i])
    if (!match) continue
    var modifiers = match[2].trim()
    ways.push({ keycode: Number(match[1]), modifiers: modifiers ? modifiers.split(/\s+/) : [] })
  }
  return ways
}

function needsLock(way) {
  return way.modifiers.indexOf("Lock") >= 0
}

// The number engine.lua knows a key press by, or -1 for a way of typing it
// cannot follow. Caps Lock is not part of the number: which spelling counts
// is settled when the trigger has been typed.
function keyOf(way) {
  var bits = 0
  for (var i = 0; i < way.modifiers.length; i++) {
    var modifier = way.modifiers[i]
    if (modifier === "Shift") bits |= SHIFT
    else if (modifier === "LevelThree") bits |= LEVEL3
    else if (modifier !== "Mod5" && modifier !== "Lock") return -1
  }
  return way.keycode * 4 + bits
}

function sorted(keys) {
  return keys.sort(function(a, b) { return a - b })
}

function push(keys, key) {
  if (key >= 0 && keys.indexOf(key) < 0) keys.push(key)
}

// The keys that type a character with Caps Lock off.
function keysOf(ways) {
  var keys = []
  for (var i = 0; i < ways.length; i++) if (!needsLock(ways[i])) push(keys, keyOf(ways[i]))
  return sorted(keys)
}

// "e" -> "E", "E" -> "e", "" for a character without another case.
function otherCase(character) {
  var lower = character.toLowerCase()
  var upper = character.toUpperCase()
  if (lower === upper) return ""
  var other = character === lower ? upper : lower
  return characters(other).length === 1 ? other : ""
}

// The keys that type a character with Caps Lock on, given the ways to type
// it and the ways to type its other case.
//
// xkbcli lists the ways that name Caps Lock only where the layout spells
// them out, so the rest follows from what Caps Lock does: on a key it acts
// on, it swaps what Shift gives. It acts on a key when either case of the
// character is listed there with Caps Lock. On any other key ("1", "!", the
// Slovak "ľ") it changes nothing.
function lockedKeysOf(ways, otherWays) {
  var acts = {}
  var all = ways.concat(otherWays)
  for (var i = 0; i < all.length; i++) if (needsLock(all[i])) acts[all[i].keycode] = true

  // With AltGr a key is on its third and fourth levels, which Caps Lock
  // leaves as they are unless the layout says otherwise by naming it.
  function swapped(way) {
    return acts[way.keycode] && way.modifiers.indexOf("LevelThree") < 0
  }

  var keys = []
  for (var j = 0; j < ways.length; j++) {
    if (needsLock(ways[j]) || !swapped(ways[j])) push(keys, keyOf(ways[j]))
  }
  for (var k = 0; k < otherWays.length; k++) {
    if (!needsLock(otherWays[k]) && swapped(otherWays[k])) push(keys, keyOf(otherWays[k]))
  }
  return sorted(keys)
}

// Whether Caps Lock is on, out of `hyprctl devices -j`: on any keyboard, since
// the one it was pressed on and the one Hyprland calls main need not be the same.
function capsLock(devicesJson) {
  var keyboards = []
  try { keyboards = JSON.parse(devicesJson).keyboards || [] } catch (e) { return false }
  for (var i = 0; i < keyboards.length; i++) if (keyboards[i].capsLock === true) return true
  return false
}

// The number pad's keys for a character, out of the ways to press the key of
// that name. Num Lock is taken to be on, as it is unless someone turns it
// off; with it off the pad types no digits at all.
function keypadKeys(ways) {
  var keys = []
  for (var i = 0; i < ways.length; i++) {
    var plain = ways[i].modifiers.every(function(modifier) { return modifier === "Mod2" || modifier === "NumLock" })
    if (plain && keys.indexOf(ways[i].keycode * 4) < 0) keys.push(ways[i].keycode * 4)
  }
  return keys
}

// The characters every plan asks xkbcli about, whatever the triggers are.
// What is asked shows in xkbcli's arguments, and so to anything that lists
// processes; asking only for the characters of the triggers would spell them
// out there. So the whole of ASCII is always asked, and the whole of the
// accented Latin letters as soon as any trigger uses one: what shows is at
// most "a trigger has an accented letter". A character outside both
// (Cyrillic, say) brings in its whole block of 256 the same way.
function range(from, to) {
  var list = []
  for (var point = from; point <= to; point++) list.push(String.fromCodePoint(point))
  return list
}
var ASCII = range(0x20, 0x7e)
var LATIN = range(0xa1, 0xff).concat(range(0x100, 0x17f))

function isLatin(character) {
  var point = character.codePointAt(0)
  return point >= 0xa1 && point <= 0x17f
}

// Every question a plan needs answered: the named keys and the number pad's,
// ASCII, the accented Latin letters when a trigger has one, then the block
// around any other character of a trigger or its other case.
//   [{ what: "Shift_L", named: true }, { what: " ", named: false }, ...]
function questions(snippets) {
  var names = NAMED.slice()
  for (var character in KEYPAD) if (names.indexOf(KEYPAD[character]) < 0) names.push(KEYPAD[character])
  var list = names.map(function(name) { return { what: name, named: true } })

  var latin = false
  var others = {}
  for (var i = 0; i < snippets.length; i++) {
    var letters = characters(snippets[i].trigger)
    for (var j = 0; j < letters.length; j++) {
      var both = [letters[j], otherCase(letters[j])]
      for (var k = 0; k < both.length; k++) {
        if (both[k] === "" || both[k].codePointAt(0) <= 0x7e) continue
        if (isLatin(both[k])) latin = true
        else others[both[k].codePointAt(0) >> 8] = true
      }
    }
  }
  // A character of another script brings in the 256 code points around it,
  // so that it is its script that shows, not the character.
  var asked = ASCII.concat(latin ? LATIN : [])
  Object.keys(others).map(Number).sort(function(a, b) { return a - b }).forEach(function(block) {
    for (var point = block * 256; point < block * 256 + 256; point++) {
      if (point >= 0xd800 && point <= 0xdfff) continue
      if (point <= 0x17f) continue
      asked.push(String.fromCodePoint(point))
    }
  })
  for (var n = 0; n < asked.length; n++) list.push({ what: asked[n], named: false })
  return list
}

// Where an answer is kept: named keys and characters must not collide ("1").
function slot(what, named) {
  return (named ? "name:" : "char:") + what
}

// A replacement without the control characters that would be typed as keys
// (a backspace would rub out, an escape would close things). Line breaks and
// tabs stay.
function clean(text) {
  return String(text || "").replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "")
}

// Why a snippet cannot be saved, "" when it can. `at` is the index of the
// snippet being edited, -1 for a new one.
function problem(snippets, trigger, text, at) {
  if (at < 0 && snippets.length >= MAX_SNIPPETS) return "There can be at most " + MAX_SNIPPETS + " snippets."
  var letters = characters(trigger)
  if (letters.length < 2) return "A trigger needs at least two characters."
  if (letters.length > MAX_TRIGGER) return "A trigger can be at most " + MAX_TRIGGER + " characters."
  if (/[\u0000-\u001f\u007f]/.test(trigger)) return "A trigger cannot contain line breaks or tabs."
  if (String(text || "") === "") return "The replacement is empty."
  if (clean(text) !== text) return "The replacement contains control characters."
  if (characters(text).length > MAX_TEXT) return "A replacement can be at most " + MAX_TEXT + " characters."
  for (var i = 0; i < snippets.length; i++) {
    if (i !== at && snippets[i].trigger === trigger) return "The trigger \"" + trigger + "\" is already in use."
  }
  return ""
}

// The snippets out of the config file's text. Anything that is not a usable
// snippet is dropped, so a hand-edited file cannot feed the rest odd values.
//   { enabled: true, shiftEnter: true, undo: true, skipped: [], snippets: [{ trigger: "!em", replacement: "me@example.com" }], error: "" }
// The file's own names for these are longer: see formatConfig().
function parseConfig(text) {
  var result = { enabled: true, shiftEnter: true, undo: true, wordStart: true, dateFormat: DATE_FORMATS[0],
    timeFormat: TIME_FORMATS[0], skipped: [], snippets: [], dropped: 0, error: "" }
  if (String(text || "").trim() === "") return result
  var config
  try { config = JSON.parse(text) } catch (e) {
    result.error = String(e.message || e)
    return result
  }
  if (!config || typeof config !== "object") return result
  if (config.enabled === false) result.enabled = false
  if (config.lineBreaksWithShiftEnter === false) result.shiftEnter = false
  if (config.undoWithBackspace === false) result.undo = false
  if (config.expandOnlyAtWordStart === false) result.wordStart = false
  result.dateFormat = format(DATE_FORMATS, config.dateFormat)
  result.timeFormat = format(TIME_FORMATS, config.timeFormat)
  var apps = Array.isArray(config.excludedApps) ? config.excludedApps : []
  for (var a = 0; a < apps.length && result.skipped.length < MAX_SKIPPED; a++) {
    if (appName(apps[a]) && result.skipped.indexOf(apps[a]) < 0) result.skipped.push(apps[a])
  }
  // What is not a usable snippet is counted: a file with any is not written
  // back, which would lose them.
  var list = Array.isArray(config.snippets) ? config.snippets : []
  for (var i = 0; i < list.length; i++) {
    var snippet = list[i]
    var usable = snippet && typeof snippet.trigger === "string" && typeof snippet.replacement === "string"
      && problem(result.snippets, snippet.trigger, snippet.replacement, -1) === ""
    if (usable) result.snippets.push({ trigger: snippet.trigger, replacement: snippet.replacement })
    else result.dropped++
  }
  return result
}

// `config` as parseConfig() gives it; the error is not written.
function formatConfig(config) {
  return JSON.stringify({
    enabled: config.enabled, lineBreaksWithShiftEnter: config.shiftEnter, undoWithBackspace: config.undo,
    expandOnlyAtWordStart: config.wordStart, dateFormat: config.dateFormat, timeFormat: config.timeFormat,
    excludedApps: config.skipped, snippets: config.snippets
  }, null, 2) + "\n"
}

// ---------- Apps left alone ----------
// Windows are told apart by their class ("com.mitchellh.ghostty"). The engine
// is to stop listening in the ones the user names, and it is given only
// numbers, so each class goes to it as a number worked out the same way on
// both sides: here and in engine.lua's class_key().

var MAX_SKIPPED = 100

// Whether this can be a window's class at all.
function appName(name) {
  return typeof name === "string" && name.length > 0 && name.length <= 200 && !/[\u0000-\u001f\u007f]/.test(name)
}

function utf8(text) {
  var out = []
  var letters = characters(text)
  for (var i = 0; i < letters.length; i++) {
    var point = letters[i].codePointAt(0)
    if (point < 0x80) out.push(point)
    else if (point < 0x800) out.push(0xc0 | (point >> 6), 0x80 | (point & 0x3f))
    else if (point < 0x10000) out.push(0xe0 | (point >> 12), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f))
    else out.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f))
  }
  return out
}

function classKey(name) {
  var key = 5381
  var data = utf8(name)
  for (var i = 0; i < data.length; i++) key = (key * 33 + data[i]) % 2147483647
  return key
}

// `skipped` with `name` put in or taken out.
function skipping(skipped, name, skip) {
  var next = skipped.filter(function(other) { return other !== name })
  if (skip && appName(name) && next.length < MAX_SKIPPED) next.push(name)
  return next
}

// ---------- Colours that can be read ----------
// The theme gives a foreground, a background and an accent, and nothing says
// the accent, or a dimmed foreground, is readable on that background. These
// hold text to WCAG AA: a contrast of 4.5 to 1. Colours are { r, g, b } with
// parts from 0 to 1, which is what a QML colour looks like from here.

var READABLE = 4.5

function luminance(color) {
  function linear(part) {
    return part <= 0.04045 ? part / 12.92 : Math.pow((part + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
}

// 1 for the same colour, 21 for black on white.
function contrast(a, b) {
  var la = luminance(a)
  var lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function mix(from, to, share) {
  return { r: from.r + (to.r - from.r) * share, g: from.g + (to.g - from.g) * share, b: from.b + (to.b - from.b) * share }
}

// `color` as it is when it reads on `background`, else moved toward
// `foreground` just far enough that it does. `needed` is the contrast to
// reach, 4.5 unless given.
function legible(color, background, foreground, needed) {
  needed = needed || READABLE
  for (var step = 0; step <= 20; step++) {
    var candidate = mix(color, foreground, step / 20)
    if (contrast(candidate, background) >= needed) return candidate
  }
  return foreground
}

// The quietest version of the foreground that still reads: for captions,
// hints and placeholders. A little over 4.5, because fields and hovered rows
// are a shade off the panel's own background.
function dimmed(foreground, background) {
  return legible(mix(background, foreground, 0.4), background, foreground, 5)
}

// ---------- Paste ----------
// The most that is read from the clipboard for one paste: what the longest
// snippet there can be takes, at four bytes a character. The read asks for
// one byte more, which is how it is known that there was more.
var PASTE_BYTES = MAX_TEXT * 4

function bytes(text) {
  return utf8(text).length
}

// What a paste puts into a field, out of what was read from the clipboard.
//   { text: "...", cut: true }  `cut` when not all of the clipboard went in
// `lines` is 0 for a snippet's text, which keeps its lines and is held to
// `room`, the characters the snippet still has room for. A one-line field
// gives its length in characters there: it gets the first line, up to that
// length. `limit` is the bytes that were read at most.
function pasted(raw, lines, room, limit) {
  limit = limit || PASTE_BYTES
  // A read that stops in the middle of a character leaves a replacement
  // mark, and stopping there is itself the sign that there was more: without
  // it, text whose next character happened to start on the last byte read
  // would pass for whole.
  var whole = String(raw || "")
  var text = whole.replace(/\ufffd+$/, "")
  var cut = bytes(text) > limit || (text !== whole && bytes(text) > limit - 4)
  text = clean(text)
  if (cut) {
    var letters = characters(text)
    var kept = ""
    var size = 0
    for (var i = 0; i < letters.length; i++) {
      size += bytes(letters[i])
      if (size > limit) break
      kept += letters[i]
    }
    text = kept
  }
  if (lines > 0) {
    var first = characters(text.split("\n")[0].replace(/[\u0000-\u001f\u007f]/g, ""))
    var fitted = first.slice(0, lines).join("")
    if (fitted !== text) cut = true
    text = fitted
  } else if (room !== undefined) {
    var all = characters(text)
    if (all.length > room) {
      text = all.slice(0, Math.max(0, room)).join("")
      cut = true
    }
  }
  return { text: text, cut: cut }
}

// The command that reads the clipboard for a paste: never more than the
// limit and a byte, never for longer than two seconds.
function pasting() {
  return ["sh", "-c", "timeout 2 wl-paste --no-newline 2>/dev/null | head -c " + (PASTE_BYTES + 1)]
}

// A snippet's text on one line of the list: its line breaks and runs of
// spaces become single spaces, and only the start is kept.
function preview(text) {
  return String(text || "").substring(0, 300).replace(/\s+/g, " ").trim().substring(0, 160)
}

// The snippets a filter leaves, as indexes into `snippets`. Every word of the
// filter has to be in the trigger or the text, whatever the case.
//   filter([{ trigger: "!em", text: "me@example.com" }], "EXAMPLE me") -> [0]
function filter(snippets, query) {
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(word) { return word !== "" })
  var found = []
  for (var i = 0; i < snippets.length; i++) {
    var hay = (snippets[i].trigger + "\n" + snippets[i].replacement).toLowerCase()
    var all = true
    for (var j = 0; j < words.length && all; j++) all = hay.indexOf(words[j]) >= 0
    if (all) found.push(i)
  }
  return found
}

function quote(text) {
  return '"' + String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

function table(entries) {
  return "{ " + entries.join(", ") + " }"
}

// The Lua for `hyprctl eval` that starts the engine, and what could not be
// started.
//   snippets  [{ trigger, text }]
//   answers   { "char:!": [ways], "name:Shift_L": [ways] }
//   options   { engine: "/path/engine.lua", nonce }
// -> { lua: "...", active: [snippet index per trigger id], untypable: [snippet index] }
// `lua` is "" when no trigger can be typed. Only numbers and the engine's
// path go into it.
function plan(snippets, answers, options) {
  function ways(character) {
    return character ? answers[slot(character, false)] || [] : []
  }

  // The keys for each character of a trigger, "" when one has none.
  function spelling(letters, locked) {
    var positions = []
    for (var j = 0; j < letters.length; j++) {
      var keys = locked ? lockedKeysOf(ways(letters[j]), ways(otherCase(letters[j]))) : keysOf(ways(letters[j]))
      if (KEYPAD[letters[j]]) {
        var pad = keypadKeys(answers[slot(KEYPAD[letters[j]], true)] || [])
        for (var p = 0; p < pad.length; p++) push(keys, pad[p])
      }
      if (keys.length === 0) return ""
      positions.push(table(keys))
    }
    return letters.length > 0 ? table(positions) : ""
  }

  var triggers = []
  var lockedTriggers = []
  var active = []
  var untypable = []
  for (var i = 0; i < snippets.length; i++) {
    var letters = characters(snippets[i].trigger)
    var plain = spelling(letters, false)
    if (plain === "") {
      untypable.push(i)
      continue
    }
    active.push(i)
    // 1 for a trigger that begins with punctuation, which is taken to start
    // a word where the text before it is not known; 0 for one that is a word.
    var loose = /^[\p{L}\p{N}]/u.test(snippets[i].trigger) ? 0 : 1
    triggers.push(table([active.length, plain, loose]))
    var locked = spelling(letters, true)
    if (locked !== "") lockedTriggers.push(table([active.length, locked, loose]))
  }
  if (triggers.length === 0) return { lua: "", active: [], untypable: untypable }

  // A key can be two of these (Caps Lock is on the Shift keys' second level
  // on some layouts): what it is when pressed alone counts, and a modifier
  // over a key to pass over.
  var roles = {}
  for (var name in MODIFIERS) {
    var ways = answers[slot(name, true)] || []
    for (var k = 0; k < ways.length; k++) {
      if (MODIFIERS[name] === 0 && ways[k].modifiers.length > 0) continue
      roles[ways[k].keycode] = Math.max(roles[ways[k].keycode] || 0, MODIFIERS[name])
    }
  }
  var modifiers = Object.keys(roles).map(function(keycode) { return "[" + keycode + "] = " + roles[keycode] })

  function keycodes(name) {
    var found = []
    var ways = answers[slot(name, true)] || []
    for (var k = 0; k < ways.length; k++) {
      var entry = "[" + ways[k].keycode + "] = true"
      if (found.indexOf(entry) < 0) found.push(entry)
    }
    return found
  }

  // A separator counts with Shift or AltGr held too: Shift+Enter ends a word.
  function separators() {
    var found = []
    for (var n = 0; n < SEPARATORS.length; n++) {
      var ways = answers[slot(SEPARATORS[n], true)] || []
      for (var k = 0; k < ways.length; k++) {
        for (var bits = 0; bits < 4; bits++) {
          var entry = "[" + (ways[k].keycode * 4 + bits) + "] = true"
          if (found.indexOf(entry) < 0) found.push(entry)
        }
      }
    }
    return found
  }

  var config = table([
    "nonce = " + Math.floor(Number(options.nonce) || 0),
    "idle = 5000",
    "repeat_delay = tonumber(hl.get_config(\"input.repeat_delay\")) or 600",
    "busy_timeout = 60000",
    "modifiers = " + table(modifiers),
    "backspace = " + table(keycodes("BackSpace")),
    "compose = " + table(keycodes("Multi_key")),
    "word_start = " + (options.wordStart ? "true" : "false"),
    "separators = " + table(separators()),
    "moving = " + table(MOVING.reduce(function(found, name) {
      keycodes(name).forEach(function(entry) { if (found.indexOf(entry) < 0) found.push(entry) })
      return found
    }, [])),
    "triggers = " + table(triggers),
    "locked = " + table(lockedTriggers),
    "skipped = " + table((options.skipped || []).filter(appName).map(function(name) {
      return "[" + classKey(name) + "] = true"
    }))
  ])

  var lua = [
    stop(),
    "local engine = assert(loadfile(" + quote(options.engine) + "))",
    "__instant_snippets = engine().start(hl, " + config + ")"
  ].join("\n")
  return { lua: lua, active: active, untypable: untypable }
}

// Tells the engine the shell did nothing with a match: see engine.reject().
function reject() {
  return "if __instant_snippets then __instant_snippets.reject() end"
}

// The command that writes its stdin to `path`, as a file only its owner can
// read, replacing what is there in one step. A leftover of an earlier write
// is removed first and never written through (set -C), so a link planted in
// its place leads nowhere. With `ownDirectory` the directory is the plugin's
// own and is closed to others too.
function writing(path, ownDirectory) {
  var script = 'umask 077 && d=$(dirname -- "$1") && mkdir -p -- "$d" && '
    + (ownDirectory ? 'chmod 700 -- "$d" && ' : "")
    + 'rm -f -- "$1.new" && set -C && cat > "$1.new" && mv -f -- "$1.new" "$1"'
  return ["sh", "-c", script, "sh", path]
}

// The command that closes a file to everyone but its owner, if it is not
// closed already. It must not touch a file that is: the file is watched, and
// a change of mode is a change, so doing this on every read would have each
// read cause the next.
function tightening(path) {
  // -L: a link to the file is judged, and closed, by the file it leads to.
  return ["sh", "-c", '[ "$(stat -L -c %a -- "$1" 2>/dev/null)" = 600 ] || chmod 600 -- "$1"', "sh", path]
}

// ---------- Where the snippets file is ----------
// The file can be kept somewhere else, a folder that is backed up or synced
// say. What the user typed for that is kept as typed, in a file of its own
// that stays where it is.
var DATA_FILE = "instant-snippets.json"
var MAX_LOCATION = 512

// The snippets file out of what was typed for it: a folder, which the file
// is then in under its usual name, or the file itself when it ends in .json.
// A leading ~ is the home directory.
//   { path: "/home/me/Sync/instant-snippets.json", error: "" }
// `path` is "" for nothing typed, which is the usual place.
function dataFile(typed, home) {
  var text = String(typed || "").trim()
  if (text === "") return { path: "", error: "" }
  if (/[\u0000-\u001f\u007f]/.test(text)) return { path: "", error: "The location cannot contain line breaks or tabs." }
  if (characters(text).length > MAX_LOCATION) return { path: "", error: "The location is too long." }
  if (text === "~" || text.indexOf("~/") === 0) {
    // Without a home directory ~ would be the root of the disk.
    if (String(home || "").charAt(0) !== "/") return { path: "", error: "The home directory is not known. Enter a full path." }
    text = String(home) + text.substring(1)
  }
  if (text.charAt(0) !== "/") return { path: "", error: "Enter a full path, such as ~/Sync/snippets." }
  var file = /\.json$/i.test(text)
  text = text.replace(/\/+/g, "/").replace(/(.)\/$/, "$1")
  return { path: file ? text : (text === "/" ? "" : text) + "/" + DATA_FILE, error: "" }
}

// What the note of the location says, out of the text of its file: the first
// line of it, as it was typed. A note that cannot be gone by is not gone by.
//   { location: "~/Sync/snippets", error: "" }
function noted(text, home) {
  var typed = String(text || "").split("\n")[0].trim()
  if (dataFile(typed, home).error === "") return { location: typed, error: "" }
  return { location: "", error: "The saved data location cannot be used. Using the default location instead." }
}

// What to make of there being no snippets file, given where it is kept. In
// the usual place that is no snippets yet: "". Anywhere else moving() left a
// file, so one that is not there is away for now (a disk not mounted, whose
// mount point is an empty folder like any other; a sync not done), and
// taking that for no snippets would have the next save write a new list
// where the snippets are to come back.
function absent(location) {
  return String(location || "").trim() === "" ? "" : "missing"
}

// The command that takes the snippets file from `from` to `to` and notes
// `typed` in `pointer` as where it now is ("" removes the note: the usual
// place). A file already at `to` is the one to use, another computer's say,
// and is left as it is, as is the one at `from` then. Otherwise the file is
// copied, closed to others, and removed from `from` only once the note is
// written, so that whatever fails the snippets are still where the note says.
// With no file at either end an empty one is left at `to`: see absent().
// Nothing but a file is taken for one at `to`, and `to` is never inside the
// note, which would then be a folder.
function moving(from, to, pointer, typed) {
  var script = 'umask 077; [ -e "$2" ] && [ ! -f "$2" ] && exit 1\n'
    + 'case "$2" in "$3"|"$3"/*) exit 1;; esac\n'
    + '[ -d "$3" ] && exit 1\n'
    + 'd=$(dirname -- "$2") && mkdir -p -- "$d" && [ -w "$d" ] || exit 1\n'
    + 'moved=\n'
    + 'if [ ! -e "$2" ]; then\n'
    + '  rm -f -- "$2.new" && (set -C; if [ -f "$1" ]; then cat -- "$1"; fi > "$2.new")'
    + ' && mv -f -- "$2.new" "$2" || exit 1\n'
    + '  moved=1\n'
    + 'fi\n'
    + 'if [ -n "$4" ]; then\n'
    + '  p=$(dirname -- "$3") && mkdir -p -- "$p" && rm -f -- "$3.new" && (set -C; printf "%s\\n" "$4" > "$3.new")'
    + ' && mv -f -- "$3.new" "$3"\n'
    + 'else\n'
    + '  rm -f -- "$3"\n'
    + 'fi || { [ -z "$moved" ] || rm -f -- "$2"; exit 1; }\n'
    // The empty file just made may be `from` itself, under another spelling.
    + '[ -z "$moved" ] || [ "$1" -ef "$2" ] || rm -f -- "$1"\n'
    + 'exit 0'
  return ["sh", "-c", script, "sh", from, to, pointer, typed]
}

// What `hyprctl eval` is given to start the engine: nothing but where the
// plan is. The plan itself, which spells the triggers out as key numbers, is
// in a file only its owner can read, not in a process's arguments.
function loader(planPath) {
  return "assert(loadfile(" + quote(planPath) + "))()"
}

// With a nonce, only the engine that was started with it is stopped: a
// reloaded plugin's old instance must not take down the new one's engine.
function stop(nonce) {
  var mine = nonce ? " and __instant_snippets.nonce == " + Math.floor(Number(nonce)) : ""
  return "if __instant_snippets" + mine + " then __instant_snippets.stop() __instant_snippets = nil end"
}

// `undoable` after a snippet was typed: Backspace as the very next key takes
// it back.
function resume(undoable) {
  return "if __instant_snippets then __instant_snippets.resume(" + (undoable ? "true" : "false") + ") end"
}

// The engine's event, out of Hyprland's "custom" event data: the trigger the
// keys spell without Caps Lock and the one they spell with it (0 is none),
// or that Backspace was pressed right after a snippet, or that the focus
// moved while one was being typed. Numbers only: not even a trigger's length.
//   "instant-snippets:7:1:2" -> { nonce: 7, plain: 1, locked: 2 }
//   "instant-snippets:7:undo" -> { nonce: 7, undo: true }
//   "instant-snippets:7:moved" -> { nonce: 7, moved: true }
// null for anything else.
function parseEvent(data) {
  var text = String(data || "")
  var word = /^instant-snippets:(\d+):(undo|moved)$/.exec(text)
  if (word) return word[2] === "undo" ? { nonce: Number(word[1]), undo: true } : { nonce: Number(word[1]), moved: true }
  var match = /^instant-snippets:(\d+):(\d+):(\d+)$/.exec(text)
  if (!match) return null
  return { nonce: Number(match[1]), plain: Number(match[2]), locked: Number(match[3]) }
}

// The keyboard a layout-change event is about.
//   "mx-keys-keyboard,Slovak (QWERTY)" -> "mx-keys-keyboard"
function switchedKeyboard(data) {
  var text = String(data || "")
  var comma = text.indexOf(",")
  return comma < 0 ? text : text.substring(0, comma)
}

// Whether a layout-change event is worth a new plan. The keyboards that
// wtype and input methods make for themselves come and go with every snippet
// typed, and say nothing about the layout the user types on.
//   "hl-virtual-keyboard-wtype,English (US)" -> false
function realKeyboard(data) {
  return String(data || "").indexOf("hl-virtual-keyboard-") !== 0
}

// What tells one plan from another: the layout and the triggers, in order.
// The engine is left running while this stays the same.
function fingerprint(layout, snippets, skipped, wordStart) {
  return JSON.stringify([layout.id, snippets.map(function(snippet) { return snippet.trigger }), skipped || [], !!wordStart])
}

// `count` backspaces, as text: wtype presses Backspace for each. They go to it
// on stdin with the rest, so how long a trigger or a replacement is shows in
// no process's arguments.
function backspaces(count) {
  return "\b".repeat(Math.max(0, count))
}

// The command that types what is on its stdin.
function typing() {
  return ["wtype", "-"]
}

// What to run, in order, to type a text: [{ command: [...], input: "..." }],
// `input` being what goes to the command's stdin, absent when it takes none.
//
// With `shiftEnter`, which is how it is unless turned off, a line break is
// typed as Shift+Enter: in chats and the like that starts a new line where
// Enter alone would send what is there, half a snippet at a time. Without
// it a line break is Enter, which is what a shell's prompt wants.
var LINE_BREAK = ["wtype", "-M", "shift", "-k", "Return", "-m", "shift"]

// What is run before a key is pressed by itself (a line break as Shift+Enter,
// the cursor going left) straight after text. Without it the key's release
// can reach the window late, behind the text an input method is still
// handing on, and a key down that long repeats: thirty line breaks for one.
var PAUSE = ["sleep", "0.5"]

function steps(text, shiftEnter) {
  var list = []
  var lines = shiftEnter ? String(text || "").split("\n") : [String(text || "")]
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) {
      list.push({ command: PAUSE })
      list.push({ command: LINE_BREAK })
    }
    var pieces = chunks(lines[i])
    for (var j = 0; j < pieces.length; j++) list.push({ command: typing(), input: pieces[j] })
  }
  return list
}

// ---------- Date and time formats ----------
// What {date} and {time} can look like, as Qt format strings. The first of
// each is used until another is chosen; the system's locale is not gone by,
// since that is often English on a machine whose owner writes dates otherwise.
var DATE_FORMATS = ["yyyy-MM-dd", "d.M.yyyy", "dd.MM.yyyy", "d/M/yyyy", "M/d/yyyy", "d MMMM yyyy"]
var TIME_FORMATS = ["HH:mm", "H:mm", "h:mm AP"]

// `wanted` if it is one of `formats`, else the first of them.
function format(formats, wanted) {
  return formats.indexOf(wanted) >= 0 ? wanted : formats[0]
}

// The format after `current`, round and round.
function nextFormat(formats, current) {
  return formats[(formats.indexOf(current) + 1) % formats.length]
}

// ---------- Placeholders ----------
// A replacement as it is typed: {date} and {time} filled in from `values`,
// and {cursor} taken out, with the number of characters after it, which is
// how far left the cursor has to go to end up there.
//   render("Dear {cursor},\n{date}", { date: "1.2.2026" }) -> { text: "Dear ,\n1.2.2026", back: 10 }
function render(replacement, values) {
  var text = String(replacement || "").replace(/\{(date|time)\}/g, function(whole, name) {
    return typeof values[name] === "string" ? values[name] : whole
  })
  var at = text.indexOf("{cursor}")
  if (at < 0) return { text: text, back: 0 }
  var after = text.substring(at + 8).split("{cursor}").join("")
  return { text: text.substring(0, at) + after, back: clusters(after) }
}

// How many times Left or Backspace has to be pressed to get across a text:
// once for what a reader sees as one character. An accent typed after its
// letter, a flag, a family joined out of several faces are each several code
// points and one press.
function clusters(text) {
  var count = 0
  var joined = false
  var flags = 0
  var letters = characters(text)
  for (var i = 0; i < letters.length; i++) {
    var point = letters[i].codePointAt(0)
    var mark = (point >= 0x300 && point <= 0x36f) || (point >= 0xfe00 && point <= 0xfe0f) || point === 0x20e3
      || (point >= 0x1f3fb && point <= 0x1f3ff) || (point >= 0xe0020 && point <= 0xe007f)
    if (point === 0x200d) { joined = true; continue }
    var flag = point >= 0x1f1e6 && point <= 0x1f1ff
    flags = flag ? flags + 1 : 0
    if (!mark && !joined && !(flag && flags % 2 === 0)) count++
    joined = false
  }
  return count
}

// Whether Backspace can take a text back once it is typed: not when a tab
// may have moved the focus on, nor when a line break was Enter, which may
// have sent what was there.
function undoable(text, shiftEnter) {
  return text !== "" && text.indexOf("\t") < 0 && (shiftEnter || text.indexOf("\n") < 0)
}

// The commands that move the cursor left: one by ten characters, one by a
// single character. They are run as many times as it takes and never told
// how many, so no process's arguments say how much of the replacement comes
// after the cursor. Tens keep a cursor far from the end from taking long.
function backing(ten) {
  var command = ["wtype"]
  for (var i = 0; i < (ten ? 10 : 1); i++) command.push("-k", "Left")
  return command
}

// A trigger of `length` keys rubbed out, the text typed, and the cursor moved
// `back` characters into it.
function expanding(length, text, shiftEnter, back) {
  var list = steps(backspaces(length) + text, shiftEnter)
  if (back > 0) list.push({ command: PAUSE })
  for (var tens = Math.floor(back / 10); tens > 0; tens--) list.push({ command: backing(true) })
  for (var ones = back % 10; ones > 0; ones--) list.push({ command: backing(false) })
  return list
}

// A snippet's text taken back and its trigger typed again. The Backspace
// that asked for this has already rubbed out one character.
function undoing(text, trigger) {
  return steps(backspaces(clusters(text) - 1) + trigger, false)
}

// A text cut into the pieces to hand wtype one at a time.
//
// wtype makes up a keyboard as it goes: the first new character it meets is
// key 1, the next key 2, and so on. Those numbers are also the numbers of
// real keys, and some programs go by the number: Ghostty takes key 15 for
// Tab whatever it is labelled, so the fifteenth different character of a
// text (the "@" of many an email address) arrives as a tab. A fresh wtype
// starts counting again, so no piece is given more than `most` different
// characters, which keeps it on the keys before Backspace (14), Tab (15),
// Enter (28) and the modifiers.
//   chunks("abcabc d", 3) -> ["abcabc", " d"]
var KEYS_PER_PIECE = 13

function chunks(text, most) {
  most = most || KEYS_PER_PIECE
  var pieces = []
  var piece = ""
  var seen = {}
  var count = 0
  var letters = characters(text)
  for (var i = 0; i < letters.length; i++) {
    var letter = letters[i]
    if (!seen[letter]) {
      if (count === most) {
        pieces.push(piece)
        piece = ""
        seen = {}
        count = 0
      }
      seen[letter] = true
      count++
    }
    piece += letter
  }
  if (piece !== "") pieces.push(piece)
  return pieces
}
