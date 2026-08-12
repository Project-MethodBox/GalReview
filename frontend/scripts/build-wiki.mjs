import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { marked } from 'marked'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const repositoryRoot = resolve(scriptDirectory, '..', '..')
const wikiRoot = join(repositoryRoot, 'wiki')
const outputArgumentIndex = process.argv.indexOf('--output')
if (outputArgumentIndex >= 0 && !process.argv[outputArgumentIndex + 1]) {
  throw new Error('--output requires a directory path.')
}
const outputRoot = outputArgumentIndex >= 0
  ? resolve(process.cwd(), process.argv[outputArgumentIndex + 1])
  : join(repositoryRoot, 'frontend', 'dist', 'wiki')

const preferredOrder = [
  'Home.md',
  '快速开始.md',
  '账户与登录.md',
  '藏书阁与资料解析.md',
  '研习册与自动成题.md',
  '答题与智能复习.md',
  '识网与知识点.md',
  '故事回响.md',
  '项目包与同窗书架.md',
  'Credits与兑换.md',
  '个人设置.md',
  '管理员观测台.md',
  '服务架构.md',
  '部署与资源准备.md',
  '常见问题.md',
]

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function pageLabel(filename) {
  return filename.replace(/\.md$/i, '')
}

function outputName(filename) {
  return filename.replace(/\.md$/i, '.html')
}

function rewriteMarkdownLinks(source) {
  return source.replace(/\]\(([^)\s]+)\.md(#[^)\s]+)?\)/g, (_match, target, fragment = '') => {
    const normalized = target === 'Home' || target === './Home' ? './index' : target
    return `](${normalized}.html${fragment})`
  })
}

function titleFromMarkdown(source, filename) {
  const heading = source.match(/^#\s+(.+)$/m)
  return heading?.[1]?.trim() || pageLabel(filename)
}

function navigationHtml(pages, current) {
  return pages.map((page) => {
    const active = page.filename === current ? ' aria-current="page" class="is-active"' : ''
    const href = page.filename === 'Home.md' ? './' : `./${encodeURI(outputName(page.filename))}`
    return `<a href="${href}"${active}>${escapeHtml(page.label)}</a>`
  }).join('\n')
}

function pageTemplate({ title, content, navigation, previous, next }) {
  const previousLink = previous
    ? `<a rel="prev" href="${previous.filename === 'Home.md' ? './' : `./${encodeURI(outputName(previous.filename))}`}"><span>上一页</span><strong>${escapeHtml(previous.label)}</strong></a>`
    : ''
  const nextLink = next
    ? `<a rel="next" href="./${encodeURI(outputName(next.filename))}"><span>下一页</span><strong>${escapeHtml(next.label)}</strong></a>`
    : ''
  const pager = previousLink || nextLink
    ? `<nav class="wiki-pager" aria-label="相邻页面">${previousLink}${nextLink}</nav>`
    : ''

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <meta name="description" content="千知万理使用 Wiki：${escapeHtml(title)}" />
  <link rel="icon" type="image/svg+xml" href="/brand-logo.svg" />
  <title>千知万理 · 使用WIKI</title>
  <link rel="stylesheet" href="./res/wiki.css" />
</head>
<body>
  <a class="skip-link" href="#wiki-content">跳到正文</a>
  <header class="wiki-header">
    <a class="wiki-brand" href="/">
      <img class="wiki-brand-logo" src="/brand-logo.svg" alt="" aria-hidden="true" />
      <strong>千知万理</strong><span>使用 Wiki</span>
    </a>
    <nav aria-label="站点导航"><a href="/">返回产品首页</a><a href="/login">进入工作台</a></nav>
    <button class="wiki-nav-toggle" type="button" aria-expanded="false" aria-controls="wiki-sidebar">目录</button>
  </header>
  <div class="wiki-layout">
    <aside class="wiki-sidebar" id="wiki-sidebar">
      <label class="wiki-search">查找页面<input type="search" placeholder="输入页面名称" /></label>
      <nav aria-label="Wiki 页面">${navigation}</nav>
      <p>文档内容以当前产品契约和已验证界面为准。</p>
    </aside>
    <main class="wiki-main" id="wiki-content">
      <article class="wiki-article">${content}</article>
      ${pager}
      <footer class="wiki-footer">千知万理 · GalReview 项目使用手册</footer>
    </main>
  </div>
  <script src="./res/wiki.js" defer></script>
</body>
</html>`
}

const entries = await readdir(wikiRoot, { withFileTypes: true })
const markdownFiles = entries.filter((entry) => entry.isFile() && entry.name.endsWith('.md')).map((entry) => entry.name)
const order = new Map(preferredOrder.map((name, index) => [name, index]))
markdownFiles.sort((left, right) => (order.get(left) ?? 999) - (order.get(right) ?? 999) || left.localeCompare(right, 'zh-CN'))

if (!markdownFiles.includes('Home.md')) throw new Error('wiki/Home.md is required.')

const pages = markdownFiles.map((filename) => ({ filename, label: pageLabel(filename) }))
await rm(outputRoot, { recursive: true, force: true })
await mkdir(outputRoot, { recursive: true })
await cp(join(wikiRoot, 'res'), join(outputRoot, 'res'), { recursive: true })

for (const [index, page] of pages.entries()) {
  const source = await readFile(join(wikiRoot, page.filename), 'utf8')
  const title = titleFromMarkdown(source, page.filename)
  const content = await marked.parse(rewriteMarkdownLinks(source), { gfm: true })
  const html = pageTemplate({
    title,
    content,
    navigation: navigationHtml(pages, page.filename),
    previous: index > 0 ? pages[index - 1] : undefined,
    next: index + 1 < pages.length ? pages[index + 1] : undefined,
  })
  await writeFile(join(outputRoot, outputName(page.filename)), html, 'utf8')
  if (page.filename === 'Home.md') await writeFile(join(outputRoot, 'index.html'), html, 'utf8')
}

console.log(`Wiki built: ${pages.length} pages -> ${outputRoot}`)
