import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the panel knows about a live tunnel, read from the kernel.
//
// Once a tunnel is up it is just a netdev, so none of this is protocol-
// specific and none of it needs privilege: /sys/class/net/<dev>/statistics for
// bytes, `ip` for addresses and routes, `resolvectl` for the resolvers in
// effect. The management socket that would give cipher and reconnect counts is
// root-owned, which is why those are not here.
//
// Sampling is split by cost, per the stats catalog: byte counters ride the
// normal poll because they are two sysfs reads, while routes, resolvers and
// the exit IP only run while the popup is actually open. A bar widget must not
// wake the radio for a panel nobody is looking at.
Item {
  id: root

  property string device: ""
  property bool detailed: false          // true while the popup is open
  property bool exitIpEnabled: false     // opt-in; see exitIpProvider
  property string exitIpProvider: "https://api.ipify.org"

  property var telemetry: Model.emptyTelemetry()
  property string exitIp: ""

  // Previous sample, for the rate calculation.
  property double _prevRx: 0
  property double _prevTx: 0
  property double _prevAt: 0
  property string _prevDevice: ""

  readonly property bool hasDevice: device !== "" && _isDeviceName(device)

  // A device name reaches `ip` and a sysfs path as an argument. It comes from
  // the kernel via `ip -j link`, but validating it here means a malformed one
  // can never be concatenated into a path.
  function _isDeviceName(name) {
    return /^[A-Za-z0-9_.:-]{1,15}$/.test(String(name || ""))
  }

  function reset() {
    _prevRx = 0
    _prevTx = 0
    _prevAt = 0
    _prevDevice = ""
    exitIp = ""
    telemetry = Model.emptyTelemetry()
  }

  function sample() {
    if (!hasDevice) {
      if (telemetry.rxBytes !== 0 || telemetry.sampledAt !== 0) reset()
      return
    }
    if (countersProcess.running) return
    countersProcess.command = [
      "cat",
      "/sys/class/net/" + device + "/statistics/rx_bytes",
      "/sys/class/net/" + device + "/statistics/tx_bytes"
    ]
    countersProcess.running = true
  }

  function sampleDetailed() {
    if (!hasDevice || !detailed) return
    if (!routeProcess.running) {
      routeProcess.command = ["ip", "-j", "route"]
      routeProcess.running = true
    }
    if (!addrProcess.running) {
      addrProcess.command = ["ip", "-j", "addr", "show", "dev", device]
      addrProcess.running = true
    }
    if (!dnsProcess.running) {
      dnsProcess.command = ["resolvectl", "status", device]
      dnsProcess.running = true
    }
  }

  // Only on a state change, never on the poll — this is the one probe that
  // leaves the machine.
  function sampleExitIp() {
    if (!exitIpEnabled || !hasDevice || exitIpProcess.running) return
    exitIpProcess.command = ["curl", "--silent", "--max-time", "5",
                             "--interface", device, exitIpProvider]
    exitIpProcess.running = true
  }

  function _patch(fields) {
    var next = {}
    for (var key in telemetry) next[key] = telemetry[key]
    for (var field in fields) next[field] = fields[field]
    telemetry = next
  }

  onDeviceChanged: {
    // A new device means the old counters describe a different tunnel.
    reset()
    if (hasDevice) {
      sample()
      sampleExitIp()
    }
  }

  Process {
    id: countersProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: countersOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var lines = String(countersOut.text || "").split("\n")
      var rx = Model.parseCounter(lines[0])
      var tx = Model.parseCounter(lines[1])
      var now = Date.now()

      // Only rate against a sample from the same device, or a rebuilt tunnel
      // reads as a huge burst.
      var sameDevice = root._prevDevice === root.device
      var rxRate = sameDevice ? Model.rate(root._prevRx, rx, root._prevAt, now) : 0
      var txRate = sameDevice ? Model.rate(root._prevTx, tx, root._prevAt, now) : 0

      root._prevRx = rx
      root._prevTx = tx
      root._prevAt = now
      root._prevDevice = root.device

      root._patch({ rxBytes: rx, txBytes: tx, rxRate: rxRate, txRate: txRate, sampledAt: now })
    }
  }

  Process {
    id: routeProcess
    running: false
    command: []
    stdout: StdioCollector { id: routeOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root._patch({ defaultRoute: Model.defaultRouteVia(String(routeOut.text || ""), root.device) })
    }
  }

  Process {
    id: addrProcess
    running: false
    command: []
    stdout: StdioCollector { id: addrOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root._patch({ addresses: Model.parseAddresses(String(addrOut.text || "")) })
    }
  }

  Process {
    id: dnsProcess
    running: false
    command: []
    stdout: StdioCollector { id: dnsOut; waitForEnd: true }
    onExited: function(exitCode) {
      // resolvectl exits non-zero for a link it does not track, which is a
      // real answer: no resolvers are scoped to the tunnel.
      root._patch({ dns: exitCode === 0 ? Model.parseResolvers(String(dnsOut.text || "")) : [] })
    }
  }

  Process {
    id: exitIpProcess
    running: false
    command: []
    stdout: StdioCollector { id: exitIpOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.exitIp = exitCode === 0 ? String(exitIpOut.text || "").trim() : ""
    }
  }
}
