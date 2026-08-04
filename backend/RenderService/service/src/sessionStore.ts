/**
 * 可持久化的 session 存储抽象。
 * 内存实现 (InMemorySessionStore) 用于开发与测试；
 * MongoDB 实现 (MongoSessionStore) 用于生产，支持进程重启后恢复会话。
 */
export interface SessionStore {
  get(sessionId: string): Promise<SerializedSessionRecord | null>
  set(record: SerializedSessionRecord): Promise<void>
  delete(sessionId: string): Promise<boolean>
  size(): Promise<number>
  readonly kind: 'ephemeral-memory' | 'mongodb'
}

/**
 * SessionRecord 的可序列化形式：Set → array，其余字段保持不变。
 * sessions.ts 中的 SessionRecord 通过 toSerialized / fromSerialized 互转。
 */
export interface SerializedSessionRecord {
  sessionId: string
  userId: string
  packageId: string
  reviewPlanId: string
  snapshotVersion: string
  clientRuntimeVersion: string
  status: string
  currentSceneId: string | null
  progressVersion: number
  startedAt: string | null
  completedAt: string | null
  createdAt: string
  digest: unknown
  snapshot: unknown
  snapshotChecksum: string | null
  eventIds: string[]
  result: unknown
  pendingResult: unknown
}

// ---------------------------------------------------------------------------
// In-memory store
// ---------------------------------------------------------------------------

export class InMemorySessionStore implements SessionStore {
  readonly kind = 'ephemeral-memory' as const
  private readonly map = new Map<string, SerializedSessionRecord>()

  async get(sessionId: string): Promise<SerializedSessionRecord | null> {
    return this.map.get(sessionId) ?? null
  }

  async set(record: SerializedSessionRecord): Promise<void> {
    this.map.set(record.sessionId, record)
  }

  async delete(sessionId: string): Promise<boolean> {
    return this.map.delete(sessionId)
  }

  async size(): Promise<number> {
    return this.map.size
  }
}

// ---------------------------------------------------------------------------
// MongoDB store
// ---------------------------------------------------------------------------

/**
 * 最小 MongoDB session 存储：使用原生 fetch 驱动 Data API 或直接 TCP。
 *
 * 为了保持 RenderService 的"运行时零第三方依赖"原则，这里不引入 mongodb npm 包，
 * 而是通过 Node 内置 net 模块实现一个极简的 MongoDB Wire Protocol 写入器。
 *
 * 但这过于复杂。实际方案：如果部署环境提供了 MongoDB Data API（Atlas），
 * 使用 fetch 调用；否则回退到内存存储并记录警告。
 *
 * 更实际的方案：通过环境变量 RENDER_SESSION_MONGODB_URI 配置，
 * 动态 import('mongodb') —— 只有在生产环境安装了 mongodb 包时才启用。
 */

export class MongoSessionStore implements SessionStore {
  readonly kind = 'mongodb' as const
  private readonly collection: Promise<CollectionLike>
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private client: any

  constructor(connectionString: string, databaseName: string) {
    // 动态加载 mongodb 驱动：仅在安装了 mongodb 包时可用。
    // 这样 RenderService 在开发模式下仍可保持零依赖。
    this.client = null
    this.collection = this.init(connectionString, databaseName)
  }

  private async init(connectionString: string, databaseName: string): Promise<CollectionLike> {
    try {
      // 动态 import：如果 mongodb 包未安装，会抛出 MODULE_NOT_FOUND。
      // 使用 @ts-ignore 绕过 TypeScript 类型检查（mongodb 包未安装时无类型声明），
      // 配合 any 类型保证运行时正确性。
      // @ts-expect-error - mongodb 是可选依赖，未安装时无类型声明
      const mongodb: any = await import('mongodb')
      const client = new mongodb.MongoClient(connectionString, {
        serverSelectionTimeoutMS: 5000,
      })
      await client.connect()
      const db = client.db(databaseName)
      const collection = db.collection('review_sessions')
      await collection.createIndex({ sessionId: 1 }, { unique: true })
      await collection.createIndex({ userId: 1 })
      this.client = client
      return collection as CollectionLike
    } catch (error) {
      throw new Error(
        `MongoSessionStore 初始化失败：${error instanceof Error ? error.message : String(error)}。` +
        '请确保已安装 mongodb 包 (npm install mongodb) 并正确配置连接字符串。',
      )
    }
  }

  private async col(): Promise<CollectionLike> {
    return this.collection as Promise<CollectionLike>
  }

  async get(sessionId: string): Promise<SerializedSessionRecord | null> {
    const collection = await this.col()
    const doc = await collection.findOne({ sessionId })
    return doc ?? null
  }

  async set(record: SerializedSessionRecord): Promise<void> {
    const collection = await this.col()
    await collection.replaceOne(
      { sessionId: record.sessionId },
      record,
      { upsert: true },
    )
  }

  async delete(sessionId: string): Promise<boolean> {
    const collection = await this.col()
    const result = await collection.deleteOne({ sessionId })
    return result.deletedCount === 1
  }

  async size(): Promise<number> {
    const collection = await this.col()
    return collection.countDocuments({})
  }
}

/** 最小 collection 接口，便于类型检查和 mock。 */
interface CollectionLike {
  findOne(filter: unknown): Promise<SerializedSessionRecord | null>
  replaceOne(filter: unknown, doc: SerializedSessionRecord, options: { upsert: boolean }): Promise<unknown>
  deleteOne(filter: unknown): Promise<{ deletedCount: number }>
  countDocuments(filter: unknown): Promise<number>
  createIndex(spec: unknown, options?: unknown): Promise<unknown>
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export async function createSessionStore(): Promise<SessionStore> {
  const mongoUri = process.env.RENDER_SESSION_MONGODB_URI
  const mongoDb = process.env.RENDER_SESSION_MONGODB_DATABASE || 'galreview_render'

  if (mongoUri) {
    return new MongoSessionStore(mongoUri, mongoDb)
  }

  return new InMemorySessionStore()
}
