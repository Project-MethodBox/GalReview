import { FormEvent, useEffect, useState } from 'react'
import { Link } from 'react-router'
import AppShell, { PageHeader } from '../components/AppShell'
import { api } from '../lib/api'
import type { KnowledgeGraphSummary, Material, StudyProject } from '../types/api'

export default function PracticeProjectsPage() {
  const [projects, setProjects] = useState<StudyProject[]>([])
  const [materials, setMaterials] = useState<Material[]>([])
  const [name, setName] = useState('')
  const [subjectCode, setSubjectCode] = useState('')
  const [materialId, setMaterialId] = useState('')
  const [graphs, setGraphs] = useState<KnowledgeGraphSummary[]>([])
  const [graphId, setGraphId] = useState('')
  const [packageFile, setPackageFile] = useState<File | null>(null)
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  async function load() {
    const [projectPage, materialItems] = await Promise.all([api.listPracticeProjects(), api.getAllMaterials()])
    setProjects(projectPage.items)
    setMaterials(materialItems.filter((item) => item.status === 'READY'))
  }

  useEffect(() => { void load().catch((error: unknown) => setMessage(error instanceof Error ? error.message : '学习项目读取失败。')) }, [])
  useEffect(() => {
    setGraphId(''); if (!materialId) { setGraphs([]); return }
    void api.getAllKnowledgeGraphs(materialId).then((items) => setGraphs(items.filter((item) => item.status === 'READY'))).catch(() => setGraphs([]))
  }, [materialId])

  async function create(event: FormEvent) {
    event.preventDefault(); setBusy(true); setMessage('')
    try {
      await api.createPracticeProject({ name, subjectCode: subjectCode || undefined, materialIds: [materialId], graphId: graphId || undefined })
      setName(''); setSubjectCode(''); await load(); setMessage('学习项目已创建。')
    } catch (error) { setMessage(error instanceof Error ? error.message : '学习项目创建失败。') } finally { setBusy(false) }
  }

  async function importPackage(event: FormEvent) {
    event.preventDefault(); if (!packageFile) return; setBusy(true); setMessage('')
    try { const result = await api.importPracticePackage(packageFile, [materialId]); await load(); setPackageFile(null); setMessage(`已从 ${result.importedFromSchema} 导入 ${result.importedQuestionCount} 道题。`) }
    catch (error) { setMessage(error instanceof Error ? error.message : '项目包导入失败。') } finally { setBusy(false) }
  }

  return <AppShell><main className="page practice-projects-page">
    <PageHeader title="学习项目" description="围绕自己的资料建立题库、练习与试卷。知识图谱、SM-2 和故事复习都从项目进入。" actions={<Link className="button button--quiet" to="/shared-projects">资源中心</Link>} />
    {message ? <p className="status-line" role="status">{message}</p> : null}
    <div className="practice-project-layout">
      <section className="workspace-card">
        <header><span className="section-label">项目列表</span><h2>继续学习</h2></header>
        <div className="practice-project-list">
          {projects.map((project) => <Link key={project.projectId} to={`/projects/${project.projectId}`}>
            <span><strong>{project.name}</strong><small>{project.subjectCode || '未设置学科'} · {project.materialIds.length} 份资料</small></span>
            <span>进入</span>
          </Link>)}
          {projects.length === 0 ? <p className="empty-row">还没有学习项目。先从右侧选择一份已完成文字提取的资料。</p> : null}
        </div>
      </section>
      <div className="practice-project-side"><form className="form-section practice-project-create" onSubmit={(event) => void create(event)}>
        <header><span className="section-label">新建</span><h2>建立学习项目</h2><p>项目只引用资料，不复制文件或图谱。</p></header>
        <label>项目名称<input value={name} maxLength={120} required onChange={(event) => setName(event.target.value)} /></label>
        <label>学科代码<input value={subjectCode} maxLength={32} placeholder="例如 CS_DS" onChange={(event) => setSubjectCode(event.target.value.toUpperCase())} /></label>
        <label>主资料<select value={materialId} required onChange={(event) => setMaterialId(event.target.value)}><option value="">选择已就绪资料</option>{materials.map((item) => <option key={item.materialId} value={item.materialId}>{item.displayName}</option>)}</select></label>
        <label>知识图谱<select value={graphId} onChange={(event) => setGraphId(event.target.value)}><option value="">暂不绑定</option>{graphs.map((item) => <option key={item.graphId} value={item.graphId}>版本 {item.version} · {item.pointCount} 个知识点</option>)}</select></label>
        <button className="button button--primary" disabled={busy || materials.length === 0}>{busy ? '正在创建' : '创建项目'}</button>
      </form><form className="form-section" onSubmit={(event) => void importPackage(event)}><header><span className="section-label">迁移</span><h2>导入旧版项目包</h2><p>兼容 .rhproj、.rhp 与新版 .qzwlp。导入内容会映射到上方选中的资料。</p></header><label>项目包<input type="file" accept=".rhproj,.rhp,.qzwlp" required onChange={(event) => setPackageFile(event.target.files?.[0] || null)} /></label><button className="button button--quiet" disabled={busy || !packageFile || !materialId}>导入项目包</button></form></div>
    </div>
  </main></AppShell>
}
