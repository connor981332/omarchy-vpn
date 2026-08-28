// Prints `<name>\x1f<escaped>` for the names given on argv, using the widget's
// own escaper. test/harness/escape.test.sh diffs this against the real
// `systemd-escape` binary so the table in model.test.js cannot drift from
// whatever systemd on the host actually does.
const { load } = require("./qmljs")
const M = load("Model.js")
process.argv.slice(2).forEach((name) => {
  // \x1f rather than a tab: a profile name may legitimately contain a tab,
  // and that is exactly the case worth escaping correctly.
  process.stdout.write(name + "\x1f" + M.escapeUnitName(name) + "\n")
})
