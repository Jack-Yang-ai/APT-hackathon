/**
 * 从 Agent 全屏页「收起」时要回到哪个业务页。
 *
 * 为什么不用 `navigate(-1)`：history 里的上一页可能是外部站点，也可能是同一个页面的
 * 一次 replace，盲目后退会跑到不该去的地方。这里只记**白名单里的业务路径**，
 * 由 AppShell 在每次落在业务页时刷新；没记过就回首页。
 */

const ALLOWED = [/^\/$/, /^\/actions$/, /^\/actions\/[^/]+$/, /^\/me$/, /^\/me\/settings$/, /^\/me\/backscreen$/, /^\/me\/import$/, /^\/days\/\d+$/, /^\/recordings$/, /^\/recordings\/[^/]+$/, /^\/events\/[^/]+$/, /^\/events\/[^/]+\/transcript$/]

export function isBusinessPath(path: string): boolean {
  try {
    const decoded = decodeURIComponent(path)
    return !/[\\?#]/.test(decoded) && !decoded.split('/').some(part => part === '.' || part === '..') && ALLOWED.some(pattern => pattern.test(decoded))
  } catch { return false }
}

let lastBusinessPath = '/'
export type BusinessTab = '/' | '/actions' | '/me'
let lastTab: BusinessTab = '/'
const tabStacks: Record<BusinessTab, string[]> = { '/': ['/'], '/actions': ['/actions'], '/me': ['/me'] }
const scrollPositions = new Map<string, number>()

export function businessTab(path: string, origin?: unknown): BusinessTab {
  if (path.startsWith('/actions')) return '/actions'
  if (path.startsWith('/me') || path.startsWith('/days/')) return '/me'
  if (path === '/') return '/'
  return origin === '/' || origin === '/actions' || origin === '/me' ? origin : lastTab
}
export function getTabPath(tab: BusinessTab): string { const stack = tabStacks[tab]; return stack[stack.length - 1] ?? tab }
export function savePageScroll(path: string, top: number, tab = businessTab(path)): void { if (isBusinessPath(path)) scrollPositions.set(`${tab}:${path}`, top) }
export function pageScroll(path: string, tab = businessTab(path)): number { return scrollPositions.get(`${tab}:${path}`) ?? 0 }
export function parentPage(path: string): string {
  if (/^\/events\/.+\/transcript$/.test(path)) return path.replace(/\/transcript$/, '')
  if (path.startsWith('/actions/')) return '/actions'
  if (path.startsWith('/me/') || path.startsWith('/days/')) return '/me'
  if (path.startsWith('/recordings/')) return '/recordings'
  return '/'
}

/** AppShell 在业务页挂载 / 路径变化时调用 */
export function rememberBusinessPath(path: string, origin?: BusinessTab, back = false): void {
  if (isBusinessPath(path)) {
    lastBusinessPath = path
    lastTab = businessTab(path, origin)
    const stack = tabStacks[lastTab]
    if (path === lastTab) stack.splice(1)
    else if (stack[stack.length - 1] !== path) {
      const existing = back ? stack.lastIndexOf(path) : -1
      if (existing >= 0) stack.splice(existing + 1)
      else stack.push(path)
    }
  }
}

/** Business back follows this tab's own route chain, never another tab or an external history entry. */
export function backPage(path: string, tab = businessTab(path)): string {
  const stack = tabStacks[tab], index = stack.lastIndexOf(path)
  return index > 0 ? stack[index - 1]! : parentPage(path)
}

/** Agent 页收起时用：永远是白名单内的路径 */
export function getReturnTo(): string {
  return lastBusinessPath
}
