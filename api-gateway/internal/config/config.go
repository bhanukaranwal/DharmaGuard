package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Environment string         `mapstructure:"environment"`
	Server      ServerConfig   `mapstructure:"server"`
	JWT         JWTConfig      `mapstructure:"jwt"`
	Redis       RedisConfig    `mapstructure:"redis"`
	Services    ServicesConfig `mapstructure:"services"`
	RateLimit   RateLimitConfig `mapstructure:"ratelimit"`
	Observability ObservabilityConfig `mapstructure:"observability"`
	Metrics     MetricsConfig  `mapstructure:"metrics"`
}

type ServerConfig struct {
	Port         int    `mapstructure:"port"`
	ReadTimeout  int    `mapstructure:"read_timeout"`
	WriteTimeout int    `mapstructure:"write_timeout"`
	IdleTimeout  int    `mapstructure:"idle_timeout"`
}

type JWTConfig struct {
	Secret        string `mapstructure:"secret"`
	Issuer        string `mapstructure:"issuer"`
	ExpiryHours   int    `mapstructure:"expiry_hours"`
	RefreshHours  int    `mapstructure:"refresh_hours"`
}

type RedisConfig struct {
	Address  string `mapstructure:"address"`
	Password string `mapstructure:"password"`
	DB       int    `mapstructure:"db"`
}

type ServicesConfig struct {
	SurveillanceEngine   string `mapstructure:"surveillance_engine"`
	UserService         string `mapstructure:"user_service"`
	ComplianceService   string `mapstructure:"compliance_service"`
	ReportingService    string `mapstructure:"reporting_service"`
	AuditService        string `mapstructure:"audit_service"`
	NotificationService string `mapstructure:"notification_service"`
}

type RateLimitConfig struct {
	RequestsPerMinute int `mapstructure:"requests_per_minute"`
	BurstSize        int `mapstructure:"burst_size"`
}

type ObservabilityConfig struct {
	JaegerEndpoint string `mapstructure:"jaeger_endpoint"`
}

type MetricsConfig struct {
	Port int `mapstructure:"port"`
}

func LoadConfig() (*Config, error) {
	cfg := &Config{
		Environment: getEnvString("ENVIRONMENT", "development"),
		Server: ServerConfig{
			Port:         getEnvInt("PORT", 8080),
			ReadTimeout:  getEnvInt("READ_TIMEOUT", 15),
			WriteTimeout: getEnvInt("WRITE_TIMEOUT", 15),
			IdleTimeout:  getEnvInt("IDLE_TIMEOUT", 60),
		},
		JWT: JWTConfig{
			Secret:       getEnvString("JWT_SECRET", "your-secret-key"),
			Issuer:       getEnvString("JWT_ISSUER", "dharmaguard"),
			ExpiryHours:  getEnvInt("JWT_EXPIRY_HOURS", 24),
			RefreshHours: getEnvInt("JWT_REFRESH_HOURS", 168),
		},
		Redis: RedisConfig{
			Address:  getEnvString("REDIS_URL", "localhost:6379"),
			Password: getEnvString("REDIS_PASSWORD", ""),
			DB:       getEnvInt("REDIS_DB", 0),
		},
		Services: ServicesConfig{
			SurveillanceEngine:  getEnvString("SURVEILLANCE_ENGINE_URL", "localhost:50051"),
			UserService:        getEnvString("USER_SERVICE_URL", "http://localhost:8081"),
			ComplianceService:  getEnvString("COMPLIANCE_SERVICE_URL", "http://localhost:8082"),
			ReportingService:   getEnvString("REPORTING_SERVICE_URL", "http://localhost:8083"),
			AuditService:       getEnvString("AUDIT_SERVICE_URL", "http://localhost:8084"),
			NotificationService: getEnvString("NOTIFICATION_SERVICE_URL", "http://localhost:8085"),
		},
		RateLimit: RateLimitConfig{
			RequestsPerMinute: getEnvInt("RATE_LIMIT_REQUESTS_PER_MINUTE", 1000),
			BurstSize:        getEnvInt("RATE_LIMIT_BURST_SIZE", 100),
		},
		Observability: ObservabilityConfig{
			JaegerEndpoint: getEnvString("JAEGER_ENDPOINT", "http://localhost:14268/api/traces"),
		},
		Metrics: MetricsConfig{
			Port: getEnvInt("METRICS_PORT", 9090),
		},
	}

	// Validate required configuration
	if cfg.JWT.Secret == "your-secret-key" && cfg.Environment == "production" {
		return nil, fmt.Errorf("JWT_SECRET must be set in production environment")
	}

	return cfg, nil
}

func getEnvString(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intValue, err := strconv.Atoi(value); err == nil {
			return intValue
		}
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	if value := os.Getenv(key); value != "" {
		return strings.ToLower(value) == "true"
	}
	return defaultValue
}
