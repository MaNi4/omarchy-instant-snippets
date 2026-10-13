import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model
import "Store.js" as Store

// Owns the snippets and keeps engine.lua running in Hyprland with the keys
// that spell their triggers. When the engine reports a trigger, this rubs it
// out and types the replacement.
//
// Nothing here reads the keyboard. Hyprland hands each key to the engine,
// inside Hyprland; the engine tells this service which trigger was typed, by
// number.
//
// Mounted once for the shell; Panel.qml is a view of it on each monitor.
Item {
  id: service
  visible: false

  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    return decodeURIComponent(s.indexOf("file://") === 0 ? s.substring(7) : s)
  }
  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string defaultPath: home + "/.config/omarchy/extensions/" + Model.DATA_FILE
  // Where the snippets file is kept, as it was typed in the settings: a
  // folder, or the file itself. "" is the usual place. It is noted in a file
  // that stays here, wherever the snippets go.
  readonly property string locationPath: home + "/.config/omarchy/extensions/instant-snippets.location"
  property string location: ""
  property bool located: false      // the note has been read: it is known where the snippets are
  property string locationError: "" // the note cannot be gone by
  // The file could not be taken where it was last asked to go. Said beside
  // what was typed for it, until that is changed.
  property string moveError: ""
  readonly property string configPath: Model.dataFile(location, home).path || defaultPath
  // The plan the engine is started from spells the triggers out as key
  // numbers, so it goes in a file of the user's own, in a directory that is
  // gone at logout, and never in a process's arguments. No fallback: without
  // a runtime directory there is nowhere private to put it.
  readonly property string runtimeDir: String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  readonly property string planPath: runtimeDir + "/instant-snippets/plan.lua"

  // ---------- Snippets and settings ----------
  property bool expanding: true
  property bool shiftEnter: true    // line breaks typed as Shift+Enter
  property bool undoing: true       // Backspace right after a snippet takes it back
  property bool wordStart: true     // triggers expand only at the start of a word
  property string dateFormat: Model.DATE_FORMATS[0]   // what {date} looks like
  property string timeFormat: Model.TIME_FORMATS[0]   // what {time} looks like
  property var skipped: []          // classes of the windows to leave alone
  property var snippets: []         // [{ trigger, replacement }]
  property string configError: ""
  // Entries of the file that are not usable snippets. While there are any
  // the file is not written, which would lose them.
  property int dropped: 0
  property string saveError: ""

  function applyConfig(text) {
    var config = Model.parseConfig(text)
    service.expanding = config.enabled
    service.shiftEnter = config.shiftEnter
    service.undoing = config.undo
    service.wordStart = config.wordStart
    service.dateFormat = config.dateFormat
    service.timeFormat = config.timeFormat
    service.skipped = config.skipped
    service.snippets = config.snippets
    service.dropped = config.dropped
    service.configError = config.error
    service.settling = false
    service.schedule()
  }

  FileView {
    id: locationFile
    path: service.locationPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      // Written by hand it may be open to others: closed to them, as the snippets file is.
      Quickshell.execDetached(Model.tightening(service.locationPath))
      service.applyLocation(text())
    }
    onLoadFailed: function(error) { service.applyLocation("") }
    onFileChanged: reload()
  }

  // A note that cannot be gone by is not gone by: the usual place it is.
  function applyLocation(text) {
    if (service.relocation) return
    var note = Model.noted(text, service.home)
    service.locationError = note.error
    // The note was changed from outside: what is here was read from the old
    // place, and is not to be written over the file at the new one.
    if (service.located && (Model.dataFile(note.location, service.home).path || service.defaultPath) !== service.configPath) {
      service.unsaved = ""
      service.settling = true
    }
    service.location = note.location
    service.located = true
  }

  FileView {
    id: configFile
    // Nothing is read until it is known where from.
    path: service.located ? service.configPath : ""
    watchChanges: true
    printErrors: false
    onLoaded: {
      // The file is on its way elsewhere: what is read next is what counts.
      if (moveProc.running) return
      // A file made or edited by hand may be open to others: it is closed
      // to them every time it is read.
      Quickshell.execDetached(Model.tightening(service.configPath))
      service.applyConfig(text())
    }
    // No file yet, in the usual place, is no snippets yet. A file that is
    // there and cannot be read is not, and nor is one missing from a place
    // it was taken to: taking either for empty would have the next save
    // replace it.
    onLoadFailed: function(error) {
      if (moveProc.running) return
      var why = error === FileViewError.FileNotFound ? Model.absent(service.location) : "unreadable"
      // Looked for again, and still not there.
      if (why === "missing" && service.configError === why) { service.settling = false; return }
      service.applyConfig("")
      service.configError = why
    }
    onFileChanged: reload()
  }

  // A folder that comes back by being mounted is not reported as a change,
  // so a file that is missing is looked for again now and then.
  Timer {
    interval: 5000
    repeat: true
    running: service.configError === "missing"
    onTriggered: configFile.reload()
  }

  // The file holds whatever the snippets expand to, so it is created readable
  // by its owner only, and replaced in one step. The text goes in on stdin.
  // Only the latest state waits to be written.
  property string unsaved: ""

  function save() {
    if (service.configError !== "" || service.dropped > 0) return
    // What is here is about to give way to the file at the new place, and
    // must not be written over it.
    if (service.relocation || service.settling) return
    service.schedule()
    service.unsaved = Model.formatConfig({ enabled: service.expanding, shiftEnter: service.shiftEnter,
      undo: service.undoing, wordStart: service.wordStart, dateFormat: service.dateFormat,
      timeFormat: service.timeFormat, skipped: service.skipped, snippets: service.snippets })
    service.pumpSave()
  }

  function pumpSave() {
    if (saveProc.running || moveProc.running) return
    if (service.unsaved === "") {
      // Everything is written where it was: now the file can go elsewhere.
      var to = service.relocation
      if (!to) return
      moveProc.command = Model.moving(to.from, to.path, service.locationPath, to.typed)
      moveProc.running = true
      return
    }
    saveProc.payload = service.unsaved
    service.unsaved = ""
    saveProc.stdinEnabled = true
    saveProc.running = true
  }

  Process {
    id: saveProc
    property string payload: ""
    command: Model.writing(service.configPath, false)
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onRunningChanged: running ? saveWatchdog.restart() : saveWatchdog.stop()
    onExited: function(exitCode) {
      service.saveError = exitCode === 0 ? "" : "Failed to save the snippets file."
      service.pumpSave()
    }
  }

  // A write that hangs is stopped and reported, not waited on for ever.
  Timer {
    id: saveWatchdog
    interval: 5000
    onTriggered: {
      saveProc.running = false
      service.saveError = "Failed to save the snippets file."
    }
  }

  // ---------- Moving the snippets file ----------
  // What is to become the location, while the file is taken there:
  // { from, path, typed }.
  property var relocation: null
  // The file at the new place has not been read yet.
  property bool settling: false

  // Keeps the snippets file at `typed` from now on: see Model.dataFile().
  // Returns why not, "" when it does or is on its way to.
  function setLocation(typed) {
    var text = String(typed || "").trim()
    var found = Model.dataFile(text, service.home)
    if (found.error !== "") return found.error
    if (found.path === "" || found.path === service.defaultPath) text = ""
    var path = found.path || service.defaultPath
    if (!service.located || service.relocation || service.settling) return "Still busy with the last change."
    service.moveError = ""
    if (path === service.configPath) return ""
    service.relocation = { from: service.configPath, path: path, typed: text }
    service.pumpSave()
    return ""
  }

  Process {
    id: moveProc
    onRunningChanged: running ? moveWatchdog.restart() : moveWatchdog.stop()
    onExited: function(exitCode) {
      var to = service.relocation
      service.relocation = null
      if (!to) return
      if (exitCode !== 0) {
        service.moveFailed()
        return
      }
      service.settling = true
      service.location = to.typed
    }
  }

  // A folder that does not answer, on a network say, is given up on.
  Timer {
    id: moveWatchdog
    interval: 10000
    onTriggered: {
      service.relocation = null
      moveProc.running = false
      service.moveFailed()
    }
  }

  // The file is where the note says, which a move stopped halfway may have
  // written already, and may have been reported as changed meanwhile.
  function moveFailed() {
    service.moveError = "Failed to use that location. Check that it can be written to."
    locationFile.reload()
    configFile.reload()
  }

  function add(trigger, replacement) {
    service.snippets = service.snippets.concat([{ trigger: trigger, replacement: replacement }])
    service.save()
  }

  function replace(index, trigger, replacement) {
    if (index < 0 || index >= service.snippets.length) return
    var next = service.snippets.slice()
    next[index] = { trigger: trigger, replacement: replacement }
    service.snippets = next
    service.save()
  }

  function remove(index) {
    if (index < 0 || index >= service.snippets.length) return
    var next = service.snippets.slice()
    next.splice(index, 1)
    service.snippets = next
    service.save()
  }

  function setExpanding(expanding) {
    service.expanding = expanding
    service.save()
  }

  function setShiftEnter(shiftEnter) {
    service.shiftEnter = shiftEnter
    service.save()
  }

  function setUndoing(undoing) {
    service.undoing = undoing
    service.save()
  }

  function setWordStart(wordStart) {
    service.wordStart = wordStart
    service.save()
  }

  function nextDateFormat() {
    service.dateFormat = Model.nextFormat(Model.DATE_FORMATS, service.dateFormat)
    service.save()
  }

  function nextTimeFormat() {
    service.timeFormat = Model.nextFormat(Model.TIME_FORMATS, service.timeFormat)
    service.save()
  }

  // Whether snippets expand in windows of this class.
  function setSkipped(name, skip) {
    service.skipped = Model.skipping(service.skipped, name, skip)
    service.save()
  }

  // ---------- The engine in Hyprland ----------
  property var layout: null        // the layout the triggers are spelled for
  property string switched: ""     // the real keyboard that last reported a layout change
  property var answers: ({})       // layout id -> { "char:!": ways, "name:Shift_L": ways }
  property var active: []          // for each trigger number the engine knows, its snippet as it was planned
  property var untypable: []       // snippet indexes the layout has no keys for
  property int nonce: 0            // names the engine this service started
  property bool listening: false
  property string engineError: ""
  property string installed: ""    // the fingerprint of the plan the engine runs

  // A plan is made of several processes run one after another. `plan` names
  // the one in hand; each process remembers which it was started for, so
  // what comes back for one that was given up is not taken for the next.
  property int plan: 0
  property int reloads: 0          // times Hyprland has reloaded its config, and dropped the engine
  property bool planning: false
  property bool planAgain: false
  property var planned: null       // what the plan in hand is for: { snippets, skipped, wordStart }
  property var pending: []         // questions still to ask xkbcli

  // Several things can ask for a new plan at once (every keyboard reports a
  // layout change), and a reloaded plugin's old instance needs a moment to
  // take its engine down first.
  function schedule() { planTimer.restart() }

  Timer {
    id: planTimer
    interval: 400
    onTriggered: service.startPlan()
  }

  function startPlan() {
    if (service.planning) { service.planAgain = true; return }
    if (!service.expanding || service.snippets.length === 0) { service.halt(); return }
    if (service.runtimeDir === "") {
      service.halt()
      service.engineError = "XDG_RUNTIME_DIR is not set."
      return
    }
    service.plan += 1
    service.planning = true
    service.planned = { snippets: service.snippets, skipped: service.skipped, wordStart: service.wordStart,
      reloads: service.reloads }
    planWatchdog.restart()
    devicesProc.plan = service.plan
    devicesProc.running = true
  }

  function endPlan() {
    service.planning = false
    service.planned = null
    planWatchdog.stop()
    if (service.planAgain) { service.planAgain = false; service.schedule() }
  }

  // A tool that is missing or hangs must not leave the service stuck: the
  // step it was on is given eight seconds, then everything of this plan is
  // stopped.
  Timer {
    id: planWatchdog
    interval: 8000
    onTriggered: {
      service.plan += 1
      devicesProc.running = false
      keysProc.running = false
      planFileProc.running = false
      evalProc.running = false
      // Whether the engine was started or not is no longer known.
      service.listening = false
      service.installed = ""
      service.failPlan("Failed to read the keyboard layout.")
    }
  }

  // A plan that failed (a tool slow to answer at login, say) is tried again
  // a little later, a few times, rather than left until something changes.
  property int retries: 0

  function failPlan(message) {
    service.engineError = message
    service.tell(message)
    if (service.retries < 3) {
      service.retries += 1
      retryTimer.restart()
    }
    service.endPlan()
  }

  function planDone() {
    service.engineError = ""
    service.retries = 0
    retryTimer.stop()
  }

  Timer {
    id: retryTimer
    interval: 30000
    onTriggered: service.schedule()
  }

  // Something went wrong while the panel is most likely shut and the user in
  // another window, so it is said in a notification: a fixed sentence, never
  // a trigger or a replacement, and not more than once a minute.
  function tell(message) {
    if (quiet.running) return
    quiet.start()
    Quickshell.execDetached(["notify-send", "-a", "Instant Snippets", "--", "Instant Snippets", message])
  }

  Timer {
    id: quiet
    interval: 60000
  }

  function halt() {
    Quickshell.execDetached(["hyprctl", "eval", Model.stop()])
    if (service.runtimeDir !== "") Quickshell.execDetached(["rm", "-f", "--", service.planPath])
    service.listening = false
    service.installed = ""
    service.active = []
    service.untypable = []
    service.engineError = ""
  }

  Process {
    id: devicesProc
    property int plan: 0
    command: ["hyprctl", "devices", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (devicesProc.plan === service.plan) service.askKeys(Model.activeLayout(String(text || ""), service.switched))
      }
    }
  }

  function askKeys(layout) {
    if (!layout) {
      service.engineError = "No keyboard was found."
      service.endPlan()
      return
    }
    service.layout = layout
    var known = service.answers[layout.id] || {}
    service.pending = Model.questions(service.planned.snippets).filter(function(q) {
      return known[Model.slot(q.what, q.named)] === undefined
    })
    service.askSome()
  }

  // A few hundred questions in a run, each run with the time limit to
  // itself and its answers kept, so that triggers in many scripts take
  // longer to look up and do not fail.
  function askSome() {
    if (service.pending.length === 0) { service.install(); return }
    planWatchdog.restart()
    keysProc.plan = service.plan
    keysProc.asked = service.pending.slice(0, Model.ASK_AT_ONCE)
    service.pending = service.pending.slice(Model.ASK_AT_ONCE)
    keysProc.command = Model.asking(service.layout, keysProc.asked)
    keysProc.running = true
  }

  Process {
    id: keysProc
    property int plan: 0
    property var asked: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (keysProc.plan !== service.plan) return
        var answered = Model.parseAnswers(String(text || ""), keysProc.asked)
        var known = Object.assign({}, service.answers[service.layout.id] || {}, answered || {})
        // No layout is without a Backspace key: xkbcli is missing or failed.
        if (!answered || (known["name:BackSpace"] || []).length === 0) {
          service.pending = []
          service.failPlan("Failed to read the keyboard layout.")
          return
        }
        var all = Object.assign({}, service.answers)
        all[service.layout.id] = known
        service.answers = all
        service.askSome()
      }
    }
  }

  function install() {
    var planned = service.planned
    // Nothing the engine goes by has changed: leave it, and whatever it has
    // seen typed so far, alone.
    var fingerprint = Model.fingerprint(service.layout, planned.snippets, planned.skipped, planned.wordStart)
    var nonce = Math.floor(Math.random() * 2000000000) + 1
    var made = Model.plan(planned.snippets, service.answers[service.layout.id] || {},
      { engine: service.pluginDir + "engine.lua", nonce: nonce, skipped: planned.skipped, wordStart: planned.wordStart })
    if (service.listening && fingerprint === service.installed) {
      // The triggers are the same, so the engine's numbers still stand; what
      // they expand to may have been edited, and is taken afresh.
      service.active = made.active.map(function(index) { return planned.snippets[index] })
      service.untypable = made.untypable
      service.planDone()
      service.finishPlan()
      return
    }
    if (made.lua === "") {
      service.halt()
      service.untypable = made.untypable
      service.finishPlan()
      return
    }
    planWatchdog.restart()
    planFileProc.plan = service.plan
    planFileProc.payload = made.lua
    planFileProc.made = { nonce: nonce, untypable: made.untypable, fingerprint: fingerprint,
      active: made.active.map(function(index) { return planned.snippets[index] }) }
    planFileProc.stdinEnabled = true
    planFileProc.running = true
  }

  // The plan was made for the snippets as they were when it began. If they
  // have changed since, what was just installed is already out of date.
  function finishPlan() {
    var planned = service.planned
    if (planned && (planned.snippets !== service.snippets || planned.skipped !== service.skipped
        || planned.wordStart !== service.wordStart)) service.planAgain = true
    // Hyprland reloaded while this plan was being made: what it installed is gone.
    if (planned && planned.reloads !== service.reloads) {
      service.listening = false
      service.installed = ""
      service.planAgain = true
    }
    service.endPlan()
  }

  // Writes the plan where only the user can read it, then has Hyprland load it.
  Process {
    id: planFileProc
    property int plan: 0
    property string payload: ""
    property var made: null
    command: Model.writing(service.planPath, true)
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (planFileProc.plan !== service.plan) return
      if (exitCode !== 0) {
        service.failPlan("Failed to start text expansion in Hyprland.")
        return
      }
      planWatchdog.restart()
      evalProc.plan = service.plan
      evalProc.command = ["hyprctl", "eval", Model.loader(service.planPath)]
      evalProc.running = true
    }
  }

  Process {
    id: evalProc
    property int plan: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (evalProc.plan !== service.plan) return
        var made = planFileProc.made
        service.listening = String(text || "").trim() === "ok"
        service.engineError = service.listening ? "" : "Failed to start text expansion in Hyprland."
        service.installed = service.listening ? made.fingerprint : ""
        service.nonce = service.listening ? made.nonce : 0
        service.active = service.listening ? made.active : []
        service.untypable = made.untypable
        if (service.listening) {
          service.planDone()
        } else {
          console.warn("instant-snippets: Hyprland did not load the engine")
          if (service.retries < 3) { service.retries += 1; retryTimer.restart() }
        }
        service.finishPlan()
      }
    }
  }

  // ---------- Typing a snippet ----------
  // The engine reports what the keys spell without Caps Lock and with it,
  // or that Backspace was pressed right after a snippet. Before anything is
  // typed Hyprland is asked whether the session is locked (nothing goes into
  // a lock screen), and, when the two spellings differ, whether Caps Lock is
  // on.
  property var matchedEvent: null
  // The snippet typed last, for Backspace to take back: { trigger, replacement }.
  property var last: null

  function resume(undoable) {
    Quickshell.execDetached(["hyprctl", "eval", Model.resume(undoable)])
  }

  function matched(data) {
    var event = Model.parseEvent(data)
    if (!event || event.nonce !== service.nonce) return
    // The focus went elsewhere while a snippet was being typed: the rest of
    // it is not typed into wherever that is, and it is not one to undo.
    if (event.moved) {
      service.typed = null
      service.last = null
      // Still deciding what the keys spelled: nothing is typed at all.
      if (service.matchedEvent) service.abandon()
      else service.steps = []
      return
    }
    if (service.matchedEvent || service.stepWaiting || stepProc.running || service.steps.length > 0) return
    service.matchedEvent = event
    stepWatchdog.restart()
    lockProc.running = true
  }

  // Asked before a match is acted on, and again before each step of typing:
  // a session locked halfway through a long snippet gets no more of it.
  Process {
    id: lockProc
    command: ["hyprctl", "locked"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Anything but a plain "no" is taken for locked.
        var unlocked = String(text || "").trim() === "false"
        if (service.stepWaiting) {
          service.stepWaiting = false
          if (unlocked) service.runStep()
          else { service.last = null; service.abandon() }
          return
        }
        var event = service.matchedEvent
        if (!event) return
        if (!unlocked) { service.abandon(); return }
        if (event.undo) { service.matchedEvent = null; service.undo(); return }
        if (event.plain === event.locked) {
          service.matchedEvent = null
          service.expand(event.plain)
          return
        }
        capsProc.running = true
      }
    }
  }

  Process {
    id: capsProc
    command: ["hyprctl", "devices", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var event = service.matchedEvent
        service.matchedEvent = null
        if (!event) return
        service.expand(Model.capsLock(String(text || "")) ? event.locked : event.plain)
      }
    }
  }

  // Nothing is typed, and the engine forgets what led here.
  function abandon() {
    stepWatchdog.stop()
    service.matchedEvent = null
    service.stepWaiting = false
    service.steps = []
    service.typed = null
    service.resume(false)
  }

  function expand(match) {
    // The keys spell a trigger only in the other Caps Lock state: the engine
    // gets them back as they were.
    if (match === 0) {
      stepWatchdog.stop()
      Quickshell.execDetached(["hyprctl", "eval", Model.reject()])
      return
    }
    // The snippet as the engine's plan has it: the list may have changed
    // since, and a number would then point at another one.
    var snippet = service.active[match - 1]
    if (!snippet) { service.abandon(); return }
    var length = Model.characters(snippet.trigger).length
    // {date} and {time} in the formats chosen in the settings; {cursor} is
    // where the cursor is left, which Backspace could not undo from.
    var now = new Date()
    var filled = Model.render(snippet.replacement, {
      date: Qt.formatDate(now, service.dateFormat),
      time: Qt.formatTime(now, service.timeFormat)
    })
    var undoable = service.undoing && filled.back === 0 && Model.undoable(filled.text, service.shiftEnter)
    service.typed = undoable ? { trigger: snippet.trigger, replacement: filled.text } : null
    service.steps = Model.expanding(length, filled.text, service.shiftEnter, filled.back)
    service.nextStep()
  }

  // Backspace right after a snippet: what is left of it is rubbed out and
  // the trigger put back, as if it had never expanded.
  function undo() {
    var snippet = service.last
    service.last = null
    if (!snippet) { service.abandon(); return }
    service.typed = null
    service.steps = Model.undoing(snippet.replacement, snippet.trigger)
    service.nextStep()
  }

  // What is still to run for the snippet being typed: see Model.steps().
  // `typed` is that snippet when Backspace may take it back, else null.
  property var steps: []
  property var typed: null
  property string typingError: ""

  function nextStep() {
    if (service.steps.length === 0) {
      stepWatchdog.stop()
      service.typingError = ""
      service.last = service.typed
      service.typed = null
      service.resume(service.last !== null)
      return
    }
    stepWatchdog.restart()
    service.stepWaiting = true
    lockProc.running = true
  }

  property bool stepWaiting: false

  function runStep() {
    if (service.steps.length === 0) { service.abandon(); return }
    var step = service.steps[0]
    service.steps = service.steps.slice(1)
    stepProc.command = step.command
    stepProc.input = step.input === undefined ? "" : step.input
    stepProc.stdinEnabled = step.input !== undefined
    stepWatchdog.restart()
    stepProc.running = true
  }

  // wtype or hyprctl failed, is missing, or hangs: whatever is still running
  // is stopped, what is left of the snippet is given up, the engine is let
  // listen again, and the user is told.
  function typingFailed() {
    lockProc.running = false
    capsProc.running = false
    stepProc.running = false
    service.last = null
    service.typingError = "Failed to insert the snippet."
    service.tell(service.typingError)
    service.abandon()
  }

  Timer {
    id: stepWatchdog
    interval: 10000
    onTriggered: service.typingFailed()
  }

  // Runs one step. A step's text reaches wtype on stdin, so it never shows
  // in a process list. The engine was told to ignore keys meanwhile, and is
  // told it can listen again after the last step.
  Process {
    id: stepProc
    property string input: ""
    onStarted: {
      if (!stdinEnabled) return
      write(input)
      input = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      // Stopped by typingFailed(), which has already dealt with it.
      if (!stepWatchdog.running) return
      exitCode === 0 ? service.nextStep() : service.typingFailed()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name)
      if (name === "custom") service.matched(String(event.data))
      // Hyprland forgets the engine when its config reloads, and the keys
      // that spell a trigger change with the layout.
      else if (name === "configreloaded") {
        // The engine is gone whatever a plan under way may conclude.
        service.reloads += 1
        service.listening = false
        service.installed = ""
        service.schedule()
      } else if (name === "activelayout" && Model.realKeyboard(event.data)) {
        service.switched = Model.switchedKeyboard(event.data)
        service.schedule()
      }
    }
  }

  Component.onCompleted: Store.set(service)

  // Disabling, removing or reloading the plugin takes its engine with it,
  // but not one a newer instance has already started.
  Component.onDestruction: {
    Store.clear(service)
    if (service.nonce > 0) Quickshell.execDetached(["hyprctl", "eval", Model.stop(service.nonce)])
    // One whose start was still under way, or outlived its time limit,
    // would be left behind otherwise.
    var starting = planFileProc.made ? planFileProc.made.nonce : 0
    if (starting > 0 && starting !== service.nonce) Quickshell.execDetached(["hyprctl", "eval", Model.stop(starting)])
  }
}
