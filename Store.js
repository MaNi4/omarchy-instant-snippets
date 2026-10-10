.pragma library

// The service, for widgets the shell will not hand it to.
//
// A widget hosted in a tray drawer is given the drawer's bar facade, whose
// serviceFor() only answers for the drawer itself, so the panel would never
// find its own service. `.pragma library` makes this one instance per engine
// rather than one per importing document, so the service and every bar's
// panel meet here regardless of load order.
var _service = null

function set(service) {
  _service = service
}

function get() {
  return _service
}

// Only the instance that registered may unregister, so a reloaded service
// coming up before the old one is destroyed is not wiped out by it.
function clear(service) {
  if (_service === service) _service = null
}
