// A 40-line test runner, so the test suite has no dependency to install and
// `node test/*.test.js` works on a clean machine. Prints TAP-ish output and
// exits non-zero on the first failing file's summary.
let passed = 0
let failed = 0
const failures = []
let current = ""

function suite(name) {
  current = name
  console.log("# " + name)
}

function test(name, fn) {
  try {
    fn()
    passed++
    console.log("ok " + (passed + failed) + " - " + name)
  } catch (error) {
    failed++
    failures.push({ suite: current, name, error })
    console.log("not ok " + (passed + failed) + " - " + name)
    console.log("  " + String(error.message).split("\n").join("\n  "))
  }
}

function eq(actual, expected, note) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) {
    throw new Error((note ? note + ": " : "") + "expected " + b + "\n     got " + a)
  }
}

function ok(value, note) {
  if (!value) throw new Error((note || "expected truthy") + ", got " + JSON.stringify(value))
}

function near(actual, expected, tolerance, note) {
  if (Math.abs(actual - expected) > (tolerance === undefined ? 1e-9 : tolerance)) {
    throw new Error((note ? note + ": " : "") + "expected ~" + expected + ", got " + actual)
  }
}

function done() {
  console.log("1.." + (passed + failed))
  console.log("# pass " + passed + "  fail " + failed)
  if (failed > 0) process.exit(1)
}

process.on("exit", (code) => { if (code === 0 && failed > 0) process.exit(1) })

module.exports = { suite, test, eq, ok, near, done }
