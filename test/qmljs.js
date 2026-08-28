// Loads a QML .js resource into node.
//
// `.pragma library` and `.import` are QML engine directives, not JavaScript —
// node's parser rejects them outright. Stripping those lines and evaluating
// the rest in a module wrapper is what lets the same file be the shipped
// implementation and the unit-test subject, with no build step and no second
// copy to drift.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

function load(relativePath) {
  const file = path.resolve(__dirname, "..", relativePath)
  const source = fs
    .readFileSync(file, "utf8")
    .replace(/^\s*\.(pragma|import)\b.*$/gm, "")

  const sandbox = { console, JSON, Math, Date, parseInt, parseFloat, isFinite,
                    encodeURIComponent, decodeURIComponent, String, Number, Object, Array, RegExp }
  vm.createContext(sandbox)
  vm.runInContext(source, sandbox, { filename: file })
  return sandbox
}

module.exports = { load }
