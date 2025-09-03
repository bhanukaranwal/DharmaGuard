//! User management HTTP handlers

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
};
use uuid::Uuid;
use validator::Validate;

use crate::{
    error::AppError,
    models::*,
    AppState,
};

/// Create a new user
pub async fn create_user(
    State(state): State<AppState>,
    Json(payload): Json<CreateUserRequest>,
) -> Result<Json<ApiResponse<UserProfile>>, AppError> {
    // Validate request
    payload.validate()?;

    // Create user through service
    let user = state.user_service.create_user(payload).await?;
    let profile = UserProfile::from(user);

    Ok(Json(ApiResponse::success(profile)))
}

/// Get user by ID
pub async fn get_user(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<UserProfile>>, AppError> {
    let user = state.user_service.get_user_by_id(user_id).await?;
    let profile = UserProfile::from(user);

    Ok(Json(ApiResponse::success(profile)))
}

/// List users with pagination
pub async fn list_users(
    Query(pagination): Query<PaginationParams>,
    Query(search): Query<UserSearchParams>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<PaginatedResponse<UserProfile>>>, AppError> {
    pagination.validate()?;

    let result = state.user_service.list_users(search, pagination).await?;
    
    let profiles: Vec<UserProfile> = result.items.into_iter().map(UserProfile::from).collect();
    let response = PaginatedResponse {
        items: profiles,
        total: result.total,
        limit: result.limit,
        offset: result.offset,
        has_more: result.has_more,
    };

    Ok(Json(ApiResponse::success(response)))
}

/// Update user
pub async fn update_user(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateUserRequest>,
) -> Result<Json<ApiResponse<UserProfile>>, AppError> {
    payload.validate()?;

    let user = state.user_service.update_user(user_id, payload).await?;
    let profile = UserProfile::from(user);

    Ok(Json(ApiResponse::success(profile)))
}

/// Delete user (soft delete)
pub async fn delete_user(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<StatusCode, AppError> {
    state.user_service.delete_user(user_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Activate user
pub async fn activate_user(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<UserProfile>>, AppError> {
    let user = state.user_service.activate_user(user_id).await?;
    let profile = UserProfile::from(user);

    Ok(Json(ApiResponse::success(profile)))
}

/// Deactivate user
pub async fn deactivate_user(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<UserProfile>>, AppError> {
    let user = state.user_service.deactivate_user(user_id).await?;
    let profile = UserProfile::from(user);

    Ok(Json(ApiResponse::success(profile)))
}

/// Search users
pub async fn search_users(
    Query(search_params): Query<UserSearchParams>,
    Query(pagination): Query<PaginationParams>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<PaginatedResponse<UserProfile>>>, AppError> {
    pagination.validate()?;

    let result = state.user_service.search_users(search_params, pagination).await?;
    
    let profiles: Vec<UserProfile> = result.items.into_iter().map(UserProfile::from).collect();
    let response = PaginatedResponse {
        items: profiles,
        total: result.total,
        limit: result.limit,
        offset: result.offset,
        has_more: result.has_more,
    };

    Ok(Json(ApiResponse::success(response)))
}

/// Bulk create users
pub async fn bulk_create_users(
    State(state): State<AppState>,
    Json(payload): Json<BulkCreateUsersRequest>,
) -> Result<Json<ApiResponse<Vec<UserProfile>>>, AppError> {
    payload.validate()?;

    let users = state.user_service.bulk_create_users(payload).await?;
    let profiles: Vec<UserProfile> = users.into_iter().map(UserProfile::from).collect();

    Ok(Json(ApiResponse::success(profiles)))
}

/// Bulk update users
pub async fn bulk_update_users(
    State(state): State<AppState>,
    Json(payload): Json<BulkUpdateUsersRequest>,
) -> Result<Json<ApiResponse<u64>>, AppError> {
    let count = state.user_service.bulk_update_users(payload).await?;

    Ok(Json(ApiResponse::success(count)))
}

/// Reset user password
pub async fn reset_password(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<String>>, AppError> {
    let reset_token = state.user_service.generate_password_reset(user_id).await?;

    Ok(Json(ApiResponse::success(reset_token)))
}

/// Get user sessions
pub async fn get_user_sessions(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<Vec<UserSession>>>, AppError> {
    let sessions = state.user_service.get_user_sessions(user_id).await?;

    Ok(Json(ApiResponse::success(sessions)))
}

/// Get user permissions
pub async fn get_user_permissions(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
) -> Result<Json<ApiResponse<Vec<UserPermission>>>, AppError> {
    let permissions = state.user_service.get_user_permissions(user_id).await?;

    Ok(Json(ApiResponse::success(permissions)))
}

/// Grant permission to user
pub async fn grant_permission(
    Path(user_id): Path<Uuid>,
    State(state): State<AppState>,
    Json(payload): Json<GrantPermissionRequest>,
) -> Result<Json<ApiResponse<UserPermission>>, AppError> {
    let permission = state.user_service.grant_permission(user_id, payload).await?;

    Ok(Json(ApiResponse::success(permission)))
}
