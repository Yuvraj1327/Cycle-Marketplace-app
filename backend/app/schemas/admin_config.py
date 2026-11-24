from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

from app.schemas.common import StrictModel


class SettingOut(BaseModel):
    key: str
    value: Any | None
    configured: bool
    description: str
    default_behaviour: str


class SettingUpdate(StrictModel):
    value: Any


class CommissionRuleOut(BaseModel):
    id: UUID
    name: str
    applies_to: str
    vendor_id: UUID | None
    category_id: UUID | None
    service_category_id: UUID | None
    commission_type: str
    commission_value: float
    priority: int
    is_active: bool
    effective_from: datetime
    effective_until: datetime | None
    created_at: datetime


class CommissionRuleCreate(StrictModel):
    name: str = Field(min_length=2, max_length=120)
    applies_to: str = Field("product", pattern="^(product|service)$")
    vendor_id: UUID | None = None
    category_id: UUID | None = None
    service_category_id: UUID | None = None
    commission_type: str = Field("percentage", pattern="^(percentage|fixed)$")
    commission_value: float = Field(ge=0, le=1_000_000)
    priority: int = Field(0, ge=-1000, le=1000)
    is_active: bool = True
    effective_from: datetime | None = None
    effective_until: datetime | None = None

    @model_validator(mode="after")
    def _rules(self):
        if self.commission_type == "percentage" and self.commission_value > 100:
            raise ValueError("a percentage commission cannot exceed 100")
        if self.applies_to == "product" and self.service_category_id:
            raise ValueError("a product rule cannot target a service category")
        if self.applies_to == "service" and self.category_id:
            raise ValueError("a service rule cannot target a product category")
        if self.effective_from and self.effective_until and self.effective_until <= self.effective_from:
            raise ValueError("effective_until must be after effective_from")
        return self


class CommissionRuleUpdate(StrictModel):
    name: str | None = Field(None, min_length=2, max_length=120)
    commission_type: str | None = Field(None, pattern="^(percentage|fixed)$")
    commission_value: float | None = Field(None, ge=0, le=1_000_000)
    priority: int | None = Field(None, ge=-1000, le=1000)
    is_active: bool | None = None
    effective_until: datetime | None = None
