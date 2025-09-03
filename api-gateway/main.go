// DharmaGuard API Gateway
// High-performance, scalable API gateway with advanced features:
// - JWT authentication & authorization
// - Rate limiting with Redis backend
// - Request/response transformation
// - Circuit breaker pattern
// - Real-time metrics & observability
// - gRPC and HTTP proxy capabilities
// - WebSocket support for real-time features

package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"dharmaguard/api-gateway/internal/auth"
	"dharmaguard/api-gateway/internal/config"
	"dharmaguard/api-gateway/internal/handlers"
	"dharmaguard/api-gateway/internal/middleware"
	"dharmaguard/api-gateway/internal/metrics"
	"dharmaguard/api-gateway/internal/proxy"
	"dharmaguard/api-gateway/internal/ratelimit"

	"github.com/gin-gonic/gin"
	"github.com/go-redis/redis/v8"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/jaeger"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

var (
	logger           *zap.Logger
	cfg             *config.Config
	redisClient     *redis.Client
	grpcConnections map[string]*grpc.ClientConn
)

func main() {
	// Initialize logger
	var err error
	logger, err = zap.NewProduction()
	if err != nil {
		panic(fmt.Sprintf("Failed to initialize logger: %v", err))
	}
	defer logger.Sync()

	// Load configuration
	cfg, err = config.LoadConfig()
	if err != nil {
		logger.Fatal("Failed to load configuration", zap.Error(err))
	}

	// Initialize observability
	if err := initTracing(); err != nil {
		logger.Fatal("Failed to initialize tracing", zap.Error(err))
	}

	// Initialize Redis client
	redisClient = redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Address,
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})

	// Test Redis connection
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := redisClient.Ping(ctx).Err(); err != nil {
		logger.Fatal("Failed to connect to Redis", zap.Error(err))
	}

	// Initialize gRPC connections
	if err := initGRPCConnections(); err != nil {
		logger.Fatal("Failed to initialize gRPC connections", zap.Error(err))
	}
	defer closeGRPCConnections()

	// Initialize metrics
	metrics.InitMetrics()

	// Setup Gin router
	router := setupRouter()

	// Start metrics server
	go startMetricsServer()

	// Start main server
	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Server.Port),
		Handler:      router,
		ReadTimeout:  time.Duration(cfg.Server.ReadTimeout) * time.Second,
		WriteTimeout: time.Duration(cfg.Server.WriteTimeout) * time.Second,
		IdleTimeout:  time.Duration(cfg.Server.IdleTimeout) * time.Second,
	}

	// Start server in goroutine
	go func() {
		logger.Info("Starting API Gateway", 
			zap.Int("port", cfg.Server.Port),
			zap.String("environment", cfg.Environment))
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal("Failed to start server", zap.Error(err))
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("Shutting down server gracefully...")

	// Graceful shutdown
	ctx, cancel = context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		logger.Error("Server forced to shutdown", zap.Error(err))
	}

	logger.Info("Server shutdown complete")
}

func initTracing() error {
	// Create Jaeger exporter
	exp, err := jaeger.New(jaeger.WithCollectorEndpoint(
		jaeger.WithEndpoint(cfg.Observability.JaegerEndpoint),
	))
	if err != nil {
		return fmt.Errorf("failed to create Jaeger exporter: %w", err)
	}

	// Create tracer provider
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceNameKey.String("dharmaguard-api-gateway"),
			semconv.ServiceVersionKey.String("1.0.0"),
			semconv.DeploymentEnvironmentKey.String(cfg.Environment),
		)),
	)

	otel.SetTracerProvider(tp)
	return nil
}

func initGRPCConnections() error {
	grpcConnections = make(map[string]*grpc.ClientConn)

	services := map[string]string{
		"surveillance-engine": cfg.Services.SurveillanceEngine,
		"user-service":        cfg.Services.UserService,
		"compliance-service":  cfg.Services.ComplianceService,
		"reporting-service":   cfg.Services.ReportingService,
		"audit-service":       cfg.Services.AuditService,
		"notification-service": cfg.Services.NotificationService,
	}

	for name, address := range services {
		conn, err := grpc.Dial(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			return fmt.Errorf("failed to connect to %s at %s: %w", name, address, err)
		}
		grpcConnections[name] = conn
		logger.Info("Connected to gRPC service", zap.String("service", name), zap.String("address", address))
	}

	return nil
}

func closeGRPCConnections() {
	for name, conn := range grpcConnections {
		if err := conn.Close(); err != nil {
			logger.Error("Error closing gRPC connection", zap.String("service", name), zap.Error(err))
		}
	}
}

func setupRouter() *gin.Engine {
	// Set Gin mode
	if cfg.Environment == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	router := gin.New()

	// Global middlewares
	router.Use(gin.Logger())
	router.Use(gin.Recovery())
	router.Use(otelgin.Middleware("dharmaguard-api-gateway"))
	router.Use(middleware.CORS())
	router.Use(middleware.RequestID())
	router.Use(middleware.SecurityHeaders())

	// Initialize services
	authService := auth.NewService(cfg.JWT.Secret, cfg.JWT.Issuer, redisClient)
	rateLimiter := ratelimit.NewRedisRateLimiter(redisClient)
	proxyService := proxy.NewService(grpcConnections, logger)

	// Rate limiting middleware
	router.Use(middleware.RateLimit(rateLimiter))

	// Health check (no auth required)
	router.GET("/health", handlers.HealthCheck)
	router.GET("/ready", handlers.ReadinessCheck(redisClient, grpcConnections))

	// Authentication endpoints (no auth required)
	authGroup := router.Group("/api/v1/auth")
	{
		authGroup.POST("/login", handlers.Login(authService, proxyService))
		authGroup.POST("/refresh", handlers.RefreshToken(authService))
		authGroup.POST("/logout", handlers.Logout(authService))
		authGroup.POST("/register", handlers.Register(proxyService))
		authGroup.POST("/forgot-password", handlers.ForgotPassword(proxyService))
		authGroup.POST("/reset-password", handlers.ResetPassword(proxyService))
	}

	// Protected API routes
	apiV1 := router.Group("/api/v1")
	apiV1.Use(middleware.AuthRequired(authService))
	{
		// User management
		userGroup := apiV1.Group("/users")
		{
			userGroup.GET("", handlers.ListUsers(proxyService))
			userGroup.POST("", handlers.CreateUser(proxyService))
			userGroup.GET("/:id", handlers.GetUser(proxyService))
			userGroup.PATCH("/:id", handlers.UpdateUser(proxyService))
			userGroup.DELETE("/:id", handlers.DeleteUser(proxyService))
			userGroup.POST("/:id/activate", handlers.ActivateUser(proxyService))
			userGroup.POST("/:id/deactivate", handlers.DeactivateUser(proxyService))
			userGroup.GET("/:id/sessions", handlers.GetUserSessions(proxyService))
			userGroup.GET("/:id/permissions", handlers.GetUserPermissions(proxyService))
		}

		// Surveillance and compliance
		surveillanceGroup := apiV1.Group("/surveillance")
		{
			surveillanceGroup.GET("/alerts", handlers.GetAlerts(proxyService))
			surveillanceGroup.GET("/alerts/:id", handlers.GetAlert(proxyService))
			surveillanceGroup.PATCH("/alerts/:id", handlers.UpdateAlert(proxyService))
			surveillanceGroup.POST("/alerts/:id/resolve", handlers.ResolveAlert(proxyService))
			surveillanceGroup.GET("/patterns", handlers.GetPatterns(proxyService))
			surveillanceGroup.POST("/patterns", handlers.CreatePattern(proxyService))
			surveillanceGroup.GET("/statistics", handlers.GetSurveillanceStats(proxyService))
		}

		// Trading and positions
		tradingGroup := apiV1.Group("/trading")
		{
			tradingGroup.GET("/trades", handlers.GetTrades(proxyService))
			tradingGroup.GET("/trades/:id", handlers.GetTrade(proxyService))
			tradingGroup.GET("/positions", handlers.GetPositions(proxyService))
			tradingGroup.GET("/orders", handlers.GetOrders(proxyService))
			tradingGroup.POST("/orders", handlers.CreateOrder(proxyService))
			tradingGroup.PATCH("/orders/:id", handlers.UpdateOrder(proxyService))
		}

		// Compliance and reporting
		complianceGroup := apiV1.Group("/compliance")
		{
			complianceGroup.GET("/reports", handlers.GetReports(proxyService))
			complianceGroup.POST("/reports", handlers.GenerateReport(proxyService))
			complianceGroup.GET("/reports/:id", handlers.GetReport(proxyService))
			complianceGroup.POST("/reports/:id/submit", handlers.SubmitReport(proxyService))
			complianceGroup.GET("/violations", handlers.GetViolations(proxyService))
			complianceGroup.GET("/frameworks", handlers.GetRegulatoryFrameworks(proxyService))
		}

		// Audit trails
		auditGroup := apiV1.Group("/audit")
		{
			auditGroup.GET("/logs", handlers.GetAuditLogs(proxyService))
			auditGroup.GET("/logs/:id", handlers.GetAuditLog(proxyService))
			auditGroup.GET("/events", handlers.GetSystemEvents(proxyService))
		}

		// Notifications
		notificationGroup := apiV1.Group("/notifications")
		{
			notificationGroup.GET("", handlers.GetNotifications(proxyService))
			notificationGroup.POST("", handlers.SendNotification(proxyService))
			notificationGroup.PATCH("/:id/read", handlers.MarkAsRead(proxyService))
			notificationGroup.GET("/settings", handlers.GetNotificationSettings(proxyService))
			notificationGroup.PATCH("/settings", handlers.UpdateNotificationSettings(proxyService))
		}

		// File uploads and downloads
		fileGroup := apiV1.Group("/files")
		{
			fileGroup.POST("/upload", handlers.UploadFile(proxyService))
			fileGroup.GET("/:id/download", handlers.DownloadFile(proxyService))
			fileGroup.DELETE("/:id", handlers.DeleteFile(proxyService))
		}
	}

	// Admin routes (requires admin role)
	adminGroup := router.Group("/api/v1/admin")
	adminGroup.Use(middleware.AuthRequired(authService))
	adminGroup.Use(middleware.RequireRole("SUPER_ADMIN", "TENANT_ADMIN"))
	{
		adminGroup.GET("/tenants", handlers.ListTenants(proxyService))
		adminGroup.POST("/tenants", handlers.CreateTenant(proxyService))
		adminGroup.GET("/tenants/:id", handlers.GetTenant(proxyService))
		adminGroup.PATCH("/tenants/:id", handlers.UpdateTenant(proxyService))
		adminGroup.GET("/users/stats", handlers.GetUserStats(proxyService))
		adminGroup.GET("/system/health", handlers.SystemHealth(proxyService))
		adminGroup.GET("/system/metrics", handlers.SystemMetrics(proxyService))
		adminGroup.POST("/cache/clear", handlers.ClearCache(redisClient))
	}

	// WebSocket endpoints for real-time features
	wsGroup := router.Group("/ws")
	wsGroup.Use(middleware.WebSocketAuth(authService))
	{
		wsGroup.GET("/alerts", handlers.AlertsWebSocket(proxyService))
		wsGroup.GET("/trades", handlers.TradesWebSocket(proxyService))
		wsGroup.GET("/notifications", handlers.NotificationsWebSocket(proxyService))
		wsGroup.GET("/surveillance", handlers.SurveillanceWebSocket(proxyService))
	}

	// Static file serving for documentation
	router.Static("/docs", "./docs")
	router.StaticFile("/openapi.yaml", "./docs/api/openapi.yaml")

	return router
}

func startMetricsServer() {
	metricsRouter := gin.New()
	metricsRouter.Use(gin.Recovery())
	metricsRouter.GET("/metrics", gin.WrapH(promhttp.Handler()))

	metricsServer := &http.Server{
		Addr:    fmt.Sprintf(":%d", cfg.Metrics.Port),
		Handler: metricsRouter,
	}

	logger.Info("Starting metrics server", zap.Int("port", cfg.Metrics.Port))
	if err := metricsServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Error("Metrics server error", zap.Error(err))
	}
}
