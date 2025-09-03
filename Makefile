# DharmaGuard Enterprise Platform Makefile
# Comprehensive automation for development, testing, and deployment

.PHONY: help dev test build clean docker deploy lint format security benchmark docs

# Colors for output
RED=\033[0;31m
GREEN=\033[0;32m
YELLOW=\033[1;33m
BLUE=\033[0;34m
NC=\033[0m # No Color

# Default target
help: ## Show this help message
	@echo "$(BLUE)DharmaGuard Platform - Available Commands$(NC)"
	@echo "================================================="
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

# Development commands
dev: ## Start development environment
	@echo "$(YELLOW)Starting DharmaGuard development environment...$(NC)"
	docker-compose up -d postgres redis clickhouse kafka zookeeper
	@echo "$(GREEN)Development environment started!$(NC)"
	@echo "Access points:"
	@echo "- Frontend: http://localhost:3000"
	@echo "- API Gateway: http://localhost:8080"
	@echo "- Grafana: http://localhost:3001"

dev-full: ## Start complete development stack
	@echo "$(YELLOW)Starting complete DharmaGuard stack...$(NC)"
	docker-compose up -d
	@echo "$(GREEN)Complete stack started!$(NC)"

dev-stop: ## Stop development environment
	@echo "$(YELLOW)Stopping development environment...$(NC)"
	docker-compose down
	@echo "$(GREEN)Development environment stopped!$(NC)"

dev-clean: ## Clean development environment (removes volumes)
	@echo "$(RED)Cleaning development environment (this will remove all data)...$(NC)"
	docker-compose down -v --remove-orphans
	docker system prune -f
	@echo "$(GREEN)Development environment cleaned!$(NC)"

# Database commands
db-migrate: ## Run database migrations
	@echo "$(YELLOW)Running database migrations...$(NC)"
	docker-compose exec postgres psql -U dharmaguard -d dharmaguard -f /docker-entrypoint-initdb.d/001_schema.sql
	docker-compose exec postgres psql -U dharmaguard -d dharmaguard -f /docker-entrypoint-initdb.d/002_compliance_schema.sql
	@echo "$(GREEN)Database migrations completed!$(NC)"

db-seed: ## Seed database with test data
	@echo "$(YELLOW)Seeding database with test data...$(NC)"
	./scripts/database/seed-test-data.sh
	@echo "$(GREEN)Database seeded successfully!$(NC)"

db-reset: ## Reset database (WARNING: destroys all data)
	@echo "$(RED)Resetting database (this will destroy all data)...$(NC)"
	docker-compose exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS dharmaguard;"
	docker-compose exec postgres psql -U postgres -c "CREATE DATABASE dharmaguard OWNER dharmaguard;"
	$(MAKE) db-migrate
	@echo "$(GREEN)Database reset completed!$(NC)"

# Build commands
build: build-core build-services build-gateway build-frontend ## Build all components

build-core: ## Build core surveillance engine
	@echo "$(YELLOW)Building core surveillance engine...$(NC)"
	cd core-engine && mkdir -p build && cd build && \
	cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=23 .. && \
	make -j$$(nproc)
	@echo "$(GREEN)Core engine built successfully!$(NC)"

build-services: ## Build all Rust microservices
	@echo "$(YELLOW)Building Rust microservices...$(NC)"
	cd microservices/user-service && cargo build --release
	cd microservices/compliance-service && cargo build --release
	cd microservices/reporting-service && cargo build --release
	cd microservices/audit-service && cargo build --release
	@echo "$(GREEN)Microservices built successfully!$(NC)"

build-gateway: ## Build API gateway
	@echo "$(YELLOW)Building API gateway...$(NC)"
	cd api-gateway && go build -o bin/api-gateway .
	@echo "$(GREEN)API gateway built successfully!$(NC)"

build-frontend: ## Build frontend application
	@echo "$(YELLOW)Building frontend application...$(NC)"
	cd frontend && npm ci && npm run build
	@echo "$(GREEN)Frontend built successfully!$(NC)"

build-ml: ## Build ML platform
	@echo "$(YELLOW)Building ML platform...$(NC)"
	cd ml-platform && pip install -r requirements.txt
	@echo "$(GREEN)ML platform built successfully!$(NC)"

# Docker commands
docker: ## Build all Docker images
	@echo "$(YELLOW)Building Docker images...$(NC)"
	docker build -t dharmaguard/surveillance-engine:latest ./core-engine
	docker build -t dharmaguard/user-service:latest ./microservices/user-service
	docker build -t dharmaguard/compliance-service:latest ./microservices/compliance-service
	docker build -t dharmaguard/reporting-service:latest ./microservices/reporting-service
	docker build -t dharmaguard/audit-service:latest ./microservices/audit-service
	docker build -t dharmaguard/api-gateway:latest ./api-gateway
	docker build -t dharmaguard/frontend:latest ./frontend
	docker build -t dharmaguard/ml-platform:latest ./ml-platform
	@echo "$(GREEN)Docker images built successfully!$(NC)"

docker-push: ## Push Docker images to registry
	@echo "$(YELLOW)Pushing Docker images to registry...$(NC)"
	docker push dharmaguard/surveillance-engine:latest
	docker push dharmaguard/user-service:latest
	docker push dharmaguard/compliance-service:latest
	docker push dharmaguard/reporting-service:latest
	docker push dharmaguard/audit-service:latest
	docker push dharmaguard/api-gateway:latest
	docker push dharmaguard/frontend:latest
	docker push dharmaguard/ml-platform:latest
	@echo "$(GREEN)Docker images pushed successfully!$(NC)"

# Testing commands
test: test-unit test-integration ## Run all tests

test-unit: ## Run unit tests for all components
	@echo "$(YELLOW)Running unit tests...$(NC)"
	# Core engine tests
	cd core-engine/build && ctest --output-on-failure
	# Rust service tests
	cd microservices/user-service && cargo test
	cd microservices/compliance-service && cargo test
	cd microservices/reporting-service && cargo test
	cd microservices/audit-service && cargo test
	# Go gateway tests
	cd api-gateway && go test -v ./...
	# Frontend tests
	cd frontend && npm test -- --coverage --watchAll=false
	@echo "$(GREEN)Unit tests completed!$(NC)"

test-integration: ## Run integration tests
	@echo "$(YELLOW)Running integration tests...$(NC)"
	docker-compose -f docker-compose.test.yml up -d
	sleep 30
	./scripts/testing/run-integration-tests.sh
	docker-compose -f docker-compose.test.yml down
	@echo "$(GREEN)Integration tests completed!$(NC)"

test-load: ## Run load tests
	@echo "$(YELLOW)Running load tests...$(NC)"
	k6 run testing/load/api-gateway.js
	k6 run testing/load/surveillance-engine.js
	@echo "$(GREEN)Load tests completed!$(NC)"

test-security: ## Run security tests
	@echo "$(YELLOW)Running security tests...$(NC)"
	trivy fs --security-checks vuln,config .
	# Run SAST scans
	semgrep --config=auto .
	@echo "$(GREEN)Security tests completed!$(NC)"

# Code quality commands
lint: lint-rust lint-go lint-frontend lint-python ## Run all linters

lint-rust: ## Lint Rust code
	@echo "$(YELLOW)Linting Rust code...$(NC)"
	cd microservices/user-service && cargo clippy -- -D warnings
	cd microservices/compliance-service && cargo clippy -- -D warnings
	cd microservices/reporting-service && cargo clippy -- -D warnings
	cd microservices/audit-service && cargo clippy -- -D warnings

lint-go: ## Lint Go code
	@echo "$(YELLOW)Linting Go code...$(NC)"
	cd api-gateway && golangci-lint run

lint-frontend: ## Lint frontend code
	@echo "$(YELLOW)Linting frontend code...$(NC)"
	cd frontend && npm run lint

lint-python: ## Lint Python code
	@echo "$(YELLOW)Linting Python code...$(NC)"
	cd ml-platform && flake8 src/
	cd ml-platform && black --check src/

format: format-rust format-go format-frontend format-python ## Format all code

format-rust: ## Format Rust code
	@echo "$(YELLOW)Formatting Rust code...$(NC)"
	cd microservices/user-service && cargo fmt
	cd microservices/compliance-service && cargo fmt
	cd microservices/reporting-service && cargo fmt
	cd microservices/audit-service && cargo fmt

format-go: ## Format Go code
	@echo "$(YELLOW)Formatting Go code...$(NC)"
	cd api-gateway && gofmt -w .

format-frontend: ## Format frontend code
	@echo "$(YELLOW)Formatting frontend code...$(NC)"
	cd frontend && npm run format

format-python: ## Format Python code
	@echo "$(YELLOW)Formatting Python code...$(NC)"
	cd ml-platform && black src/

# Security commands
security: security-scan security-audit ## Run all security checks

security-scan: ## Run security scans
	@echo "$(YELLOW)Running security scans...$(NC)"
	trivy fs --security-checks vuln,config,secret .
	docker scout cves --only-severity critical,high dharmaguard/surveillance-engine:latest || true

security-audit: ## Run security audits
	@echo "$(YELLOW)Running security audits...$(NC)"
	cd microservices/user-service && cargo audit
	cd api-gateway && go mod audit || true
	cd frontend && npm audit --audit-level=high

# Benchmark commands
benchmark: benchmark-core benchmark-services ## Run all benchmarks

benchmark-core: ## Run core engine benchmarks
	@echo "$(YELLOW)Running core engine benchmarks...$(NC)"
	cd core-engine/build && ./performance_benchmarks --benchmark_format=json --benchmark_out=benchmark_results.json

benchmark-services: ## Run service benchmarks
	@echo "$(YELLOW)Running service benchmarks...$(NC)"
	cd microservices/user-service && cargo bench
	cd api-gateway && go test -bench=. -benchmem ./...

# Documentation commands
docs: docs-api docs-architecture ## Generate all documentation

docs-api: ## Generate API documentation
	@echo "$(YELLOW)Generating API documentation...$(NC)"
	swagger-codegen generate -i docs/api/openapi.yaml -l html2 -o docs/api/html

docs-architecture: ## Generate architecture documentation
	@echo "$(YELLOW)Generating architecture documentation...$(NC)"
	# Generate architecture diagrams from code
	@echo "Architecture documentation would be generated here"

# Deployment commands
deploy-dev: ## Deploy to development environment
	@echo "$(YELLOW)Deploying to development environment...$(NC)"
	kubectl apply -f infrastructure/kubernetes/namespace.yaml
	kubectl apply -f infrastructure/kubernetes/configmap.yaml
	kubectl apply -f infrastructure/kubernetes/secrets.yaml
	helm upgrade --install dharmaguard infrastructure/helm/dharmaguard \
		--namespace dharmaguard-dev \
		--values infrastructure/helm/dharmaguard/values-dev.yaml

deploy-staging: ## Deploy to staging environment
	@echo "$(YELLOW)Deploying to staging environment...$(NC)"
	helm upgrade --install dharmaguard infrastructure/helm/dharmaguard \
		--namespace dharmaguard-staging \
		--values infrastructure/helm/dharmaguard/values-staging.yaml

deploy-prod: ## Deploy to production environment
	@echo "$(RED)Deploying to production environment...$(NC)"
	@echo "$(RED)WARNING: This will deploy to production!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		helm upgrade --install dharmaguard infrastructure/helm/dharmaguard \
			--namespace dharmaguard \
			--values infrastructure/helm/dharmaguard/values-prod.yaml; \
	fi

# Infrastructure commands
infra-plan: ## Plan infrastructure changes
	@echo "$(YELLOW)Planning infrastructure changes...$(NC)"
	cd infrastructure/terraform && terraform plan -var-file="environments/dev.tfvars"

infra-apply: ## Apply infrastructure changes
	@echo "$(YELLOW)Applying infrastructure changes...$(NC)"
	cd infrastructure/terraform && terraform apply -var-file="environments/dev.tfvars"

infra-destroy: ## Destroy infrastructure (WARNING: destroys everything)
	@echo "$(RED)WARNING: This will destroy all infrastructure!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd infrastructure/terraform && terraform destroy -var-file="environments/dev.tfvars"; \
	fi

# Monitoring commands
monitoring-setup: ## Setup monitoring stack
	@echo "$(YELLOW)Setting up monitoring stack...$(NC)"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
	helm repo update
	helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
	helm install jaeger jaegertracing/jaeger --namespace monitoring

logs: ## View application logs
	@echo "$(BLUE)Viewing application logs...$(NC)"
	kubectl logs -f deployment/surveillance-engine -n dharmaguard

metrics: ## View metrics dashboard
	@echo "$(BLUE)Opening metrics dashboard...$(NC)"
	kubectl port-forward service/grafana 3000:80 -n monitoring &
	open http://localhost:3000

# Utility commands
clean: ## Clean build artifacts
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	rm -rf core-engine/build
	cd microservices/user-service && cargo clean
	cd microservices/compliance-service && cargo clean
	cd microservices/reporting-service && cargo clean
	cd microservices/audit-service && cargo clean
	cd api-gateway && rm -rf bin/
	cd frontend && rm -rf .next/ dist/
	@echo "$(GREEN)Build artifacts cleaned!$(NC)"

deps: ## Install/update dependencies
	@echo "$(YELLOW)Installing/updating dependencies...$(NC)"
	cd frontend && npm install
	cd microservices/user-service && cargo update
	cd microservices/compliance-service && cargo update
	cd microservices/reporting-service && cargo update
	cd microservices/audit-service && cargo update
	cd api-gateway && go mod tidy
	cd ml-platform && pip install -r requirements.txt --upgrade
	@echo "$(GREEN)Dependencies updated!$(NC)"

check: ## Check system requirements and dependencies
	@echo "$(YELLOW)Checking system requirements...$(NC)"
	./scripts/setup/check-requirements.sh
	@echo "$(GREEN)System check completed!$(NC)"

# Convenience commands
all: clean deps build test ## Clean, install deps, build, and test everything

quick-test: ## Run quick smoke tests
	@echo "$(YELLOW)Running quick smoke tests...$(NC)"
	curl -f http://localhost:8080/health || echo "API Gateway not running"
	curl -f http://localhost:3000 || echo "Frontend not running"

status: ## Show status of all services
	@echo "$(BLUE)DharmaGuard Service Status:$(NC)"
	@echo "=================================="
	docker-compose ps

backup: ## Backup development data
	@echo "$(YELLOW)Backing up development data...$(NC)"
	./scripts/backup/backup-dev-data.sh
	@echo "$(GREEN)Backup completed!$(NC)"

restore: ## Restore development data from backup
	@echo "$(YELLOW)Restoring development data...$(NC)"
	./scripts/backup/restore-dev-data.sh
	@echo "$(GREEN)Restore completed!$(NC)"
