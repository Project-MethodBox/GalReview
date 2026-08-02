import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5121,
    proxy: {
      '/api': {
        target: 'http://localhost:5000',
        changeOrigin: true,
        // 网关早期拒绝（401/413/429）时客户端请求体可能仍在上传：
        // 消费剩余请求体，避免连接被 RST、错误信封被裸 5xx 替换
        configure: (proxy) => {
          proxy.on('proxyRes', (_proxyRes, req) => {
            if (req.complete || req.readableEnded || req.destroyed) return
            // 上游腿已停止收体，先解除 pipe 背压再排空，否则流被冻结、
            // 排空只能等超时（http-proxy 内部用 pipe 转发请求体）
            req.unpipe()
            let drained = 0
            const timer = setTimeout(() => req.destroy(), 10_000)
            req.on('error', () => {})
            req.on('data', (chunk: Buffer) => {
              drained += chunk.length
              if (drained > 12 * 1024 * 1024) {
                clearTimeout(timer)
                req.destroy()
              }
            })
            req.once('end', () => clearTimeout(timer))
            req.once('close', () => clearTimeout(timer))
            req.resume()
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
