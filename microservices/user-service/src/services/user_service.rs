//! User service business logic implementation

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use chrono::{Duration, Utc};
use sqlx::Row;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::{
    database::Database,
    error::AppError,
    models::*,
};

#[derive(Clone)]
pub struct UserService {
    db: Database,
    redis: redis::Client,
}

impl UserService {
    pub fn new(db: Database, redis: redis::Client) -> Self {
        Self { db, redis }
    }

    /// Create a new user
    pub async fn create_user(&self, request: CreateUserRequest) -> Result<User, AppError> {
        // Check if user already exists
        if self.user_exists(&request.username, &request.email, request.tenant_id).await? {
            return Err(AppError::Conflict("User already exists".to_string()));
        }

        // Hash password
        let salt = SaltString::generate(&mut OsRng);
        let argon2 = Argon2::default();
        let password_hash = argon2
            .hash_password(request.password.as_bytes(), &salt)
            .map_err(|e| AppError::Internal(format!("Password hashing failed: {}", e)))?
            .to_string();

        // Create user in database
        let user_id = Uuid::new_v4();
        let now = Utc::now();
        let password_expires_at = now + Duration::days(90); // 90-day password expiry

        let user = sqlx::query_as::<_, User>(
            r#"
            INSERT INTO users (
                user_id, tenant_id, username, email, password_hash, salt, role,
                is_active, is_verified, mfa_enabled, failed_login_attempts,
                last_password_change, password_expires_at, created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
            RETURNING *
            "#,
        )
        .bind(user_id)
        .bind(request.tenant_id)
        .bind(&request.username)
        .bind(&request.email)
        .bind(&password_hash)
        .bind(salt.as_str())
        .bind(&request.role)
        .bind(true) // is_active
        .bind(false) // is_verified
        .bind(false) // mfa_enabled
        .bind(0) // failed_login_attempts
        .bind(now) // last_password_change
        .bind(password_expires_at)
        .bind(now) // created_at
        .bind(now) // updated_at
        .fetch_one(&self.db.pool)
        .await?;

        // Send welcome email if requested
        if request.send_welcome_email {
            self.send_welcome_email(&user).await?;
        }

        // Log user creation
        info!(
            "User created: {} ({}), Tenant: {}, Role: {:?}",
            user.username, user.email, user.tenant_id, user.role
        );

        // Clear user cache
        self.invalidate_user_cache(user_id).await?;

        Ok(user)
    }

    /// Get user by ID
    pub async fn get_user_by_id(&self, user_id: Uuid) -> Result<User, AppError> {
        // Try cache first
        if let Ok(cached_user) = self.get_cached_user(user_id).await {
            return Ok(cached_user);
        }

        // Fetch from database
        let user = sqlx::query_as::<_, User>("SELECT * FROM users WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&self.db.pool)
            .await?
            .ok_or(AppError::NotFound("User not found".to_string()))?;

        // Cache user
        self.cache_user(&user).await?;

        Ok(user)
    }

    /// List users with search and pagination
    pub async fn list_users(
        &self,
        search: UserSearchParams,
        pagination: PaginationParams,
    ) -> Result<PaginatedResponse<User>, AppError> {
        let limit = pagination.limit.unwrap_or(20);
        let offset = pagination.offset.unwrap_or(0);

        // Build dynamic query
        let mut query = "SELECT * FROM users WHERE 1=1".to_string();
        let mut count_query = "SELECT COUNT(*) FROM users WHERE 1=1".to_string();
        let mut bind_values: Vec<Box<dyn sqlx::Encode<'_, sqlx::Postgres> + Send + Sync>> = Vec::new();
        let mut param_count = 0;

        // Add search filters
        if let Some(tenant_id) = search.tenant_id {
            param_count += 1;
            query.push_str(&format!(" AND tenant_id = ${}", param_count));
            count_query.push_str(&format!(" AND tenant_id = ${}", param_count));
            bind_values.push(Box::new(tenant_id));
        }

        if let Some(username) = search.username {
            param_count += 1;
            query.push_str(&format!(" AND username ILIKE ${}", param_count));
            count_query.push_str(&format!(" AND username ILIKE ${}", param_count));
            bind_values.push(Box::new(format!("%{}%", username)));
        }

        if let Some(email) = search.email {
            param_count += 1;
            query.push_str(&format!(" AND email ILIKE ${}", param_count));
            count_query.push_str(&format!(" AND email ILIKE ${}", param_count));
            bind_values.push(Box::new(format!("%{}%", email)));
        }

        if let Some(is_active) = search.is_active {
            param_count += 1;
            query.push_str(&format!(" AND is_active = ${}", param_count));
            count_query.push_str(&format!(" AND is_active = ${}", param_count));
            bind_values.push(Box::new(is_active));
        }

        // Add sorting
        let sort_by = pagination.sort_by.unwrap_or_else(|| "created_at".to_string());
        let sort_order = match pagination.sort_order.unwrap_or(SortOrder::Desc) {
            SortOrder::Asc => "ASC",
            SortOrder::Desc => "DESC",
        };
        query.push_str(&format!(" ORDER BY {} {}", sort_by, sort_order));

        // Add pagination
        query.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));

        // Execute queries (simplified - in real implementation, use proper parameter binding)
        let users = sqlx::query_as::<_, User>(&query)
            .fetch_all(&self.db.pool)
            .await?;

        let total_count: i64 = sqlx::query(&count_query)
            .fetch_one(&self.db.pool)
            .await?
            .get(0);

        Ok(PaginatedResponse {
            items: users,
            total: total_count as u64,
            limit,
            offset,
            has_more: (offset + limit) < total_count as u32,
        })
    }

    /// Update user
    pub async fn update_user(
        &self,
        user_id: Uuid,
        request: UpdateUserRequest,
    ) -> Result<User, AppError> {
        let mut user = self.get_user_by_id(user_id).await?;

        // Update fields
        if let Some(email) = request.email {
            user.email = email;
        }
        if let Some(role) = request.role {
            user.role = role;
        }
        if let Some(is_active) = request.is_active {
            user.is_active = is_active;
        }

        user.updated_at = Utc::now();

        // Update in database
        let updated_user = sqlx::query_as::<_, User>(
            r#"
            UPDATE users 
            SET email = $2, role = $3, is_active = $4, updated_at = $5
            WHERE user_id = $1
            RETURNING *
            "#,
        )
        .bind(user_id)
        .bind(&user.email)
        .bind(&user.role)
        .bind(user.is_active)
        .bind(user.updated_at)
        .fetch_one(&self.db.pool)
        .await?;

        // Invalidate cache
        self.invalidate_user_cache(user_id).await?;

        info!("User updated: {} ({})", updated_user.username, updated_user.email);

        Ok(updated_user)
    }

    /// Soft delete user
    pub async fn delete_user(&self, user_id: Uuid) -> Result<(), AppError> {
        let result = sqlx::query(
            "UPDATE users SET is_active = false, updated_at = $2 WHERE user_id = $1",
        )
        .bind(user_id)
        .bind(Utc::now())
        .execute(&self.db.pool)
        .await?;

        if result.rows_affected() == 0 {
            return Err(AppError::NotFound("User not found".to_string()));
        }

        // Invalidate cache
        self.invalidate_user_cache(user_id).await?;

        // Terminate all user sessions
        self.terminate_all_user_sessions(user_id).await?;

        info!("User soft deleted: {}", user_id);

        Ok(())
    }

    /// Verify user password
    pub async fn verify_password(&self, user_id: Uuid, password: &str) -> Result<bool, AppError> {
        let user = self.get_user_by_id(user_id).await?;
        
        let parsed_hash = PasswordHash::new(&user.password_hash)
            .map_err(|e| AppError::Internal(format!("Invalid password hash: {}", e)))?;

        let is_valid = Argon2::default()
            .verify_password(password.as_bytes(), &parsed_hash)
            .is_ok();

        Ok(is_valid)
    }

    /// Change user password
    pub async fn change_password(
        &self,
        user_id: Uuid,
        current_password: &str,
        new_password: &str,
    ) -> Result<(), AppError> {
        // Verify current password
        if !self.verify_password(user_id, current_password).await? {
            return Err(AppError::Unauthorized("Invalid current password".to_string()));
        }

        // Hash new password
        let salt = SaltString::generate(&mut OsRng);
        let argon2 = Argon2::default();
        let password_hash = argon2
            .hash_password(new_password.as_bytes(), &salt)
            .map_err(|e| AppError::Internal(format!("Password hashing failed: {}", e)))?
            .to_string();

        let now = Utc::now();
        let password_expires_at = now + Duration::days(90);

        // Update password in database
        sqlx::query(
            r#"
            UPDATE users 
            SET password_hash = $2, salt = $3, last_password_change = $4, 
                password_expires_at = $5, failed_login_attempts = 0, locked_until = NULL,
                updated_at = $6
            WHERE user_id = $1
            "#,
        )
        .bind(user_id)
        .bind(&password_hash)
        .bind(salt.as_str())
        .bind(now)
        .bind(password_expires_at)
        .bind(now)
        .execute(&self.db.pool)
        .await?;

        // Invalidate cache
        self.invalidate_user_cache(user_id).await?;

        info!("Password changed for user: {}", user_id);

        Ok(())
    }

    // Helper methods

    async fn user_exists(&self, username: &str, email: &str, tenant_id: Uuid) -> Result<bool, AppError> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM users WHERE (username = $1 OR email = $2) AND tenant_id = $3"
        )
        .bind(username)
        .bind(email)
        .bind(tenant_id)
        .fetch_one(&self.db.pool)
        .await?;

        Ok(count > 0)
    }

    async fn send_welcome_email(&self, _user: &User) -> Result<(), AppError> {
        // TODO: Implement email sending
        info!("Welcome email would be sent to: {}", _user.email);
        Ok(())
    }

    async fn get_cached_user(&self, user_id: Uuid) -> Result<User, AppError> {
        let mut conn = self.redis.get_connection()
            .map_err(|e| AppError::Internal(format!("Redis connection error: {}", e)))?;
        
        let cached_data: Option<String> = redis::cmd("GET")
            .arg(format!("user:{}", user_id))
            .query(&mut conn)
            .map_err(|e| AppError::Internal(format!("Redis query error: {}", e)))?;

        match cached_data {
            Some(data) => {
                serde_json::from_str(&data)
                    .map_err(|e| AppError::Internal(format!("User deserialization error: {}", e)))
            }
            None => Err(AppError::NotFound("User not in cache".to_string())),
        }
    }

    async fn cache_user(&self, user: &User) -> Result<(), AppError> {
        let mut conn = self.redis.get_connection()
            .map_err(|e| AppError::Internal(format!("Redis connection error: {}", e)))?;

        let user_data = serde_json::to_string(user)
            .map_err(|e| AppError::Internal(format!("User serialization error: {}", e)))?;

        redis::cmd("SETEX")
            .arg(format!("user:{}", user.user_id))
            .arg(3600) // 1 hour expiry
            .arg(user_data)
            .execute(&mut conn);

        Ok(())
    }

    async fn invalidate_user_cache(&self, user_id: Uuid) -> Result<(), AppError> {
        let mut conn = self.redis.get_connection()
            .map_err(|e| AppError::Internal(format!("Redis connection error: {}", e)))?;

        redis::cmd("DEL")
            .arg(format!("user:{}", user_id))
            .execute(&mut conn);

        Ok(())
    }

    async fn terminate_all_user_sessions(&self, user_id: Uuid) -> Result<(), AppError> {
        sqlx::query("UPDATE user_sessions SET is_active = false WHERE user_id = $1")
            .bind(user_id)
            .execute(&self.db.pool)
            .await?;

        // Also clear from Redis session cache
        let mut conn = self.redis.get_connection()
            .map_err(|e| AppError::Internal(format!("Redis connection error: {}", e)))?;

        redis::cmd("DEL")
            .arg(format!("sessions:user:{}", user_id))
            .execute(&mut conn);

        Ok(())
    }
}
