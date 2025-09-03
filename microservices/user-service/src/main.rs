//! DharmaGuard User Management Microservice
//! 
//! High-performance user management service built with Axum and SQLx
//! Features:
//! - Multi-tenant user management
//! - JWT-based authentication
//! - Password hashing with Argon2
//! - Redis caching
//! - Comprehensive validation
//! - Real-time metrics
//! - gRPC integration with core engine

use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    middleware,
    response::Json,
    routing::{delete, get, patch, post},
    Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::{net::SocketAddr, sync::Arc};
use tokio::signal;
use tower::ServiceBuilder;
use tower_http::{
    cors::{Any, CorsLayer},
    request_id::MakeRequestUuid,
    trace::{DefaultMakeSpan, DefaultOnRequest, DefaultOnResponse, TraceLayer},
    RequestIdLayer,
};
use tracing::{info, Level};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use uuid::Uuid;

mod auth;
mod config;
mod database;
mod error;
mod handlers;
mod middleware as mw;
mod models;
mod services;
mod validation;

use crate::{
    auth::AuthService,
    config::Config,
    database::Database,
    error::AppError,
    handlers::*,
    models::*,
    services::*,
};

/// Application state shared across all handlers
#[derive(Clone)]
pub struct AppState {
    pub db: Database,
    pub redis: redis::Client,
    pub auth: AuthService,
    pub user_service: UserService,
    pub config: Arc<Config>,
}

/// Health check response
#[derive(Serialize)]
struct HealthResponse {
    status: String,
    version: String,
    timestamp: DateTime<Utc>,
    database: String,
    redis: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize tracing
    init_tracing()?;

    // Load configuration
    let config = Arc::new(Config::from_env()?);
    info!("Configuration loaded successfully");

    // Initialize database
    let database_url = &config.database.url;
    let pool = PgPoolOptions::new()
        .max_connections(config.database.max_connections)
        .min_connections(config.database.min_connections)
        .connect(database_url)
        .await?;

    // Run database migrations
    sqlx::migrate!("./migrations").run(&pool).await?;
    info!("Database migrations completed");

    let database = Database::new(pool);

    // Initialize Redis
    let redis_client = redis::Client::open(config.redis.url.as_str())?;
    let mut redis_conn = redis_client.get_connection()?;
    redis::cmd("PING").execute(&mut redis_conn);
    info!("Redis connection established");

    // Initialize services
    let auth_service = AuthService::new(config.jwt.clone());
    let user_service = UserService::new(database.clone(), redis_client.clone());

    // Create application state
    let app_state = AppState {
        db: database,
        redis: redis_client,
        auth: auth_service,
        user_service,
        config: config.clone(),
    };

    // Build application router
    let app = create_router(app_state).await;

    // Start metrics server
    start_metrics_server(&config).await?;

    // Start main server
    let addr = SocketAddr::from(([0, 0, 0, 0], config.server.port));
    info!("Starting server on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    info!("Server shutdown complete");
    Ok(())
}

/// Initialize distributed tracing
fn init_tracing() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "user_service=debug,tower_http=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer().json())
        .init();

    info!("Tracing initialized");
    Ok(())
}

/// Create the main application router
async fn create_router(state: AppState) -> Router {
    // Health check router
    let health_router = Router::new().route("/health", get(health_check));

    // API v1 router
    let api_v1_router = Router::new()
        .nest("/users", create_user_routes())
        .nest("/auth", create_auth_routes())
        .nest("/sessions", create_session_routes())
        .nest("/permissions", create_permission_routes())
        .layer(middleware::from_fn_with_state(
            state.clone(),
            mw::auth_middleware,
        ));

    // Protected admin routes
    let admin_router = Router::new()
        .nest("/admin", create_admin_routes())
        .layer(middleware::from_fn_with_state(
            state.clone(),
            mw::admin_middleware,
        ));

    // Combine all routes
    Router::new()
        .merge(health_router)
        .nest("/api/v1", api_v1_router)
        .merge(admin_router)
        .with_state(state)
        .layer(
            ServiceBuilder::new()
                .layer(RequestIdLayer::new(MakeRequestUuid))
                .layer(
                    TraceLayer::new_for_http()
                        .make_span_with(DefaultMakeSpan::new().level(Level::INFO))
                        .on_request(DefaultOnRequest::new().level(Level::INFO))
                        .on_response(DefaultOnResponse::new().level(Level::INFO)),
                )
                .layer(
                    CorsLayer::new()
                        .allow_origin(Any)
                        .allow_methods(Any)
                        .allow_headers(Any),
                )
                .into_inner(),
        )
}

/// Create user management routes
fn create_user_routes() -> Router<AppState> {
    Router::new()
        .route("/", post(create_user).get(list_users))
        .route("/:user_id", get(get_user).patch(update_user).delete(delete_user))
        .route("/:user_id/sessions", get(get_user_sessions))
        .route("/:user_id/permissions", get(get_user_permissions).post(grant_permission))
        .route("/:user_id/activate", post(activate_user))
        .route("/:user_id/deactivate", post(deactivate_user))
        .route("/:user_id/reset-password", post(reset_password))
        .route("/search", get(search_users))
        .route("/bulk", post(bulk_create_users).patch(bulk_update_users))
}

/// Create authentication routes
fn create_auth_routes() -> Router<AppState> {
    Router::new()
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/refresh", post(refresh_token))
        .route("/register", post(register))
        .route("/forgot-password", post(forgot_password))
        .route("/reset-password", post(confirm_reset_password))
        .route("/verify-email", post(verify_email))
        .route("/resend-verification", post(resend_verification))
        .route("/change-password", post(change_password))
        .route("/enable-mfa", post(enable_mfa))
        .route("/disable-mfa", post(disable_mfa))
        .route("/verify-mfa", post(verify_mfa))
}

/// Create session management routes
fn create_session_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(list_sessions))
        .route("/:session_id", get(get_session).delete(terminate_session))
        .route("/terminate-all", post(terminate_all_sessions))
        .route("/active", get(get_active_sessions))
}

/// Create permission management routes
fn create_permission_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(list_permissions))
        .route("/roles", get(list_roles))
        .route("/roles/:role", get(get_role_permissions))
        .route("/check", post(check_permissions))
}

/// Create admin routes
fn create_admin_routes() -> Router<AppState> {
    Router::new()
        .route("/users/stats", get(get_user_statistics))
        .route("/sessions/stats", get(get_session_statistics))
        .route("/security/audit", get(get_security_audit))
        .route("/tenants", get(list_tenants).post(create_tenant))
        .route("/tenants/:tenant_id", get(get_tenant).patch(update_tenant))
        .route("/system/health", get(system_health_check))
        .route("/system/metrics", get(get_system_metrics))
}

/// Health check handler
async fn health_check(State(state): State<AppState>) -> Result<Json<HealthResponse>, AppError> {
    // Check database connectivity
    let db_status = match sqlx::query("SELECT 1").fetch_one(&state.db.pool).await {
        Ok(_) => "healthy",
        Err(_) => "unhealthy",
    };

    // Check Redis connectivity
    let redis_status = match state.redis.get_connection() {
        Ok(_) => "healthy",
        Err(_) => "unhealthy",
    };

    Ok(Json(HealthResponse {
        status: "ok".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        timestamp: Utc::now(),
        database: db_status.to_string(),
        redis: redis_status.to_string(),
    }))
}

/// Start metrics server on separate port
async fn start_metrics_server(config: &Config) -> anyhow::Result<()> {
    let metrics_router = Router::new().route("/metrics", get(metrics_handler));

    let metrics_addr = SocketAddr::from(([0, 0, 0, 0], config.metrics.port));
    
    tokio::spawn(async move {
        let listener = tokio::net::TcpListener::bind(metrics_addr).await.unwrap();
        axum::serve(listener, metrics_router).await.unwrap();
    });

    info!("Metrics server started on port {}", config.metrics.port);
    Ok(())
}

/// Metrics endpoint handler
async fn metrics_handler() -> String {
    use metrics_exporter_prometheus::PrometheusBuilder;
    
    let handle = PrometheusBuilder::new().build_recorder().handle();
    handle.render()
}

/// Graceful shutdown signal handler
async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {
            info!("Received Ctrl+C, shutting down gracefully...");
        },
        _ = terminate => {
            info!("Received SIGTERM, shutting down gracefully...");
        },
    }
}
