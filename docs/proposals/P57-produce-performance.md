# P57: Production Caching and Performance

**Status:** IMPLEMENTED
**Created:** 2026-01-18
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Depends On:** P54 (removes grep tests expecting this feature)
**Estimated Effort:** 1-2 weeks
**Breaking Changes:** No - additive feature

---

## 1. Executive Summary

### 1.1 Problem Statement

The verification tests expect `produce.sh` to handle caching and performance:
```bash
grep -qE '(cache|redis|memcache|performance)' scripts/commands/produce.sh
```

Currently **none** of these features exist in produce.sh.

### 1.2 Proposed Solution

Add caching and performance optimization features to `produce.sh`:
1. Redis caching with Drupal integration
2. Memcached as alternative cache backend
3. PHP-FPM performance tuning
4. Nginx performance optimization

### 1.3 Key Benefits

| Benefit | Impact |
|---------|--------|
| Page load reduction | 50%+ faster |
| Database load | Significantly reduced |
| Server efficiency | Better resource utilization |
| Scalability | Handle more concurrent users |

---

## 2. Proposed Features

### 2.1 Redis Caching

```bash
setup_redis() {
    local server_ip="$1"

    print_info "Installing and configuring Redis..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Install Redis
        apt-get install -y redis-server

        # Configure Redis
        cat > /etc/redis/redis.conf << 'EOF'
bind 127.0.0.1
port 6379
daemonize yes
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log
databases 16
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistence
save 900 1
save 300 10
save 60 10000
EOF

        # Restart Redis
        systemctl restart redis-server
        systemctl enable redis-server

        # Test connection
        redis-cli ping
REMOTE_SCRIPT

    print_success "Redis configured"
}

configure_drupal_redis() {
    local site_path="$1"

    print_info "Configuring Drupal Redis cache..."

    # Add Redis settings to settings.php
    cat >> "${site_path}/web/sites/default/settings.php" << 'EOF'

// Redis cache configuration
$settings['redis.connection']['interface'] = 'PhpRedis';
$settings['redis.connection']['host'] = '127.0.0.1';
$settings['redis.connection']['port'] = '6379';
$settings['cache']['default'] = 'cache.backend.redis';
$settings['cache']['bins']['render'] = 'cache.backend.redis';
$settings['cache']['bins']['page'] = 'cache.backend.redis';
$settings['cache']['bins']['dynamic_page_cache'] = 'cache.backend.redis';
EOF

    print_success "Drupal Redis configuration added"
}
```

### 2.2 Memcached Alternative

```bash
setup_memcache() {
    local server_ip="$1"

    print_info "Installing and configuring Memcached..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Install Memcached
        apt-get install -y memcached libmemcached-tools

        # Configure Memcached
        cat > /etc/memcached.conf << 'EOF'
-d
logfile /var/log/memcached.log
-m 256
-p 11211
-u memcache
-l 127.0.0.1
-c 1024
EOF

        # Restart Memcached
        systemctl restart memcached
        systemctl enable memcached

        # Test connection
        echo "stats" | nc localhost 11211 | head -5
REMOTE_SCRIPT

    print_success "Memcached configured"
}
```

### 2.3 PHP-FPM Performance Tuning

```bash
tune_php_fpm() {
    local server_ip="$1"
    local memory_mb="${2:-2048}"  # Default 2GB server

    print_info "Tuning PHP-FPM for performance..."

    # Calculate optimal settings based on memory
    local max_children=$((memory_mb / 64))  # ~64MB per process
    local start_servers=$((max_children / 4))
    local min_spare=$((max_children / 8))
    local max_spare=$((max_children / 2))

    ssh "root@${server_ip}" << REMOTE_SCRIPT
        # Detect PHP version
        PHP_VERSION=\$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

        # Update PHP-FPM pool config
        cat > /etc/php/\${PHP_VERSION}/fpm/pool.d/www.conf << 'EOF'
[www]
user = www-data
group = www-data
listen = /run/php/php\${PHP_VERSION}-fpm.sock
listen.owner = www-data
listen.group = www-data

pm = dynamic
pm.max_children = ${max_children}
pm.start_servers = ${start_servers}
pm.min_spare_servers = ${min_spare}
pm.max_spare_servers = ${max_spare}
pm.max_requests = 500

; Performance settings
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 16
php_admin_value[opcache.max_accelerated_files] = 10000
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[realpath_cache_size] = 4096K
php_admin_value[realpath_cache_ttl] = 600
EOF

        systemctl restart php\${PHP_VERSION}-fpm
REMOTE_SCRIPT

    print_success "PHP-FPM tuned (max_children=${max_children})"
}
```

### 2.4 Nginx Performance Optimization

```bash
tune_nginx() {
    local server_ip="$1"

    print_info "Optimizing Nginx configuration..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        cat > /etc/nginx/conf.d/performance.conf << 'EOF'
# Performance optimizations

# Caching
open_file_cache max=10000 inactive=30s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

# Compression
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;

# Buffers
client_body_buffer_size 128k;
client_max_body_size 100M;

# Timeouts
client_body_timeout 60;
client_header_timeout 60;
keepalive_timeout 65;
send_timeout 60;

# Static file caching headers
location ~* \.(jpg|jpeg|gif|png|css|js|ico|xml|woff|woff2|ttf|svg)$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
}
EOF

        nginx -t && systemctl reload nginx
REMOTE_SCRIPT

    print_success "Nginx optimized"
}
```

---

## 3. Integration into produce.sh

### 3.1 Main Workflow Addition

```bash
main() {
    # ... existing provisioning ...

    # Performance optimization (new)
    case "$CACHE_BACKEND" in
        redis)
            setup_redis "$SERVER_IP"
            configure_drupal_redis "$SITE_PATH"
            ;;
        memcache)
            setup_memcache "$SERVER_IP"
            configure_drupal_memcache "$SITE_PATH"
            ;;
        none)
            print_info "Skipping cache configuration"
            ;;
    esac

    if [[ "$SKIP_PERFORMANCE" != "true" ]]; then
        tune_php_fpm "$SERVER_IP" "$SERVER_MEMORY"
        tune_nginx "$SERVER_IP"
    fi

    # ... rest of provisioning ...
}
```

### 3.2 CLI Options

| Flag | Description |
|------|-------------|
| `--cache redis` | Use Redis for caching (default) |
| `--cache memcache` | Use Memcached for caching |
| `--cache none` | Skip cache configuration |
| `--memory SIZE` | Server memory in MB for tuning (default: 2048) |
| `--performance-only` | Only run performance tuning |
| `--no-performance` | Skip all performance tuning |

### 3.3 Example Usage

```bash
# Full provisioning with Redis (default)
pl produce mysite

# Use Memcached instead
pl produce mysite --cache memcache

# Skip caching for dev environment
pl produce mysite --cache none

# Tune for 4GB server
pl produce mysite --memory 4096

# Performance tuning only on existing server
pl produce mysite --performance-only
```

---

## 4. Verification

### 4.1 Machine Tests

```yaml
# Add to .verification.yml produce: section
- text: "Performance optimization configured"
  machine:
    automatable: true
    checks:
      thorough:
        commands:
          - cmd: grep -qE '(cache|redis|memcache|performance)' scripts/commands/produce.sh
            expect_exit: 0
          - cmd: grep -q 'setup_redis\|setup_memcache' scripts/commands/produce.sh
            expect_exit: 0
          - cmd: grep -q 'tune_php_fpm' scripts/commands/produce.sh
            expect_exit: 0
```

### 4.2 Manual Verification

| Check | Command | Expected |
|-------|---------|----------|
| Redis status | `ssh root@server 'redis-cli ping'` | PONG |
| Memcache status | `ssh root@server 'echo stats \| nc localhost 11211'` | Stats output |
| PHP-FPM config | `ssh root@server 'php-fpm -tt'` | No errors |
| Nginx config | `ssh root@server 'nginx -t'` | Syntax OK |

### 4.3 Performance Benchmarks

| Metric | Before | After | Target |
|--------|--------|-------|--------|
| TTFB | >500ms | <100ms | 80% reduction |
| Page load | >2s | <1s | 50% reduction |
| Cache hit rate | 0% | >90% | Effective caching |

---

## 5. Success Criteria

- [ ] `grep -qE '(cache|redis|memcache|performance)' produce.sh` passes
- [ ] Redis/Memcache running and accessible
- [ ] Drupal using cache backend (verified in status report)
- [ ] PHP-FPM tuned based on server memory
- [ ] Nginx gzip and caching enabled
- [ ] Page load time reduced by 50%+
- [ ] All features optional via CLI flags
- [ ] Documentation updated

---

## 6. Technical Considerations

### 6.1 Cache Backend Selection

| Factor | Redis | Memcached |
|--------|-------|-----------|
| Persistence | Yes | No |
| Data types | Rich | Simple |
| Memory efficiency | Good | Better |
| Drupal support | Excellent | Good |
| Recommendation | Default choice | Memory-constrained servers |

### 6.2 Memory Calculations

PHP-FPM tuning formula:
```
max_children = server_memory_mb / process_memory_mb
process_memory_mb ≈ 64MB for Drupal
```

Example for 2GB server:
- max_children = 2048 / 64 = 32
- start_servers = 32 / 4 = 8
- min_spare_servers = 32 / 8 = 4
- max_spare_servers = 32 / 2 = 16

### 6.3 OPcache Settings

Optimized for Drupal production:
```ini
opcache.memory_consumption = 256      # Sufficient for most sites
opcache.max_accelerated_files = 10000 # Drupal has many files
opcache.revalidate_freq = 60          # Check for changes every minute
```

---

## 7. Related Proposals

| Proposal | Relationship |
|----------|--------------|
| P54 | Removes grep test that expects this feature |
| P56 | Companion security hardening proposal |
| P50 | Verification system this integrates with |
