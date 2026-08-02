// Test-port allocation inside the repository's reserved range 5260-5299,
// mirroring gateway/tests/support/testPorts.ts so every suite obeys the
// project port policy (scripts/Test-PortPolicy.ps1, CI job "port-policy").
// Parallel node:test workers may pick the same seed, so occupied ports are
// skipped until the whole range has been tried.
import { spawn } from 'node:child_process'

const FIRST_TEST_PORT = 5260
const LAST_TEST_PORT = 5299
const TEST_PORT_COUNT = LAST_TEST_PORT - FIRST_TEST_PORT + 1

let nextCandidate = FIRST_TEST_PORT + (process.pid % TEST_PORT_COUNT)

function takeCandidate() {
  const port = nextCandidate
  nextCandidate = port === LAST_TEST_PORT ? FIRST_TEST_PORT : port + 1
  return port
}

// Binds an http.Server on a free port in the reserved range; returns the port.
export async function listenOnTestPort(server, host = '127.0.0.1') {
  for (let attempt = 0; attempt < TEST_PORT_COUNT; attempt += 1) {
    const port = takeCandidate()
    try {
      await new Promise((resolve, reject) => {
        const cleanup = () => {
          server.off('error', onError)
          server.off('listening', onListening)
        }
        const onError = (error) => {
          cleanup()
          reject(error)
        }
        const onListening = () => {
          cleanup()
          resolve()
        }
        server.once('error', onError)
        server.once('listening', onListening)
        server.listen(port, host)
      })
      return port
    } catch (error) {
      if (error.code !== 'EADDRINUSE') throw error
    }
  }
  throw new Error(`No available test port in ${FIRST_TEST_PORT}-${LAST_TEST_PORT}.`)
}

// Spawns a node server script with PORT set to a free reserved port and waits
// for its "listening on port" line. Retries on EADDRINUSE crashes.
export async function spawnServerOnTestPort(scriptPath, extraEnv = {}) {
  let lastError = ''
  for (let attempt = 0; attempt < TEST_PORT_COUNT; attempt += 1) {
    const port = takeCandidate()
    const child = spawn(process.execPath, [scriptPath], {
      env: { ...process.env, ...extraEnv, PORT: String(port) },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')

    const outcome = await new Promise((resolve) => {
      let stdoutBuffer = ''
      let stderrBuffer = ''
      const onStdout = (chunk) => {
        stdoutBuffer += chunk
        if (/listening on port \d+/.test(stdoutBuffer)) {
          cleanup()
          resolve({ ok: true })
        }
      }
      const onStderr = (chunk) => {
        stderrBuffer += chunk
      }
      const onExit = () => {
        cleanup()
        resolve({ ok: false, stderr: stderrBuffer })
      }
      const cleanup = () => {
        child.stdout.off('data', onStdout)
        child.stderr.off('data', onStderr)
        child.off('exit', onExit)
      }
      child.stdout.on('data', onStdout)
      child.stderr.on('data', onStderr)
      child.on('exit', onExit)
    })

    if (outcome.ok) {
      return { child, port, base: `http://127.0.0.1:${port}` }
    }
    lastError = outcome.stderr
    if (!/EADDRINUSE/.test(outcome.stderr)) {
      throw new Error(`server failed to start on port ${port}: ${outcome.stderr.slice(0, 500)}`)
    }
  }
  throw new Error(`No available test port in ${FIRST_TEST_PORT}-${LAST_TEST_PORT}. Last error: ${lastError.slice(0, 200)}`)
}
