-- The half of Instant Snippets that lives in Hyprland: it watches the keys
-- going by and tells the shell when the last few spell a trigger.
--
-- Hyprland hands every key to "input.keyboard.key" before the focused window
-- gets it, as a keycode. Service.qml works out which keycodes spell each
-- trigger on the active layout and starts this with nothing but numbers:
-- neither the triggers' characters nor the snippets' text ever come here.
--
-- What is kept is the last `max` keys, as numbers, and only until the focus
-- moves, the keyboard goes quiet, or a shortcut is pressed. Nothing is
-- written anywhere. The one thing sent out is "trigger number 3 was typed".
--
-- Caps Lock changes which keys spell a trigger ("!EM" is Shift+e, Shift+m
-- without it and plain e, m with it), and Hyprland's Lua cannot ask whether
-- it is on. So the engine is given both spellings, reports what the keys
-- spell either way, and the shell, which can ask, picks.
--
-- `hl` and the clock are passed in rather than taken from the globals, so
-- tests/engine.lua can drive this with stand-ins under plain Lua.

local M = {}

-- Modifier bits. A key is remembered as keycode * 4 + (SHIFT | LEVEL3), which
-- is what tells "1" from "!". SHORTCUT is Ctrl, Alt or Super: with one of
-- those down the key is a command, not text.
local SHIFT, LEVEL3, SHORTCUT = 1, 2, 4
M.SHIFT, M.LEVEL3, M.SHORTCUT = SHIFT, LEVEL3, SHORTCUT

-- config:
--   nonce         number the shell made up, echoed in every event
--   idle          ms of silence after which what was typed is forgotten
--   repeat_delay  ms a key is held before it starts repeating
--   busy_timeout  ms to wait for the shell to finish typing a snippet
--   modifiers     { [keycode] = SHIFT | LEVEL3 | SHORTCUT }
--   backspace     { [keycode] = true }
--   compose       { [keycode] = true }
--   triggers      { { id, { { key, key }, { key }, ... } }, ... }
--                 one list of alternative keys per character
--   locked        the same, for the keys that spell them with Caps Lock on
--   skipped       { [class_key(class)] = true } for the windows to leave alone
--   word_start    whether a trigger only counts at the start of a word
--   separators    { [key] = true } for the keys that end a word
--   moving        { [keycode] = true } for the keys that move the cursor or delete forward
--                 a trigger entry's third field is 1 when it begins with punctuation
-- A window's class as a number, so that the classes to leave alone can be
-- handed over as numbers too. Model.js's classKey() is the same sum.
function M.class_key(name)
  local key = 5381
  for i = 1, #name do key = (key * 33 + name:byte(i)) % 2147483647 end
  return key
end

function M.start(hl, config, clock)
  clock = clock or os.time
  local down = {}       -- keycode -> the second it went down
  local held = {}       -- modifier keycode -> its bit, while it is down
  local modifiers = 0   -- every bit in `held`
  local typed = {}      -- the last keys typed, oldest first
  local count = 0
  local max = 0         -- the longest trigger
  local pressed = {}    -- keycode -> when it went down, on Hyprland's clock
  local last = 0        -- when the last key went down
  local last_wall = 0   -- the same, in the clock's seconds
  local composing = 0   -- keys left that belong to a Compose sequence
  local busy = false    -- the shell is typing a snippet
  local paused = false  -- the focused window is one to leave alone
  local layered = false -- a launcher, panel or the like has the keyboard
  -- Whether what is remembered begins where a word begins: true, false, or
  -- "unknown" when the cursor has been moved or text deleted out of sight.
  local at_start = true
  local saved = nil     -- what was remembered when a match was handed over
  local disturbed = false -- a key was pressed while the shell was typing
  local told = false    -- the shell has been told the focus moved, this time round
  local before = nil    -- what was remembered when the last snippet's trigger was typed
  local undoing = false -- the shell is taking that snippet back
  local undo_until = 0  -- Backspace before this second takes the last snippet back
  local waiting = nil   -- a match held back until Shift is let go
  local round = 0       -- counts matches, so an old timeout cannot end a new one
  local subscriptions = {}

  -- An index lists, for a key, the triggers ending in it, longest first, so
  -- a key that ends no trigger costs one lookup.
  local function index(entries)
    local by_last = {}
    for _, entry in ipairs(entries) do
      local trigger = { id = entry[1], keys = {}, length = #entry[2], loose = entry[3] == 1 }
      for position, alternatives in ipairs(entry[2]) do
        local set = {}
        for _, key in ipairs(alternatives) do set[key] = true end
        trigger.keys[position] = set
      end
      if trigger.length > max then max = trigger.length end
      for key in pairs(trigger.keys[trigger.length]) do
        by_last[key] = by_last[key] or {}
        table.insert(by_last[key], trigger)
      end
    end
    for _, list in pairs(by_last) do
      table.sort(list, function(a, b) return a.length > b.length end)
    end
    return by_last
  end
  local plain = index(config.triggers)
  local locked = index(config.locked or {})
  -- One more key is remembered than the longest trigger has: the one before it.
  if config.word_start then max = max + 1 end

  local function ends_word(key)
    return (config.separators or {})[key] == true
  end

  -- Forgets what was typed. Whether what comes next begins a word is what
  -- `fresh` says (true for another window, false after a snippet, "unknown"
  -- after a shortcut or a move of the cursor); left out, it does if the
  -- last key remembered ended one.
  local function forget(fresh)
    if fresh ~= nil then at_start = fresh
    elseif count > 0 then at_start = ends_word(typed[count]) end
    for i = 1, count do typed[i] = nil end
    count = 0
    composing = 0
  end

  local function remember(key)
    if count == max then
      at_start = ends_word(table.remove(typed, 1))
    else
      count = count + 1
    end
    typed[count] = key
  end

  local function ends_with(trigger)
    if count < trigger.length then return false end
    local from = count - trigger.length
    -- At the start of a word: after a key that ends one, or, when nothing
    -- before the trigger is remembered, where a word is known to begin.
    if config.word_start then
      if from > 0 and not ends_word(typed[from]) then return false end
      -- Where it is not known what comes before, a trigger that begins with
      -- punctuation ("!em") is taken to start a word, since it would hardly
      -- be typed inside one; a trigger that is itself a word is not.
      if from == 0 and at_start ~= true and not (at_start == "unknown" and trigger.loose) then return false end
    end
    for position = 1, trigger.length do
      if not trigger.keys[position][typed[from + position]] then return false end
    end
    return true
  end

  local function refresh_modifiers()
    modifiers = 0
    for _, bit in pairs(held) do modifiers = modifiers | bit end
  end

  -- The longest trigger in an index that what was typed ends with.
  local function find(by_last, key)
    for _, trigger in ipairs(by_last[key] or {}) do
      if ends_with(trigger) then return trigger end
    end
  end

  -- Tells the shell something and stops listening until it reports back:
  -- what it types comes through here as keys too.
  local function hand_over(message)
    -- Kept in case the shell hands the match back: see engine.reject().
    saved = { keys = {}, count = count, at_start = at_start, since = {} }
    for i = 1, count do saved.keys[i] = typed[i] end
    -- An undo puts the trigger back on the screen, so what was remembered
    -- when it was typed is what will be true again.
    undoing = message == "undo"
    if not undoing then before = saved end
    busy = true
    disturbed = false
    told = false
    waiting = nil
    undo_until = 0
    forget(false)
    round = round + 1
    local mine = round
    hl.timer(function()
      if busy and round == mine then busy = false end
    end, { timeout = config.busy_timeout, type = "oneshot" })
    hl.dispatch(hl.dsp.event(string.format("instant-snippets:%d:%s", config.nonce, message)))
  end

  -- A match is what the keys spell without Caps Lock, with it, or both.
  local function announce(match)
    local off, on = match.plain, match.locked
    hand_over(string.format("%d:%d", off and off.id or 0, on and on.id or 0))
  end

  local function released(keycode, time)
    if held[keycode] then
      held[keycode] = nil
      refresh_modifiers()
    else
      -- A key held until it repeated typed more than the one key seen here.
      local since = pressed[keycode]
      pressed[keycode] = nil
      if since and time - since >= config.repeat_delay then
        waiting = nil
        forget()
      end
    end
    if waiting and modifiers == 0 then
      -- A key still down long enough to be repeating has typed more than
      -- the trigger: the match is off.
      for _, since in pairs(pressed) do
        if time - since >= config.repeat_delay then
          waiting = nil
          return forget()
        end
      end
      announce(waiting)
    end
  end

  local function key_down(keycode, time)
    local bit = config.modifiers[keycode]
    if bit then
      held[keycode] = bit
      refresh_modifiers()
      -- Caps Lock and its kind type nothing, but what comes after one is
      -- typed in another state than what came before: no trigger spans it.
      if bit == 0 and count > 0 then
        waiting = nil
        forget()
      end
      return
    end

    -- Typing went on before Shift came up: the trigger is no longer the end
    -- of what was typed.
    if waiting then
      waiting = nil
      forget()
    end
    if time - last > config.idle then forget() end
    last_wall = clock()
    last = time
    pressed[keycode] = time

    -- Backspace as the first key after a snippet, and soon after it, takes
    -- the snippet back. Any other key means it was wanted.
    if undo_until > 0 then
      local offered = clock() <= undo_until
      undo_until = 0
      if offered and modifiers == 0 and config.backspace[keycode] then return hand_over("undo") end
      -- The offer is over: what was kept to put back is kept no longer.
      before = nil
    end

    if modifiers >= SHORTCUT then return forget("unknown") end
    -- An arrow, Home, End, Delete: the cursor is somewhere else now, or the
    -- text after it is gone.
    if (config.moving or {})[keycode] then return forget("unknown") end
    if config.backspace[keycode] then
      if count > 0 then
        typed[count] = nil
        count = count - 1
      else
        -- Rubbed out further back than is remembered: into what, is not known.
        at_start = "unknown"
      end
      return
    end
    -- Compose and the two keys after it make one character.
    if config.compose[keycode] then
      forget(false)
      composing = 2
      return
    end
    if composing > 0 then
      composing = composing - 1
      return
    end

    local key = keycode * 4 + modifiers
    remember(key)
    local match = { plain = find(plain, key), locked = find(locked, key) }
    if not match.plain and not match.locked then return end
    -- A modifier still down would join the keys the shell types.
    if modifiers == 0 then announce(match) else waiting = match end
  end

  -- An input method (fcitx5, on Omarchy) is handed each key and sends it back
  -- through a keyboard of its own, so the same press and release arrive
  -- twice. A key that is already down cannot go down again, which tells the
  -- echo apart whatever causes it. Should a release ever be missed, the key
  -- counts as up again after a few seconds.
  local function seen_before(keycode, state)
    if state == 1 then
      local now = clock()
      if down[keycode] and now - down[keycode] < 3 then return true end
      down[keycode] = now
      return false
    end
    if not down[keycode] then return true end
    down[keycode] = nil
    return false
  end

  subscriptions[1] = hl.on("input.keyboard.key", function(keycode, time, state)
    if state ~= 0 and state ~= 1 then return end
    -- Keys that wtype types carry no time, and are nobody's typing.
    if time == 0 then return end
    if seen_before(keycode, state) then return end
    if busy or paused or layered then
      -- Not text to match, but Shift pressed or let go now is still Shift
      -- when the shell is done or the focus has moved on.
      local bit = config.modifiers[keycode]
      if bit then
        held[keycode] = state == 1 and bit or nil
        refresh_modifiers()
      elseif busy and state == 1 then
        -- It reached the window among what the shell typed: what is there
        -- now is no longer just the snippet, and Backspace cannot undo it.
        disturbed = true
        -- Should the shell hand the match back, this key was typed too; a
        -- shortcut among them makes what was typed unknown.
        if saved then
          if modifiers >= SHORTCUT then saved.moved = true end
          saved.since[#saved.since + 1] = keycode * 4 + (modifiers & (SHIFT | LEVEL3))
        end
      end
      pressed[keycode] = nil
      return
    end
    if state == 1 then key_down(keycode, time) else released(keycode, time) end
  end)

  -- Whether the focused window is one to leave alone.
  local function look(window)
    if not window and hl.get_active_window then window = hl.get_active_window() end
    local name = window and window.class
    paused = type(name) == "string" and (config.skipped or {})[M.class_key(name)] == true
  end

  -- A trigger does not carry over from one window to the next, and neither
  -- does the offer to take a snippet back.
  -- The focus moved while the shell was typing or deciding: the snippet is
  -- not one to undo, a match handed back is not restored, and the shell is
  -- told, once, so that it stops typing into wherever the focus went.
  local function moved()
    if not busy then return end
    if saved then saved.moved = true end
    if not told then
      told = true
      hl.dispatch(hl.dsp.event(string.format("instant-snippets:%d:moved", config.nonce)))
    end
    disturbed = true
  end

  subscriptions[2] = hl.on("window.active", function(window)
    moved()
    waiting = nil
    undo_until = 0
    if not busy then before = nil end
    forget(true)
    look(window)
  end)
  look(nil)

  -- A layer that takes the keyboard for itself (a launcher, a menu, a panel,
  -- this plugin's own) is not a place to expand snippets or to remember
  -- what is typed. `closing` is a layer on its way out, still listed.
  local function look_at_layers(closing)
    layered = false
    if not hl.get_layers then return end
    for _, layer in ipairs(hl.get_layers()) do
      local gone = closing and layer.address == closing.address
      -- Omarchy's panels take the keyboard outright for a moment and on
      -- demand after that; either way keys can be going to them.
      if not gone and layer.mapped ~= false and (layer.interactivity or 0) ~= 0 then layered = true end
    end
  end

  subscriptions[3] = hl.on("layer.opened", function(layer)
    -- A toast or the like takes no keys and no focus.
    if not layer or (layer.interactivity or 0) ~= 0 then moved() end
    waiting = nil
    undo_until = 0
    forget(true)
    look_at_layers(nil)
  end)
  subscriptions[4] = hl.on("layer.closed", function(layer)
    forget(true)
    look_at_layers(layer)
  end)
  look_at_layers(nil)

  -- What was typed is forgotten after a while without a key, whether or not
  -- another key ever comes: this looks every so often.
  local idle_seconds = math.max(1, math.floor(config.idle / 1000))
  local stopped = false
  local idle_timer = hl.timer(function()
    if stopped or busy then return end
    if undo_until > 0 and clock() > undo_until then
      undo_until = 0
      before = nil
    end
    if clock() - last_wall < idle_seconds then return end
    waiting = nil
    if count > 0 then forget() end
  end, { timeout = config.idle, type = "repeat" })

  local engine = { nonce = config.nonce }

  -- The shell has finished typing. `undoable` when what it typed was a
  -- snippet, which Backspace may now take back.
  -- An input method is still handing back the last keys typed for a moment
  -- after wtype has gone; listening again at once would take those for the
  -- user's, and the first of them would turn down the offer to undo.
  function engine.resume(undoable)
    local mine = round
    saved = nil
    hl.timer(function()
      if not busy or round ~= mine then return end
      busy = false
      if undoing and before and not disturbed then
        -- The trigger is back where it was: it can be corrected, or rubbed
        -- out and typed again, and will expand as it did the first time.
        for i = 1, before.count do typed[i] = before.keys[i] end
        count = before.count
        at_start = before.at_start
        composing = 0
      else
        -- What was typed ends wherever the snippet ended, not at a word's start.
        forget(false)
      end
      undoing = false
      if not undoable then before = nil end
      undo_until = undoable and not disturbed and clock() + 3 or 0
    end, { timeout = config.settle or 150, type = "oneshot" })
  end

  -- The shell did nothing with the match: the keys spelled a trigger only in
  -- the other Caps Lock state. They are remembered again as they were, so a
  -- longer trigger they are the beginning of can still be typed out.
  function engine.reject()
    if not busy or not saved then return end
    -- The focus went elsewhere meanwhile: nothing of it carries over.
    if saved.moved then
      saved = nil
      busy = false
      return forget(true)
    end
    for i = 1, saved.count do typed[i] = saved.keys[i] end
    count = saved.count
    at_start = saved.at_start
    local since = saved.since
    saved = nil
    busy = false
    -- Keys typed while the shell was making up its mind. A Backspace among
    -- them is not worth following: what was typed is then simply forgotten.
    for _, key in ipairs(since) do
      if config.backspace[key // 4] then return forget(false) end
      remember(key)
    end
  end

  function engine.stop()
    for _, subscription in ipairs(subscriptions) do subscription:remove() end
    subscriptions = {}
    stopped = true
    if idle_timer and idle_timer.set_enabled then idle_timer:set_enabled(false) end
    busy = false
    waiting = nil
    forget()
  end

  return engine
end

return M
