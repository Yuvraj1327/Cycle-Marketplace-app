from pydantic import BaseModel

from app.schemas.common import Money


class DashboardOrders(BaseModel):
    total: int
    by_status: dict[str, int]
    sales_total: Money          # sum of `subtotal` of delivered vendor orders
    commission_total: Money     # commission snapshots of those orders (backend-calculated)


class DashboardProducts(BaseModel):
    total: int
    active: int                 # approved and not deactivated
    pending_approval: int
    rejected: int
    out_of_stock: int


class DashboardBookings(BaseModel):
    total: int
    by_status: dict[str, int]
    completed_value: Money      # recorded value of completed services; no payment is collected through the platform


class SettlementTotals(BaseModel):
    count: int
    gross: Money
    commission: Money
    deductions: Money
    net: Money


class VendorDashboard(BaseModel):
    orders: DashboardOrders
    products: DashboardProducts
    bookings: DashboardBookings
    settlements: dict[str, SettlementTotals]    # keyed by settlement status: pending | ready | paid | cancelled
