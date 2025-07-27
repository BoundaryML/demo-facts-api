# Build stage
FROM alpine:latest AS builder

# Install Zig
RUN apk add --no-cache curl xz && \
    curl -L https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz | tar -xJ && \
    mv zig-linux-x86_64-0.14.0 /usr/local/zig

# Set PATH
ENV PATH="/usr/local/zig:${PATH}"

# Set working directory
WORKDIR /app

# Copy source files
COPY build.zig .
COPY src/ ./src/

# Build the application
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache libc6-compat

# Copy the built binary
COPY --from=builder /app/zig-out/bin/facts-api /usr/local/bin/facts-api

# Expose port (fly.io uses 8080 by default)
EXPOSE 8080

# Set the internal port for fly.io
ENV PORT=8080

# Run the application
CMD ["facts-api"]