import { FormEvent, useEffect, useState } from 'react'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import type { SharedPracticePackage } from '../types/api'

export default function SharedPracticePackagesPage() {
  const [items, setItems] = useState<SharedPracticePackage[]>([]); const [query, setQuery] = useState(''); const [message, setMessage] = useState(''); const [busy, setBusy] = useState(false)
  async function load(value = '') { const page = await api.listSharedPracticePackages(value); setItems(page.items) }
  useEffect(() => { void load().catch((error: unknown) => setMessage(error instanceof Error ? error.message : '资源中心读取失败。')) }, [])
  async function search(event: FormEvent) { event.preventDefault(); setBusy(true); setMessage(''); try { await load(query) } catch (error) { setMessage(error instanceof Error ? error.message : '搜索失败。') } finally { setBusy(false) } }
  async function download(item: SharedPracticePackage) {
    setBusy(true); setMessage(''); try { const blob = await api.getSharedPracticePackageContent(item.packageId); const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = `${item.title}-${item.version}.qzwlp`; anchor.click(); URL.revokeObjectURL(url) } catch (error) { setMessage(error instanceof Error ? error.message : '下载失败。') } finally { setBusy(false) }
  }
  return <AppShell><main className="page shared-practice-page"><PageHeader title="复习资源中心" description="资源中心保存不可变的题库项目包。下载后仍需映射到你自己的复习资料，避免复制他人的资料所有权。" />
    {message ? <p className="status-line" role="status">{message}</p> : null}
    <form className="practice-resource-search" onSubmit={(event) => void search(event)}><label>搜索项目<input value={query} placeholder="项目名称" onChange={(event) => setQuery(event.target.value)} /></label><button className="button button--primary" disabled={busy}>搜索</button></form>
    <section className="workspace-card"><div className="practice-project-list">{items.map((item) => <article key={item.packageId}><span><strong>{item.title}</strong><small>{item.subjectCode || '未设置学科'} · 版本 {item.version} · 下载 {item.downloadCount}</small></span><button className="button button--quiet" disabled={busy} onClick={() => void download(item)}>下载</button></article>)}{items.length === 0 ? <p className="empty-row">没有符合条件的公开项目包。</p> : null}</div></section>
  </main></AppShell>
}
