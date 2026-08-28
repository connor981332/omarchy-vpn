import QtQuick
import "../../Model.js" as Model
import "Config.js" as Config

// The WireGuard strategy, beside the OpenVPN one rather than threaded through
// the service. Same shape, same contract: a lookup table with a parser
// attached, owning no Process and no state.
//
// It adds exactly one seam the other backend does not use — deviceFor() —
// because wg-quick names the interface after the config file, so the device is
// known before the unit starts rather than discovered after it.
QtObject {
  id: root

  readonly property string protocol: "wireguard"
  readonly property string label: "WireGuard"

  // Not in Omarchy's base packages, so the same lazy detection applies: this
  // is probed when the user reaches for WireGuard and at no other time.
  readonly property string packageName: "wireguard-tools"
  readonly property var commands: ["wg", "wg-quick"]

  // Ships with wireguard-tools as /usr/lib/systemd/system/wg-quick@.service.
  // Notably it sets no sandboxing directives at all — no ProtectHome — so a
  // config referencing a path under /home would work. Import still keeps
  // everything self-contained, because relying on the absence of a hardening
  // directive is a bet on the next release of the unit.
  readonly property string unitTemplate: "wg-quick@"

  // Deliberately empty. The device name is not guessable from a prefix — a
  // profile called "home" creates an interface called "home" — and deviceFor()
  // below answers exactly. Guessing would be worse than not knowing, because
  // every telemetry read downstream would follow the wrong interface.
  readonly property var devicePrefixes: []

  // Things a profile may need beyond this backend, looked up by command name.
  //
  // The catalogue lives here, and the profile index stores only the command
  // name, so a correction to the package or the wording reaches profiles that
  // were imported before it. Persisting the sentence meant the first version
  // of this advice — which named the wrong package — stayed on disk after the
  // code was fixed.
  readonly property var requirements: [
    {
      command: "resolvconf",
      // NOT openresolv. It also provides `resolvconf`, and it refuses to
      // manage the /etc/resolv.conf symlink systemd-resolved owns: wg-quick
      // dies on `resolvconf: signature mismatch`. systemd-resolvconf points
      // resolvconf at resolvectl, which implements the interface itself.
      packageName: "systemd-resolvconf",
      label: "systemd-resolvconf",
      warning: "This profile sets DNS, which wg-quick applies with `resolvconf`, "
        + "and that command is not installed. Without it the tunnel will fail to "
        + "start. Install systemd-resolvconf, or remove the DNS line from the "
        + "profile. (Not openresolv — it will not manage a resolv.conf that "
        + "systemd-resolved owns.)"
    }
  ]

  function requirementFor(command) {
    for (var i = 0; i < requirements.length; i++) {
      if (requirements[i].command === command) return requirements[i]
    }
    return null
  }

  readonly property string fileExtensions: "conf"
  readonly property string importTitle: "Import a WireGuard profile"
  readonly property string configExtension: "conf"

  // IFNAMSIZ. wg-quick enforces it too, in its own argument parsing:
  //   [[ $CONFIG_FILE =~ (^|/)([a-zA-Z0-9_=+.-]{1,15})\.conf$ ]] || die ...
  // so a longer name produces a profile that installs and can never start.
  // WireGuard authenticates with the keys already inside the config, so there
  // is nothing to store and no credential UI. The helper refuses the verb for
  // this protocol too, so a bug here cannot create a file wg-quick ignores.
  readonly property bool supportsCredentials: false

  readonly property int maxNameLength: 15

  // ExecStart is `/usr/bin/wg-quick up %i`, and wg-quick turns that instance
  // straight into /etc/wireguard/%i.conf — so, exactly as for the other
  // backend, the instance is the profile name literally and must never be
  // systemd-escaped.
  function unitFor(name) {
    if (!Model.isLiteralUnitInstance(name)) return ""
    if (String(name).length > maxNameLength) return ""
    return unitTemplate + name + ".service"
  }

  // The seam. wg-quick derives the interface name from the config filename,
  // which is the profile name — so there is nothing to discover.
  function deviceFor(name) {
    return Model.isLiteralUnitInstance(name) ? String(name) : ""
  }

  function planImport(text, sourcePath, name) {
    var plan = Config.plan(text, { name: name })
    plan.configName = name + "." + configExtension
    return plan
  }

  function endpointOf(text) {
    return Config.endpoint(Config.parse(text))
  }
}
