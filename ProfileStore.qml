import QtQuick
import Quickshell
import Quickshell.Io

// The list of installed profiles, kept on the user's side.
//
// It would be better to read the profile directories directly, and the plan
// was to. But the packages that own them ship tmpfiles entries making each one
// mode 0750 owned by a service user and a group that is empty on a stock
// install — so an unprivileged process cannot list such a directory, stat a
// file in it, or even traverse into it. Polling one would mean a polkit prompt
// on every refresh, which is not a widget. (The concrete modes are recorded in
// each backend and in the README.)
//
// So the plugin records what it installed, and the record is the thing that is
// polled. `reconcile()` repairs drift (a profile deleted by hand, or one
// installed before this widget existed) with a single privileged listing, and
// is only ever called because the user asked.
Item {
  id: root

  // { name, protocol, endpoint, importedAt, requires }
  //
  // `requires` is a list of COMMAND NAMES the profile needs at connect time
  // beyond its backend. Recorded here rather than reported once at import
  // because it is a property of the installed profile, not of the moment it
  // was installed: the profile stays broken until the package arrives, across
  // restarts, and the panel has to keep saying so.
  //
  // Names only. The package and the wording live in the backend, so correcting
  // them reaches profiles that were imported before the correction — the first
  // version of this stored the sentence and named the wrong package, which
  // then survived the fix.
  property var profiles: []
  property bool loaded: false

  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/connor.vpn/profiles.json"

  signal changed()

  function has(protocol, name) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].protocol === protocol && profiles[i].name === name) return true
    }
    return false
  }

  function find(protocol, name) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].protocol === protocol && profiles[i].name === name) return profiles[i]
    }
    return null
  }

  function forProtocol(protocol) {
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].protocol === protocol) out.push(profiles[i])
    }
    return out
  }

  // Reassign rather than mutate: QML does not notify on in-place edits, and
  // the panel binds straight to this.
  function add(entry) {
    var next = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].protocol === entry.protocol && profiles[i].name === entry.name) continue
      next.push(profiles[i])
    }
    next.push({
      name: String(entry.name),
      protocol: String(entry.protocol),
      endpoint: String(entry.endpoint || ""),
      importedAt: entry.importedAt || Math.floor(Date.now() / 1000),
      requires: _cleanRequires(entry.requires)
    })
    profiles = next
    save()
  }

  function remove(protocol, name) {
    var next = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].protocol === protocol && profiles[i].name === name) continue
      next.push(profiles[i])
    }
    profiles = next
    save()
  }

  // Replaces every entry for one protocol with what the privileged listing
  // actually found, keeping the endpoint we already knew for names that
  // survive — the listing cannot tell us that, and re-reading the configs
  // would need privilege we do not want to hold.
  function replaceProtocol(protocol, names) {
    var next = []
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].protocol !== protocol) next.push(profiles[i])
    }
    for (var j = 0; j < names.length; j++) {
      var known = find(protocol, names[j])
      next.push({
        name: names[j],
        protocol: protocol,
        endpoint: known ? known.endpoint : "",
        importedAt: known ? known.importedAt : Math.floor(Date.now() / 1000),
        // A privileged listing returns names and nothing else, so a profile
        // this widget did not import has no known requirements. Absence here
        // means "not known to need anything", never "known to need nothing".
        requires: known ? known.requires : []
      })
    }
    profiles = next
    save()
  }

  // The index is a file on disk that a person can edit, so nothing read back
  // out of it is trusted to have the right shape.
  function _cleanRequires(list) {
    var out = []
    if (!list || typeof list === "string" || typeof list.length !== "number") return out
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      // An index written by an earlier version stored the whole record. Take
      // the name out of it rather than discarding the profile's requirement.
      if (item && typeof item === "object" && item.command) item = item.command
      if (!item || typeof item !== "string") continue
      out.push(item)
    }
    return out
  }

  function load(text) {
    var parsed = { profiles: [] }
    try {
      parsed = JSON.parse(String(text || "")) || { profiles: [] }
    } catch (e) {
      parsed = { profiles: [] }
    }

    var list = parsed.profiles instanceof Array ? parsed.profiles : []
    var clean = []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      if (!entry.name || !entry.protocol) continue
      clean.push({
        name: String(entry.name),
        protocol: String(entry.protocol),
        endpoint: String(entry.endpoint || ""),
        importedAt: entry.importedAt || 0,
        requires: _cleanRequires(entry.requires)
      })
    }

    profiles = clean
    loaded = true
    root.changed()
  }

  function save() {
    indexFile.setText(JSON.stringify({ version: 1, profiles: profiles }, null, 2) + "\n")
    root.changed()
  }

  FileView {
    id: indexFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    // A first run has no file yet; that is the normal case, not an error.
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.load("")
    onFileChanged: reload()
  }
}
