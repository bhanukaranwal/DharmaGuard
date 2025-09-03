#include <iostream>
#include <memory>
#include <string>
#include <csignal>
#include <atomic>
#include <thread>
#include <chrono>

#include <boost/program_options.hpp>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/sinks/rotating_file_sink.h>

#include "surveillance/trade_pattern_detector.hpp"
#include "grpc/surveillance_service.hpp"
#include "database/postgres_connection.hpp"
#include "database/redis_connection.hpp"
#include "messaging/kafka_consumer.hpp"
#include "utils/config_manager.hpp"
#include "utils/logger.hpp"
#include "utils/metrics_collector.hpp"

using namespace dharmaguard;
namespace po = boost::program_options;

// Global flag for graceful shutdown
std::atomic<bool> shutdown_requested{false};

// Signal handler for graceful shutdown
void signal_handler(int signal) {
    spdlog::info("Received signal {}, initiating graceful shutdown...", signal);
    shutdown_requested.store(true);
}

class DharmaGuardEngine {
public:
    DharmaGuardEngine() = default;
    ~DharmaGuardEngine() = default;

    bool initialize(const std::string& config_file) {
        try {
            // Initialize configuration manager
            config_manager_ = std::make_unique<utils::ConfigManager>();
            if (!config_manager_->load_config(config_file)) {
                spdlog::error("Failed to load configuration from: {}", config_file);
                return false;
            }

            // Initialize logging
            setup_logging();

            // Initialize database connections
            if (!initialize_database_connections()) {
                return false;
            }

            // Initialize trade pattern detector
            auto num_threads = config_manager_->get<size_t>("surveillance.num_threads", 
                                                          std::thread::hardware_concurrency());
            auto queue_size = config_manager_->get<size_t>("surveillance.queue_size", 1000000);
            
            pattern_detector_ = std::make_unique<surveillance::TradePatternDetector>(
                num_threads, queue_size);
            
            if (!pattern_detector_->initialize(config_file)) {
                spdlog::error("Failed to initialize trade pattern detector");
                return false;
            }

            // Set up alert callback
            pattern_detector_->set_alert_callback(
                [this](const surveillance::SurveillanceAlert& alert) {
                    handle_surveillance_alert(alert);
                });

            // Initialize Kafka consumer for real-time trade data
            if (!initialize_kafka_consumer()) {
                return false;
            }

            // Initialize gRPC service
            if (!initialize_grpc_service()) {
                return false;
            }

            // Initialize metrics collector
            metrics_collector_ = std::make_unique<utils::MetricsCollector>();
            metrics_collector_->start();

            spdlog::info("DharmaGuard Engine initialized successfully");
            return true;

        } catch (const std::exception& e) {
            spdlog::error("Error initializing DharmaGuard Engine: {}", e.what());
            return false;
        }
    }

    bool start() {
        try {
            // Start pattern detector
            if (!pattern_detector_->start()) {
                spdlog::error("Failed to start trade pattern detector");
                return false;
            }

            // Start Kafka consumer
            if (!kafka_consumer_->start()) {
                spdlog::error("Failed to start Kafka consumer");
                return false;
            }

            // Start gRPC service
            if (!grpc_service_->start()) {
                spdlog::error("Failed to start gRPC service");
                return false;
            }

            // Start metrics collection thread
            start_metrics_collection();

            spdlog::info("DharmaGuard Engine started successfully");
            return true;

        } catch (const std::exception& e) {
            spdlog::error("Error starting DharmaGuard Engine: {}", e.what());
            return false;
        }
    }

    void run() {
        spdlog::info("DharmaGuard Engine is running...");
        
        auto stats_interval = std::chrono::seconds(
            config_manager_->get<int>("monitoring.stats_interval_seconds", 60));
        auto last_stats_time = std::chrono::steady_clock::now();

        while (!shutdown_requested.load()) {
            auto now = std::chrono::steady_clock::now();
            
            // Print statistics periodically
            if (now - last_stats_time >= stats_interval) {
                print_statistics();
                last_stats_time = now;
            }

            // Process any pending maintenance tasks
            perform_maintenance();

            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        spdlog::info("Shutdown requested, stopping services...");
        stop();
    }

    void stop() {
        try {
            // Stop services in reverse order
            if (grpc_service_) {
                grpc_service_->stop();
            }

            if (kafka_consumer_) {
                kafka_consumer_->stop();
            }

            if (pattern_detector_) {
                pattern_detector_->stop();
            }

            if (metrics_collector_) {
                metrics_collector_->stop();
            }

            spdlog::info("DharmaGuard Engine stopped successfully");

        } catch (const std::exception& e) {
            spdlog::error("Error stopping DharmaGuard Engine: {}", e.what());
        }
    }

private:
    std::unique_ptr<utils::ConfigManager> config_manager_;
    std::unique_ptr<surveillance::TradePatternDetector> pattern_detector_;
    std::unique_ptr<grpc::SurveillanceService> grpc_service_;
    std::unique_ptr<database::PostgresConnection> postgres_connection_;
    std::unique_ptr<database::RedisConnection> redis_connection_;
    std::unique_ptr<messaging::KafkaConsumer> kafka_consumer_;
    std::unique_ptr<utils::MetricsCollector> metrics_collector_;

    std::thread metrics_thread_;
    std::atomic<bool> metrics_running_{false};

    void setup_logging() {
        auto log_level = config_manager_->get<std::string>("logging.level", "info");
        auto log_file = config_manager_->get<std::string>("logging.file", "dharmaguard.log");
        auto max_file_size = config_manager_->get<size_t>("logging.max_file_size_mb", 100);
        auto max_files = config_manager_->get<size_t>("logging.max_files", 10);

        // Create console and file sinks
        auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
        auto file_sink = std::make_shared<spdlog::sinks::rotating_file_sink_mt>(
            log_file, max_file_size * 1024 * 1024, max_files);

        // Create logger with multiple sinks
        auto logger = std::make_shared<spdlog::logger>("dharmaguard", 
            spdlog::sinks_init_list{console_sink, file_sink});

        // Set log level
        if (log_level == "debug") {
            logger->set_level(spdlog::level::debug);
        } else if (log_level == "info") {
            logger->set_level(spdlog::level::info);
        } else if (log_level == "warn") {
            logger->set_level(spdlog::level::warn);
        } else if (log_level == "error") {
            logger->set_level(spdlog::level::err);
        }

        spdlog::set_default_logger(logger);
        spdlog::set_pattern("[%Y-%m-%d %H:%M:%S.%e] [%^%l%$] [%t] %v");

        spdlog::info("Logging initialized - Level: {}, File: {}", log_level, log_file);
    }

    bool initialize_database_connections() {
        // Initialize PostgreSQL connection
        auto postgres_config = config_manager_->get_section("database.postgres");
        postgres_connection_ = std::make_unique<database::PostgresConnection>();
        
        if (!postgres_connection_->connect(postgres_config)) {
            spdlog::error("Failed to connect to PostgreSQL database");
            return false;
        }

        // Initialize Redis connection
        auto redis_config = config_manager_->get_section("database.redis");
        redis_connection_ = std::make_unique<database::RedisConnection>();
        
        if (!redis_connection_->connect(redis_config)) {
            spdlog::error("Failed to connect to Redis");
            return false;
        }

        spdlog::info("Database connections initialized successfully");
        return true;
    }

    bool initialize_kafka_consumer() {
        auto kafka_config = config_manager_->get_section("messaging.kafka");
        kafka_consumer_ = std::make_unique<messaging::KafkaConsumer>(kafka_config);

        // Set trade callback
        kafka_consumer_->set_trade_callback([this](const surveillance::TradeData& trade) {
            if (!pattern_detector_->process_trade(trade)) {
                spdlog::warn("Failed to process trade: {}", trade.trade_id);
            }
        });

        return kafka_consumer_->initialize();
    }

    bool initialize_grpc_service() {
        auto grpc_config = config_manager_->get_section("grpc");
        grpc_service_ = std::make_unique<grpc::SurveillanceService>(
            pattern_detector_.get(), grpc_config);

        return grpc_service_->initialize();
    }

    void handle_surveillance_alert(const surveillance::SurveillanceAlert& alert) {
        try {
            // Log the alert
            spdlog::warn("Surveillance Alert - Type: {}, Severity: {}, Description: {}",
                        alert.alert_type, 
                        static_cast<int>(alert.severity),
                        alert.description);

            // Store alert in database
            postgres_connection_->store_alert(alert);

            // Cache alert in Redis for real-time access
            redis_connection_->cache_alert(alert);

            // Send notification if high severity
            if (alert.severity >= surveillance::AlertSeverity::HIGH) {
                send_high_priority_notification(alert);
            }

            // Update metrics
            metrics_collector_->increment_alert_count(alert.alert_type);

        } catch (const std::exception& e) {
            spdlog::error("Error handling surveillance alert: {}", e.what());
        }
    }

    void send_high_priority_notification(const surveillance::SurveillanceAlert& alert) {
        // Implementation for sending notifications (email, SMS, etc.)
        spdlog::critical("HIGH PRIORITY ALERT: {}", alert.title);
        
        // TODO: Implement actual notification sending
        // - Email notifications
        // - SMS alerts
        // - Webhook calls
        // - Dashboard real-time updates
    }

    void start_metrics_collection() {
        metrics_running_.store(true);
        metrics_thread_ = std::thread([this]() {
            while (metrics_running_.load()) {
                try {
                    collect_metrics();
                    std::this_thread::sleep_for(std::chrono::seconds(10));
                } catch (const std::exception& e) {
                    spdlog::error("Error collecting metrics: {}", e.what());
                }
            }
        });
    }

    void collect_metrics() {
        // Collect pattern detector statistics
        auto stats = pattern_detector_->get_statistics();
        metrics_collector_->record_trades_processed(stats.total_trades_processed);
        metrics_collector_->record_alerts_generated(stats.total_alerts_generated);
        metrics_collector_->record_throughput(stats.throughput_trades_per_second);
        metrics_collector_->record_processing_time(stats.avg_processing_time_ns);

        // Collect system metrics
        metrics_collector_->record_memory_usage();
        metrics_collector_->record_cpu_usage();

        // Collect database metrics
        if (postgres_connection_) {
            auto db_stats = postgres_connection_->get_connection_stats();
            metrics_collector_->record_database_connections(db_stats.active_connections);
            metrics_collector_->record_database_query_time(db_stats.avg_query_time_ms);
        }
    }

    void print_statistics() {
        auto stats = pattern_detector_->get_statistics();
        
        spdlog::info("=== DharmaGuard Engine Statistics ===");
        spdlog::info("Trades Processed: {}", stats.total_trades_processed);
        spdlog::info("Alerts Generated: {}", stats.total_alerts_generated);
        spdlog::info("Queue Size: {}", stats.queue_size);
        spdlog::info("Throughput: {:.2f} trades/sec", stats.throughput_trades_per_second);
        spdlog::info("Avg Processing Time: {:.2f} μs", 
                    stats.avg_processing_time_ns / 1000.0);
        spdlog::info("Peak Processing Time: {:.2f} μs", 
                    stats.peak_processing_time_ns / 1000.0);
        spdlog::info("Memory Usage: {:.2f} MB", 
                    stats.memory_usage_bytes / (1024.0 * 1024.0));
        spdlog::info("CPU Utilization: {:.1f}%", stats.cpu_utilization_percent);
        
        // Print per-pattern statistics
        if (!stats.pattern_alerts_count.empty()) {
            spdlog::info("--- Pattern Detection Statistics ---");
            for (const auto& [pattern, count] : stats.pattern_alerts_count) {
                auto avg_time = stats.pattern_processing_time_ns.at(pattern) / 
                               std::max(count, 1UL);
                spdlog::info("{}: {} alerts, {:.2f} μs avg time", 
                           pattern, count, avg_time / 1000.0);
            }
        }
        
        spdlog::info("=====================================");
    }

    void perform_maintenance() {
        // Periodic maintenance tasks
        static auto last_cleanup = std::chrono::steady_clock::now();
        auto now = std::chrono::steady_clock::now();
        
        // Cleanup old data every hour
        if (now - last_cleanup >= std::chrono::hours(1)) {
            // Clean up old cache entries
            redis_connection_->cleanup_expired_entries();
            
            // Archive old alerts
            postgres_connection_->archive_old_alerts();
            
            last_cleanup = now;
            spdlog::info("Performed periodic maintenance");
        }
    }
};

int main(int argc, char* argv[]) {
    try {
        // Parse command line arguments
        po::options_description desc("DharmaGuard Core Engine Options");
        desc.add_options()
            ("help,h", "Show help message")
            ("config,c", po::value<std::string>()->default_value("config/engine.json"), 
             "Configuration file path")
            ("daemon,d", "Run as daemon")
            ("version,v", "Show version information");

        po::variables_map vm;
        po::store(po::parse_command_line(argc, argv, desc), vm);
        po::notify(vm);

        if (vm.count("help")) {
            std::cout << desc << std::endl;
            return 0;
        }

        if (vm.count("version")) {
            std::cout << "DharmaGuard Core Engine v1.0.0" << std::endl;
            std::cout << "High-Performance Trade Surveillance System" << std::endl;
            return 0;
        }

        // Set up signal handlers for graceful shutdown
        signal(SIGINT, signal_handler);
        signal(SIGTERM, signal_handler);

        // Initialize and start the engine
        DharmaGuardEngine engine;
        
        std::string config_file = vm["config"].as<std::string>();
        if (!engine.initialize(config_file)) {
            std::cerr << "Failed to initialize DharmaGuard Engine" << std::endl;
            return 1;
        }

        if (!engine.start()) {
            std::cerr << "Failed to start DharmaGuard Engine" << std::endl;
            return 1;
        }

        // Run the main loop
        engine.run();

        return 0;

    } catch (const std::exception& e) {
        std::cerr << "Fatal error: " << e.what() << std::endl;
        return 1;
    } catch (...) {
        std::cerr << "Unknown fatal error occurred" << std::endl;
        return 1;
    }
}
