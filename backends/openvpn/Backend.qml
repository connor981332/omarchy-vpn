import QtQuick
import "../../Model.js" as Model
import "Config.js" as Config

// The OpenVPN strategy. Everything protocol-specific about the control plane
// is one of the properties or functions below; Service.qml drives all of it
// without ever naming a protocol, which is what lets a second backend be added
// beside this one rather than threaded through the service.
//
// Deliberately owns no Process and no state — it is a lookup table with a
// parser attached, so it stays cheap to instantiate and easy to reason about.
QtObject {
  id: root

  readonly property string protocol: "openvpn"
  readonly property string label: "OpenVPN"

  // Lazy dependency detection. The widget must never warn about this on load —
  // only when the user tries to import or start an OpenVPN profile.
  readonly property string packageName: "openvpn"
  readonly property var commands: ["openvpn"]

  // The stock template unit from the openvpn package. No unit file is shipped
  // by this plugin, so `systemctl start` is authorized by the stock
  // org.freedesktop.systemd1.manage-units polkit action.
  readonly property string unitTemplate: "openvpn-client@"

  // Devices an OpenVPN tunnel can create. Used to tell which netdev appeared
  // while the unit was starting.
  readonly property var devicePrefixes: ["tun", "tap"]

  // For the file chooser.
  readonly property string fileExtensions: "ovpn conf"
  readonly property string importTitle: "Import an OpenVPN profile"

  // The extension the profile takes once installed — the unit runs
  // `--config %i.conf`, so this is not a free choice.
  readonly property string configExtension: "conf"

  // The instance name is the profile name LITERALLY, not systemd-escaped.
  //
  // The stock unit runs `--config %i.conf`, and `%i` is the raw instance name,
  // so the instance has to equal the filename install-profile wrote. Escaping
  // it would point a perfectly valid profile like "work-vpn" at
  // "work\x2dvpn.conf", which does not exist — the unit then fails with a
  // missing config file and nothing explains why.
  //
  // Safe because sanitizeProfileName() restricts names to [A-Za-z0-9._-], all
  // of which are legal in an instance name as-is. The guard makes that a
  // checked property rather than a comment.
  function unitFor(name) {
    if (!Model.isLiteralUnitInstance(name)) return ""
    return unitTemplate + name + ".service"
  }

  // Reads a chosen .ovpn and returns the whole import as data: the config text
  // to write, the side files to copy beside it, and anything to tell the user.
  // Service.qml stages and installs the result without knowing what any of it
  // means.
  function planImport(text, sourcePath, name) {
    var plan = Config.plan(text, {
      name: name,
      sourceDir: sourcePath.substring(0, sourcePath.lastIndexOf("/"))
    })
    plan.configName = name + "." + configExtension
    return plan
  }

  // The endpoint shown in the panel, recovered from a config we can read.
  function endpointOf(text) {
    return Config.endpoint(Config.parse(text))
  }
}
