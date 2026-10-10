import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model
import "Store.js" as Store
import qs.Ui
import qs.Commons

// The snippets, in two views of one panel. The list: a filter, the snippets
// one to a line in a box that scrolls, and the switch that stops the
// expanding. The editor: a trigger and the text it becomes, as many lines as
// it needs. Service.qml owns the snippets and the engine in Hyprland; this
// widget exists once per monitor and shows them.
// Theme colours, stock qs.Ui parts.
Panel {
  id: root

  moduleName: "mani4.instant-snippets"
  ipcTarget: "mani4.instant-snippets"

  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  // Every colour text is drawn in is held to a contrast of 4.5 to 1 against
  // the panel, whatever the theme: see "Colours that can be read" in Model.js.
  readonly property color surface: Color.popups.background
  // A row under the pointer or the keyboard cursor is tinted, which eats into
  // the contrast of what is on it. Coloured text is measured against that
  // tint, the harder of the two backgrounds it is seen on.
  readonly property color tinted: {
    var c = Model.mix(surface, barForeground, Math.min(0.3, Style.hoverFillAlpha || 0.16))
    return Qt.rgba(c.r, c.g, c.b, 1)
  }
  function readable(color) {
    var c = Model.legible(color, tinted, barForeground)
    return Qt.rgba(c.r, c.g, c.b, 1)
  }
  readonly property color dimForeground: {
    var c = Model.dimmed(barForeground, surface)
    return Qt.rgba(c.r, c.g, c.b, 1)
  }
  readonly property color accent: readable(Color.accent)
  readonly property color danger: readable(Color.urgent)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------- Service ----------
  property var service: null

  function bindService() {
    if (service) return
    var host = bar && bar.shell ? bar.shell : null
    var s = host && typeof host.serviceFor === "function" ? host.serviceFor(moduleName) : null
    // A tray drawer hands its widgets a facade without their service; see Store.js.
    if (!s) s = Store.get()
    if (s) service = s
  }

  // Polled: serviceFor() is a call, so nothing notifies a binding.
  Timer {
    interval: 100
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.bindService()
  }

  // ---------- Data ----------
  readonly property var snippets: service ? service.snippets : []
  readonly property bool expanding: service ? service.expanding : false
  readonly property bool shiftEnter: service ? service.shiftEnter : false
  readonly property bool undo: service ? service.undoing : false
  readonly property bool wordStart: service ? service.wordStart : false
  readonly property var skipped: service ? service.skipped : []

  // ---------- Settings ----------
  // The settings take the list's place: the two switches, and the apps in
  // which nothing expands.
  property bool configuring: false
  readonly property bool listing: !composing && !configuring
  // The class of the window that had the focus when the panel was opened,
  // "" when there was none: the likeliest app to be meant, so it is offered first.
  property string app: ""
  // The classes of the windows open when the settings were, in that order,
  // without the ones already left alone.
  property var seen: []
  readonly property var openApps: seen.filter(function(name) { return skipped.indexOf(name) < 0 })

  // The moment the settings were opened, for the examples of the formats.
  property date today: new Date()

  function configure() {
    today = new Date()
    var names = app !== "" ? [app] : []
    var windows = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < windows.length; i++) {
      var name = windows[i] ? windows[i].appId : ""
      if (Model.appName(name) && names.indexOf(name) < 0) names.push(name)
    }
    seen = names
    configuring = true
    setCursor(0, 0)
  }

  function leaveSettings() {
    configuring = false
    setCursor(0, 0)
  }
  readonly property bool listening: service ? service.listening : false
  readonly property string layoutName: service && service.layout ? service.layout.name : ""
  // A file that does not parse is left alone until it is fixed by hand:
  // saving over it would lose what is in it.
  readonly property string blocked: !service ? "Starting"
    : service.configError === "unreadable" ? "The snippets file cannot be read. Fix its permissions to make changes here."
    : service.configError !== "" ? "The snippets file is not valid JSON. Fix it to make changes here."
    : service.dropped > 0 ? "The snippets file has " + service.dropped + (service.dropped === 1 ? " entry" : " entries")
      + " that cannot be used (a trigger or replacement that is too short, too long or repeated). Fix the file to make changes here."
    : ""
  readonly property string trouble: !service ? "" : service.saveError !== "" ? service.saveError
    : service.engineError !== "" ? service.engineError : service.typingError

  // The snippets the filter leaves, as indexes into `snippets`.
  readonly property var shown: Model.filter(snippets, filterField.text)
  readonly property string summary: {
    if (blocked !== "" || snippets.length === 0) return ""
    var count = shown.length !== snippets.length ? shown.length + " of " + snippets.length
      : snippets.length === 1 ? "1 snippet" : snippets.length + " snippets"
    return expanding ? count : count + "  ·  disabled"
  }

  // The triggers share a column as wide as the longest one shown, so a list
  // of short triggers does not push its texts to the far side.
  FontMetrics {
    id: triggerMetrics
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
  }
  readonly property real triggerColumn: {
    var widest = 0
    for (var i = 0; i < shown.length; i++) {
      var snippet = snippets[shown[i]]
      if (snippet) widest = Math.max(widest, triggerMetrics.advanceWidth((untypable(shown[i]) ? "\u{f0026} " : "") + snippet.trigger))
    }
    return Math.min(Style.space(160), Math.ceil(widest) + 1)
  }

  function untypable(index) {
    return service ? service.untypable.indexOf(index) >= 0 : false
  }

  // ---------- Editing ----------
  // The editor takes the list's place while a snippet is written or changed.
  property bool composing: false
  // -1 while the editor holds a new snippet, else the one being changed.
  property int editing: -1
  property string problem: ""

  // The trigger the snippet in the editor had when it was opened, to find it
  // again should the list change underneath (the file edited by hand, or a
  // delete from the panel on another monitor).
  property string editingTrigger: ""

  onSnippetsChanged: {
    doomed = -1
    if (!composing || editing < 0) return
    var found = -1
    for (var i = 0; i < snippets.length; i++) if (snippets[i].trigger === editingTrigger) found = i
    if (found < 0) leave()
    else editing = found
  }

  function compose(index) {
    var snippet = index >= 0 ? snippets[index] : null
    if (index >= 0 && !snippet) return
    editing = index
    editingTrigger = snippet ? snippet.trigger : ""
    problem = ""
    pasteNote = ""
    // What was typed to find a snippet that is not there is a good start
    // for its trigger.
    triggerField.text = snippet ? snippet.trigger
      : shown.length === 0 ? Model.characters(filterField.text.trim()).slice(0, Model.MAX_TRIGGER).join("") : ""
    textEdit.text = snippet ? snippet.replacement : ""
    composing = true
    setCursor(snippet || triggerField.text !== "" ? 1 : 0, 0)
  }

  function leave() {
    composing = false
    editing = -1
    pasteNote = ""
    doomed = -1
    problem = ""
    triggerField.text = ""
    textEdit.text = ""
    setCursor(0, 0)
  }

  function submit() {
    if (!service || blocked !== "") return
    var trigger = triggerField.text.trim()
    problem = Model.problem(snippets, trigger, textEdit.text, editing)
    if (problem !== "") { setCursor(Model.characters(trigger).length < 2 ? 0 : 1, 0); return }
    if (editing >= 0) service.replace(editing, trigger, textEdit.text)
    else service.add(trigger, textEdit.text)
    filterField.text = ""
    leave()
  }

  // Deleting takes two presses of the same bin (or of Delete): the first
  // asks, the second does it. Looking elsewhere takes the question back.
  property int doomed: -1

  function remove(index) {
    if (!service || blocked !== "" || index < 0) return
    if (doomed !== index) {
      doomed = index
      doomedTimer.restart()
      return
    }
    doomed = -1
    service.remove(index)
    if (composing) leave()
  }

  Timer {
    id: doomedTimer
    interval: 4000
    onTriggered: root.doomed = -1
  }

  function toggleExpanding() {
    if (service && blocked === "") service.setExpanding(!expanding)
  }

  // ---------- Paste ----------
  // No field here runs Qt's own paste, which reads the clipboard to its end
  // on the shell's thread whatever its size. This reads at most
  // Model.PASTE_BYTES, which is all a snippet can hold, for at most two
  // seconds, and says when there was more.
  property var pasteTarget: null
  // What to say under the editor when a paste did not all go in, "" when it did.
  property string pasteNote: ""

  // `room` is the characters a one-line field takes; left out for the
  // replacement, which takes what it still has room for.
  property int pasteRoom: 0

  function paste(target, room) {
    if (pasteProc.running) return
    pasteTarget = target
    pasteRoom = room || 0
    pasteProc.running = true
  }

  function finishPaste(raw) {
    var target = pasteTarget
    pasteTarget = null
    // The panel was shut, or the view the field is in left, while the
    // clipboard was being read.
    if (!target || !opened || !target.activeFocus) return
    target.remove(target.selectionStart, target.selectionEnd)
    // A one-line field takes what it still has room for, which may be nothing.
    var room = pasteRoom - Model.characters(target.text).length
    if (target !== textEdit && room <= 0) {
      pasteNote = target === triggerField.input ? "The trigger is as long as it can be; nothing was pasted." : ""
      return
    }
    var paste = target === textEdit
      ? Model.pasted(raw, 0, Model.MAX_TEXT - Model.characters(textEdit.text).length)
      : Model.pasted(raw, room)
    if (paste.text !== "") target.insert(target.cursorPosition, paste.text)
    pasteNote = !paste.cut ? ""
      : target === textEdit ? "Paste truncated: a replacement can be up to " + Model.MAX_TEXT + " characters."
      : target === triggerField.input ? "Only the first line was pasted. Put the text to insert in Replacement."
      : ""
  }

  Process {
    id: pasteProc
    command: Model.pasting()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishPaste(text)
    }
  }

  // ---------- Keyboard cursor ----------
  // A grid for each view. The list: the filter and the button for a new
  // snippet, a row per snippet shown, the switch. The editor: the trigger,
  // the text, the buttons. A field takes the keys while the cursor is on it.
  property int cursorRow: 0
  property int cursorCol: 0
  readonly property var rows: composing
    ? [["trigger"], ["text"], editing >= 0 ? ["save", "cancel", "delete"] : ["save", "cancel"]]
    : configuring
    ? [["back"], ["expanding"], ["shiftEnter"], ["undo"], ["wordStart"], ["dateFormat"], ["timeFormat"]]
      .concat(skipped.map(function(name, index) { return ["skip:" + index] }))
      .concat(openApps.map(function(name, index) { return ["open:" + index] }))
    : [snippets.length > 0 ? ["filter", "new", "settings"] : ["new", "settings"]]
      .concat(shown.map(function(index) { return ["item:" + index] }))
  readonly property string cursorItem: {
    var row = rows[Math.min(cursorRow, rows.length - 1)]
    return row[Math.min(cursorCol, row.length - 1)]
  }
  // The row the cursor was on may be gone: it moves to what is there now,
  // and the focus with it.
  onRowsChanged: if (cursorRow >= rows.length) setCursor(rows.length - 1, cursorCol)

  function hasCursor(key) { return cursorItem === key }

  function setCursor(row, col) {
    doomed = -1
    cursorRow = Math.max(0, Math.min(rows.length - 1, row))
    cursorCol = Math.max(0, Math.min(rows[cursorRow].length - 1, col))
    if (!opened) return
    if (cursorItem === "filter") filterField.focusInput()
    else if (cursorItem === "trigger") triggerField.focusInput()
    else if (cursorItem === "text") textEdit.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function moveCursor(dx, dy) {
    setCursor(cursorRow + dy, dy !== 0 ? cursorCol : cursorCol + dx)
  }

  function activate(key) {
    if (key === "new") compose(-1)
    else if (key === "save") submit()
    else if (key === "cancel") leave()
    else if (key === "delete") remove(editing)
    else if (key === "expanding") toggleExpanding()
    else if (key === "shiftEnter") { if (service && blocked === "") service.setShiftEnter(!shiftEnter) }
    else if (key === "undo") { if (service && blocked === "") service.setUndoing(!undo) }
    else if (key === "wordStart") { if (service && blocked === "") service.setWordStart(!wordStart) }
    else if (key === "dateFormat") { if (service && blocked === "") service.nextDateFormat() }
    else if (key === "timeFormat") { if (service && blocked === "") service.nextTimeFormat() }
    else if (key === "settings") configure()
    else if (key === "back") leaveSettings()
    else if (key.indexOf("skip:") === 0) { if (service && blocked === "") service.setSkipped(skipped[Number(key.substring(5))], false) }
    else if (key.indexOf("open:") === 0) { if (service && blocked === "") service.setSkipped(openApps[Number(key.substring(5))], true) }
    else if (key.indexOf("item:") === 0) compose(Number(key.substring(5)))
  }

  onOpenedChanged: {
    if (!opened) return
    composing = false
    configuring = false
    editing = -1
    doomed = -1
    problem = ""
    filterField.text = ""
    var toplevel = ToplevelManager.activeToplevel
    app = toplevel && Model.appName(toplevel.appId) ? toplevel.appId : ""
    Qt.callLater(function() { if (root.opened) root.setCursor(0, 0) })
  }

  // ---------- Bar icon ----------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f060e}" // nf-md-form-textbox
    active: root.listening && root.trouble === ""
    tooltipText: root.blocked !== "" ? "Instant Snippets"
      : root.trouble !== "" ? "Instant Snippets  ·  " + root.trouble
      : !root.expanding ? "Instant Snippets  ·  disabled"
      : root.snippets.length === 1 ? "1 snippet" : root.snippets.length + " snippets"
    onPressed: function(b) { root.toggle() }
  }

  // ---------- Pieces ----------
  // A one-line field. It is a TextEdit held to one line and not a TextField:
  // a TextField asks the clipboard for its whole text whenever the clipboard
  // changes, to know whether Paste could be offered, and a context menu with
  // Paste comes with it. Pasting goes through root.paste() instead: Ctrl+V
  // and Shift+Insert are taken before the field sees them, and the middle
  // and right buttons are swallowed.
  component LineField: BorderSurface {
    id: line
    property alias text: input.text
    property alias input: input
    property string placeholderText: ""
    property int maximumLength: 64
    property bool hasCursor: false
    readonly property bool editing: input.activeFocus
    signal edited()
    signal entered()
    signal escaped()
    signal tabbed(int direction)
    signal steppedDown()

    function clear() { input.text = "" }
    function focusInput() { input.forceActiveFocus() }

    readonly property bool hot: lineHover.hovered || hasCursor
    readonly property var spec: Border.controlSpec(input.activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"),
      root.barForeground, root.accent)
    implicitHeight: input.implicitHeight + (Style.spacing.controlPaddingY + Border.top(spec)) * 2
    color: Style.controlFill(input.activeFocus, hot, root.barForeground, root.accent)
    borderSpec: spec
    radius: Style.cornerRadius

    HoverHandler {
      id: lineHover
      cursorShape: Qt.IBeamCursor
    }

    TextEdit {
      id: input
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlGap + Border.left(line.spec)
      anchors.rightMargin: Style.spacing.controlGap + Border.right(line.spec)
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.NoWrap
      clip: true
      selectByMouse: true
      color: root.barForeground
      selectionColor: Style.selectionFillFor(root.barForeground, root.accent)
      selectedTextColor: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall

      // The last text that was one line and no longer than allowed. An edit
      // that would break either is taken back.
      property string kept: ""
      onTextChanged: {
        var line1 = text.replace(/[\n\r\t]/g, "")
        if (Model.characters(line1).length > line.maximumLength) line1 = kept
        if (line1 !== text) {
          var at = cursorPosition
          text = line1
          cursorPosition = Math.min(at, line1.length)
          return
        }
        kept = line1
        line.edited()
      }

      Keys.onPressed: function(event) {
        root.pasteNote = ""
        if (event.matches(StandardKey.Paste)) {
          event.accepted = true
          root.paste(input, line.maximumLength)
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true
          line.entered()
        } else if (event.key === Qt.Key_Escape) {
          event.accepted = true
          line.escaped()
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          event.accepted = true
          line.tabbed(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
        } else if (event.key === Qt.Key_Down) {
          event.accepted = true
          line.steppedDown()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.RightButton
        onPressed: function(mouse) { mouse.accepted = true }
        onReleased: function(mouse) { mouse.accepted = true }
      }
    }

    Text {
      visible: input.length === 0
      anchors.left: input.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: line.placeholderText
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
  }

  component FieldCaption: Text {
    width: parent ? parent.width : 0
    // Sits on its field rather than halfway between two.
    height: implicitHeight - Style.space(6)
    textFormat: Text.PlainText
    color: root.dimForeground
    font.family: root.ff
    font.pixelSize: Style.font.caption
  }

  component PanelButton: Button {
    iconSize: Style.font.icon
    fontSize: Style.font.bodySmall
    foreground: root.barForeground
    fontFamily: root.ff
    bordered: true
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
  }

  // One snippet on one line: its trigger, the start of its text, and a bin
  // that deletes it. Clicking anywhere else on it opens it in the editor.
  component SnippetRow: Rectangle {
    id: row
    property var snippet: ({})
    property bool hasCursor: false
    property bool untypable: false
    // The bin was pressed once and waits to be pressed again.
    property bool doomed: false
    signal chosen()
    signal removeRequested()
    signal unhovered()

    readonly property bool hot: hasCursor || rowHover.hovered

    width: parent ? parent.width : 0
    implicitHeight: Math.max(triggerText.implicitHeight, bin.implicitHeight) + Style.space(4)
    radius: Style.space(4)
    color: hot ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    // Covers the bin too, which a MouseArea under it would not.
    HoverHandler {
      id: rowHover
      onHoveredChanged: if (!hovered) row.unhovered()
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: row.chosen()
    }

    Text {
      id: triggerText
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: root.triggerColumn
      textFormat: Text.PlainText
      text: (row.untypable ? "\u{f0026} " : "") + (row.snippet.trigger || "") // nf-md-alert
      elide: Text.ElideRight
      color: row.untypable ? root.dimForeground : root.accent
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.left: triggerText.right
      anchors.leftMargin: Style.space(14)
      anchors.right: bin.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      // The question is asked here, where there is room for it: the bin
      // stays the size it was and where it was, under the pointer, for the
      // second press.
      text: row.doomed ? "Click again to delete this snippet" : Model.preview(row.snippet.replacement)
      elide: Text.ElideRight
      maximumLineCount: 1
      color: row.doomed ? root.danger : root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    // Quiet until the row is pointed at, so fifty bins do not shout, but
    // never too faint to see.
    Button {
      id: bin
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{f0a7a}" // nf-md-trash-can-outline
      iconSize: Style.font.icon
      tooltipText: row.doomed ? "Click again to confirm" : "Delete snippet"
      foreground: row.doomed ? root.danger : row.hot ? root.barForeground : root.dimForeground
      fontFamily: root.ff
      horizontalPadding: Style.spacing.controlPaddingX
      verticalPadding: Style.space(3)
      onClicked: row.removeRequested()
    }
  }

  // A setting: a label with a switch; the whole row takes the click.
  component SwitchRow: Rectangle {
    id: setting
    property string key: ""
    property string label: ""
    property bool checked: false

    width: parent ? parent.width : 0
    implicitHeight: Math.max(settingLabel.implicitHeight, settingSwitch.implicitHeight) + Style.spacing.controlPaddingY * 2
    radius: Style.space(4)
    color: settingMouse.containsMouse || root.hasCursor(key)
      ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    Text {
      id: settingLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.right: settingSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideMiddle
      textFormat: Text.PlainText
      text: setting.label
      color: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: settingMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activate(setting.key)
    }

    ToggleSwitch {
      id: settingSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      checked: setting.checked
      foreground: root.barForeground
      onToggled: root.activate(setting.key)
    }
  }

  // A setting with several values: a label and the value now chosen. The
  // whole row takes the click, which moves on to the next value.
  component ChoiceRow: Rectangle {
    id: choice
    property string key: ""
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: choiceLabel.implicitHeight + Style.spacing.controlPaddingY * 2 + Style.space(4)
    radius: Style.space(4)
    color: choiceMouse.containsMouse || root.hasCursor(key)
      ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    Text {
      id: choiceLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: choice.label
      color: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: choice.value + "  \u{f0142}" // nf-md-chevron-right
      color: root.accent
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: choiceMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activate(choice.key)
    }
  }

  // An app in the settings: one left alone, with a cross that lets snippets
  // back into it, or an open one, with a plus that leaves it alone. The
  // whole row takes the click.
  component AppRow: Rectangle {
    id: appRow
    property string name: ""
    property string key: ""
    property bool kept: false
    readonly property bool hasCursor: root.hasCursor(key)

    width: parent ? parent.width : 0
    implicitHeight: appName.implicitHeight + Style.spacing.controlPaddingY * 2
    radius: Style.space(4)
    color: hasCursor || appMouse.containsMouse ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    Text {
      id: appMark
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      textFormat: Text.PlainText
      text: appRow.kept ? "\u{f0156}" : "\u{f0415}" // nf-md-close, nf-md-plus
      color: appRow.kept ? root.accent : root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.icon
    }

    Text {
      id: appName
      anchors.left: appMark.right
      anchors.leftMargin: Style.space(8)
      anchors.right: appHint.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: appRow.name
      elide: Text.ElideMiddle
      color: appRow.kept ? root.barForeground : root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: appHint
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: appRow.kept ? "excluded" : "running"
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: appMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activate(appRow.key)
    }
  }

  // The thumb of a box that scrolls, shown while there is more than fits.
  component ScrollThumb: Rectangle {
    property Flickable view: null
    visible: view !== null && view.contentHeight > view.height
    anchors.right: parent ? parent.right : undefined
    width: Style.space(3)
    radius: width / 2
    color: root.dimForeground
    opacity: 1
    y: view ? view.y + view.contentY / view.contentHeight * view.height : 0
    height: view ? Math.max(Style.space(16), view.height / view.contentHeight * view.height) : 0
  }

  // ---------- Panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.snippets.length > 0 ? filterField.input : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a field is being typed in, every key belongs to it.
      blocked: filterField.editing || triggerField.editing || textEdit.activeFocus
      onCloseRequested: root.composing ? root.leave() : root.configuring ? root.leaveSettings() : root.close()
      // Tab goes on to the next panel from the list; from the editor or the
      // settings, where that would throw away what is open, it goes back to
      // the top.
      onTabRequested: function(direction) { root.listing ? root.switchPanel(direction) : root.setCursor(0, 0) }
      // "x" deletes in every Omarchy panel; Delete does here too.
      Keys.onDeletePressed: if (root.cursorItem.indexOf("item:") === 0) root.remove(Number(root.cursorItem.substring(5)))
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate(root.cursorItem)
      onDeleteRequested: if (root.cursorItem.indexOf("item:") === 0) root.remove(Number(root.cursorItem.substring(5)))

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------- Heading ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heading.implicitHeight, summaryText.implicitHeight)

          PanelSectionHeader {
            id: heading
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.configuring ? "SETTINGS" : !root.composing ? "SNIPPETS" : root.editing >= 0 ? "EDIT SNIPPET" : "NEW SNIPPET"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          Text {
            id: summaryText
            visible: root.listing
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.summary
            color: root.dimForeground
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: text !== ""
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.blocked !== "" ? root.blocked : root.trouble
          color: root.accent
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        // ================= The list =================

        // ---------- Filter, and a new snippet ----------
        Row {
          id: filterRow
          visible: root.listing
          width: parent.width
          spacing: Style.space(6)

          LineField {
            id: filterField
            visible: root.snippets.length > 0
            width: filterRow.width - newButton.width - gearButton.width - filterRow.spacing * 2
            placeholderText: "Search snippets"
            maximumLength: 40
            hasCursor: root.hasCursor("filter")

            onEditingChanged: if (editing) { root.cursorRow = 0; root.cursorCol = 0 }
            onEdited: listView.contentY = 0
            // Enter opens the first snippet found, or starts the one that was not.
            onEntered: root.compose(root.shown.length > 0 ? root.shown[0] : -1)
            onEscaped: text !== "" ? clear() : root.close()
            onTabbed: root.setCursor(0, 1)
            onSteppedDown: root.setCursor(1, 0)
          }

          // As tall as the field beside it; the whole row when there is no
          // list to filter yet.
          PanelButton {
            id: newButton
            width: root.snippets.length > 0 ? implicitWidth : filterRow.width - gearButton.width - filterRow.spacing
            height: filterField.implicitHeight
            opacity: root.blocked === "" ? 1 : 0.5
            iconText: "\u{f0415}" // nf-md-plus
            text: root.snippets.length > 0 ? "New" : "New snippet"
            hasCursor: root.hasCursor("new")
            onClicked: root.activate("new")
          }

          PanelButton {
            id: gearButton
            height: filterField.implicitHeight
            iconText: "\u{f0493}" // nf-md-cog
            tooltipText: "Settings"
            hasCursor: root.hasCursor("settings")
            onClicked: root.activate("settings")
          }
        }

        // ---------- Snippets ----------
        // A box of a fixed greatest height: fifty snippets scroll in it
        // rather than stretch the panel.
        Item {
          visible: root.listing && root.shown.length > 0
          width: parent.width
          implicitHeight: listView.height

          Flickable {
            id: listView
            width: parent.width
            height: Math.min(list.implicitHeight, Style.space(300), Math.max(Style.space(120), panel.availableCardHeight - Style.space(200)))
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // Keep the row under the keyboard cursor in view.
            function reveal(row) {
              if (!row) return
              if (row.y < contentY) contentY = row.y
              else if (row.y + row.height > contentY + height) contentY = row.y + row.height - height
            }

            Column {
              id: list
              width: parent.width - Style.space(6)
              spacing: Style.space(2)

              Repeater {
                model: root.shown
                SnippetRow {
                  required property var modelData
                  snippet: root.snippets[modelData] || ({})
                  hasCursor: root.hasCursor("item:" + modelData)
                  untypable: root.untypable(modelData)
                  onHasCursorChanged: if (hasCursor) listView.reveal(this)
                  doomed: root.doomed === modelData
                  onChosen: root.compose(modelData)
                  onRemoveRequested: root.remove(modelData)
                  onUnhovered: if (root.doomed === modelData) root.doomed = -1
                }
              }
            }
          }

          ScrollThumb { view: listView }
        }

        Text {
          visible: root.listing && root.shown.length === 0 && root.blocked === ""
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.snippets.length === 0
            ? "No snippets yet. Create one, then type its trigger in any app to insert its text."
            : "No matches. Press Enter to create a snippet with this trigger."
          color: root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        // ================= The settings =================

        PanelButton {
          visible: root.configuring
          iconText: "\u{f004d}" // nf-md-arrow-left
          text: "Back"
          hasCursor: root.hasCursor("back")
          onClicked: root.activate("back")
        }

        SwitchRow {
          visible: root.configuring
          key: "expanding"
          label: "Enable text expansion"
          checked: root.expanding
        }

        SwitchRow {
          visible: root.configuring
          key: "shiftEnter"
          label: "Insert line breaks with Shift+Enter"
          checked: root.shiftEnter
        }

        SwitchRow {
          visible: root.configuring
          key: "undo"
          label: "Undo an expansion with Backspace"
          checked: root.undo
        }

        SwitchRow {
          visible: root.configuring
          key: "wordStart"
          label: "Expand only at the start of a word"
          checked: root.wordStart
        }

        // What {date} and {time} look like, shown as they would be typed
        // now. A click moves on to the next format.
        ChoiceRow {
          visible: root.configuring
          key: "dateFormat"
          label: "Format of {date}"
          value: root.service ? Qt.formatDate(root.today, root.service.dateFormat) : ""
        }

        ChoiceRow {
          visible: root.configuring
          key: "timeFormat"
          label: "Format of {time}"
          value: root.service ? Qt.formatTime(root.today, root.service.timeFormat) : ""
        }

        PanelSeparator {
          visible: root.configuring
          width: parent.width
          foreground: root.barForeground
        }

        // ---------- Apps left alone ----------
        PanelSectionHeader {
          visible: root.configuring
          text: "EXCLUDED APPS"
          foreground: root.barForeground
          fontFamily: root.ff
        }

        Text {
          visible: root.configuring
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.skipped.length === 0 && root.openApps.length === 0
            ? "No apps are excluded. To exclude one, open it and return to these settings."
            : "Snippets never expand in excluded apps, and keys typed in them are ignored."
          color: root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        // The apps left alone, each with a cross that lets snippets back in,
        // then the open apps that could join them, each with a plus.
        Item {
          visible: root.configuring && root.skipped.length + root.openApps.length > 0
          width: parent.width
          implicitHeight: appsView.height

          Flickable {
            id: appsView
            width: parent.width
            height: Math.min(apps.implicitHeight, Style.space(220))
            contentHeight: apps.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            function reveal(row) {
              if (!row) return
              if (row.y < contentY) contentY = row.y
              else if (row.y + row.height > contentY + height) contentY = row.y + row.height - height
            }

            Column {
              id: apps
              width: parent.width - Style.space(6)
              spacing: Style.space(2)

              Repeater {
                model: root.skipped
                AppRow {
                  required property var modelData
                  required property int index
                  name: modelData
                  key: "skip:" + index
                  kept: true
                  onHasCursorChanged: if (hasCursor) appsView.reveal(this)
                }
              }

              Repeater {
                model: root.openApps
                AppRow {
                  required property var modelData
                  required property int index
                  name: modelData
                  key: "open:" + index
                  kept: false
                  onHasCursorChanged: if (hasCursor) appsView.reveal(this)
                }
              }
            }
          }

          ScrollThumb { view: appsView }
        }

        // ================= The editor =================

        // ---------- Trigger ----------
        // Named above the field: a placeholder is gone once there is text,
        // and an opened snippet always has some.
        FieldCaption {
          visible: root.composing
          text: "Trigger"
        }

        LineField {
          id: triggerField
          visible: root.composing
          width: parent.width
          placeholderText: "e.g. !em"
          maximumLength: Model.MAX_TRIGGER
          hasCursor: root.hasCursor("trigger")

          onEditingChanged: if (editing) { root.cursorRow = 0; root.cursorCol = 0 }
          onEdited: root.problem = ""
          onEntered: root.setCursor(1, 0)
          onEscaped: root.leave()
          onTabbed: root.setCursor(1, 0)
          onSteppedDown: root.setCursor(1, 0)
        }

        // ---------- Text ----------
        // As many lines as the snippet needs, in a box that scrolls. Enter
        // is a line break here; Ctrl+Enter saves.
        FieldCaption {
          visible: root.composing
          text: "Replacement"
        }

        BorderSurface {
          id: textBox
          visible: root.composing
          width: parent.width
          implicitHeight: Style.space(170)
          readonly property bool hot: textHover.hovered || root.hasCursor("text")
          readonly property var spec: Border.controlSpec(textEdit.activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"),
            root.barForeground, root.accent)
          color: Style.controlFill(textEdit.activeFocus, hot, root.barForeground, root.accent)
          borderSpec: spec
          radius: Style.cornerRadius

          HoverHandler { id: textHover }

          Flickable {
            id: textView
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.controlGap + Border.left(textBox.spec)
            anchors.rightMargin: Style.spacing.controlGap + Border.right(textBox.spec)
            anchors.topMargin: Style.spacing.controlPaddingY + Border.top(textBox.spec)
            anchors.bottomMargin: Style.spacing.controlPaddingY + Border.bottom(textBox.spec)
            contentHeight: textEdit.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // Keep the line being typed in view.
            function follow(rect) {
              if (rect.y < contentY) contentY = rect.y
              else if (rect.y + rect.height > contentY + height) contentY = rect.y + rect.height - height
            }

            TextEdit {
              id: textEdit
              width: textView.width - Style.space(6)
              height: Math.max(implicitHeight, textView.height)
              textFormat: TextEdit.PlainText
              wrapMode: TextEdit.Wrap
              selectByMouse: true
              color: root.barForeground
              selectionColor: Style.selectionFillFor(root.barForeground, root.accent)
              selectedTextColor: root.barForeground
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall

              onActiveFocusChanged: if (activeFocus) { root.cursorRow = 1; root.cursorCol = 0 }
              onCursorRectangleChanged: textView.follow(cursorRectangle)
              // The last text that was within the limit, which is counted in
              // characters as the model counts them. An edit that would go
              // over is taken back, where it was made.
              property string kept: ""
              onTextChanged: {
                root.problem = ""
                if (Model.characters(text).length > Model.MAX_TEXT) {
                  var at = cursorPosition
                  text = kept
                  cursorPosition = Math.min(at, kept.length)
                  return
                }
                kept = text
              }

              Keys.onPressed: function(event) {
                // The note that a paste was cut stays until the next key.
                // It is not cleared when the text changes: the paste itself
                // changes it, and an input method may report that late.
                root.pasteNote = ""
                if (event.matches(StandardKey.Paste)) {
                  event.accepted = true
                  root.paste(textEdit, 0)
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                  event.accepted = true
                  root.submit()
                }
              }
              Keys.onEscapePressed: root.leave()
              Keys.onTabPressed: root.setCursor(2, 0)
              Keys.onBacktabPressed: root.setCursor(0, 0)

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.MiddleButton | Qt.RightButton
                onPressed: function(mouse) { mouse.accepted = true }
                onReleased: function(mouse) { mouse.accepted = true }
              }
            }
          }

          Text {
            visible: textEdit.length === 0
            anchors.left: textView.left
            anchors.top: textView.top
            textFormat: Text.PlainText
            text: "Text to insert"
            color: root.dimForeground
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }

          ScrollThumb {
            view: textView
            anchors.rightMargin: Style.space(3)
          }
        }

        Text {
          visible: root.composing
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          // The same question, in the same words, as the bin in the list asks.
          text: root.problem !== "" ? root.problem
            : root.editing >= 0 && root.doomed === root.editing ? "Press Delete again to confirm"
            : root.pasteNote !== "" ? root.pasteNote
            : root.editing >= 0 && root.untypable(root.editing)
              ? "This trigger cannot be typed on the " + (root.layoutName || "current") + " layout, so it will not expand."
              : "Ctrl+Enter saves. {date} and {time} are filled in; {cursor} sets where the cursor ends up."
          color: root.problem !== "" || root.pasteNote !== "" ? root.accent
            : root.editing >= 0 && root.doomed === root.editing ? root.danger : root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        // ---------- Save, give up, delete ----------
        Row {
          id: saveRow
          visible: root.composing
          width: parent.width
          spacing: Style.space(6)
          readonly property int buttons: root.editing >= 0 ? 3 : 2
          readonly property real each: (width - spacing * (buttons - 1)) / buttons

          PanelButton {
            width: saveRow.each
            opacity: root.blocked === "" ? 1 : 0.5
            iconText: "\u{f012c}" // nf-md-check
            text: "Save"
            // The one that keeps the work stands out from the two that do not.
            foreground: root.accent
            hasCursor: root.hasCursor("save")
            onClicked: root.activate("save")
          }

          PanelButton {
            width: saveRow.each
            iconText: "\u{f0156}" // nf-md-close
            text: "Cancel"
            hasCursor: root.hasCursor("cancel")
            onClicked: root.activate("cancel")
          }

          PanelButton {
            visible: root.editing >= 0
            width: saveRow.each
            iconText: "\u{f0a7a}" // nf-md-trash-can-outline
            text: "Delete"
            foreground: root.doomed === root.editing ? root.danger : root.barForeground
            hasCursor: root.hasCursor("delete")
            onClicked: root.remove(root.editing)
          }
        }
      }
    }
  }
}
