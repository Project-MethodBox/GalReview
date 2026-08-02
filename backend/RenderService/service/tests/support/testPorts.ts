// Test servers bind to port 0 so the OS chooses an available ephemeral port.
// Fixed ranges are unsafe on Windows because they may overlap WinNAT excluded
// ranges, and they also create needless collisions between parallel workers.
import { spawn, type ChildProcess } from 'node:child_process'
import type { Server } from 'node:http'

// Binds an http.Server on an OS-assigned ephemeral port; returns that port.
export async function listenOnTestPort(server: Server, host = '127.0.0.1'): Promise<number> {
  await new Promise<void>((resolve, reject) => {
    const cleanup = (): void => {
      server.off('error', onError)
      server.off('listening', onListening)
    }
    const onError = (error: Error): void => {
      cleanup()
      reject(error)
    }
    const onListening = (): void => {
      cleanup()
      resolve()
    }
    server.once('error', onError)
    server.once('listening', onListening)
    server.listen(0, host)
  })
  const address = server.address()
  if (!address || typeof address === 'string') {
    throw new Error('Test server did not bind a TCP port.')
  }
  return address.port
}

export interface SpawnedServer {
  child: ChildProcess
  port: number
  base: string
}

type StartupOutcome =
  | { ok: true; port: number }
  | { ok: false; stderr: string }

// Spawns a node server with PORT=0 and reads the actual OS-assigned port from
// its startup message.
export async function spawnServerOnTestPort(
  scriptPath: string, extraEnv: Record<string, string> = {},
): Promise<SpawnedServer> {
  const child = spawn(process.execPath, [scriptPath], {
    env: { ...process.env, ...extraEnv, PORT: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  child.stdout!.setEncoding('utf8')
  child.stderr!.setEncoding('utf8')

  const outcome = await new Promise<StartupOutcome>((resolve) => {
    let stdoutBuffer = ''
    let stderrBuffer = ''
    let settled = false
    let startupTimer: ReturnType<typeof setTimeout>
    function cleanup(): void {
      clearTimeout(startupTimer)
      child.stdout!.off('data', onStdout)
      child.stderr!.off('data', onStderr)
      child.off('error', onError)
      child.off('exit', onExit)
    }
    function finish(result: StartupOutcome): void {
      if (settled) return
      settled = true
      cleanup()
      resolve(result)
    }
    function onStdout(chunk: string): void {
      stdoutBuffer += chunk
      const match = stdoutBuffer.match(/listening on port (\d+)/)
      if (match) {
        finish({ ok: true, port: Number.parseInt(match[1], 10) })
      }
    }
    function onStderr(chunk: string): void {
      stderrBuffer += chunk
    }
    function onError(error: Error): void {
      finish({ ok: false, stderr: `${stderrBuffer}\n${error.message}` })
    }
    function onExit(): void {
      finish({ ok: false, stderr: stderrBuffer })
    }
    startupTimer = setTimeout(() => {
      child.kill()
      finish({ ok: false, stderr: `${stderrBuffer}\nserver startup timed out` })
    }, 15_000)
    child.stdout!.on('data', onStdout)
    child.stderr!.on('data', onStderr)
    child.on('error', onError)
    child.on('exit', onExit)
  })

  if (!outcome.ok) {
    throw new Error(`server failed to start on an ephemeral port: ${outcome.stderr.slice(0, 500)}`)
  }
  return { child, port: outcome.port, base: `http://127.0.0.1:${outcome.port}` }
}
