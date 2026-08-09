import { Router } from 'express';
import type { GatewayConfig } from '../config.js';
import { buildApiSuccess, buildApiFailure } from '../types.js';

/** 下游探测超时 */
const PROBE_TIMEOUT_MS = 3_000;

/**
 * 对单个下游服务做真实健康探测
 */
async function probeService(url: string): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
  try {
    const base = url.replace(/\/+$/, '');
    const res = await fetch(`${base}/healthz`, { signal: controller.signal });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
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

    const readinessKeys = config.readinessServices ?? Object.keys(config.services);
    const entries = readinessKeys.map(
      (key) => [key, config.services[key]] as const,
    );

    const invalid = entries
      .filter(([, service]) => !service || !service.url.startsWith('http'))
      .map(([key]) => key);
    if (invalid.length > 0) {
      res.status(503).json(buildApiFailure(
        'SERVICE_UNAVAILABLE',
        '路由配置未就绪',
        traceId,
        { invalid },
      ));
      return;
    }

    const results = await Promise.allSettled(
      entries.map(([, svc]) => probeService(svc!.url)),
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
