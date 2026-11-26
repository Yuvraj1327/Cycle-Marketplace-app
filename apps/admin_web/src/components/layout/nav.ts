export interface NavItem {
  to: string
  label: string
  icon: string // svg path (24x24 stroke icon)
  end?: boolean
}

export interface NavGroup {
  heading: string
  items: NavItem[]
}

export const I = {
  home: 'M3 12 12 3l9 9M5 10v10h5v-6h4v6h5V10',
  people: 'M16 11a4 4 0 1 0-8 0 4 4 0 0 0 8 0ZM4 21a8 8 0 0 1 16 0',
  store: 'M3 9l1.5-5h15L21 9M3 9v11h18V9M3 9h18M9 20v-6h6v6',
  box: 'M12 3l9 4.5v9L12 21l-9-4.5v-9L12 3Zm0 9 9-4.5M12 12v9M12 12 3 7.5',
  tag: 'M3 12V3h9l9 9-9 9-9-9Zm5-5h.01',
  star: 'm12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.2 6.4 20.2l1.1-6.2L3 9.6l6.2-.9L12 3Z',
  image: 'M3 5h18v14H3V5Zm0 11 5-5 4 4 3-3 6 6M9 9.5h.01',
  cart: 'M6 2h12l2 5v15H4V7l2-5Zm-2 5h16M9 12h6',
  wrench: 'M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4 2.6-2.6Z',
  calendar: 'M4 5h16v16H4V5Zm0 5h16M8 3v4M16 3v4',
  truck: 'M2 6h11v10H2V6Zm11 4h4l3 3v3h-7M6 19a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Zm11 0a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z',
  card: 'M2 6h20v12H2V6Zm0 4h20M6 15h4',
  undo: 'M9 14 4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3',
  percent: 'M19 5 5 19M7 9a2 2 0 1 0 0-4 2 2 0 0 0 0 4Zm10 10a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z',
  bank: 'M3 10 12 4l9 6M5 10v8M9 10v8M15 10v8M19 10v8M3 20h18',
  bell: 'M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8Zm4 12a2 2 0 0 0 4 0',
  megaphone: 'M3 11v3h3l8 4V7L6 11H3Zm14-2a4 4 0 0 1 0 6',
  chart: 'M4 20V10M10 20V4M16 20v-8M22 20H2',
  sliders: 'M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6',
  gift: 'M3 8h18v4H3V8Zm2 4v9h14v-9M12 8v13M12 8c-2 0-4-1-4-3a2 2 0 0 1 4 0c0-2 4-2 4 0 0 2-2 3-4 3Z',
}

/** Account Settings is not part of the scrolling groups: the layout pins it to the bottom of the sidebar. */
export const ACCOUNT_NAV = {
  to: '/profile',
  label: 'Account Settings',
  // gear
  icon: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1Z',
} satisfies NavItem

export const NAV_GROUPS: NavGroup[] = [
  { heading: 'Main', items: [
    { to: '/', label: 'Overview', icon: I.home, end: true },
    { to: '/customers', label: 'Customers', icon: I.people },
    { to: '/vendors', label: 'Vendors', icon: I.store },
  ] },
  { heading: 'Marketplace', items: [
    { to: '/products', label: 'Products', icon: I.box },
    { to: '/categories', label: 'Categories', icon: I.tag },
    { to: '/featured-products', label: 'Featured Products', icon: I.star },
    { to: '/banners', label: 'Promotional Banners', icon: I.image },
  ] },
  { heading: 'Operations', items: [
    { to: '/orders', label: 'Orders', icon: I.cart },
    { to: '/services', label: 'Services', icon: I.wrench },
    { to: '/service-categories', label: 'Service Categories', icon: I.tag },
    { to: '/service-bookings', label: 'Service Bookings', icon: I.calendar },
    { to: '/pickups', label: 'Pickup & Drop-Off', icon: I.truck },
  ] },
  { heading: 'Finance', items: [
    { to: '/payments', label: 'Payments', icon: I.card },
    { to: '/refunds', label: 'Refunds', icon: I.undo },
    { to: '/commission', label: 'Commission Management', icon: I.percent },
    { to: '/settlements', label: 'Vendor Settlements', icon: I.bank },
  ] },
  { heading: 'Communication', items: [
    { to: '/notifications', label: 'Notifications', icon: I.bell },
    { to: '/announcements', label: 'Announcements', icon: I.megaphone },
  ] },
  { heading: 'Reports', items: [
    { to: '/reports/sales', label: 'Sales Reports', icon: I.chart },
    { to: '/reports/orders', label: 'Order Reports', icon: I.chart },
    { to: '/reports/vendors', label: 'Vendor Reports', icon: I.chart },
    { to: '/reports/customers', label: 'Customer Reports', icon: I.chart },
    { to: '/reports/services', label: 'Service Reports', icon: I.chart },
    { to: '/reports/payments', label: 'Payment Reports', icon: I.chart },
  ] },
  { heading: 'Settings', items: [
    { to: '/settings', label: 'Platform Settings', icon: I.sliders, end: true },
    { to: '/settings/charges', label: 'Pickup and Delivery Charges', icon: I.truck },
    { to: '/settings/coupons', label: 'Offers and Coupons', icon: I.gift },
  ] },
]
