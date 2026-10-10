-- Drives engine.lua with a stand-in for Hyprland's `hl`. Run from the plugin
-- folder: lua tests/engine.lua

local Engine = dofile("engine.lua")

local failures = 0
local function check(name, got, want)
  if got == want then return end
  failures = failures + 1
  print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
end

-- US keycodes used below.
local ONE, E, M, X, SPACE = 10, 26, 58, 53, 65
local SHIFT_L, CTRL_L, BACKSPACE, COMPOSE, LEFT = 50, 37, 22, 66, 113
local DELETE = 119
local LOCK_KEY = 78 -- a Caps Lock key of its own: passed over, role 0

local function key(keycode, modifiers) return keycode * 4 + (modifiers or 0) end

-- "!em" is trigger 1, "em" trigger 2, "m!" trigger 3.
local TRIGGERS = {
  { 1, { { key(ONE, Engine.SHIFT) }, { key(E) }, { key(M) } } },
  { 2, { { key(E) }, { key(M) } } },
  { 3, { { key(M) }, { key(ONE, Engine.SHIFT) } } },
}

local function world(triggers, locked, skipped, word_start)
  local w = { handlers = {}, events = {}, timers = {}, removed = 0, time = 1000, clock = 100, layers = {} }
  local hl = {
    dsp = { event = function(text) return text end },
    dispatch = function(text) table.insert(w.events, text) end,
    -- The engine's own repeating timer is kept apart from the one-shot ones.
    timer = function(callback, options)
      if options and options.type == "repeat" then w.tick = callback else table.insert(w.timers, callback) end
      return { set_enabled = function() w.ticking = false end }
    end,
    get_layers = function() return w.layers end,
    on = function(name, callback)
      w.handlers[name] = callback
      return { remove = function() w.handlers[name] = nil; w.removed = w.removed + 1 end }
    end,
  }
  w.engine = Engine.start(hl, {
    nonce = 7, idle = 5000, repeat_delay = 250, busy_timeout = 10000,
    modifiers = { [SHIFT_L] = Engine.SHIFT, [CTRL_L] = Engine.SHORTCUT, [LOCK_KEY] = 0 },
    backspace = { [BACKSPACE] = true },
    compose = { [COMPOSE] = true },
    triggers = triggers or TRIGGERS,
    locked = locked,
    skipped = skipped,
    word_start = word_start,
    separators = { [SPACE * 4] = true },
    moving = { [LEFT] = true, [DELETE] = true },
  }, function() return w.clock end)
  function w.down(keycode) w.time = w.time + 40; w.handlers["input.keyboard.key"](keycode, w.time, 1) end
  function w.up(keycode) w.time = w.time + 40; w.handlers["input.keyboard.key"](keycode, w.time, 0) end
  function w.tap(keycode) w.down(keycode); w.up(keycode) end
  function w.shifted(keycode) w.down(SHIFT_L); w.tap(keycode); w.up(SHIFT_L) end
  function w.bang() w.shifted(ONE) end
  function w.last() return w.events[#w.events] end
  -- The engine listens again a moment after it is told to: that moment passes here.
  function w.resume(undoable)
    w.engine.resume(undoable)
    table.remove(w.timers)()
  end
  return w
end

do -- the trigger, and the longest one when two end the same way
  local w = world()
  w.bang(); w.tap(E); w.tap(M)
  check("types !em", w.last(), "instant-snippets:7:1:0")
  check("one event", #w.events, 1)
end

do -- the shorter trigger on its own
  local w = world()
  w.tap(X); w.tap(E); w.tap(M)
  check("types em", w.last(), "instant-snippets:7:2:0")
end

do -- nothing is heard while the shell types, then it listens again
  local w = world()
  w.tap(E); w.tap(M)
  w.tap(E); w.tap(M)
  check("deaf while busy", #w.events, 1)
  w.resume()
  w.tap(E); w.tap(M)
  check("listens after resume", #w.events, 2)
end

do -- the shell never reports back
  local w = world()
  w.tap(E); w.tap(M)
  w.timers[1]()
  w.tap(E); w.tap(M)
  check("timeout ends busy", #w.events, 2)
end

do -- a timeout left over from an earlier match does not end a later one
  local w = world()
  w.tap(E); w.tap(M)
  w.resume()
  w.tap(E); w.tap(M)
  w.timers[1]()
  w.tap(E); w.tap(M)
  check("stale timeout ignored", #w.events, 2)
end

do -- Backspace takes back the last key
  local w = world()
  w.tap(E); w.tap(X); w.tap(BACKSPACE); w.tap(M)
  check("backspace", w.last(), "instant-snippets:7:2:0")
end

do -- a key in between breaks the trigger
  local w = world()
  w.tap(E); w.tap(LEFT); w.tap(M)
  check("arrow in between", #w.events, 0)
end

do -- a shortcut is not text
  local w = world()
  w.tap(E); w.down(CTRL_L); w.tap(X); w.up(CTRL_L); w.tap(M)
  check("shortcut forgets", #w.events, 0)
  w.down(CTRL_L); w.tap(E); w.tap(M); w.up(CTRL_L)
  check("typed with ctrl", #w.events, 0)
end

do -- the focus moved
  local w = world()
  w.tap(E)
  w.handlers["window.active"]()
  w.tap(M)
  check("window change forgets", #w.events, 0)
end

do -- a pause in typing
  local w = world()
  w.tap(E)
  w.time = w.time + 6000
  w.tap(M)
  check("idle forgets", #w.events, 0)
end

do -- a key held until it repeats typed more than once
  local w = world()
  w.down(E); w.time = w.time + 400; w.up(E); w.tap(M)
  check("held key forgets", #w.events, 0)
end

do -- fast typing: the next key goes down before the last one is up
  local w = world()
  w.down(E); w.down(M); w.up(E); w.up(M)
  check("rollover", w.last(), "instant-snippets:7:2:0")
end

do -- Compose and the two keys after it are one character
  local w = world()
  w.tap(COMPOSE); w.tap(E); w.tap(M)
  check("compose sequence", #w.events, 0)
  w.tap(E); w.tap(M)
  check("after compose", #w.events, 1)
end

do -- a trigger ending on a shifted key waits for Shift to come up
  local w = world()
  w.tap(M); w.down(SHIFT_L); w.tap(ONE)
  check("waits for shift", #w.events, 0)
  w.up(SHIFT_L)
  check("fires on release", w.last(), "instant-snippets:7:3:0")
end

do -- and is dropped if typing goes on first
  local w = world()
  w.tap(M); w.down(SHIFT_L); w.tap(ONE); w.tap(X); w.up(SHIFT_L)
  check("typing on cancels", #w.events, 0)
end

do -- "1" is not "!"
  local w = world()
  w.tap(ONE); w.tap(E); w.tap(M)
  check("unshifted 1", w.last(), "instant-snippets:7:2:0")
end

do -- a character two keys can type
  local w = world({ { 1, { { key(E), key(X) }, { key(M) } } } })
  w.tap(X); w.tap(M)
  check("alternative key", w.last(), "instant-snippets:7:1:0")
end

do -- an input method echoes every press and release
  local w = world()
  local function echoed(keycode)
    w.down(keycode); w.down(keycode); w.up(keycode); w.up(keycode)
  end
  w.down(SHIFT_L); w.down(SHIFT_L); echoed(ONE); w.up(SHIFT_L); w.up(SHIFT_L)
  echoed(E); echoed(M)
  check("echoed keys", w.last(), "instant-snippets:7:1:0")
  check("echoed once", #w.events, 1)
end

do -- a key let go while the shell types is up afterwards
  local w = world()
  w.tap(E); w.down(M)
  check("matched on press", #w.events, 1)
  w.up(M)
  w.resume()
  w.tap(E); w.tap(M)
  check("key released while busy", #w.events, 2)
end

do -- Shift let go while the shell types does not stay held
  local w = world({ { 1, { { key(E) }, { key(M) } } } })
  w.tap(E); w.tap(M)
  w.down(SHIFT_L)
  w.resume()
  w.tap(E); w.tap(M)
  check("shift pressed while busy is held", #w.events, 1)
  w.up(SHIFT_L)
  w.tap(E); w.tap(M)
  check("shift not stuck", #w.events, 2)
end

do -- a release that never came does not shut a key out for good
  local w = world()
  w.down(E)
  w.clock = w.clock + 5
  w.time = w.time + 6000
  w.tap(E); w.tap(M)
  check("stale key recovers", w.last(), "instant-snippets:7:2:0")
end

do -- with Caps Lock the same keys spell another trigger: both are reported
  -- "em" is trigger 1 without Caps Lock; with it those keys spell "EM",
  -- trigger 2, and "em" is Shift+e, Shift+m.
  local plain = { { 1, { { key(E) }, { key(M) } } }, { 2, { { key(E, Engine.SHIFT) }, { key(M, Engine.SHIFT) } } } }
  local locked = { { 2, { { key(E) }, { key(M) } } }, { 1, { { key(E, Engine.SHIFT) }, { key(M, Engine.SHIFT) } } } }
  local w = world(plain, locked)
  w.tap(E); w.tap(M)
  check("plain keys, either way", w.last(), "instant-snippets:7:1:2")
  w.resume()
  w.down(SHIFT_L); w.tap(E); w.tap(M); w.up(SHIFT_L)
  check("shifted keys, either way", w.last(), "instant-snippets:7:2:1")
end

do -- a trigger only Caps Lock spells that way, and a longer one without it
  local plain = { { 1, { { key(X) }, { key(E) }, { key(M) } } } }
  local locked = { { 2, { { key(E) }, { key(M) } } } }
  local w = world(plain, locked)
  w.tap(E); w.tap(M)
  check("only with caps lock", w.last(), "instant-snippets:7:0:2")
  w.resume()
  w.tap(X); w.tap(E); w.tap(M)
  check("each its longest", w.last(), "instant-snippets:7:1:2")
end

do -- Backspace right after a snippet takes it back
  local w = world()
  w.tap(E); w.tap(M)
  w.resume(true)
  w.tap(BACKSPACE)
  check("backspace undoes", w.last(), "instant-snippets:7:undo")
  w.resume(false)
  w.tap(BACKSPACE)
  check("only once", #w.events, 2)
end

do -- a snippet taken back can be typed again, where it is or after rubbing its trigger out
  local w = world({ { 1, { { key(E) }, { key(M) } } } }, nil, nil, true)
  w.tap(SPACE); w.tap(E); w.tap(M)
  w.resume(true)
  w.tap(BACKSPACE)
  check("undone", w.last(), "instant-snippets:7:undo")
  w.resume(false)
  -- "em" is back on the screen. Rub out the "m" and type it again:
  w.tap(BACKSPACE); w.tap(M)
  check("the last letter retyped", w.last(), "instant-snippets:7:1:0")
  w.resume(true)
  w.tap(BACKSPACE)
  w.resume(false)
  -- Rub the whole trigger out and type it again:
  w.tap(BACKSPACE); w.tap(BACKSPACE); w.tap(E); w.tap(M)
  check("the whole trigger retyped", #w.events, 5)
  check("expanded again", w.last(), "instant-snippets:7:1:0")
end

do -- but not after another key, a wait, a move to another window, or when nothing was typed
  local w = world()
  w.tap(E); w.tap(M); w.resume(true)
  w.tap(X); w.tap(BACKSPACE)
  check("another key first", #w.events, 1)
  w.tap(E); w.tap(M); w.resume(true)
  w.clock = w.clock + 4
  w.tap(BACKSPACE)
  check("too late", #w.events, 2)
  w.tap(E); w.tap(M); w.resume(true)
  w.handlers["window.active"]({ class = "other" })
  w.tap(BACKSPACE)
  check("another window", #w.events, 3)
  w.tap(E); w.tap(M); w.resume(false)
  w.tap(BACKSPACE)
  check("nothing to undo", #w.events, 4)
end

do -- windows to leave alone
  local w = world(nil, nil, { [Engine.class_key("org.keepassxc.KeePassXC")] = true })
  w.handlers["window.active"]({ class = "org.keepassxc.KeePassXC" })
  w.tap(E); w.tap(M)
  check("skipped window", #w.events, 0)
  w.handlers["window.active"]({ class = "foot" })
  w.tap(E); w.tap(M)
  check("back in another window", #w.events, 1)
  w.resume()
  -- What was typed in the skipped window is not kept for the next one.
  w.handlers["window.active"]({ class = "org.keepassxc.KeePassXC" })
  w.tap(E)
  w.handlers["window.active"]({ class = "foot" })
  w.tap(M)
  check("nothing carried out", #w.events, 1)
end

do -- keys without a time are wtype's, not the user's
  local w = world()
  w.tap(E)
  w.handlers["input.keyboard.key"](X, 0, 1); w.handlers["input.keyboard.key"](X, 0, 0)
  w.tap(M)
  check("timeless keys unseen", w.last(), "instant-snippets:7:2:0")
end

do -- a key pressed while the shell types got in among the snippet: no undo
  local w = world()
  w.tap(E); w.tap(M)
  w.engine.resume(true)
  w.tap(X)
  table.remove(w.timers)()
  w.tap(BACKSPACE)
  check("a key among the snippet withdraws the undo", #w.events, 1)
  w.tap(E); w.tap(M)
  check("and is not remembered", #w.events, 2)
end

do -- a match the shell hands back leaves what was typed as it was
  -- "em" is trigger 1 with Caps Lock; without it "!emx" is trigger 2.
  local plain = { { 2, { { key(ONE, Engine.SHIFT) }, { key(E) }, { key(M) }, { key(X) } } } }
  local locked = { { 1, { { key(E) }, { key(M) } } } }
  local w = world(plain, locked)
  w.bang(); w.tap(E); w.tap(M)
  check("the other spelling is reported", w.last(), "instant-snippets:7:0:1")
  w.engine.reject()
  w.tap(X)
  check("and the longer trigger still completes", w.last(), "instant-snippets:7:2:0")
end

do -- only at the start of a word, when asked
  local w = world({ { 1, { { key(E) }, { key(M) } } } }, nil, nil, true)
  w.tap(X); w.tap(E); w.tap(M)
  check("inside a word", #w.events, 0)
  w.tap(SPACE); w.tap(E); w.tap(M)
  check("after a space", w.last(), "instant-snippets:7:1:0")
  w.resume()
  w.tap(E); w.tap(M)
  check("not straight after a snippet", #w.events, 1)
  w.handlers["window.active"]({ class = "other" })
  w.tap(E); w.tap(M)
  check("in a fresh window", #w.events, 2)
  w.resume()
  w.tap(SPACE); w.tap(X); w.tap(BACKSPACE); w.tap(E); w.tap(M)
  check("after a corrected key", #w.events, 3)
end

do -- where what comes before is not known, a trigger led by punctuation still expands; a word does not
  -- "!m" is trigger 1 (led by punctuation), "em" trigger 2.
  local triggers = { { 1, { { key(ONE, Engine.SHIFT) }, { key(M) } }, 1 }, { 2, { { key(E) }, { key(M) } }, 0 } }
  -- A snippet is typed, got rid of as `prepare` does, and then one of the
  -- two triggers is tried, each from the same beginning.
  local function attempt(prepare, type)
    local w = world(triggers, nil, nil, true)
    w.tap(SPACE); w.tap(E); w.tap(M)
    w.resume()
    prepare(w)
    local seen = #w.events
    type(w)
    return #w.events > seen
  end
  local function typed_after(prepare)
    return attempt(prepare, function(w) w.tap(E); w.tap(M) end),
      attempt(prepare, function(w) w.bang(); w.tap(M) end)
  end
  local word, led = typed_after(function(w) w.tap(BACKSPACE); w.tap(BACKSPACE) end)
  check("rubbed out: the word does not expand", word, false)
  check("rubbed out: the punctuation-led trigger does", led, true)
  word, led = typed_after(function(w) w.down(CTRL_L); w.tap(X); w.up(CTRL_L); w.tap(DELETE) end)
  check("selected and deleted: the word does not expand", word, false)
  check("selected and deleted: the punctuation-led trigger does", led, true)
  word, led = typed_after(function(w) w.tap(LEFT) end)
  check("cursor moved: the punctuation-led trigger expands", led, true)
  -- Straight after the snippet, with nothing done, neither does: it would be inside what was typed.
  word, led = typed_after(function() end)
  check("straight after a snippet: neither", (word or led), false)
  -- A letter known to be before it still blocks the punctuation-led trigger.
  local w = world(triggers, nil, nil, true)
  w.tap(X); w.bang(); w.tap(M)
  check("inside a word, known", #w.events, 0)
end

do -- a word start is not assumed where the text before is unknown
  local w = world({ { 1, { { key(E) }, { key(M) } } } }, nil, nil, true)
  w.tap(X); w.tap(BACKSPACE); w.tap(BACKSPACE); w.tap(E); w.tap(M)
  check("rubbed out past what is remembered", #w.events, 0)
  w.tap(SPACE)
  w.time = w.time + 6000
  w.tap(E); w.tap(M)
  check("a pause after a space keeps the word start", #w.events, 1)
  w.resume()
  w.tap(SPACE); w.tap(X)
  w.time = w.time + 6000
  w.tap(E); w.tap(M)
  check("a pause inside a word does not make one", #w.events, 1)
  w.tap(SPACE); w.down(CTRL_L); w.tap(X); w.up(CTRL_L); w.tap(E); w.tap(M)
  check("nor does a shortcut", #w.events, 1)
end

do -- nothing is heard while a layer has the keyboard to itself
  local w = world()
  local menu = { address = "0x1", mapped = true, interactivity = 1 }
  w.tap(E)
  w.layers = { { address = "0x0", mapped = true, interactivity = 0 }, menu }
  w.handlers["layer.opened"](menu)
  w.tap(E); w.tap(M)
  check("deaf under a menu", #w.events, 0)
  w.handlers["layer.closed"](menu) -- still listed as it closes
  w.tap(E); w.tap(M)
  check("listening once it has gone", #w.events, 1)
end

do -- an Omarchy panel has the keyboard on demand; a toast opening over it changes nothing
  local w = world()
  local panel = { address = "0x1", mapped = true, interactivity = 2 }
  local toast = { address = "0x2", mapped = true, interactivity = 0 }
  w.layers = { panel }
  w.handlers["layer.opened"](panel)
  w.layers = { panel, toast }
  w.handlers["layer.opened"](toast)
  w.tap(E); w.tap(M)
  check("deaf in a panel, toast or not", #w.events, 0)
end

do -- the focus moving while the shell types withdraws the undo, and the shell is told once
  local w = world()
  w.tap(E); w.tap(M)
  w.handlers["window.active"]({ class = "other" })
  check("the shell is told", w.last(), "instant-snippets:7:moved")
  w.handlers["window.active"]({ class = "another" })
  check("only once", #w.events, 2)
  w.resume(true)
  w.tap(BACKSPACE)
  check("no undo into another window", #w.events, 2)
  -- A toast opening over the window is not a move.
  w.tap(E); w.tap(M)
  w.handlers["layer.opened"]({ address = "0x9", mapped = true, interactivity = 0 })
  check("a toast is not a move", w.last(), "instant-snippets:7:2:0")
end

do -- a match handed back after the focus moved restores nothing
  local plain = { { 2, { { key(E) }, { key(M) }, { key(X) } } } }
  local locked = { { 1, { { key(E) }, { key(M) } } } }
  local w = world(plain, locked)
  w.tap(E); w.tap(M)
  w.handlers["window.active"]({ class = "other" })
  w.engine.reject()
  w.tap(X)
  check("no trigger across two windows", w.last(), "instant-snippets:7:moved")
end

do -- held until it repeats, the last key does not expand whichever is let go first
  local w = world()
  w.tap(M); w.down(SHIFT_L); w.down(ONE); w.time = w.time + 400; w.up(SHIFT_L); w.up(ONE)
  check("Shift let go first", #w.events, 0)
end

do -- Caps Lock in the middle of a trigger breaks it; before one it is passed over
  local w = world()
  w.tap(E); w.tap(LOCK_KEY); w.tap(M)
  check("no trigger spans a Caps Lock", #w.events, 0)
  w.tap(LOCK_KEY); w.tap(E); w.tap(M)
  check("a Caps Lock before the trigger is not a key typed", w.last(), "instant-snippets:7:2:0")
end

do -- waiting for Shift does not outlast the pause after which keys are forgotten
  local w = world()
  w.tap(M); w.down(SHIFT_L); w.tap(ONE)
  w.clock = w.clock + 6
  w.tick()
  w.up(SHIFT_L)
  check("the wait lapses", #w.events, 0)
end

do -- a held last key does not expand when Shift comes up
  local w = world()
  w.tap(M); w.down(SHIFT_L); w.down(ONE); w.time = w.time + 400; w.up(ONE); w.up(SHIFT_L)
  check("held key cancels the wait", #w.events, 0)
end

do -- keys typed while the shell decides are not lost when it hands the match back
  local plain = { { 2, { { key(E) }, { key(M) }, { key(X) }, { key(X) } } } }
  local locked = { { 1, { { key(E) }, { key(M) } } } }
  local w = world(plain, locked)
  w.tap(E); w.tap(M)
  w.tap(X) -- before the shell has answered
  w.engine.reject()
  w.tap(X)
  check("the longer trigger completes", w.last(), "instant-snippets:7:2:0")
end

do -- what was typed is forgotten after a while even if no key follows
  local w = world()
  w.tap(E)
  w.clock = w.clock + 6
  w.tick()
  w.time = w.time + 100 -- the next key comes soon by Hyprland's clock
  w.tap(M)
  check("forgotten on the timer", #w.events, 0)
  w.engine.stop()
  check("the timer is stopped with the engine", w.ticking, false)
end

do -- a bar, which takes no keys, changes nothing
  local w = world()
  w.layers = { { address = "0x0", mapped = true, interactivity = 0 } }
  w.handlers["layer.opened"](w.layers[1])
  w.tap(E); w.tap(M)
  check("a bar is not in the way", #w.events, 1)
end

do -- stopping lets go of Hyprland
  local w = world()
  w.engine.stop()
  check("subscriptions removed", w.removed, 4)
  check("no key handler", w.handlers["input.keyboard.key"], nil)
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("engine: ok")
