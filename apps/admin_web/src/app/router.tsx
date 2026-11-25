import { createBrowserRouter, createMemoryRouter, Navigate, type RouteObject } from 'react-router-dom'
import { AdminLayout } from '../components/layout/AdminLayout'
import { AccessDeniedPage, ForgotPasswordPage, LoginPage, ProtectedRoute } from '../features/authentication/AuthPages'
import { BannersPage } from '../features/banners/BannersPage'
import { CategoriesPage } from '../features/categories/CategoriesPage'
import { AnnouncementsPage } from '../features/communication/AnnouncementsPage'
import { NotificationsPage } from '../features/communication/NotificationsPage'
import { CustomerDetailPage } from '../features/customers/CustomerDetailPage'
import { CustomersPage } from '../features/customers/CustomersPage'
import { DashboardPage } from '../features/dashboard/DashboardPage'
import { CommissionPage } from '../features/finance/CommissionPage'
import { SettlementsPage } from '../features/finance/SettlementsPage'
import { FulfilmentPage } from '../features/orders/FulfilmentPage'
import { OrderDetailPage } from '../features/orders/OrderDetailPage'
import { OrdersPage } from '../features/orders/OrdersPage'
import { PaymentDetailPage } from '../features/payments/PaymentDetailPage'
import { PaymentsPage } from '../features/payments/PaymentsPage'
import { RefundsPage } from '../features/payments/RefundsPage'
import { NotFoundPage } from '../features/placeholders/NotFoundPage'
import { FeaturedPage } from '../features/products/FeaturedPage'
import { ProductDetailPage } from '../features/products/ProductDetailPage'
import { ProductsPage } from '../features/products/ProductsPage'
import { ProfilePage } from '../features/profile/ProfilePage'
import { CustomerReport, OrderReport, PaymentReport, SalesReport, ServiceReport, VendorReport } from '../features/reports/ReportPages'
import { BookingDetailPage } from '../features/services/BookingDetailPage'
import { BookingsPage } from '../features/services/BookingsPage'
import { PickupsPage } from '../features/services/PickupsPage'
import { ServicesPage } from '../features/services/ServicesPage'
import { ChargesPage } from '../features/settings/ChargesPage'
import { CouponsPage } from '../features/settings/CouponsPage'
import { PlatformSettingsPage } from '../features/settings/PlatformSettingsPage'
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
          // marketplace
          { path: 'products', element: <ProductsPage /> },
          { path: 'products/:id', element: <ProductDetailPage /> },
          { path: 'categories', element: <CategoriesPage variant="product" /> },
          { path: 'featured-products', element: <FeaturedPage /> },
          { path: 'banners', element: <BannersPage /> },
          // operations
          { path: 'orders', element: <OrdersPage /> },
          { path: 'orders/fulfilment', element: <FulfilmentPage /> },
          { path: 'orders/:id', element: <OrderDetailPage /> },
          { path: 'services', element: <ServicesPage /> },
          { path: 'service-categories', element: <CategoriesPage variant="service" /> },
          { path: 'service-bookings', element: <BookingsPage /> },
          { path: 'service-bookings/:id', element: <BookingDetailPage /> },
          { path: 'pickups', element: <PickupsPage /> },
          // finance
          { path: 'payments', element: <PaymentsPage /> },
          { path: 'payments/:id', element: <PaymentDetailPage /> },
          { path: 'refunds', element: <RefundsPage /> },
          { path: 'commission', element: <CommissionPage /> },
          { path: 'settlements', element: <SettlementsPage /> },
          // communication
          { path: 'notifications', element: <NotificationsPage /> },
          { path: 'announcements', element: <AnnouncementsPage /> },
          // reports
          { path: 'reports', element: <Navigate to="/reports/sales" replace /> },
          { path: 'reports/sales', element: <SalesReport /> },
          { path: 'reports/orders', element: <OrderReport /> },
          { path: 'reports/vendors', element: <VendorReport /> },
          { path: 'reports/customers', element: <CustomerReport /> },
          { path: 'reports/services', element: <ServiceReport /> },
          { path: 'reports/payments', element: <PaymentReport /> },
          // settings
          { path: 'settings', element: <PlatformSettingsPage /> },
          { path: 'settings/charges', element: <ChargesPage /> },
          { path: 'settings/coupons', element: <CouponsPage /> },
          { path: 'profile', element: <ProfilePage /> },
          { path: '*', element: <NotFoundPage /> },
        ],
      },
    ],
  },
]

export const createAppRouter = () => createBrowserRouter(routes)
export const createTestRouter = (initial: string[]) => createMemoryRouter(routes, { initialEntries: initial })
