#include "surveillance/trade_pattern_detector.hpp"
#include "surveillance/pump_dump_detector.hpp"
#include "surveillance/layering_detector.hpp"
#include "surveillance/wash_trading_detector.hpp"
#include "surveillance/insider_trading_detector.hpp"
#include "surveillance/front_running_detector.hpp"
#include "utils/logger.hpp"
#include "utils/config_manager.hpp"
#include "utils/metrics_collector.hpp"

#include <boost/json.hpp>
#include <spdlog/spdlog.h>
#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>

#include <fstream>
#include <algorithm>
#include <execution>

namespace dharmaguard {
namespace surveillance {

/**
 * @brief Internal implementation class using PIMPL pattern
 */
class TradeProcessorImpl {
public:
    explicit TradeProcessorImpl(size_t num_threads)
        : num_threads_(num_threads)
        , memory_pool_(std::make_unique<MemoryPool>(1000000)) // 1M trades buffer
        , metrics_collector_(std::make_unique<MetricsCollector>())
    {
        // Initialize performance counters
        reset_statistics();
    }

    void reset_statistics() {
        trades_processed_.store(0);
        alerts_generated_.store(0);
        total_processing_time_ns_.store(0);
        peak_processing_time_ns_.store(0);
    }

    std::atomic<uint64_t> trades_processed_{0};
    std::atomic<uint64_t> alerts_generated_{0};
    std::atomic<uint64_t> total_processing_time_ns_{0};
    std::atomic<uint64_t> peak_processing_time_ns_{0};
    
    size_t num_threads_;
    std::unique_ptr<MemoryPool> memory_pool_;
    std::unique_ptr<MetricsCollector> metrics_collector_;
    
    // Cache for frequently accessed data
    tbb::concurrent_unordered_map<std::string, HistoricalContext> context_cache_;
    
    // Performance optimization: pre-allocated vectors
    thread_local std::vector<TradeData> batch_buffer_;
};

TradePatternDetector::TradePatternDetector(size_t num_threads, size_t queue_size)
    : impl_(std::make_unique<TradeProcessorImpl>(num_threads))
    , running_(false)
    , shutdown_requested_(false)
    , trade_queue_(queue_size)
    , config_manager_(std::make_unique<PatternConfigManager>())
    , last_stats_update_(std::chrono::high_resolution_clock::now())
    , trades_processed_(0)
    , alerts_generated_(0)
    , processing_time_ns_(0)
{
    // Reserve space for worker threads
    worker_threads_.reserve(num_threads);
    
    spdlog::info("TradePatternDetector initialized with {} threads, queue size: {}", 
                 num_threads, queue_size);
}

TradePatternDetector::~TradePatternDetector() {
    if (running_.load()) {
        stop();
    }
}

bool TradePatternDetector::initialize(const std::string& config_path) {
    try {
        // Load configuration
        if (!load_configuration(config_path)) {
            spdlog::error("Failed to load configuration from: {}", config_path);
            return false;
        }
        
        // Initialize built-in pattern detectors
        initialize_builtin_detectors();
        
        spdlog::info("TradePatternDetector initialized successfully");
        return true;
    }
    catch (const std::exception& e) {
        spdlog::error("Error initializing TradePatternDetector: {}", e.what());
        return false;
    }
}

bool TradePatternDetector::start() {
    if (running_.load()) {
        spdlog::warn("TradePatternDetector is already running");
        return false;
    }
    
    shutdown_requested_.store(false);
    running_.store(true);
    
    // Start worker threads
    for (size_t i = 0; i < impl_->num_threads_; ++i) {
        worker_threads_.emplace_back(&TradePatternDetector::worker_thread_func, this);
    }
    
    // Start alert dispatcher thread
    alert_dispatcher_thread_ = std::thread(&TradePatternDetector::alert_dispatcher_func, this);
    
    spdlog::info("TradePatternDetector started with {} worker threads", impl_->num_threads_);
    return true;
}

void TradePatternDetector::stop() {
    if (!running_.load()) {
        return;
    }
    
    spdlog::info("Stopping TradePatternDetector...");
    
    shutdown_requested_.store(true);
    running_.store(false);
    
    // Wait for all worker threads to finish
    for (auto& thread : worker_threads_) {
        if (thread.joinable()) {
            thread.join();
        }
    }
    
    // Stop alert dispatcher
    if (alert_dispatcher_thread_.joinable()) {
        alert_dispatcher_thread_.join();
    }
    
    worker_threads_.clear();
    
    // Log final statistics
    auto stats = get_statistics();
    spdlog::info("TradePatternDetector stopped. Final stats - Trades: {}, Alerts: {}, "
                 "Throughput: {:.2f} trades/sec",
                 stats.total_trades_processed,
                 stats.total_alerts_generated,
                 stats.throughput_trades_per_second);
}

bool TradePatternDetector::process_trade(const TradeData& trade) {
    if (!running_.load()) {
        return false;
    }
    
    if (!validate_trade_data(trade)) {
        spdlog::warn("Invalid trade data received: {}", trade.trade_id);
        return false;
    }
    
    // Allocate trade from memory pool for zero-copy processing
    TradeData* pooled_trade = impl_->memory_pool_->allocate();
    if (!pooled_trade) {
        spdlog::error("Memory pool exhausted, dropping trade: {}", trade.trade_id);
        return false;
    }
    
    *pooled_trade = trade;
    
    // Push to lock-free queue
    if (!trade_queue_.push(pooled_trade)) {
        impl_->memory_pool_->deallocate(pooled_trade);
        spdlog::warn("Trade queue full, dropping trade: {}", trade.trade_id);
        return false;
    }
    
    return true;
}

size_t TradePatternDetector::process_trades_batch(const std::vector<TradeData>& trades) {
    if (!running_.load()) {
        return 0;
    }
    
    size_t successful_count = 0;
    
    // Process trades in parallel for validation
    std::vector<bool> validation_results(trades.size());
    
    tbb::parallel_for(tbb::blocked_range<size_t>(0, trades.size()),
        [&](const tbb::blocked_range<size_t>& range) {
            for (size_t i = range.begin(); i != range.end(); ++i) {
                validation_results[i] = validate_trade_data(trades[i]);
            }
        });
    
    // Queue valid trades
    for (size_t i = 0; i < trades.size(); ++i) {
        if (validation_results[i]) {
            if (process_trade(trades[i])) {
                ++successful_count;
            }
        }
    }
    
    return successful_count;
}

void TradePatternDetector::register_pattern_detector(
    const std::string& pattern_name,
    std::shared_ptr<IPatternDetector> detector) {
    
    detectors_[pattern_name] = std::move(detector);
    spdlog::info("Registered pattern detector: {}", pattern_name);
}

ProcessingStats TradePatternDetector::get_statistics() const {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    
    ProcessingStats stats = statistics_;
    
    // Update real-time counters
    stats.total_trades_processed = trades_processed_.load();
    stats.total_alerts_generated = alerts_generated_.load();
    stats.queue_size = trade_queue_.read_available();
    
    // Calculate throughput
    auto now = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::seconds>(
        now - last_stats_update_).count();
    
    if (duration > 0) {
        stats.throughput_trades_per_second = 
            static_cast<double>(stats.total_trades_processed) / duration;
    }
    
    stats.last_updated = std::chrono::system_clock::now();
    
    return stats;
}

void TradePatternDetector::set_alert_callback(
    std::function<void(const SurveillanceAlert&)> callback) {
    alert_callback_ = std::move(callback);
}

void TradePatternDetector::toggle_pattern(const std::string& pattern_name, bool enabled) {
    auto it = detectors_.find(pattern_name);
    if (it != detectors_.end()) {
        it->second->set_enabled(enabled);
        spdlog::info("Pattern {} {}", pattern_name, enabled ? "enabled" : "disabled");
    } else {
        spdlog::warn("Pattern not found: {}", pattern_name);
    }
}

void TradePatternDetector::update_pattern_config(
    const std::string& pattern_name,
    const PatternConfig& config) {
    
    auto it = detectors_.find(pattern_name);
    if (it != detectors_.end()) {
        it->second->update_config(config);
        spdlog::info("Updated configuration for pattern: {}", pattern_name);
    } else {
        spdlog::warn("Pattern not found: {}", pattern_name);
    }
}

void TradePatternDetector::worker_thread_func() {
    spdlog::debug("Worker thread started: {}", std::this_thread::get_id());
    
    TradeData* trade = nullptr;
    
    while (running_.load() || !trade_queue_.empty()) {
        if (trade_queue_.pop(trade)) {
            if (trade) {
                auto start_time = std::chrono::high_resolution_clock::now();
                
                process_trade_internal(*trade);
                
                auto end_time = std::chrono::high_resolution_clock::now();
                auto processing_time = std::chrono::duration_cast<std::chrono::nanoseconds>(
                    end_time - start_time).count();
                
                // Update performance metrics
                processing_time_ns_.fetch_add(processing_time);
                
                // Update peak processing time
                uint64_t current_peak = peak_processing_time_ns_.load();
                while (processing_time > current_peak &&
                       !peak_processing_time_ns_.compare_exchange_weak(current_peak, processing_time)) {
                    // Retry until successful or no longer the peak
                }
                
                trades_processed_.fetch_add(1);
                
                // Return trade to memory pool
                impl_->memory_pool_->deallocate(trade);
            }
        } else {
            // No trades available, yield to avoid busy waiting
            std::this_thread::yield();
        }
    }
    
    spdlog::debug("Worker thread finished: {}", std::this_thread::get_id());
}

void TradePatternDetector::alert_dispatcher_func() {
    spdlog::debug("Alert dispatcher thread started");
    
    SurveillanceAlert alert;
    
    while (running_.load() || !alert_queue_.empty()) {
        if (alert_queue_.try_pop(alert)) {
            if (alert_callback_) {
                try {
                    alert_callback_(alert);
                } catch (const std::exception& e) {
                    spdlog::error("Error in alert callback: {}", e.what());
                }
            }
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    
    spdlog::debug("Alert dispatcher thread finished");
}

void TradePatternDetector::process_trade_internal(const TradeData& trade) {
    // Get or create historical context for the instrument
    HistoricalContext context;
    auto context_key = trade.instrument_symbol + "_" + trade.account_id;
    
    auto context_it = impl_->context_cache_.find(context_key);
    if (context_it != impl_->context_cache_.end()) {
        context = context_it->second;
    }
    
    // Update context with current trade
    context.recent_trades.push_back(trade);
    
    // Keep only recent trades (sliding window)
    auto cutoff_time = trade.timestamp - context.lookback_window;
    context.recent_trades.erase(
        std::remove_if(context.recent_trades.begin(), context.recent_trades.end(),
                      [cutoff_time](const TradeData& t) {
                          return t.timestamp < cutoff_time;
                      }),
        context.recent_trades.end());
    
    // Update context cache
    impl_->context_cache_[context_key] = context;
    
    // Run all enabled pattern detectors in parallel
    std::vector<std::pair<std::string, std::shared_ptr<IPatternDetector>>> enabled_detectors;
    for (const auto& [name, detector] : detectors_) {
        if (detector->is_enabled()) {
            enabled_detectors.emplace_back(name, detector);
        }
    }
    
    tbb::parallel_for(tbb::blocked_range<size_t>(0, enabled_detectors.size()),
        [&](const tbb::blocked_range<size_t>& range) {
            for (size_t i = range.begin(); i != range.end(); ++i) {
                const auto& [name, detector] = enabled_detectors[i];
                
                try {
                    auto alert_opt = detector->detect_pattern(trade, context);
                    if (alert_opt) {
                        alert_queue_.push(*alert_opt);
                        alerts_generated_.fetch_add(1);
                        
                        spdlog::info("Alert generated by {}: {} for trade {}", 
                                   name, alert_opt->title, trade.trade_id);
                    }
                } catch (const std::exception& e) {
                    spdlog::error("Error in pattern detector {}: {}", name, e.what());
                }
            }
        });
}

void TradePatternDetector::initialize_builtin_detectors() {
    // Register built-in pattern detectors
    register_pattern_detector("pump_dump", 
        std::make_shared<PumpDumpDetector>());
    
    register_pattern_detector("layering", 
        std::make_shared<LayeringDetector>());
    
    register_pattern_detector("wash_trading", 
        std::make_shared<WashTradingDetector>());
    
    register_pattern_detector("insider_trading", 
        std::make_shared<InsiderTradingDetector>());
    
    register_pattern_detector("front_running", 
        std::make_shared<FrontRunningDetector>());
    
    spdlog::info("Initialized {} built-in pattern detectors", detectors_.size());
}

bool TradePatternDetector::load_configuration(const std::string& config_path) {
    try {
        std::ifstream config_file(config_path);
        if (!config_file.is_open()) {
            spdlog::error("Cannot open configuration file: {}", config_path);
            return false;
        }
        
        std::string json_content((std::istreambuf_iterator<char>(config_file)),
                                std::istreambuf_iterator<char>());
        
        auto config_json = boost::json::parse(json_content);
        
        // Parse configuration and update detectors
        if (config_json.as_object().contains("patterns")) {
            const auto& patterns = config_json.at("patterns").as_object();
            
            for (const auto& [pattern_name, pattern_config] : patterns) {
                config_manager_->load_pattern_config(
                    std::string(pattern_name), pattern_config);
            }
        }
        
        return true;
    }
    catch (const std::exception& e) {
        spdlog::error("Error loading configuration: {}", e.what());
        return false;
    }
}

bool TradePatternDetector::validate_trade_data(const TradeData& trade) const {
    if (!trade.is_valid()) {
        return false;
    }
    
    // Additional validation rules
    if (trade.timestamp > std::chrono::system_clock::now()) {
        spdlog::warn("Trade timestamp is in the future: {}", trade.trade_id);
        return false;
    }
    
    if (trade.price <= 0.0 || trade.quantity == 0) {
        spdlog::warn("Invalid price or quantity: {}", trade.trade_id);
        return false;
    }
    
    return true;
}

} // namespace surveillance
} // namespace dharmaguard
