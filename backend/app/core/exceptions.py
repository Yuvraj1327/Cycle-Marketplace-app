"""Application-level exceptions. Routes/services raise these; handlers in main.py turn them into a consistent JSON error body."""


class AppError(Exception):
    status_code = 500
    code = "internal_error"
    message = "An unexpected error occurred."
    headers: dict[str, str] | None = None
    details: list[dict] | None = None

    def __init__(self, message: str | None = None, details: list[dict] | None = None):
        super().__init__(message or self.message)
        self.message = message or self.message
        self.details = details


class ConfigurationError(AppError):
    status_code = 503
    code = "configuration_error"
    message = "The service is not configured correctly."


class NotFoundError(AppError):
    status_code = 404
    code = "not_found"
    message = "The requested record was not found."


class ConflictError(AppError):
    status_code = 409
    code = "conflict"
    message = "The record conflicts with an existing one."


class ValidationFailedError(AppError):
    status_code = 422
    code = "validation_failed"
    message = "The submitted data violates a database rule."


class PermissionDeniedError(AppError):
    status_code = 403
    code = "permission_denied"
    message = "You are not allowed to perform this action."


class DatabaseError(AppError):
    status_code = 502
    code = "database_error"
    message = "A database error occurred."


class BadRequestError(AppError):
    status_code = 400
    code = "bad_request"
    message = "The request is invalid."


class AuthenticationError(AppError):
    """401 - missing/invalid/expired credentials. Always carries a WWW-Authenticate header."""

    status_code = 401
    code = "not_authenticated"
    message = "Authentication required."
    headers = {"WWW-Authenticate": "Bearer"}


class TokenExpiredError(AuthenticationError):
    code = "token_expired"
    message = "The access token has expired."


class InvalidTokenError(AuthenticationError):
    code = "invalid_token"
    message = "The access token is invalid."


class ServiceUnavailableError(AppError):
    status_code = 503
    code = "service_unavailable"
    message = "A required upstream service is unavailable."


def conflict(code: str, message: str, details: list[dict] | None = None) -> "ConflictError":
    """409 with a machine-readable business code, e.g. conflict('out_of_stock', '...')."""
    err = ConflictError(message, details)
    err.code = code
    return err


def unprocessable(code: str, message: str, details: list[dict] | None = None) -> "ValidationFailedError":
    err = ValidationFailedError(message, details)
    err.code = code
    return err


def service_unavailable(code: str, message: str) -> "ServiceUnavailableError":
    err = ServiceUnavailableError(message)
    err.code = code
    return err
