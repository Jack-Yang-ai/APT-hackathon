import { useLayoutEffect, useRef, useState } from 'react'
import { Link, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { ChevronLeft, ListChecks } from 'lucide-react'
import { Composer } from '../components/Composer'
import { AptGlyph } from '../components/AptGlyph'
import { MAIN_TOPIC_ID } from '@/shared/ask/store'
import { PageTitleProvider } from './PageTitle'
import { rememberBusinessPath, businessTab, getTabPath, pageScroll, savePageScroll, backPage, type BusinessTab } from './returnTo'
import { AgentEntry } from '../components/AgentFace'

const ROOT_ROUTES = new Set(['/', '/actions', '/me'])
const TABS: { to: BusinessTab; label: string; glyph?: 'now' | 'me' }[] = [
  { to: '/', label: '此刻', glyph: 'now' }, { to: '/actions', label: '行动' }, { to: '/me', label: '我', glyph: 'me' },
]

export function AppShell() {
  const navigate = useNavigate(), { pathname, state } = useLocation(), mainRef = useRef<HTMLElement>(null)
  const [pageTitle, setPageTitle] = useState<string>(), [, setTopBleed] = useState(false)
  const isRoot = ROOT_ROUTES.has(pathname), selectedTab = businessTab(pathname, state?.businessTab)
  const returning = state?.businessBack === true
  const eventPage = /^\/events\/[^/]+$/.test(pathname)
  const actionPage = /^\/actions\/[^/]+$/.test(pathname) && pathname !== '/actions/removed'
  const whitePage = pathname.startsWith('/events/')

  useLayoutEffect(() => {
    rememberBusinessPath(pathname, selectedTab, returning)
    const main = mainRef.current
    if (main) main.scrollTop = pageScroll(pathname, selectedTab)
  }, [pathname, selectedTab, returning])

  return <div className="flex h-screen-dvh flex-col bg-background text-foreground">
    <header className={`z-20 shrink-0 pt-safe-top ${whitePage ? 'bg-surface' : 'bg-background'}`}>
      <div className="apt-nav-bar mx-auto w-full max-w-[640px]">
        <div className="flex justify-start">{!isRoot && <button type="button" aria-label="返回" className="apt-icon-button -ml-2 !text-foreground" onClick={() => {
          navigate(backPage(pathname, selectedTab), { replace: true, state: { businessTab: selectedTab, businessBack: true } })
        }}><ChevronLeft className="size-6" aria-hidden /></button>}</div>
        {isRoot ? <div className="mx-auto"><AgentEntry /></div> : <h1 className="apt-nav-title">{pageTitle}</h1>}
        <div className="flex justify-end">
          {pathname === '/actions' && <Link to="/actions/removed" className="apt-nav-action" aria-label="已移除的行动与候选">已移除</Link>}
          {eventPage && <Link to={pathname + '/transcript'} className="apt-nav-action">原话</Link>}
          {actionPage && <button className="apt-nav-action" onClick={() => navigate(pathname, { replace: true, state: { editAction: true } })}>编辑</button>}
        </div>
      </div>
    </header>
    <main ref={mainRef} onScroll={event => savePageScroll(pathname, event.currentTarget.scrollTop, selectedTab)} className={`min-h-0 flex-1 scroll-y ${whitePage ? 'bg-surface' : ''}`}>
      <PageTitleProvider onChange={setPageTitle} onTopBleedChange={setTopBleed}><Outlet /></PageTitleProvider>
    </main>
    <footer className="apt-business-footer z-20 shrink-0">
      <div className="mx-auto w-full max-w-[600px]"><Composer draftKey={MAIN_TOPIC_ID} forceMain onSent={() => navigate('/ask', { replace: true })} /></div>
      <nav className="apt-tabs" aria-label="主导航"><ul className="flex gap-1">
        {TABS.map(({ to, label, glyph }) => <li key={to} className="min-w-0 flex-1"><Link to={selectedTab === to ? pathname : getTabPath(to)} replace state={{ businessTab: to }} aria-current={selectedTab === to ? 'page' : undefined} className="apt-tab">
          {glyph ? <AptGlyph kind={glyph} /> : <ListChecks aria-hidden />}<span>{label}</span>
        </Link></li>)}
      </ul></nav>
    </footer>
  </div>
}
