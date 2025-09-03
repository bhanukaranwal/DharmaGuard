//! User data models and related types

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;
use validator::Validate;

/// User role enumeration
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "user_role", rename_all = "SCREAMING_SNAKE_CASE")]
pub enum UserRole {
    SuperAdmin,
    TenantAdmin,
    ComplianceOfficer,
    Trader,
    Viewer,
}

/// User entity from database
#[derive(Debug, Clone, FromRow, Serialize)]
pub struct User {
    pub user_id: Uuid,
    pub tenant_id: Uuid,
    pub username: String,
    pub email: String,
    #[serde(skip_serializing)]
    pub password_hash: String,
    #[serde(skip_serializing)]
    pub salt: String,
    pub role: UserRole,
    pub is_active: bool,
    pub is_verified: bool,
    pub mfa_enabled: bool,
    #[serde(skip_serializing)]
    pub mfa_secret: Option<String>,
    pub failed_login_attempts: i32,
    pub locked_until: Option<DateTime<Utc>>,
    pub last_login_at: Option<DateTime<Utc>>,
    pub last_password_change: DateTime<Utc>,
    pub password_expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// User creation request
#[derive(Debug, Deserialize, Validate)]
pub struct CreateUserRequest {
    pub tenant_id: Uuid,
    
    #[validate(length(min = 3, max = 50))]
    #[validate(regex = "^[a-zA-Z0-9_-]+$")]
    pub username: String,
    
    #[validate(email)]
    pub email: String,
    
    #[validate(length(min = 12, max = 128))]
    pub password: String,
    
    pub role: UserRole,
    
    #[serde(default)]
    pub send_welcome_email: bool,
}

/// User update request
#[derive(Debug, Deserialize, Validate)]
pub struct UpdateUserRequest {
    #[validate(email)]
    pub email: Option<String>,
    
    pub role: Option<UserRole>,
    pub is_active: Option<bool>,
}

/// User search parameters
#[derive(Debug, Deserialize, Validate)]
pub struct UserSearchParams {
    pub tenant_id: Option<Uuid>,
    pub username: Option<String>,
    pub email: Option<String>,
    pub role: Option<UserRole>,
    pub is_active: Option<bool>,
    pub is_verified: Option<bool>,
    pub created_after: Option<DateTime<Utc>>,
    pub created_before: Option<DateTime<Utc>>,
}

/// Password change request
#[derive(Debug, Deserialize, Validate)]
pub struct ChangePasswordRequest {
    #[validate(length(min = 1))]
    pub current_password: String,
    
    #[validate(length(min = 12, max = 128))]
    pub new_password: String,
    
    #[serde(default)]
    pub logout_all_sessions: bool,
}

/// Password reset request
#[derive(Debug, Deserialize, Validate)]
pub struct ResetPasswordRequest {
    #[validate(email)]
    pub email: String,
}

/// Password reset confirmation
#[derive(Debug, Deserialize, Validate)]
pub struct ConfirmResetPasswordRequest {
    pub reset_token: String,
    
    #[validate(length(min = 12, max = 128))]
    pub new_password: String,
}

/// User statistics
#[derive(Debug, Serialize)]
pub struct UserStatistics {
    pub total_users: u64,
    pub active_users: u64,
    pub verified_users: u64,
    pub users_with_mfa: u64,
    pub locked_users: u64,
    pub users_by_role: std::collections::HashMap<String, u64>,
    pub recent_registrations: u64,
    pub password_expiry_soon: u64,
}

/// Bulk user creation request
#[derive(Debug, Deserialize, Validate)]
pub struct BulkCreateUsersRequest {
    #[validate(length(min = 1, max = 100))]
    pub users: Vec<CreateUserRequest>,
    
    #[serde(default)]
    pub skip_duplicates: bool,
    
    #[serde(default)]
    pub send_welcome_emails: bool,
}

/// Bulk user update request
#[derive(Debug, Deserialize)]
pub struct BulkUpdateUsersRequest {
    pub user_ids: Vec<Uuid>,
    pub updates: UpdateUserRequest,
}

/// User profile response (public information)
#[derive(Debug, Serialize)]
pub struct UserProfile {
    pub user_id: Uuid,
    pub username: String,
    pub email: String,
    pub role: UserRole,
    pub is_active: bool,
    pub is_verified: bool,
    pub mfa_enabled: bool,
    pub last_login_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

impl From<User> for UserProfile {
    fn from(user: User) -> Self {
        Self {
            user_id: user.user_id,
            username: user.username,
            email: user.email,
            role: user.role,
            is_active: user.is_active,
            is_verified: user.is_verified,
            mfa_enabled: user.mfa_enabled,
            last_login_at: user.last_login_at,
            created_at: user.created_at,
        }
    }
}

/// MFA enable request
#[derive(Debug, Deserialize)]
pub struct EnableMfaRequest {
    pub backup_codes: Option<Vec<String>>,
}

/// MFA verification request
#[derive(Debug, Deserialize, Validate)]
pub struct VerifyMfaRequest {
    #[validate(length(min = 6, max = 6))]
    pub totp_code: String,
}

/// Email verification request
#[derive(Debug, Deserialize)]
pub struct VerifyEmailRequest {
    pub verification_token: String,
}
