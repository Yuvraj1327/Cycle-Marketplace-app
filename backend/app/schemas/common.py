from decimal import Decimal
from typing import Annotated, Generic, TypeVar

from pydantic import BaseModel, ConfigDict, PlainSerializer

T = TypeVar("T")

# Money is validated/handled as Decimal server-side and sent to clients as a plain JSON number (2 decimals).
Money = Annotated[Decimal, PlainSerializer(lambda d: float(d), return_type=float, when_used="json")]


class ErrorBody(BaseModel):
    code: str
    message: str
    details: list[dict] | None = None


class ErrorResponse(BaseModel):
    """Every error from this API has this shape."""

    error: ErrorBody


class StrictModel(BaseModel):
    """Request models reject unknown fields, so e.g. `role` or `verification_status` in a body yields 422."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Page(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
    limit: int
    pages: int
