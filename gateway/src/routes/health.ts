import { Router } from 'express';
import type { GatewayConfig } from '../config.js';
import { buildApiSuccess, buildApiFailure } from '../types.js';

/** 下游探测超时 */
const PROBE_TIMEOUT_MS = 3_000;

/**
 * 对单个下游服务做真实健康探测
 */
async function probeService(url: string): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
    const res = await fetch(`${url}/healthz`, { signal: controller.signal });
    clearTimeout(timer);
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * 健康检查路由
 * - GET /healthz  → Gateway 进程存活
 * - GET /readyz   → 路由配置和关键依赖就绪（真实探测下游 /healthz）
 */
export function createHealthRouter(config: GatewayConfig): Router {
  const router = Router();

  router.get('/healthz', (req, res) => {
    const traceId = req.traceId ?? 'unknown';
    res.status(200).json(buildApiSuccess({ status: 'live' }, traceId));
  });

  router.get('/readyz', async (req, res) => {
    const traceId = req.traceId ?? 'unknown';

    // 配置级检查
    const servicesConfigured = Object.values(config.services).every(
      (s) => s.url.startsWith('http'),
    );
    if (!servicesConfigured) {
      res.status(503).json(buildApiFailure('SERVICE_UNAVAILABLE', '路由配置未就绪', traceId));
      return;
    }

    // 真实下游探测
    const entries = Object.entries(config.services);
    const results = await Promise.allSettled(
      entries.map(([, svc]) => probeService(svc.url)),
    );

    const unhealthy: string[] = [];
    results.forEach((result, i) => {
      const reachable = result.status === 'fulfilled' && result.value;
      if (!reachable) {
        unhealthy.push(entries[i][0]);
      }
    });

    if (unhealthy.length === 0) {
      res.status(200).json(buildApiSuccess({ status: 'ready' }, traceId));
    } else {
      res.status(503).json(buildApiFailure(
        'SERVICE_UNAVAILABLE',
        '部分下游服务不可达',
        traceId,
        { unhealthy },
      ));
    }
  });

  return router;
}
