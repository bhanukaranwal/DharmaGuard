#!/bin/bash
# DharmaGuard Development Environment Setup Script
# Sets up complete development environment with all dependencies

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check system requirements
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        DISTRO=$(lsb_release -si 2>/dev/null || echo "Unknown")
        log_info "Detected Linux distribution: $DISTRO"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        log_info "Detected macOS"
    else
        log_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    log_info "Architecture: $ARCH"
    
    # Check available memory
    if [[ "$OS" == "linux" ]]; then
        MEMORY_GB=$(free -g | awk '/^Mem:/{print $2}')
    else
        MEMORY_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    fi
    
    if [[ $MEMORY_GB -lt 8 ]]; then
        log_warning "Less than 8GB RAM detected. Some components may run slowly."
    else
        log_success "Memory check passed: ${MEMORY_GB}GB RAM"
    fi
}

# Install system dependencies
install_system_dependencies() {
    log_info "Installing system dependencies..."
    
    if [[ "$OS" == "linux" ]]; then
        if command_exists apt-get; then
            sudo apt-get update
            sudo apt-get install -y \
                curl wget git build-essential \
                pkg-config libssl-dev \
                cmake ninja-build \
                postgresql-client \
                redis-tools \
                jq unzip
        elif command_exists yum; then
            sudo yum update -y
            sudo yum groupinstall -y "Development Tools"
            sudo yum install -y \
                curl wget git \
                openssl-devel \
                cmake ninja-build \
                postgresql \
                redis \
                jq unzip
        else
            log_error "Unsupported Linux distribution"
            exit 1
        fi
    elif [[ "$OS" == "macos" ]]; then
        if ! command_exists brew; then
            log_info "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        
        brew update
        brew install \
            curl wget git \
            openssl \
            cmake ninja \
            postgresql \
            redis \
            jq
    fi
    
    log_success "System dependencies installed"
}

# Install Docker and Docker Compose
install_docker() {
    log_info "Installing Docker and Docker Compose..."
    
    if command_exists docker; then
        log_success "Docker already installed: $(docker --version)"
    else
        if [[ "$OS" == "linux" ]]; then
            # Install Docker using official script
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            sudo usermod -aG docker $USER
            rm get-docker.sh
        elif [[ "$OS" == "macos" ]]; then
            log_warning "Please install Docker Desktop for Mac from https://www.docker.com/products/docker-desktop"
            read -p "Press enter when Docker Desktop is installed and running..."
        fi
    fi
    
    # Check Docker Compose
    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose not found. Please install Docker Compose v2"
        exit 1
    fi
    
    log_success "Docker and Docker Compose ready"
}

# Install Node.js and npm
install_nodejs() {
    log_info "Installing Node.js..."
    
    if command_exists node; then
        NODE_VERSION=$(node --version)
        log_info "Node.js already installed: $NODE_VERSION"
        
        # Check if version is >= 20
        if [[ $(echo $NODE_VERSION | cut -d'v' -f2 | cut -d'.' -f1) -lt 20 ]]; then
            log_warning "Node.js version is < 20. Please upgrade to Node.js 20 or later."
        fi
    else
        # Install Node.js using NodeSource repository
        if [[ "$OS" == "linux" ]]; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt-get install -y nodejs
        elif [[ "$OS" == "macos" ]]; then
            brew install node@20
        fi
    fi
    
    # Install global packages
    npm install -g yarn pnpm
    
    log_success "Node.js and package managers installed"
}

# Install Rust
install_rust() {
    log_info "Installing Rust..."
    
    if command_exists rustc; then
        RUST_VERSION=$(rustc --version)
        log_info "Rust already installed: $RUST_VERSION"
    else
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source $HOME/.cargo/env
    fi
    
    # Install additional components
    rustup component add rustfmt clippy
    rustup target add x86_64-unknown-linux-musl # For smaller Docker images
    
    # Install cargo tools
    cargo install cargo-watch cargo-edit cargo-audit
    
    log_success "Rust toolchain installed"
}

# Install Go
install_go() {
    log_info "Installing Go..."
    
    if command_exists go; then
        GO_VERSION=$(go version)
        log_info "Go already installed: $GO_VERSION"
    else
        GO_VERSION="1.22.0"
        if [[ "$OS" == "linux" ]]; then
            wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
            sudo rm -rf /usr/local/go
            sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
            rm "go${GO_VERSION}.linux-amd64.tar.gz"
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
            export PATH=$PATH:/usr/local/go/bin
        elif [[ "$OS" == "macos" ]]; then
            brew install go
        fi
    fi
    
    # Install Go tools
    go install golang.org/x/tools/gopls@latest
    go install github.com/cosmtrek/air@latest
    go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
    
    log_success "Go toolchain installed"
}

# Install Python
install_python() {
    log_info "Installing Python..."
    
    if command_exists python3; then
        PYTHON_VERSION=$(python3 --version)
        log_info "Python already installed: $PYTHON_VERSION"
    else
        if [[ "$OS" == "linux" ]]; then
            sudo apt-get install -y python3 python3-pip python3-venv
        elif [[ "$OS" == "macos" ]]; then
            brew install python@3.12
        fi
    fi
    
    # Install pipenv and poetry
    pip3 install --user pipenv poetry
    
    log_success "Python toolchain installed"
}

# Install C++ dependencies
install_cpp_dependencies() {
    log_info "Installing C++ dependencies..."
    
    if [[ "$OS" == "linux" ]]; then
        sudo apt-get install -y \
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
            libgtest-dev
    elif [[ "$OS" == "macos" ]]; then
        brew install \
            boost \
            tbb \
            protobuf \
            grpc \
            postgresql \
            hiredis \
            librdkafka \
            spdlog \
            google-benchmark \
            googletest
    fi
    
    log_success "C++ dependencies installed"
}

# Install Kubernetes tools
install_k8s_tools() {
    log_info "Installing Kubernetes tools..."
    
    # Install kubectl
    if ! command_exists kubectl; then
        if [[ "$OS" == "linux" ]]; then
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
        elif [[ "$OS" == "macos" ]]; then
            brew install kubectl
        fi
    fi
    
    # Install Helm
    if ! command_exists helm; then
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    
    # Install kind for local Kubernetes
    if ! command_exists kind; then
        go install sigs.k8s.io/kind@latest
    fi
    
    log_success "Kubernetes tools installed"
}

# Setup development database
setup_dev_database() {
    log_info "Setting up development database..."
    
    # Create .env file if it doesn't exist
    if [[ ! -f .env ]]; then
        cp .env.example .env
        log_info "Created .env file from template"
    fi
    
    # Start development databases
    docker compose up -d postgres redis clickhouse
    
    # Wait for databases to be ready
    log_info "Waiting for databases to start..."
    sleep 30
    
    # Run database migrations
    if [[ -f database/postgresql/init/001_schema.sql ]]; then
        log_info "Running database migrations..."
        docker compose exec postgres psql -U dharmaguard -d dharmaguard -f /docker-entrypoint-initdb.d/001_schema.sql
    fi
    
    log_success "Development database setup complete"
}

# Setup IDE configuration
setup_ide_config() {
    log_info "Setting up IDE configuration..."
    
    # VS Code settings
    mkdir -p .vscode
    cat > .vscode/settings.json << EOF
{
    "rust-analyzer.cargo.features": "all",
    "rust-analyzer.check.command": "clippy",
    "go.useLanguageServer": true,
    "go.alternateTools": {
        "go-langserver": "gopls"
    },
    "typescript.preferences.importModuleSpecifier": "relative",
    "editor.formatOnSave": true,
    "editor.codeActionsOnSave": {
        "source.organizeImports": true
    }
}
EOF
    
    # VS Code extensions recommendations
    cat > .vscode/extensions.json << EOF
{
    "recommendations": [
        "rust-lang.rust-analyzer",
        "ms-vscode.cpptools",
        "golang.go",
        "ms-vscode.vscode-typescript-next",
        "bradlc.vscode-tailwindcss",
        "ms-kubernetes-tools.vscode-kubernetes-tools",
        "ms-vscode.docker"
    ]
}
EOF
    
    log_success "IDE configuration created"
}

# Main installation function
main() {
    echo "=========================================="
    echo "  DharmaGuard Development Environment   "
    echo "          Setup Script v1.0            "
    echo "=========================================="
    echo
    
    check_system_requirements
    install_system_dependencies
    install_docker
    install_nodejs
    install_rust
    install_go
    install_python
    install_cpp_dependencies
    install_k8s_tools
    setup_dev_database
    setup_ide_config
    
    echo
    echo "=========================================="
    log_success "Development environment setup complete!"
    echo "=========================================="
    echo
    echo "Next steps:"
    echo "1. Restart your terminal or run: source ~/.bashrc"
    echo "2. Run: docker compose up -d"
    echo "3. Open the project in your IDE"
    echo "4. Start developing!"
    echo
    echo "Useful commands:"
    echo "  make dev          - Start development services"
    echo "  make test         - Run all tests"
    echo "  make lint         - Run linters"
    echo "  make build        - Build all components"
    echo
}

# Run main function
main "$@"
