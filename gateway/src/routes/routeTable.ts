import type { RouteEntry } from '../types.js';

/**
 * Gateway 路由归属表
 * 对应契约文档 9.1 节
 *
 * 注意：路由匹配顺序从上到下，先匹配先命中。
 * /internal 路由放在前面，避免被 /api 通配吞掉。
 */
export const ROUTE_TABLE: RouteEntry[] = [
  // ===== INTERNAL 服务间路由（服务身份） =====
  {
    path: '/internal/v1/users',
    service: 'userService',
    auth: 'service',
    rateLimitCategory: 'general',
  },
  {
    path: '/internal/v1/auth/introspections',
    service: 'authService',
    auth: 'service',
    rateLimitCategory: 'general',
  },
  {
    path: '/internal/v1/materials',
    service: 'fileService',
    auth: 'service',
    rateLimitCategory: 'general',
  },
  {
    path: '/internal/v1/review-plans',
    service: 'knowledgeService',
    auth: 'service',
    rateLimitCategory: 'general',
  },
  {
    path: '/internal/v1/review-evidence',
    service: 'knowledgeService',
    auth: 'service',
    rateLimitCategory: 'general',
  },
  {
    path: '/internal/v1/game-package-validations',
    service: 'galGameService',
    auth: 'service',
    rateLimitCategory: 'general',
  },
  {
    path: '/internal/v1/game-packages/:packageId',
    service: 'galGameService',
    auth: 'service',
    rateLimitCategory: 'general',
    methods: ['GET'],
  },

  // ===== 浏览器公开路由（无需令牌，精确方法匹配） =====
  {
    path: '/api/v1/auth/registrations',
    service: 'authService',
    auth: 'public',
    rateLimitCategory: 'anonymous',
    methods: ['POST'],
  },
  {
    path: '/api/v1/auth/sessions',
    service: 'authService',
    auth: 'public',
    rateLimitCategory: 'anonymous',
    methods: ['POST'],  // 仅登录公开；GET/DELETE /{sessionId} 需要鉴权
  },
  {
    path: '/api/v1/auth/tokens',
    service: 'authService',
    auth: 'public',
    rateLimitCategory: 'anonymous',
    methods: ['POST'],
  },
  {
    path: '/api/v1/auth/password-reset-requests',
    service: 'authService',
    auth: 'public',
    rateLimitCategory: 'anonymous',
    methods: ['POST'],
  },
  {
    path: '/api/v1/auth/password-resets',
    service: 'authService',
    auth: 'public',
    rateLimitCategory: 'anonymous',
    methods: ['POST'],
  },
  {
    path: '/api/v1/admin/sessions',
    service: 'authService',
    auth: 'public',
    rateLimitCategory: 'anonymous',
    methods: ['POST'],  // 仅管理员登录公开；其余 /admin/* 需要鉴权
  },
  {
    path: '/api/v1/render-runtime/manifest',
    service: 'renderService',
    auth: 'public',
    rateLimitCategory: 'general',
    methods: ['GET'],
  },
  {
    path: '/api/v1/render-runtime/runtime.wasm',
    service: 'renderService',
    auth: 'public',
    rateLimitCategory: 'general',
    methods: ['GET'],
  },
  {
    path: '/api/v1/render-runtime/adapter.js',
    service: 'renderService',
    auth: 'public',
    rateLimitCategory: 'general',
    methods: ['GET'],
  },

  // ===== 浏览器用户路由（需要用户令牌） =====
  {
    path: '/api/v1/auth/sessions/:sessionId',
    service: 'authService',
    auth: 'user',
    rateLimitCategory: 'general',
    methods: ['GET', 'DELETE'],
  },
  {
    path: '/api/v1/auth',
    service: 'authService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/admin',
    service: 'authService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/users',
    service: 'userService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/materials',
    service: 'fileService',
    auth: 'user',
    rateLimitCategory: 'upload',
    methods: ['POST'],  // 仅上传需 upload 限流和长超时
  },
  {
    path: '/api/v1/materials',
    service: 'fileService',
    auth: 'user',
    rateLimitCategory: 'general',
    // GET 列表、GET /{id}、DELETE 等使用 general 限流和默认超时
  },
  {
    path: '/api/v1/ingestion-jobs',
    service: 'fileService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/knowledge-graph-builds',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'generation',
    methods: ['POST'],
  },
  {
    path: '/api/v1/knowledge-graph-builds',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/knowledge-graphs',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/knowledge-points',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/assessment-plans',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'generation',
  },
  {
    path: '/api/v1/learning-plans',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'generation',
  },
  {
    path: '/api/v1/review-plans',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/mastery-records',
    service: 'knowledgeService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/game-generations',
    service: 'galGameService',
    auth: 'user',
    rateLimitCategory: 'generation',
    methods: ['POST'],
  },
  {
    path: '/api/v1/game-generations',
    service: 'galGameService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/game-packages',
    service: 'galGameService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
  {
    path: '/api/v1/review-sessions',
    service: 'renderService',
    auth: 'user',
    rateLimitCategory: 'general',
  },
];
