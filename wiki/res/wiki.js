const toggle = document.querySelector('.wiki-nav-toggle')
const sidebar = document.querySelector('.wiki-sidebar')
const search = document.querySelector('.wiki-search input')

toggle?.addEventListener('click', () => {
  const open = sidebar?.classList.toggle('is-open') ?? false
  toggle.setAttribute('aria-expanded', String(open))
})

search?.addEventListener('input', () => {
  const query = search.value.trim().toLocaleLowerCase('zh-CN')
  document.querySelectorAll('.wiki-sidebar nav a').forEach((link) => {
    link.hidden = query.length > 0 && !link.textContent.toLocaleLowerCase('zh-CN').includes(query)
  })
})
