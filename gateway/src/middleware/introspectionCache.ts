/**
 * 带 TTL + LRU 淘汰的轻量缓存。
 * 仅用于 Gateway Token 内省结果，减少对 AuthService 的反复调用。
 *
 * 设计要点：
 * - 仅缓存 active=true 的内省结果；invalid / unreachable 不缓存，保证令牌撤销及时生效。
 * - 过期条目惰性清理（命中时检查 + 写入时检查容量），避免后台定时器。
 * - 容量满时按插入顺序淘汰最旧条目（Map 保持插入序，近似 LRU）。
 */
export class TtlLruCache<K, V> {
  private readonly store = new Map<K, { value: V; expiresAt: number }>();
  private readonly ttlMs: number;
  private readonly maxSize: number;

  constructor(options: { ttlMs: number; maxSize: number }) {
    if (options.ttlMs < 0) throw new Error('ttlMs must be >= 0');
    if (options.maxSize <= 0) throw new Error('maxSize must be > 0');
    this.ttlMs = options.ttlMs;
    this.maxSize = options.maxSize;
  }

  /** 当前缓存条目数（含已过期但未清理的）。 */
  get size(): number {
    return this.store.size;
  }

  /** 读取未过期的缓存值；过期则删除并返回 undefined。 */
  get(key: K): V | undefined {
    const entry = this.store.get(key);
    if (entry === undefined) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.store.delete(key);
      return undefined;
    }
    // 重新插入以更新插入序（Map 维持迭代顺序 = LRU 近似）。
    this.store.delete(key);
    this.store.set(key, entry);
    return entry.value;
  }

  /** 写入一条；超出容量时按最旧顺序淘汰。 */
  set(key: K, value: V): void {
    if (this.store.has(key)) this.store.delete(key);
    else if (this.store.size >= this.maxSize) {
      // 删除最旧的一条（Map 的 first key）。
      const firstKey = this.store.keys().next().value;
      if (firstKey !== undefined) this.store.delete(firstKey);
    }
    this.store.set(key, { value, expiresAt: Date.now() + this.ttlMs });
  }

  /** 清空全部缓存。 */
  clear(): void {
    this.store.clear();
  }
}
