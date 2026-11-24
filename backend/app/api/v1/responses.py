"""Reusable OpenAPI error-response documentation."""
from app.schemas.common import ErrorResponse

E401 = {401: {"model": ErrorResponse, "description": "Missing, invalid or expired access token"}}
E403 = {403: {"model": ErrorResponse, "description": "Authenticated but not permitted (role, account or vendor status)"}}
E404 = {404: {"model": ErrorResponse, "description": "Resource not found (or not owned by the caller)"}}
E409 = {409: {"model": ErrorResponse, "description": "Conflict with existing data"}}
E422 = {422: {"model": ErrorResponse, "description": "Validation error"}}
E400 = {400: {"model": ErrorResponse, "description": "Invalid request"}}

PROTECTED = {**E401, **E403}
