import type { GamePackage, ReviewSession, RuntimeManifest, WasmAdapter } from '../types/api'

interface RuntimeAdapterModule {
  createWasmAdapter(options?: { wasmUrl?: string; wasmBytes?: BufferSource }): Promise<WasmAdapter>
}

function absoluteUrl(value: string): string {
  return new URL(value, window.location.origin).href
}

function hexadecimal(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (value) => value.toString(16).padStart(2, '0')).join('')
}

async function verifiedWasm(manifest: RuntimeManifest): Promise<ArrayBuffer> {
  const response = await fetch(absoluteUrl(manifest.wasmUrl), { credentials: 'same-origin' })
  if (!response.ok) throw new Error(`无法加载渲染运行时（HTTP ${response.status}）。`)
  const bytes = await response.arrayBuffer()
  const actualChecksum = hexadecimal(await crypto.subtle.digest('SHA-256', bytes))
  if (actualChecksum.toLowerCase() !== manifest.checksum.trim().toLowerCase()) {
    throw new Error('渲染运行时校验失败，请刷新后重试。')
  }
  return bytes
}

export async function loadRuntime(
  manifest: RuntimeManifest,
  gamePackage: GamePackage,
  session: ReviewSession,
): Promise<WasmAdapter> {
  if (!manifest.supportedSchemaVersions.includes(gamePackage.schemaVersion)) {
    throw new Error(`渲染器不支持游戏包 schema ${gamePackage.schemaVersion}。`)
  }
  const module = await import(/* @vite-ignore */ absoluteUrl(manifest.jsAdapterUrl)) as RuntimeAdapterModule
  if (typeof module.createWasmAdapter !== 'function') {
    throw new Error('渲染适配器没有导出 createWasmAdapter。')
  }
  const wasmBytes = await verifiedWasm(manifest)
  const adapter = await module.createWasmAdapter({ wasmUrl: absoluteUrl(manifest.wasmUrl), wasmBytes })
  await adapter.initialize({})
  const validation = adapter.loadPackage(gamePackage)
  if (!validation.valid) {
    const details = validation.errors.map((issue) => `${issue.path}: ${issue.message}`).join('；')
    adapter.dispose()
    throw new Error(`渲染器拒绝了游戏包：${details}`)
  }
  adapter.startSession({ ...session })
  return adapter
}
