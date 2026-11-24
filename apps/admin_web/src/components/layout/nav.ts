export interface NavItem {
  to: string
  label: string
  icon: string // svg path (24x24 stroke icon)
  /** implemented in this step; the rest are placeholders for the next phase */
  ready: boolean
  end?: boolean
}

export const NAV: NavItem[] = [
  { to: '/', label: 'Overview', icon: 'M3 12 12 3l9 9M5 10v10h5v-6h4v6h5V10', ready: true, end: true },
  { to: '/customers', label: 'Customers', icon: 'M16 11a4 4 0 1 0-8 0 4 4 0 0 0 8 0ZM4 21a8 8 0 0 1 16 0', ready: true },
  { to: '/vendors', label: 'Vendors', icon: 'M3 9l1.5-5h15L21 9M3 9v11h18V9M3 9h18M9 20v-6h6v6', ready: true },
  { to: '/products', label: 'Products', icon: 'M12 3l9 4.5v9L12 21l-9-4.5v-9L12 3Zm0 9 9-4.5M12 12v9M12 12 3 7.5', ready: false },
  { to: '/orders', label: 'Orders', icon: 'M6 2h12l2 5v15H4V7l2-5Zm-2 5h16M9 12h6', ready: false },
  { to: '/services', label: 'Services & Bookings', icon: 'M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4 2.6-2.6Z', ready: false },
  { to: '/payments', label: 'Payments', icon: 'M2 6h20v12H2V6Zm0 4h20M6 15h4', ready: false },
  { to: '/notifications', label: 'Notifications', icon: 'M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8Zm4 12a2 2 0 0 0 4 0', ready: false },
  { to: '/reports', label: 'Reports', icon: 'M4 20V10M10 20V4M16 20v-8M22 20H2', ready: false },
  { to: '/settings', label: 'Settings', icon: 'M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6', ready: false },
]

export const PLACEHOLDER_TITLES: Record<string, string> = Object.fromEntries(NAV.filter((n) => !n.ready).map((n) => [n.to, n.label]))
