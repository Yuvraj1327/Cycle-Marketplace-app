import { useEffect, useState } from 'react'
import { useAuth } from '../../app/providers/authContext'
import { initials } from '../../utils/format'

/** The administrator's profile picture (a private Storage object, shown through a short-lived link), or their initials when there is none. */
export function Avatar({ path, name, email, large = false }: { path: string | null | undefined; name: string | null | undefined; email: string | null | undefined; large?: boolean }) {
  const { gateway } = useAuth()
  const [loaded, setLoaded] = useState<{ path: string; url: string } | null>(null)

  useEffect(() => {
    if (!path) return
    let alive = true
    void gateway.signedUrl('avatars', path).then((url) => { if (alive && url) setLoaded({ path, url }) }).catch(() => undefined)
    return () => { alive = false }
  }, [gateway, path])

  const url = path && loaded?.path === path ? loaded.url : null
  return (
    <span className={`avatar ${large ? 'avatar-lg' : ''}`} aria-hidden="true">
      {url ? <img src={url} alt="" onError={() => setLoaded(null)} /> : initials(name, email)}
    </span>
  )
}
