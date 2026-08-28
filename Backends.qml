import QtQuick
import "backends/openvpn" as OpenVpn
import "backends/wireguard" as WireGuard

// The backend registry, and the only file outside backends/ that names a
// protocol.
//
// Something has to instantiate the strategy objects, and concentrating that
// here means the rest of the widget — panel, service, telemetry, store — can
// be checked mechanically for protocol names and stay clean. Adding WireGuard
// is adding a line to `all` below and a folder beside backends/openvpn/.
Item {
  id: root

  readonly property var all: [openvpn, wireguard]

  // The backend used when an action is not scoped to a row — the import key,
  // for instance, before any profile exists to select.
  readonly property var primary: all.length > 0 ? all[0] : null

  function forProtocol(protocol) {
    for (var i = 0; i < all.length; i++) {
      if (all[i].protocol === protocol) return all[i]
    }
    return null
  }

  OpenVpn.Backend { id: openvpn }
  WireGuard.Backend { id: wireguard }
}
