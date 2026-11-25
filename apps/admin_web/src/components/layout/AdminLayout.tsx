import { useEffect, useRef, useState } from 'react'
import { Link, NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../../app/providers/authContext'
import { ConfirmDialog } from '../common/ui'
import { NAV_GROUPS } from './nav'

function Icon({ d }: { d: string }) {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
  )
}

function initials(name: string | null | undefined, email: string | null | undefined): string {
  const src = (name || email || '?').trim()
  const parts = src.split(/[\s@.]+/).filter(Boolean)
  return ((parts[0]?.[0] ?? '?') + (parts[1]?.[0] ?? '')).toUpperCase()
}

export function AdminLayout() {
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
          <span className="brand-mark" aria-hidden="true">C</span>
          <span><strong>Cycle Marketplace</strong><small>Admin console</small></span>
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
        <div className="sidebar-foot muted">Signed in as administrator</div>
      </aside>
      {open && <button type="button" className="scrim" aria-label="Close menu" onClick={() => setOpen(false)} />}
      <div className="main">
        <header className="topbar">
          <button type="button" className="icon-btn menu-btn" aria-label="Open menu" aria-expanded={open} onClick={() => setOpen((o) => !o)}>☰</button>
          <div className="topbar-spacer" />
          <div className="user" ref={menuRef}>
            <button type="button" className="user-btn" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((m) => !m)}>
              <span className="avatar" aria-hidden="true">{initials(me?.profile.full_name, me?.email)}</span>
              <span className="user-name">{name}</span>
            </button>
            {menu && (
              <div className="menu" role="menu">
                <div className="menu-head"><strong>{name}</strong><small>{me?.email}</small></div>
                <Link role="menuitem" to="/profile" onClick={() => setMenu(false)}>My profile</Link>
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
