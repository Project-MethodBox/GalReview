import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [react()],
  build: {
    sourcemap: false,
  },
  server: {
    host: '0.0.0.0',
    port: 5121,
    proxy: {
      '/api': {
        target: 'http://localhost:5000',
        changeOrigin: true,
        // 早期拒绝（401/413/429）到达时客户端请求体往往仍在上传。网关虽然
        // 自己"排空完才 FIN"，但它冲刷的信封带 Content-Length——本代理的
        // http 客户端凑满 CL 字节即判定响应完成并立刻 res.end()，此时请求
        // 未完整、响应又是 connection: close，Node 会在 finish 时销毁客户端
        // socket（RST 冲掉在途上传与未读响应）。因此与 frontend/server.mjs
        // 的 endAfterDrain 同构：响应字节照常立即转发，但把 res.end 推迟到
        // 客户端请求体收完为止；不得从上游腿 unpipe（截断的腿会被网关排空
        // 超时销毁，殃及同进程其他在途请求）。排空有上限、有超时，越界则
        // 响应完成后显式断开（明示降级，只影响本连接）。
        configure: (proxy) => {
          const DRAIN_MAX_BYTES = 12 * 1024 * 1024
          const DRAIN_TIMEOUT_MS = 10_000

          proxy.on('proxyReq', (proxyReq, req) => {
            // 仅由 VS Code 的“Debug Vite proxy”配置启用；普通运行不会暂停。
            if (
              process.env.MOONSTONE_PROXY_BREAK === '1'
              && req.method === 'POST'
              && req.url?.startsWith('/api/v1/game-generations')
            ) debugger
            const authorization = req.headers.authorization
            if (authorization) proxyReq.setHeader('Authorization', authorization)
          })

          proxy.on('proxyRes', (_proxyRes, req, res) => {
            // 只有上传接口的请求体大到会与 Gateway 的早期拒绝相撞，因此收尾逻辑
            // 只作用于它，其余接口保持原样直通。
            if (req.method !== 'POST' || !req.url?.startsWith('/api/v1/materials')) return
            if (req.complete || req.readableEnded || req.destroyed) return
            const originalEnd = res.end.bind(res)
            let intercepted = false
            res.end = ((chunkOrCb?: unknown, encodingOrCb?: unknown, maybeCb?: unknown) => {
              if (intercepted) return res
              intercepted = true
              // 规范化 end 的三种重载：(cb) | (chunk, cb) | (chunk, encoding, cb)
              let chunk: Buffer | string | undefined
              let encoding: BufferEncoding | undefined
              let cb: (() => void) | undefined
              if (typeof chunkOrCb === 'function') {
                cb = chunkOrCb as () => void
              } else {
                chunk = chunkOrCb as Buffer | string | undefined
                if (typeof encodingOrCb === 'function') cb = encodingOrCb as () => void
                else {
                  encoding = encodingOrCb as BufferEncoding | undefined
                  cb = maybeCb as (() => void) | undefined
                }
              }
              if (chunk != null) {
                if (encoding) res.write(chunk, encoding)
                else res.write(chunk)
              }
              let drained = 0
              let settled = false
              const finish = (forceClose: boolean) => () => {
                if (settled) return
                settled = true
                clearTimeout(timer)
                req.removeListener('data', onData)
                req.removeListener('end', graceful)
                req.removeListener('close', graceful)
                originalEnd(() => {
                  if (forceClose && !req.destroyed) setImmediate(() => req.socket?.destroy())
                  if (typeof cb === 'function') cb()
                })
              }
              const graceful = finish(false)
              const forceful = finish(true)
              const onData = (buf: Buffer) => {
                drained += buf.length
                if (drained > DRAIN_MAX_BYTES) forceful()
              }
              const timer = setTimeout(forceful, DRAIN_TIMEOUT_MS)
              timer.unref()
              req.on('error', () => {})
              req.on('data', onData)
              req.once('end', graceful)
              req.once('close', graceful)
              req.resume()
              return res
            }) as typeof res.end
          })
        },
      },
    },
  },
  preview: {
    host: '0.0.0.0',
    port: 5122,
  },
})
