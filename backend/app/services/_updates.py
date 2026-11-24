from typing import Any

from pydantic import BaseModel

from app.core.exceptions import BadRequestError


def changes(data: BaseModel, nullable: set[str]) -> dict[str, Any]:
    """Fields the client actually sent. Explicit nulls are only allowed for nullable columns."""
    values = data.model_dump(mode="json", exclude_unset=True)
    if not values:
        raise BadRequestError("No fields supplied to update.")
    bad = [k for k, v in values.items() if v is None and k not in nullable]
    if bad:
        raise BadRequestError(f"These fields cannot be null: {', '.join(sorted(bad))}.")
    return values
