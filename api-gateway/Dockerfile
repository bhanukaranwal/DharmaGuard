# Multi-stage build for optimized production image
FROM golang:1.22-alpine AS builder

# Install build dependencies
RUN apk --no-cache add ca-certificates git

# Set working directory
WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags='-w -s -extldflags "-static"' \
    -a -installsuffix cgo \
    -o api-gateway ./main.go

# Production stage
FROM scratch

# Import SSL certificates from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the binary
COPY --from=builder /app/api-gateway /api-gateway

# Copy configuration files
COPY --from=builder /app/docs /docs

# Expose ports
EXPOSE 8080 9090

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/api-gateway", "-health-check"] || exit 1

# Run the application
ENTRYPOINT ["/api-gateway"]
