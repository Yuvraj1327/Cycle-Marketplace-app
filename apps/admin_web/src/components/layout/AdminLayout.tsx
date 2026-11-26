import { useEffect, useRef, useState } from 'react'
import { Link, NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../../app/providers/authContext'
import { ConfirmDialog } from '../common/ui'
import logo from '../../assets/admin-logo.png'
import { Avatar } from '../common/Avatar'
import { humanize } from '../../utils/format'
import { GlobalSearch } from './GlobalSearch'
import { PreferencesProvider } from '../../app/providers/PreferencesProvider'
import { ACCOUNT_NAV, NAV_GROUPS } from './nav'
import { APP_NAME } from '../../app/config'

function Icon({ d }: { d: string }) {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
  )
}

function Shell() {
  const { me, signOut } = useAuth()
  const [open, setOpen] = useState(false)
  const [menu, setMenu] = useState(false)
  const [confirmOut, setConfirmOut] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!menu) return
    const close = (e: MouseEvent) => !menuRef.current?.contains(e.target as Node) && setMenu(false)
    document.addEventListener('mousedown', close)
    return () => document.removeEventListener('mousedown', close)
  }, [menu])

  const name = me?.profile.full_name || me?.email || 'Administrator'

  return (
    <div className={`shell ${open ? 'nav-open' : ''}`}>
      <aside className="sidebar" aria-label="Sidebar">
        <Link to="/" className="brand">
          <img className="brand-logo" src={logo} alt="" width="36" height="40" />
          <span><strong>{APP_NAME}</strong><small>Admin Console</small></span>
        </Link>
        <nav aria-label="Main navigation">
          {NAV_GROUPS.map((g) => (
            <div key={g.heading} role="group" aria-label={g.heading}>
              <p className="nav-heading">{g.heading}</p>
              <ul>
                {g.items.map((n) => (
                  <li key={n.to}>
                    <NavLink to={n.to} end={n.end} onClick={() => setOpen(false)} className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>
                      <Icon d={n.icon} />
                      <span>{n.label}</span>
                    </NavLink>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>
        <nav className="sidebar-foot" aria-label="Account area">
          <NavLink to={ACCOUNT_NAV.to} onClick={() => setOpen(false)} className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>
            <Icon d={ACCOUNT_NAV.icon} />
            <span>{ACCOUNT_NAV.label}</span>
          </NavLink>
        </nav>
      </aside>
      {open && <button type="button" className="scrim" aria-label="Close menu" onClick={() => setOpen(false)} />}
      <div className="main">
        <header className="topbar">
          <button type="button" className="icon-btn menu-btn" aria-label="Open menu" aria-expanded={open} onClick={() => setOpen((o) => !o)}>☰</button>
          <GlobalSearch />
          <div className="topbar-spacer" />
          <Link to="/notifications" className="icon-btn bell-btn" aria-label="Notifications" title="Notifications">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8Zm4 12a2 2 0 0 0 4 0" /></svg>
          </Link>
          <div className="user" ref={menuRef}>
            <button type="button" className="user-btn" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((m) => !m)}>
              <Avatar path={me?.profile.avatar_path} name={me?.profile.full_name} email={me?.email} />
              <span className="user-id"><span className="user-name">{name}</span><small className="user-role">{humanize(me?.role)}</small></span>
              <svg className="user-caret" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
            </button>
            {menu && (
              <div className="menu" role="menu">
                <div className="menu-head"><strong>{name}</strong><small>{me?.email}</small></div>
                <Link role="menuitem" to={ACCOUNT_NAV.to} onClick={() => setMenu(false)}>Account Settings</Link>
                <button role="menuitem" type="button" onClick={() => { setMenu(false); setConfirmOut(true) }}>Sign out</button>
              </div>
            )}
          </div>
        </header>
        <main className="content" id="main">
          <Outlet />
        </main>
      </div>
      {confirmOut && (
        <ConfirmDialog title="Sign out?" message="You will need to sign in again to use the admin console." confirmLabel="Sign out" onConfirm={() => signOut()} onClose={() => setConfirmOut(false)} />
      )}
    </div>
  )
}

export function AdminLayout() {
  return (
    <PreferencesProvider>
      <Shell />
    </PreferencesProvider>
  )
}
