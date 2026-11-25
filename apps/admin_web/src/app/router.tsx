import type { ComponentType } from 'react'
import { createBrowserRouter, createMemoryRouter, Navigate, type RouteObject } from 'react-router-dom'
import { PageLoading } from '../components/common/ui'
import { AdminLayout } from '../components/layout/AdminLayout'
import { AccessDeniedPage, ForgotPasswordPage, LoginPage, ProtectedRoute } from '../features/authentication/AuthPages'
import { DashboardPage } from '../features/dashboard/DashboardPage'
import { NotFoundPage } from '../features/placeholders/NotFoundPage'

/** Route-level code splitting: a page's code is downloaded the first time it is opened. The sign-in screens, the layout and the dashboard (the landing page)
 *  stay in the first bundle; every other module is its own chunk. */
const page = <K extends string>(load: () => Promise<Record<K, ComponentType>>, name: K): Pick<RouteObject, 'lazy'> => ({
  lazy: async () => ({ Component: (await load())[name] }),
})

const Loading = () => <PageLoading label="Loading…" />

export const routes: RouteObject[] = [
  { path: '/login', element: <LoginPage /> },
  { path: '/forgot-password', element: <ForgotPasswordPage /> },
  { path: '/access-denied', element: <AccessDeniedPage /> },
  {
    element: <ProtectedRoute />,
    HydrateFallback: Loading,
    children: [
      {
        element: <AdminLayout />,
        children: [
          { index: true, element: <DashboardPage /> },
          { path: 'customers', ...page(() => import('../features/customers/CustomersPage'), 'CustomersPage') },
          { path: 'customers/:id', ...page(() => import('../features/customers/CustomerDetailPage'), 'CustomerDetailPage') },
          { path: 'vendors', ...page(() => import('../features/vendors/VendorsPage'), 'VendorsPage') },
          { path: 'vendors/:id', ...page(() => import('../features/vendors/VendorDetailPage'), 'VendorDetailPage') },
          // marketplace
          { path: 'products', ...page(() => import('../features/products/ProductsPage'), 'ProductsPage') },
          { path: 'products/:id', ...page(() => import('../features/products/ProductDetailPage'), 'ProductDetailPage') },
          { path: 'categories', ...page(() => import('../features/categories/CategoriesPage'), 'ProductCategoriesPage') },
          { path: 'featured-products', ...page(() => import('../features/products/FeaturedPage'), 'FeaturedPage') },
          { path: 'banners', ...page(() => import('../features/banners/BannersPage'), 'BannersPage') },
          // operations
          { path: 'orders', ...page(() => import('../features/orders/OrdersPage'), 'OrdersPage') },
          { path: 'orders/fulfilment', ...page(() => import('../features/orders/FulfilmentPage'), 'FulfilmentPage') },
          { path: 'orders/:id', ...page(() => import('../features/orders/OrderDetailPage'), 'OrderDetailPage') },
          { path: 'services', ...page(() => import('../features/services/ServicesPage'), 'ServicesPage') },
          { path: 'service-categories', ...page(() => import('../features/categories/CategoriesPage'), 'ServiceCategoriesPage') },
          { path: 'service-bookings', ...page(() => import('../features/services/BookingsPage'), 'BookingsPage') },
          { path: 'service-bookings/:id', ...page(() => import('../features/services/BookingDetailPage'), 'BookingDetailPage') },
          { path: 'pickups', ...page(() => import('../features/services/PickupsPage'), 'PickupsPage') },
          // finance
          { path: 'payments', ...page(() => import('../features/payments/PaymentsPage'), 'PaymentsPage') },
          { path: 'payments/:id', ...page(() => import('../features/payments/PaymentDetailPage'), 'PaymentDetailPage') },
          { path: 'refunds', ...page(() => import('../features/payments/RefundsPage'), 'RefundsPage') },
          { path: 'commission', ...page(() => import('../features/finance/CommissionPage'), 'CommissionPage') },
          { path: 'settlements', ...page(() => import('../features/finance/SettlementsPage'), 'SettlementsPage') },
          // communication
          { path: 'notifications', ...page(() => import('../features/communication/NotificationsPage'), 'NotificationsPage') },
          { path: 'announcements', ...page(() => import('../features/communication/AnnouncementsPage'), 'AnnouncementsPage') },
          // reports
          { path: 'reports', element: <Navigate to="/reports/sales" replace /> },
          { path: 'reports/sales', ...page(() => import('../features/reports/ReportPages'), 'SalesReport') },
          { path: 'reports/orders', ...page(() => import('../features/reports/ReportPages'), 'OrderReport') },
          { path: 'reports/vendors', ...page(() => import('../features/reports/ReportPages'), 'VendorReport') },
          { path: 'reports/customers', ...page(() => import('../features/reports/ReportPages'), 'CustomerReport') },
          { path: 'reports/services', ...page(() => import('../features/reports/ReportPages'), 'ServiceReport') },
          { path: 'reports/payments', ...page(() => import('../features/reports/ReportPages'), 'PaymentReport') },
          // settings
          { path: 'settings', ...page(() => import('../features/settings/PlatformSettingsPage'), 'PlatformSettingsPage') },
          { path: 'settings/charges', ...page(() => import('../features/settings/ChargesPage'), 'ChargesPage') },
          { path: 'settings/coupons', ...page(() => import('../features/settings/CouponsPage'), 'CouponsPage') },
          { path: 'profile', ...page(() => import('../features/profile/ProfilePage'), 'ProfilePage') },
          { path: '*', element: <NotFoundPage /> },
        ],
      },
    ],
  },
]

export const createAppRouter = () => createBrowserRouter(routes)
export const createTestRouter = (initial: string[]) => createMemoryRouter(routes, { initialEntries: initial })
