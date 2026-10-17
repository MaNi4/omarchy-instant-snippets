// node tests/run.js — checks Model.js, which has no QML in it, and that the
// Lua it writes starts engine.lua and matches. Needs `lua` for the last part.
const fs = require("fs")
const path = require("path")
const assert = require("assert")
const { execFileSync } = require("child_process")

const root = path.join(__dirname, "..")
const source = fs.readFileSync(path.join(root, "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Keys = new Function(source + `\nreturn { activeLayout, characters, codePoint, asking, parseAnswers, parseAnswer, keyOf,
  keysOf, questions, slot, problem, parseConfig, formatConfig, preview, filter, plan, stop, resume, parseEvent,
  typing, backspaces, loader, switchedKeyboard, writing, tightening, dataFile, noted, absent, moving, DATA_FILE, clean, clusters, undoable, reject, MAX_SNIPPETS, ASCII, LATIN, chunks, steps, expanding, undoing, render, backing, format, nextFormat, DATE_FORMATS, TIME_FORMATS, classKey, skipping, appName, bytes, pasted, pasting, PASTE_BYTES, contrast, legible, dimmed, mix, keypadKeys, lockedKeysOf, otherCase, capsLock, realKeyboard, fingerprint, NAMED, SHIFT, LEVEL3, SHORTCUT }`)()

// What `xkbcli how-to-type --disable-compose` prints.
const answer = rows => ["keysym: something (0x0000)", "", "=== Direct access ===", "",
  "KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS"].concat(rows).join("\n") + "\n"
const row = (keycode, modifiers, level) =>
  `${keycode}       AE01      1        English (US)         ${level || 1}       [ ${modifiers || ""} ]`

const US = {
  "char:!": answer([row(10, "Shift", 2)]),
  "char:e": answer([row(26, "")]),
  "char:m": answer([row(58, "")]),
  "char:E": answer([row(26, "Shift", 2), row(26, "Lock", 2)]),
  "char:M": answer([row(58, "Shift", 2), row(58, "Lock", 2)]),
  "char:ľ": answer([]),
  "name:Shift_L": answer([row(50, "")]),
  "name:Shift_R": answer([row(62, "")]),
  "name:ISO_Level3_Shift": answer([row(92, "")]),
  "name:Control_L": answer([row(37, "")]),
  "name:Super_L": answer([row(133, ""), row(206, "Shift", 2)]),
  "name:BackSpace": answer([row(22, ""), row(22, "Shift", 2)]),
  "name:Multi_key": answer([row(66, "")]),
}
const answers = Object.fromEntries(Object.entries(US).map(([slot, text]) => [slot, Keys.parseAnswer(text)]))

const devices = keyboard => JSON.stringify({ keyboards: [
  { name: "power-button", layout: "us", variant: "", options: "", active_layout_index: 0, main: false },
  Object.assign({ name: "kbd", rules: "", model: "", layout: "us,sk", variant: ",qwerty",
    options: "compose:caps", active_layout_index: 0, active_keymap: "English (US)", main: true }, keyboard),
] })

const email = { trigger: "!em", replacement: "me@example.com" }

const tests = {
  "the layout is the main keyboard's active one"() {
    const us = Keys.activeLayout(devices())
    assert.strictEqual(us.layout, "us")
    assert.strictEqual(us.variant, "")
    const sk = Keys.activeLayout(devices({ active_layout_index: 1, active_keymap: "Slovak (QWERTY)" }))
    assert.strictEqual(sk.layout, "sk")
    assert.strictEqual(sk.variant, "qwerty")
    assert.strictEqual(sk.name, "Slovak (QWERTY)")
    assert.notStrictEqual(us.id, sk.id)
  },
  "a virtual keyboard does not decide the layout, even when it is the main one"() {
    const real = (name, index, main) => ({ name, layout: "us,sk", variant: ",qwerty", options: "", active_layout_index: index, main: !!main })
    const virtual = (who, index, main) => Object.assign(real("hl-virtual-keyboard-" + who, index, main), { layout: "us" })
    const layout = keyboards => Keys.activeLayout(JSON.stringify({ keyboards })).layout
    // wtype has just typed and is "main", on its own "us"; the real keyboards are on Slovak.
    assert.strictEqual(layout([real("laptop", 1), real("power-button", 1), virtual("wtype", 0, true)]), "sk")
    // An input method's keyboard is main; the real ones still say.
    assert.strictEqual(layout([real("laptop", 0), real("usb", 0), virtual("fcitx5", 1, true)]), "us")
    // The real ones disagree and none is main: most of them win.
    assert.strictEqual(layout([real("a", 1), real("b", 0), real("c", 1)]), "sk")
    // A real main keyboard is the one typed on, however many others say otherwise.
    assert.strictEqual(layout([real("power-button", 0), real("video-bus", 0), real("sleep", 0), real("usb", 1, true)]), "sk")
    // A real main keyboard counts over one that reported a change (a headset that has just appeared).
    assert.strictEqual(Keys.activeLayout(JSON.stringify({ keyboards: [real("headset", 0), real("usb", 1, true)] }), "headset").layout, "sk")
    // With an input method's keyboard as main, the one that last switched says.
    const three = [real("power-button", 0), real("video-bus", 0), real("usb", 1), virtual("fcitx5", 1, true)]
    assert.strictEqual(Keys.activeLayout(JSON.stringify({ keyboards: three }), "usb").layout, "sk")
    assert.strictEqual(Keys.activeLayout(JSON.stringify({ keyboards: three }), "unplugged").layout, "us")
    assert.strictEqual(Keys.switchedKeyboard("mx-keys-keyboard,Slovak (QWERTY)"), "mx-keys-keyboard")
    // Nothing but virtual ones is still something to go by.
    assert.strictEqual(layout([virtual("fcitx5", 0, true)]), "us")
  },
  "no keyboard, or no JSON, is no layout"() {
    assert.strictEqual(Keys.activeLayout("{}"), null)
    assert.strictEqual(Keys.activeLayout("not json"), null)
  },
  "a character is asked for by code point"() {
    assert.strictEqual(Keys.codePoint("1"), "U+0031")
    assert.strictEqual(Keys.codePoint("-"), "U+002D")
    assert.strictEqual(Keys.codePoint("€"), "U+20AC")
    assert.strictEqual(Keys.codePoint("😀"), "U+1F600")
  },
  "everything is asked of xkbcli in one go, and answered in order"() {
    const sk = Keys.activeLayout(devices({ active_layout_index: 1 }))
    const list = [{ what: "BackSpace", named: true }, { what: "-", named: false }, { what: "ľ", named: false }]
    const command = Keys.asking(sk, list)
    assert.deepStrictEqual(command.slice(0, 2), ["sh", "-c"])
    assert.deepStrictEqual(command.slice(3), ["sh", "", "", "sk", "qwerty", "compose:caps", "k:BackSpace", "c:U+002D", "c:U+013E"])
    const out = [answer([row(22, "")]), answer([row(20, "")]), answer([])].join("\u001e\n") + "\u001e\n"
    assert.deepStrictEqual(Keys.parseAnswers(out, list), {
      "name:BackSpace": [{ keycode: 22, modifiers: [] }], "char:-": [{ keycode: 20, modifiers: [] }], "char:ľ": [] })
    // xkbcli missing: nothing but separators, or nothing at all, is still an answer of sorts...
    assert.deepStrictEqual(Keys.parseAnswers("\u001e\n\u001e\n\u001e\n", list)["char:-"], [])
    // ...but too few records is not.
    assert.strictEqual(Keys.parseAnswers("\u001e\n", list), null)
    assert.strictEqual(Keys.parseAnswers("", list), null)
  },
  "the real xkbcli answers the real script"() {
    const us = { rules: "", model: "", layout: "us", variant: "", options: "" }
    const list = [{ what: "BackSpace", named: true }, { what: "!", named: false }, { what: "e", named: false }]
    const command = Keys.asking(us, list)
    const got = Keys.parseAnswers(execFileSync(command[0], command.slice(1), { encoding: "utf8" }), list)
    assert.deepStrictEqual(Keys.keysOf(got["char:!"]), [41])
    assert.deepStrictEqual(Keys.keysOf(got["char:e"]), [104])
    assert.deepStrictEqual(got["name:BackSpace"][0].keycode, 22)
  },
  "an answer is read row by row"() {
    assert.deepStrictEqual(Keys.parseAnswer(US["char:E"]),
      [{ keycode: 26, modifiers: ["Shift"] }, { keycode: 26, modifiers: ["Lock"] }])
    assert.deepStrictEqual(Keys.parseAnswer(US["char:ľ"]), [])
    assert.deepStrictEqual(Keys.parseAnswer(answer(["26       AD03      2        Slovak (QWERTY)      3       [ Mod5 LevelThree ]"])),
      [{ keycode: 26, modifiers: ["Mod5", "LevelThree"] }])
  },
  "a key is its keycode and Shift or AltGr"() {
    assert.strictEqual(Keys.keyOf({ keycode: 10, modifiers: [] }), 40)
    assert.strictEqual(Keys.keyOf({ keycode: 10, modifiers: ["Shift"] }), 41)
    assert.strictEqual(Keys.keyOf({ keycode: 26, modifiers: ["Mod5", "LevelThree"] }), 106)
    assert.strictEqual(Keys.keyOf({ keycode: 26, modifiers: ["Control"] }), -1)
    assert.deepStrictEqual(Keys.keysOf(answers["char:E"]), [105])
  },
  "Caps Lock swaps what Shift gives on a letter's key, and nothing else"() {
    const e = answers["char:e"], E = answers["char:E"], bang = answers["char:!"]
    assert.deepStrictEqual(Keys.lockedKeysOf(e, E), [105])   // Shift+e
    assert.deepStrictEqual(Keys.lockedKeysOf(E, e), [104])   // plain e
    assert.deepStrictEqual(Keys.lockedKeysOf(bang, []), [41]) // "!" as ever
    // Slovak: "e" is spelled out with Shift+Lock; "ľ" sits on a key Caps Lock leaves alone.
    const skE = Keys.parseAnswer(answer([row(26, ""), row(26, "Shift Lock")]))
    const skBigE = Keys.parseAnswer(answer([row(26, "Shift", 2), row(26, "Lock", 2)]))
    assert.deepStrictEqual(Keys.lockedKeysOf(skE, skBigE), [105])
    const lcaron = Keys.parseAnswer(answer([row(11, "")]))
    assert.deepStrictEqual(Keys.lockedKeysOf(lcaron, []), [44])
    // Shift+AltGr+e is "E" on its fourth level, Caps Lock or not: it does not spell "e".
    const skE4 = Keys.parseAnswer(answer([row(26, "Shift", 2), row(26, "Lock", 2), row(26, "Shift Mod5 LevelThree", 4)]))
    assert.deepStrictEqual(Keys.lockedKeysOf(skE, skE4), [105])
    assert.deepStrictEqual(Keys.lockedKeysOf(skE4, skE), [104, 107])
  },
  "the other case of a character"() {
    assert.strictEqual(Keys.otherCase("e"), "E")
    assert.strictEqual(Keys.otherCase("Š"), "š")
    assert.strictEqual(Keys.otherCase("1"), "")
    assert.strictEqual(Keys.otherCase("ß"), "")
  },
  "Caps Lock is on if it is on on any keyboard"() {
    assert.strictEqual(Keys.capsLock(devices({ capsLock: true })), true)
    assert.strictEqual(Keys.capsLock(devices({ capsLock: false })), false)
    assert.strictEqual(Keys.capsLock("not json"), false)
  },
  "what is asked of xkbcli does not spell the triggers out"() {
    const asked = snippets => Keys.questions(snippets).filter(q => !q.named).map(q => q.what)
    const named = snippets => Keys.questions(snippets).filter(q => q.named).map(q => q.what)
    // ASCII triggers: the same questions whatever they are.
    assert.deepStrictEqual(asked([email]), Keys.ASCII)
    assert.deepStrictEqual(asked([{ trigger: ";zq9", replacement: "x" }]), asked([]))
    assert.deepStrictEqual(named([email]), named([{ trigger: ";1", replacement: "x" }]))
    assert.ok(named([]).includes("KP_1") && named([]).includes("BackSpace") && named([]).includes("space"))
    // An accented letter brings in all of them, not itself.
    assert.deepStrictEqual(asked([{ trigger: "ľa", replacement: "x" }]), Keys.ASCII.concat(Keys.LATIN))
    assert.deepStrictEqual(asked([{ trigger: "šé", replacement: "x" }]), asked([{ trigger: "ľa", replacement: "x" }]))
    // Anything else brings in the 256 code points around it, the same for every trigger of that script.
    const cyrillic = asked([{ trigger: "яд", replacement: "x" }]).slice(Keys.ASCII.length)
    assert.strictEqual(cyrillic.length, 256)
    assert.ok(cyrillic.includes("я") && cyrillic.includes("Ж") && cyrillic[0] === "\u0400")
    assert.deepStrictEqual(asked([{ trigger: "жш", replacement: "x" }]), asked([{ trigger: "яд", replacement: "x" }]))
  },
  "digits and signs can come from the number pad"() {
    const pad = Keys.parseAnswer(answer([row(87, "Mod2 NumLock", 2), row(87, "Shift", 1), row(86, "Control", 1)]))
    assert.deepStrictEqual(Keys.keypadKeys(pad), [348])
    const known = Object.assign({}, answers, {
      "char:;": Keys.parseAnswer(answer([row(47, "")])), "char:1": Keys.parseAnswer(answer([row(10, "")])),
      "name:KP_1": Keys.parseAnswer(answer([row(87, "Mod2 NumLock", 2)])) })
    const plan = Keys.plan([{ trigger: ";1", replacement: "x" }], known, { engine: "/e.lua", nonce: 1 })
    assert.ok(plan.lua.includes("triggers = { { 1, { { 188 }, { 40, 348 } }, 1 } }"))
  },
  "a snippet has to be worth saving"() {
    assert.strictEqual(Keys.problem([], "!em", "x", -1), "")
    assert.notStrictEqual(Keys.problem([], "!", "x", -1), "")
    assert.notStrictEqual(Keys.problem([], "!em", "", -1), "")
    assert.notStrictEqual(Keys.problem([], "!e\nm", "x", -1), "")
    assert.notStrictEqual(Keys.problem([], "x".repeat(33), "x", -1), "")
    assert.notStrictEqual(Keys.problem([email], "!em", "x", -1), "")
    assert.strictEqual(Keys.problem([email], "!em", "x", 0), "")
  },
  "the config file is read defensively"() {
    const empty = { enabled: true, shiftEnter: true, undo: true, wordStart: true, coloredIcon: true, dateFormat: "yyyy-MM-dd",
      timeFormat: "HH:mm", skipped: [], snippets: [], dropped: 0, error: "" }
    assert.deepStrictEqual(Keys.parseConfig(""), empty)
    assert.notStrictEqual(Keys.parseConfig("{").error, "")
    const config = Keys.parseConfig(JSON.stringify({ enabled: false, snippets: [
      email, { trigger: "!em", replacement: "twice" }, { trigger: 5, replacement: "x" }, null, { trigger: "ok", replacement: "fine", extra: 1 }] }))
    assert.strictEqual(config.enabled, false)
    assert.deepStrictEqual(config.snippets, [email, { trigger: "ok", replacement: "fine" }])
    // The three that were not usable are counted, so the file is not written over.
    assert.strictEqual(config.dropped, 3)
    const full = { enabled: false, shiftEnter: false, undo: false, wordStart: false, coloredIcon: false, dateFormat: "d.M.yyyy",
      timeFormat: "h:mm AP", dropped: 0, skipped: ["org.keepassxc.KeePassXC", "foot"], snippets: [email], error: "" }
    assert.deepStrictEqual(Keys.parseConfig(Keys.formatConfig(full)), full)
    const odd = Keys.parseConfig(JSON.stringify({ lineBreaksWithShiftEnter: "yes", excludedApps: ["a", "a", 5, "", "b\nc", "ok"] }))
    assert.strictEqual(odd.shiftEnter, true)
    assert.deepStrictEqual(odd.skipped, ["a", "ok"])
  },
  "contrast is WCAG's"() {
    const black = { r: 0, g: 0, b: 0 }, white = { r: 1, g: 1, b: 1 }
    assert.strictEqual(Math.round(Keys.contrast(black, white)), 21)
    assert.strictEqual(Keys.contrast(white, white), 1)
    // #767676 on white is the textbook 4.5 to 1.
    const grey = { r: 0x76 / 255, g: 0x76 / 255, b: 0x76 / 255 }
    assert.ok(Math.abs(Keys.contrast(grey, white) - 4.54) < 0.01)
  },
  "a colour that reads is kept, one that does not is moved until it does"() {
    const dark = { r: 0.16, g: 0.16, b: 0.16 }, light = { r: 0.92, g: 0.86, b: 0.70 }
    const teal = { r: 0.51, g: 0.75, b: 0.69 }, dullRed = { r: 0.65, g: 0.33, b: 0.33 }
    assert.deepStrictEqual(Keys.legible(teal, dark, light), teal)
    const red = Keys.legible(dullRed, dark, light)
    assert.ok(Keys.contrast(dullRed, dark) < 4.5 && Keys.contrast(red, dark) >= 4.5)
    assert.ok(red.r > red.g, "still red")
    // A theme whose foreground itself does not read is left as the theme made it.
    assert.deepStrictEqual(Keys.legible(dark, dark, dark), dark)
  },
  "dimmed text is quieter than the foreground and still reads, on dark and on light"() {
    const dark = { r: 0.16, g: 0.16, b: 0.16 }, cream = { r: 0.92, g: 0.86, b: 0.70 }
    const paper = { r: 0.98, g: 0.96, b: 0.93 }, ink = { r: 0.2, g: 0.2, b: 0.22 }
    for (const [fg, bg] of [[cream, dark], [ink, paper]]) {
      const dim = Keys.dimmed(fg, bg)
      assert.ok(Keys.contrast(dim, bg) >= 5)
      assert.ok(Keys.contrast(dim, bg) < Keys.contrast(fg, bg))
    }
  },
  "the list shows the start of a text on one line"() {
    assert.strictEqual(Keys.preview("Dear Sir,\n\n  thank you\tfor"), "Dear Sir, thank you for")
    assert.strictEqual(Keys.preview("x".repeat(500)).length, 160)
    assert.strictEqual(Keys.preview(""), "")
  },
  "the filter looks in triggers and texts, a word at a time"() {
    const list = [email, { trigger: "!addr", replacement: "Main Street 1\nSpringfield" }, { trigger: "!sig", replacement: "Regards,\nMe" }]
    assert.deepStrictEqual(Keys.filter(list, ""), [0, 1, 2])
    assert.deepStrictEqual(Keys.filter(list, "  "), [0, 1, 2])
    assert.deepStrictEqual(Keys.filter(list, "ADDR"), [1])
    assert.deepStrictEqual(Keys.filter(list, "me"), [0, 2])
    assert.deepStrictEqual(Keys.filter(list, "street spring"), [1])
    assert.deepStrictEqual(Keys.filter(list, "nothing"), [])
  },
  "the plan holds numbers and the engine's path, never the snippets"() {
    const plan = Keys.plan([email], answers, { engine: "/plugins/it/engine.lua", nonce: 7 })
    assert.deepStrictEqual(plan.active, [0])
    assert.deepStrictEqual(plan.untypable, [])
    assert.ok(plan.lua.includes('loadfile("/plugins/it/engine.lua")'))
    assert.ok(plan.lua.includes("triggers = { { 1, { { 41 }, { 104 }, { 232 } }, 1 } }"))
    // With Caps Lock "!em" is Shift+1, Shift+e, Shift+m.
    assert.ok(plan.lua.includes("locked = { { 1, { { 41 }, { 105 }, { 233 } }, 1 } }"))
    assert.ok(plan.lua.includes("[50] = 1") && plan.lua.includes("[92] = 2") && plan.lua.includes("[37] = 4"))
    // Caps Lock on a Shift key's second level leaves it a Shift key; a Caps Lock key of its own is passed over.
    const locks = Object.assign({}, answers, { "name:Caps_Lock": Keys.parseAnswer(answer([row(50, "Shift", 2), row(66, "")])) })
    const withLocks = Keys.plan([email], locks, { engine: "/e.lua", nonce: 7 }).lua
    assert.ok(withLocks.includes("[50] = 1") && withLocks.includes("[66] = 0") && !withLocks.includes("[50] = 0"))
    assert.ok(plan.lua.includes("backspace = { [22] = true }"))
    assert.ok(!plan.lua.includes("example.com") && !plan.lua.includes("!em"))
  },
  "a trigger the layout cannot type is left out"() {
    const plan = Keys.plan([{ trigger: "ľe", replacement: "x" }, email], answers, { engine: "/e.lua", nonce: 1 })
    assert.deepStrictEqual(plan.untypable, [0])
    assert.deepStrictEqual(plan.active, [1])
    const none = Keys.plan([{ trigger: "ľe", replacement: "x" }], answers, { engine: "/e.lua", nonce: 1 })
    assert.strictEqual(none.lua, "")
  },
  "the engine's path is quoted"() {
    const plan = Keys.plan([email], answers, { engine: '/odd "dir"\\x/engine.lua', nonce: 1 })
    assert.ok(plan.lua.includes('loadfile("/odd \\"dir\\"\\\\x/engine.lua")'))
  },
  "only the engine's own event is taken, and it is numbers only"() {
    assert.deepStrictEqual(Keys.parseEvent("instant-snippets:7:1:0"), { nonce: 7, plain: 1, locked: 0 })
    assert.deepStrictEqual(Keys.parseEvent("instant-snippets:7:undo"), { nonce: 7, undo: true })
    assert.deepStrictEqual(Keys.parseEvent("instant-snippets:7:moved"), { nonce: 7, moved: true })
    assert.strictEqual(Keys.parseEvent("instant-snippets:7:1"), null)
    assert.strictEqual(Keys.parseEvent("instant-snippets:7:1:3:0:0"), null)
    assert.strictEqual(Keys.parseEvent("instant-snippets:7:1:0;rm"), null)
    assert.strictEqual(Keys.parseEvent("other:7:1:0"), null)
  },
  "the trigger is rubbed out and the text typed from stdin, with nothing of either in the arguments"() {
    assert.strictEqual(Keys.backspaces(3), "\b\b\b")
    assert.deepStrictEqual(Keys.typing(), ["wtype", "-"])
    assert.deepStrictEqual(Keys.expanding(2, "hi", false), [{ command: ["wtype", "-"], input: "\b\bhi" }])
    for (const step of Keys.expanding(3, "me@example.com\nline two", true))
      assert.ok(["wtype -", "wtype -M shift -k Return -m shift", "sleep 0.5"].includes(step.command.join(" ")))
  },
  "a private file is written from stdin, in one step, to a fresh inode"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const file = path.join(dir, "sub dir", "-odd name.json")
    const write = (ownDirectory, input) => { const c = Keys.writing(file, ownDirectory); execFileSync(c[0], c.slice(1), { input }) }
    write(true, "one")
    assert.strictEqual(fs2.readFileSync(file, "utf8"), "one")
    assert.strictEqual(fs2.statSync(file).mode & 0o777, 0o600)
    assert.strictEqual(fs2.statSync(path.dirname(file)).mode & 0o777, 0o700)
    // A leftover from an earlier write, made a link to somewhere else, is not written through.
    const elsewhere = path.join(dir, "elsewhere")
    fs2.writeFileSync(elsewhere, "untouched")
    fs2.symlinkSync(elsewhere, file + ".new")
    const before = fs2.statSync(file).ino
    write(false, "two")
    assert.strictEqual(fs2.readFileSync(file, "utf8"), "two")
    assert.strictEqual(fs2.readFileSync(elsewhere, "utf8"), "untouched")
    assert.notStrictEqual(fs2.statSync(file).ino, before)
    assert.ok(!Keys.writing(file, false).join(" ").includes("two"))
    // A file open to others is closed to them; one that is closed is left untouched.
    const tighten = () => { const c = Keys.tightening(file); execFileSync(c[0], c.slice(1)) }
    fs2.chmodSync(file, 0o644)
    tighten()
    assert.strictEqual(fs2.statSync(file).mode & 0o777, 0o600)
    const changed = fs2.statSync(file).ctimeMs
    tighten()
    assert.strictEqual(fs2.statSync(file).ctimeMs, changed)
    // Reached through a link, it is the file that is judged: closed already, so left alone.
    const link = path.join(dir, "link.json")
    fs2.symlinkSync(file, link)
    const c2 = Keys.tightening(link); execFileSync(c2[0], c2.slice(1))
    assert.strictEqual(fs2.statSync(file).ctimeMs, changed)
    fs2.rmSync(dir, { recursive: true })
  },
  "the snippets file is a folder's, or the .json file named"() {
    const at = typed => Keys.dataFile(typed, "/home/me")
    assert.deepStrictEqual(at(""), { path: "", error: "" })
    assert.deepStrictEqual(at("   "), { path: "", error: "" })
    assert.strictEqual(at("~/Sync/snippets").path, "/home/me/Sync/snippets/instant-snippets.json")
    assert.strictEqual(at(" ~/Sync//snippets/ ").path, "/home/me/Sync/snippets/instant-snippets.json")
    assert.strictEqual(at("~").path, "/home/me/instant-snippets.json")
    assert.strictEqual(at("/").path, "/instant-snippets.json")
    assert.strictEqual(at("/mnt/nas/my snippets.JSON").path, "/mnt/nas/my snippets.JSON")
    // A folder that happens to end in .json, said to be one with a slash.
    assert.strictEqual(at("/mnt/odd.json/").path, "/mnt/odd.json/instant-snippets.json")
    assert.notStrictEqual(at("Sync/snippets").error, "")
    assert.notStrictEqual(at("~other/snippets").error, "")
    assert.notStrictEqual(at("/a\tb").error, "")
    assert.notStrictEqual(at("/" + "x".repeat(600)).error, "")
  },
  "the snippets file is moved, unless there is one where it is to go"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const old = path.join(dir, "config", "instant-snippets.json")
    const pointer = path.join(dir, "config", "instant-snippets.location")
    const there = path.join(dir, "Sync dir", "-snippets", "instant-snippets.json")
    const move = (from, to, typed) => {
      const c = Keys.moving(from, to, pointer, typed)
      try { execFileSync(c[0], c.slice(1), { stdio: "ignore" }); return 0 } catch (error) { return error.status }
    }
    fs2.mkdirSync(path.dirname(old))
    fs2.writeFileSync(old, "mine", { mode: 0o644 })
    // To a folder that is not there yet: made, the file moved into it, closed to others.
    assert.strictEqual(move(old, there, "~/Sync dir/-snippets"), 0)
    assert.strictEqual(fs2.readFileSync(there, "utf8"), "mine")
    assert.strictEqual(fs2.statSync(there).mode & 0o777, 0o600)
    assert.ok(!fs2.existsSync(old))
    assert.strictEqual(fs2.readFileSync(pointer, "utf8"), "~/Sync dir/-snippets\n")
    // Back to the usual place: the note goes.
    assert.strictEqual(move(there, old, ""), 0)
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    assert.ok(!fs2.existsSync(there) && !fs2.existsSync(pointer))
    // A file already there is the one to use: neither is touched.
    fs2.writeFileSync(there, "theirs")
    assert.strictEqual(move(old, there, "/sync"), 0)
    assert.strictEqual(fs2.readFileSync(there, "utf8"), "theirs")
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    assert.strictEqual(fs2.readFileSync(pointer, "utf8"), "/sync\n")
    // Nothing to move and nothing there: an empty file is left there, and the note written.
    const empty = path.join(dir, "empty", "instant-snippets.json")
    assert.strictEqual(move(path.join(dir, "none.json"), empty, "/empty"), 0)
    assert.strictEqual(fs2.readFileSync(empty, "utf8"), "")
    assert.strictEqual(fs2.readFileSync(pointer, "utf8"), "/empty\n")
    // A place that cannot be written to: the file and the note stay as they were.
    const shut = path.join(dir, "shut")
    fs2.mkdirSync(shut, { mode: 0o500 })
    assert.notStrictEqual(move(old, path.join(shut, "instant-snippets.json"), "/shut"), 0)
    assert.notStrictEqual(move(old, path.join(shut, "deeper", "instant-snippets.json"), "/shut/deeper"), 0)
    assert.notStrictEqual(move(old, path.dirname(there), "/a-folder.json"), 0)
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    assert.strictEqual(fs2.readFileSync(pointer, "utf8"), "/empty\n")
    // The note cannot be written: the copy is taken back, the file stays.
    const fresh = path.join(dir, "fresh", "instant-snippets.json")
    const c = Keys.moving(old, fresh, path.join(shut, "note"), "/fresh")
    assert.throws(() => execFileSync(c[0], c.slice(1), { stdio: "ignore" }))
    assert.ok(!fs2.existsSync(fresh))
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    fs2.chmodSync(shut, 0o700)
    fs2.rmSync(dir, { recursive: true })
  },
  "a location is not made up when the home directory is not known"() {
    assert.notStrictEqual(Keys.dataFile("~", "").error, "")
    assert.notStrictEqual(Keys.dataFile("~/Sync", "").error, "")
    assert.notStrictEqual(Keys.dataFile("~/Sync", undefined).error, "")
    assert.strictEqual(Keys.dataFile("/mnt/nas", "").path, "/mnt/nas/instant-snippets.json")
    // A home written with a slash at its end is the same home.
    assert.strictEqual(Keys.dataFile("~/Sync", "/home/me/").path, "/home/me/Sync/instant-snippets.json")
    assert.strictEqual(Keys.dataFile("~/.json", "/home/me").path, "/home/me/.json")
    assert.strictEqual(Keys.dataFile("/a\u007fb", "/home/me").path, "")
    assert.notStrictEqual(Keys.dataFile("/a\nb", "/home/me").error, "")
    assert.notStrictEqual(Keys.dataFile("$HOME/Sync", "/home/me").error, "")
  },
  "the note of where the snippets are is read as one line, and gone by only if it can be"() {
    const read = text => Keys.noted(text, "/home/me")
    assert.deepStrictEqual(read(""), { location: "", error: "" })
    assert.deepStrictEqual(read(undefined), { location: "", error: "" })
    assert.deepStrictEqual(read("\n\n"), { location: "", error: "" })
    assert.deepStrictEqual(read("~/Sync/snippets\n"), { location: "~/Sync/snippets", error: "" })
    // Written on another system, or with a mark at its start.
    assert.deepStrictEqual(read("﻿~/Sync/snippets\r\n"), { location: "~/Sync/snippets", error: "" })
    // Only the first line is the location.
    assert.deepStrictEqual(read("/mnt/nas\n/etc\n"), { location: "/mnt/nas", error: "" })
    // What cannot be a location is not one: the usual place it is, and that is said.
    for (const bad of ["Sync/snippets\n", "~other\n", "/a\tb\n", "/" + "x".repeat(600) + "\n"]) {
      const got = read(bad)
      assert.strictEqual(got.location, "")
      assert.notStrictEqual(got.error, "")
    }
    assert.notStrictEqual(Keys.noted("~/Sync\n", "").error, "")
  },
  "what was typed for the location is noted as typed, and never run"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const old = path.join(dir, "instant-snippets.json")
    const pointer = path.join(dir, "instant-snippets.location")
    const marker = path.join(dir, "ran")
    fs2.writeFileSync(old, "mine")
    const odd = `it's "$(touch ${marker})" \`touch ${marker}\`; touch ${marker} #`
    const there = path.join(dir, odd, "-x", "instant-snippets.json")
    const typed = "~/" + odd + " -n \\n %s $4"
    const c = Keys.moving(old, there, pointer, typed)
    execFileSync(c[0], c.slice(1), { stdio: "ignore", cwd: dir })
    assert.ok(!fs2.existsSync(marker))
    assert.strictEqual(fs2.readFileSync(there, "utf8"), "mine")
    assert.strictEqual(fs2.readFileSync(pointer, "utf8"), typed + "\n")
    // The note is the user's alone, as the snippets are, and so is a folder made for them.
    assert.strictEqual(fs2.statSync(pointer).mode & 0o777, 0o600)
    assert.strictEqual(fs2.statSync(path.dirname(there)).mode & 0o777, 0o700)
    // None of it is in the script itself.
    assert.ok(!c[2].includes("touch"))
    fs2.rmSync(dir, { recursive: true })
  },
  "the snippets file is not moved onto or through what is not a file"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const old = path.join(dir, "instant-snippets.json")
    const pointer = path.join(dir, "instant-snippets.location")
    const move = (from, to, typed) => {
      const c = Keys.moving(from, to, pointer, typed)
      try { execFileSync(c[0], c.slice(1), { stdio: "ignore", timeout: 5000 }); return 0 } catch (error) { return error.status === null ? "hung" : error.status }
    }
    fs2.writeFileSync(old, "mine")
    // A pipe where the file would be is not a snippets file to use.
    const pipe = path.join(dir, "pipe", "instant-snippets.json")
    fs2.mkdirSync(path.dirname(pipe))
    execFileSync("mkfifo", [pipe])
    assert.ok(move(old, pipe, "/pipe") > 0)
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    assert.ok(!fs2.existsSync(pointer))
    // A link to nowhere is replaced, not written through.
    const nowhere = path.join(dir, "nowhere")
    const linked = path.join(dir, "linked", "instant-snippets.json")
    fs2.mkdirSync(path.dirname(linked))
    fs2.symlinkSync(nowhere, linked)
    assert.strictEqual(move(old, linked, "/linked"), 0)
    assert.ok(!fs2.existsSync(nowhere))
    assert.ok(fs2.lstatSync(linked).isFile())
    assert.strictEqual(fs2.readFileSync(linked, "utf8"), "mine")
    // Nor is a leftover of an earlier move that was made a link to somewhere else.
    const elsewhere = path.join(dir, "elsewhere")
    const next = path.join(dir, "next", "instant-snippets.json")
    fs2.writeFileSync(elsewhere, "untouched")
    fs2.mkdirSync(path.dirname(next))
    fs2.symlinkSync(elsewhere, next + ".new")
    fs2.symlinkSync(elsewhere, pointer + ".new")
    assert.strictEqual(move(linked, next, "/next"), 0)
    assert.strictEqual(fs2.readFileSync(elsewhere, "utf8"), "untouched")
    assert.strictEqual(fs2.readFileSync(next, "utf8"), "mine")
    assert.ok(fs2.lstatSync(pointer).isFile())
    // A file kept through a link: what it leads to is copied and stays, the link goes.
    const real = path.join(dir, "real.json")
    fs2.writeFileSync(real, "dotfiles")
    fs2.symlinkSync(real, old)
    const last = path.join(dir, "last", "instant-snippets.json")
    assert.strictEqual(move(old, last, "/last"), 0)
    assert.strictEqual(fs2.readFileSync(last, "utf8"), "dotfiles")
    assert.ok(fs2.lstatSync(last).isFile())
    assert.strictEqual(fs2.readFileSync(real, "utf8"), "dotfiles")
    assert.ok(!fs2.existsSync(old))
    fs2.rmSync(dir, { recursive: true })
  },
  "the snippets file is not put where the note of its place goes"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const old = path.join(dir, "instant-snippets.json")
    const pointer = path.join(dir, "instant-snippets.location")
    const move = (to, typed) => {
      const c = Keys.moving(old, to, pointer, typed)
      try { execFileSync(c[0], c.slice(1), { stdio: "ignore" }); return 0 } catch (error) { return error.status }
    }
    fs2.writeFileSync(old, "mine")
    // The note would become a folder, and could not be read the next time.
    assert.notStrictEqual(move(path.join(pointer, "instant-snippets.json"), pointer), 0)
    assert.notStrictEqual(move(path.join(pointer, "deeper", "mine.json"), pointer + "/deeper/mine.json"), 0)
    assert.ok(!fs2.existsSync(pointer))
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    // A folder already where the note goes: nothing is moved, since it could not be said where to.
    fs2.mkdirSync(pointer)
    const there = path.join(dir, "there", "instant-snippets.json")
    assert.notStrictEqual(move(there, "/there"), 0)
    assert.ok(!fs2.existsSync(there))
    assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    assert.deepStrictEqual(fs2.readdirSync(pointer), [])
    fs2.rmSync(dir, { recursive: true })
  },
  "the snippets file under another spelling of where it is stays as it is"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const old = path.join(dir, "config", "instant-snippets.json")
    const pointer = path.join(dir, "config", "instant-snippets.location")
    fs2.mkdirSync(path.dirname(old))
    fs2.writeFileSync(old, "mine")
    fs2.symlinkSync(path.join(dir, "config"), path.join(dir, "alias"))
    for (const same of [dir + "/config/../config/instant-snippets.json", dir + "/alias/instant-snippets.json", old]) {
      const c = Keys.moving(old, same, pointer, "/same")
      execFileSync(c[0], c.slice(1), { stdio: "ignore" })
      assert.strictEqual(fs2.readFileSync(old, "utf8"), "mine")
    }
    fs2.rmSync(dir, { recursive: true })
  },
  "a place with no snippets file is given an empty one, so that one missing later is not taken for none"() {
    const fs2 = require("fs"), os = require("os")
    const dir = fs2.mkdtempSync(path.join(os.tmpdir(), "isnip-"))
    const pointer = path.join(dir, "instant-snippets.location")
    const none = path.join(dir, "none.json")
    const fresh = path.join(dir, "fresh", "instant-snippets.json")
    let c = Keys.moving(none, fresh, pointer, "/fresh")
    execFileSync(c[0], c.slice(1), { stdio: "ignore" })
    assert.strictEqual(fs2.readFileSync(fresh, "utf8"), "")
    assert.strictEqual(fs2.statSync(fresh).mode & 0o777, 0o600)
    assert.deepStrictEqual(Keys.parseConfig(fs2.readFileSync(fresh, "utf8")).snippets, [])
    assert.strictEqual(Keys.parseConfig(fs2.readFileSync(fresh, "utf8")).error, "")
    assert.strictEqual(fs2.readFileSync(pointer, "utf8"), "/fresh\n")
    // The same place under another spelling, with nothing in it: the file made is not then removed as the old one.
    const again = path.join(dir, "again", "instant-snippets.json")
    c = Keys.moving(dir + "/again/../again/instant-snippets.json", again, pointer, "/again")
    execFileSync(c[0], c.slice(1), { stdio: "ignore" })
    assert.strictEqual(fs2.readFileSync(again, "utf8"), "")
    // The note cannot be written: the empty file is taken back too.
    const shut = path.join(dir, "shut")
    fs2.mkdirSync(shut, { mode: 0o500 })
    const other = path.join(dir, "other", "instant-snippets.json")
    c = Keys.moving(none, other, path.join(shut, "note"), "/other")
    assert.throws(() => execFileSync(c[0], c.slice(1), { stdio: "ignore" }))
    assert.ok(!fs2.existsSync(other))
    // A file already there is not emptied, whatever happens to the note.
    fs2.mkdirSync(path.dirname(other), { recursive: true })
    fs2.writeFileSync(other, "theirs")
    assert.throws(() => execFileSync(c[0], c.slice(1), { stdio: "ignore" }))
    assert.strictEqual(fs2.readFileSync(other, "utf8"), "theirs")
    fs2.chmodSync(shut, 0o700)
    fs2.rmSync(dir, { recursive: true })
  },
  "a snippets file that is not where it is kept is said to be missing, and only in the usual place taken for none"() {
    assert.strictEqual(Keys.absent(""), "")
    assert.strictEqual(Keys.absent("  "), "")
    assert.strictEqual(Keys.absent("~/Sync/snippets"), "missing")
    assert.strictEqual(Keys.absent("/mnt/nas"), "missing")
    assert.strictEqual(Keys.absent("/mnt/nas/mine.json"), "missing")
  },
  "the engine is started from a private file, not from arguments"() {
    assert.strictEqual(Keys.loader("/run/user/1000/instant-snippets/plan.lua"),
      'assert(loadfile("/run/user/1000/instant-snippets/plan.lua"))()')
  },
  "control characters do not get into a replacement"() {
    assert.strictEqual(Keys.clean("a\bb\u001bc\r\nd\te"), "abc\nd\te")
    assert.notStrictEqual(Keys.problem([], "!x", "a\bb", -1), "")
    assert.strictEqual(Keys.problem([], "!x", "a\n\tb", -1), "")
    assert.deepStrictEqual(Keys.pasted("a\bb", 0), { text: "ab", cut: false })
    assert.strictEqual(Keys.parseConfig(JSON.stringify({ snippets: [{ trigger: "!x", replacement: "a\bb" }] })).snippets.length, 0)
    const many = Array.from({ length: 600 }, (_, i) => ({ trigger: "!t" + i, replacement: "x" }))
    const capped = Keys.parseConfig(JSON.stringify({ snippets: many }))
    assert.strictEqual(capped.snippets.length, 500)
    assert.strictEqual(capped.dropped, 100)
    assert.notStrictEqual(Keys.problem(capped.snippets, "!new", "x", -1), "")
    assert.strictEqual(Keys.problem(capped.snippets, "!new", "x", 3), "")
  },
  "a paste is cut at the limit, on a whole character, and says so"() {
    assert.strictEqual(Keys.bytes("aľ😀"), 1 + 2 + 4)
    assert.deepStrictEqual(Keys.pasted("one\r\ntwo", 0), { text: "one\ntwo", cut: false })
    assert.deepStrictEqual(Keys.pasted("abcdef", 0, undefined, 4), { text: "abcd", cut: true })
    assert.deepStrictEqual(Keys.pasted("abľľ", 0, undefined, 3), { text: "ab", cut: true })
    assert.deepStrictEqual(Keys.pasted("abcd", 0, undefined, 4), { text: "abcd", cut: false })
    // A one-line field takes the first line, as far as it has room, and says
    // so when that was not everything.
    assert.deepStrictEqual(Keys.pasted("!em", 32), { text: "!em", cut: false })
    assert.deepStrictEqual(Keys.pasted("one\ntwo", 32), { text: "one", cut: true })
    assert.deepStrictEqual(Keys.pasted("abcdef", 4), { text: "abcd", cut: true })
    // The read stops a byte past the limit, which may be half a character:
    // that half is dropped, and the paste still counts as cut.
    assert.deepStrictEqual(Keys.pasted("abcd\ufffd", 0, undefined, 4), { text: "abcd", cut: true })
    assert.deepStrictEqual(Keys.pasted("ab\ufffd", 0, undefined, 100), { text: "ab", cut: false })
    // A snippet's text takes what it still has room for.
    assert.deepStrictEqual(Keys.pasted("abcdef", 0, 4), { text: "abcd", cut: true })
    assert.deepStrictEqual(Keys.pasted("abcdef", 0, 6), { text: "abcdef", cut: false })
    assert.deepStrictEqual(Keys.pasted("abcdef", 0, 0), { text: "", cut: true })
    // Whatever fits a snippet fits a paste.
    assert.strictEqual(Keys.PASTE_BYTES, 4000)
    assert.ok(Keys.pasting()[2].endsWith("head -c 4001"))
  },
  "date and time formats are chosen from a fixed list"() {
    assert.strictEqual(Keys.format(Keys.DATE_FORMATS, "d.M.yyyy"), "d.M.yyyy")
    assert.strictEqual(Keys.format(Keys.DATE_FORMATS, "'; rm -rf"), "yyyy-MM-dd")
    assert.strictEqual(Keys.format(Keys.TIME_FORMATS, undefined), "HH:mm")
    assert.strictEqual(Keys.nextFormat(Keys.TIME_FORMATS, "HH:mm"), "H:mm")
    assert.strictEqual(Keys.nextFormat(Keys.TIME_FORMATS, "h:mm AP"), "HH:mm")
    assert.strictEqual(Keys.parseConfig(JSON.stringify({ dateFormat: "nonsense" })).dateFormat, "yyyy-MM-dd")
  },
  "Left and Backspace are counted in what a reader sees as characters"() {
    assert.strictEqual(Keys.clusters("abc"), 3)
    assert.strictEqual(Keys.clusters("ľš\n"), 3)
    assert.strictEqual(Keys.clusters("e\u0301"), 1)            // e + combining acute
    assert.strictEqual(Keys.clusters("\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"), 1) // a family
    assert.strictEqual(Keys.clusters("\u{1F1F8}\u{1F1F0}\u{1F1E8}\u{1F1FF}"), 2)     // two flags
    assert.strictEqual(Keys.clusters("\u{1F44D}\u{1F3FD}!"), 2)                        // thumbs up, toned
    assert.deepStrictEqual(Keys.render("a{cursor}\u{1F468}\u200D\u{1F469}b", {}).back, 2)
    assert.deepStrictEqual(Keys.undoing("\u{1F1F8}\u{1F1F0}x", "!x"), [{ command: ["wtype", "-"], input: "\b!x" }])
  },
  "what a tab or an Enter may have set off is not offered for undo"() {
    assert.strictEqual(Keys.undoable("plain", false), true)
    assert.strictEqual(Keys.undoable("", true), false)
    // A cursor at the very start of the longest replacement is fine.
    assert.strictEqual(Keys.problem([], "!x", "{cursor}" + "y".repeat(992), -1), "")
    assert.strictEqual(Keys.undoable("a\tb", true), false)
    assert.strictEqual(Keys.undoable("a\nb", false), false)
    assert.strictEqual(Keys.undoable("a\nb", true), true)
    assert.ok(Keys.reject().includes(".reject()"))
  },
  "placeholders are filled in and the cursor's place found"() {
    const values = { date: "1.2.2026", time: "9:05" }
    assert.deepStrictEqual(Keys.render("plain", values), { text: "plain", back: 0 })
    assert.deepStrictEqual(Keys.render("{date} at {time}, {date}", values), { text: "1.2.2026 at 9:05, 1.2.2026", back: 0 })
    assert.deepStrictEqual(Keys.render("Dear {cursor},\n{date}", values), { text: "Dear ,\n1.2.2026", back: 10 })
    assert.deepStrictEqual(Keys.render("a{cursor}b{cursor}c", values), { text: "abc", back: 2 })
    assert.deepStrictEqual(Keys.render("{other} {date}", {}), { text: "{other} {date}", back: 0 })
    assert.deepStrictEqual(Keys.backing(false), ["wtype", "-k", "Left"])
    assert.strictEqual(Keys.backing(true).filter(a => a === "Left").length, 10)
    // The cursor goes back in tens and ones, each a fixed command: no count in any of them.
    const moves = Keys.expanding(1, "ab", false, 23).slice(1)
    assert.deepStrictEqual(moves[0], { command: ["sleep", "0.5"] })
    assert.deepStrictEqual(moves.slice(1).map(step => step.command.filter(a => a === "Left").length), [10, 10, 1, 1, 1])
    assert.strictEqual(Keys.expanding(1, "x", false, 1000).length, 1 + 1 + 100)
    assert.strictEqual(Keys.expanding(1, "x", false, 0).length, 1)
  },
  "word-start expansion hands the engine the keys that end a word"() {
    const known = Object.assign({}, answers, { "name:space": Keys.parseAnswer(answer([row(65, "")])) })
    const on = Keys.plan([email], known, { engine: "/e.lua", nonce: 1, wordStart: true })
    assert.ok(on.lua.includes("word_start = true"))
    assert.ok(on.lua.includes("separators = { [260] = true, [261] = true, [262] = true, [263] = true }"))
    assert.ok(Keys.plan([email], known, { engine: "/e.lua", nonce: 1 }).lua.includes("word_start = false"))
    // A trigger that is a word is marked as one; keys that move the cursor are handed over.
    const word = Object.assign({}, known, { "char:a": Keys.parseAnswer(answer([row(38, "")])), "char:d": Keys.parseAnswer(answer([row(40, "")])),
      "char:r": Keys.parseAnswer(answer([row(27, "")])), "name:Left": Keys.parseAnswer(answer([row(113, "")])) })
    const adr = Keys.plan([{ trigger: "adr", replacement: "x" }], word, { engine: "/e.lua", nonce: 1 }).lua
    assert.ok(adr.includes("triggers = { { 1, { { 152 }, { 160 }, { 108 } }, 0 } }"))
    assert.ok(adr.includes("moving = { [113] = true }"))
    const us = Keys.activeLayout(devices())
    assert.notStrictEqual(Keys.fingerprint(us, [email], [], false), Keys.fingerprint(us, [email], [], true))
  },
  "a line break can be typed as Shift+Enter"() {
    const type = input => ({ command: ["wtype", "-"], input })
    const shiftEnter = { command: ["wtype", "-M", "shift", "-k", "Return", "-m", "shift"] }
    assert.deepStrictEqual(Keys.steps("a\nb", false), [type("a\nb")])
    // A pause comes before each: a key pressed straight after text can repeat.
    const pause = { command: ["sleep", "0.5"] }
    assert.deepStrictEqual(Keys.steps("a\n\nb", true), [type("a"), pause, shiftEnter, pause, shiftEnter, type("b")])
    assert.deepStrictEqual(Keys.steps("", true), [])
    assert.deepStrictEqual(Keys.expanding(2, "hi", false), [type("\b\bhi")])
  },
  "taking a snippet back rubs out the rest of it and types the trigger"() {
    const type = input => ({ command: ["wtype", "-"], input })
    assert.deepStrictEqual(Keys.undoing("abc", "!x"), [type("\b\b!x")])
    assert.deepStrictEqual(Keys.undoing("a", "!x"), [type("!x")])
    assert.ok(Keys.resume(true).includes("resume(true)") && Keys.resume().includes("resume(false)"))
  },
  "apps to leave alone go to the engine as numbers, the same ones it works out"() {
    assert.strictEqual(Keys.classKey(""), 5381)
    const names = ["foot", "com.mitchellh.ghostty", "org.keepassxc.KeePassXC", "Poznámky ľ"]
    const lua = "local E = dofile('engine.lua'); for _, n in ipairs({" + names.map(n => JSON.stringify(n)).join(",") + "}) do print(E.class_key(n)) end"
    const out = execFileSync("lua", ["-e", lua], { encoding: "utf8", cwd: root }).trim().split("\n").map(Number)
    assert.deepStrictEqual(out, names.map(Keys.classKey))
    const plan = Keys.plan([email], answers, { engine: "/e.lua", nonce: 1, skipped: ["foot", "bad\nname"] })
    assert.ok(plan.lua.includes("skipped = { [" + Keys.classKey("foot") + "] = true }"))
    assert.ok(!plan.lua.includes("foot"))
    assert.deepStrictEqual(Keys.skipping(["a"], "b", true), ["a", "b"])
    assert.deepStrictEqual(Keys.skipping(["a", "b"], "a", false), ["b"])
    assert.deepStrictEqual(Keys.skipping(["a"], "a", true), ["a"])
    assert.notStrictEqual(Keys.fingerprint(Keys.activeLayout(devices()), [email], []), Keys.fingerprint(Keys.activeLayout(devices()), [email], ["foot"]))
  },
  "a text is typed in pieces of few different characters"() {
    assert.deepStrictEqual(Keys.chunks("abcabc d", 3), ["abcabc", " d"])
    assert.deepStrictEqual(Keys.chunks("", 3), [])
    assert.deepStrictEqual(Keys.chunks("aaaa", 1), ["aaaa"])
    // A new piece starts at the fourteenth different character.
    const pieces = Keys.chunks("jane.walker@example.com")
    assert.deepStrictEqual(pieces, ["jane.walker@example.","com"])
    for (const text of ["line one\nline two\t😀 ľščťž", "x".repeat(100), "The quick brown fox jumps over the lazy dog."]) {
      const cut = Keys.chunks(text)
      assert.strictEqual(cut.join(""), text)
      for (const piece of cut) assert.ok(new Set(Array.from(piece)).size <= 13)
    }
  },
  "keyboards made by wtype and input methods do not change the plan"() {
    assert.strictEqual(Keys.realKeyboard("hl-virtual-keyboard-wtype,English (US)"), false)
    assert.strictEqual(Keys.realKeyboard("hl-virtual-keyboard-fcitx5,error"), false)
    assert.strictEqual(Keys.realKeyboard("mx-keys-keyboard,Slovak (QWERTY)"), true)
  },
  "the plan's fingerprint is the layout and the triggers"() {
    const us = Keys.activeLayout(devices())
    const sk = Keys.activeLayout(devices({ active_layout_index: 1 }))
    assert.strictEqual(Keys.fingerprint(us, [email]), Keys.fingerprint(us, [{ trigger: "!em", replacement: "other text" }]))
    assert.notStrictEqual(Keys.fingerprint(us, [email]), Keys.fingerprint(sk, [email]))
    assert.notStrictEqual(Keys.fingerprint(us, [email]), Keys.fingerprint(us, [{ trigger: "!me", replacement: "x" }]))
  },
  "the planned Lua starts the engine and it matches"() {
    const plan = Keys.plan([email], answers, { engine: path.join(root, "engine.lua"), nonce: 7 })
    const harness = `
      local handlers, time = {}, 1000
      hl = {
        dsp = { event = function(text) return text end },
        dispatch = function(text) print(text) end,
        timer = function(callback, options) if options.timeout < 1000 then callback() end end,
        get_config = function() return 250 end,
        on = function(name, callback) handlers[name] = callback; return { remove = function() handlers[name] = nil end } end,
      }
      local function key(keycode, state) time = time + 30; handlers["input.keyboard.key"](keycode, time, state) end
      ${plan.lua}
      key(50, 1) key(10, 1) key(10, 0) key(50, 0)
      key(26, 1) key(26, 0) key(58, 1) key(58, 0)
      ${Keys.resume()}
      ${Keys.stop(8)}
      print(__instant_snippets ~= nil)
      ${Keys.stop(7)}
      print(handlers["input.keyboard.key"] == nil and __instant_snippets == nil)
    `
    const out = execFileSync("lua", ["-e", harness], { encoding: "utf8" })
    assert.strictEqual(out, "instant-snippets:7:1:0\ntrue\ntrue\n")
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try { test() } catch (error) {
    failed++
    console.log("FAIL " + name + "\n  " + String(error.message).split("\n").join("\n  "))
  }
}
if (failed) {
  console.log(failed + " failed")
  process.exit(1)
}
console.log("model: ok (" + Object.keys(tests).length + ")")
