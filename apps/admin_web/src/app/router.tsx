import { createBrowserRouter, createMemoryRouter, type RouteObject } from 'react-router-dom'
import { AdminLayout } from '../components/layout/AdminLayout'
import { AccessDeniedPage, ForgotPasswordPage, LoginPage, ProtectedRoute } from '../features/authentication/AuthPages'
import { CustomerDetailPage } from '../features/customers/CustomerDetailPage'
import { CustomersPage } from '../features/customers/CustomersPage'
import { DashboardPage } from '../features/dashboard/DashboardPage'
import { ComingSoonPage, NotFoundPage } from '../features/placeholders/ComingSoonPage'
import { ProfilePage } from '../features/profile/ProfilePage'
import { VendorDetailPage } from '../features/vendors/VendorDetailPage'
import { VendorsPage } from '../features/vendors/VendorsPage'

export const routes: RouteObject[] = [
  { path: '/login', element: <LoginPage /> },
  { path: '/forgot-password', element: <ForgotPasswordPage /> },
  { path: '/access-denied', element: <AccessDeniedPage /> },
  {
    element: <ProtectedRoute />,
    children: [
      {
        element: <AdminLayout />,
        children: [
          { index: true, element: <DashboardPage /> },
          { path: 'customers', element: <CustomersPage /> },
          { path: 'customers/:id', element: <CustomerDetailPage /> },
          { path: 'vendors', element: <VendorsPage /> },
          { path: 'vendors/:id', element: <VendorDetailPage /> },
          { path: 'profile', element: <ProfilePage /> },
          ...['products', 'orders', 'services', 'payments', 'notifications', 'reports', 'settings'].map((p) => ({ path: p, element: <ComingSoonPage /> })),
          { path: '*', element: <NotFoundPage /> },
        ],
      },
    ],
  },
]

export const createAppRouter = () => createBrowserRouter(routes)
export const createTestRouter = (initial: string[]) => createMemoryRouter(routes, { initialEntries: initial })
