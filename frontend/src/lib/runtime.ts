import type { GamePackage, ReviewSession, RuntimeManifest, WasmAdapter } from '../types/api'

interface RuntimeAdapterModule {
  createWasmAdapter(options?: { wasmUrl?: string }): Promise<WasmAdapter>
}

function absoluteUrl(value: string): string {
  return new URL(value, window.location.origin).href
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
  const adapter = await module.createWasmAdapter({ wasmUrl: absoluteUrl(manifest.wasmUrl) })
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
