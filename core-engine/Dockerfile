# Multi-stage build for optimized production image
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    git \
    wget \
    curl \
    ca-certificates \
    libboost-all-dev \
    libtbb-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libgrpc++-dev \
    protobuf-compiler-grpc \
    libpq-dev \
    libhiredis-dev \
    librdkafka-dev \
    libspdlog-dev \
    libbenchmark-dev \
    libgtest-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy source code
COPY . .

# Create build directory
RUN mkdir -p build

# Configure and build
RUN cd build && \
    cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=23 \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    .. && \
    ninja -j$(nproc)

# Run tests
RUN cd build && ctest --output-on-failure

# Install
RUN cd build && ninja install

# Production stage
FROM ubuntu:22.04 AS production

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libboost-program-options1.74.0 \
    libboost-system1.74.0 \
    libboost-thread1.74.0 \
    libboost-filesystem1.74.0 \
    libtbb12 \
    libprotobuf23 \
    libgrpc++1 \
    libpq5 \
    libhiredis0.14 \
    librdkafka1 \
    libspdlog1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create application user
RUN groupadd -r dharmaguard && \
    useradd -r -g dharmaguard -d /app -s /bin/bash dharmaguard

# Set working directory
WORKDIR /app

# Copy built binaries and libraries from builder stage
COPY --from=builder /usr/local/bin/dharmaguard_engine /usr/local/bin/
COPY --from=builder /usr/local/lib/libdharmaguard_core.so /usr/local/lib/

# Copy configuration files
COPY --from=builder /app/configs /app/configs/
COPY --from=builder /app/scripts/docker-entrypoint.sh /app/

# Create necessary directories
RUN mkdir -p /app/logs /app/data /app/models && \
    chown -R dharmaguard:dharmaguard /app

# Update library cache
RUN ldconfig

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:50051/health || exit 1

# Expose gRPC port
EXPOSE 50051

# Set user
USER dharmaguard

# Set environment variables
ENV PATH="/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH}"

# Entry point
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["dharmaguard_engine", "--config", "/app/configs/engine.json"]
