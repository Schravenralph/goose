#!/usr/bin/env python3
"""
Production-ready HTTP server to serve metrics dashboard and aggregate metrics data.
Serves the metrics dashboard HTML and provides a JSON API for metrics data.

Security features:
- Basic HTTP authentication
- Input validation and sanitization
- Rate limiting
- Audit logging
- Secure file handling
- Security headers
"""

import json
import os
import sys
import glob
import base64
import hashlib
import re
import time
import ssl
from pathlib import Path
from datetime import datetime, timedelta
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote
import argparse
from collections import defaultdict
from threading import Lock

# Add parent directory to path for logging_utils import
sys.path.insert(0, str(Path(__file__).parent))

try:
    import logging_utils
except ImportError:
    # Fallback if logging_utils is not available
    class DummyLogger:
        def log_info(self, *args, **kwargs): print(*args)
        def log_warn(self, *args, **kwargs): print(f"WARNING: {args[0] if args else ''}", file=sys.stderr)
        def log_error(self, *args, **kwargs): print(f"ERROR: {args[0] if args else ''}", file=sys.stderr)
        def log_debug(self, *args, **kwargs): pass
        def start_span(self, *args, **kwargs): pass
        def end_span(self, *args, **kwargs): pass
        def record_metric(self, *args, **kwargs): pass
        def write_metrics(self, *args, **kwargs): pass
    logging_utils = DummyLogger()


# Default metrics directory
DEFAULT_METRICS_DIR = "/tmp/goose-logs"

# Security configuration
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB max file size
MAX_SCRIPT_NAME_LENGTH = 256
MAX_DATE_STRING_LENGTH = 50
RATE_LIMIT_REQUESTS = 100  # requests per window
RATE_LIMIT_WINDOW = 60  # seconds
ALLOWED_FILE_EXTENSIONS = {'.json'}


class RateLimiter:
    """Simple rate limiter using sliding window."""
    
    def __init__(self, max_requests, window_seconds):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.requests = defaultdict(list)
        self.lock = Lock()
    
    def is_allowed(self, client_ip):
        """Check if request from client_ip is allowed."""
        with self.lock:
            now = time.time()
            # Clean old entries
            self.requests[client_ip] = [
                req_time for req_time in self.requests[client_ip]
                if now - req_time < self.window_seconds
            ]
            
            # Check limit
            if len(self.requests[client_ip]) >= self.max_requests:
                return False
            
            # Record this request
            self.requests[client_ip].append(now)
            return True


class AuditLogger:
    """Audit logger for security events."""
    
    def __init__(self, audit_log_file=None):
        self.audit_log_file = audit_log_file
        self.lock = Lock()
    
    def log(self, event_type, client_ip, path, status_code, details=None):
        """Log an audit event."""
        timestamp = datetime.utcnow().isoformat() + 'Z'
        log_entry = {
            'timestamp': timestamp,
            'event_type': event_type,
            'client_ip': client_ip,
            'path': path,
            'status_code': status_code,
            'details': details or {}
        }
        
        log_line = json.dumps(log_entry) + '\n'
        
        # Log to stderr (always visible)
        print(f"[AUDIT] {log_line}", file=sys.stderr, end='')
        
        # Also log to file if configured
        if self.audit_log_file:
            try:
                with self.lock:
                    with open(self.audit_log_file, 'a') as f:
                        f.write(log_line)
            except Exception as e:
                print(f"Error writing audit log: {e}", file=sys.stderr)


class MetricsHandler(SimpleHTTPRequestHandler):
    """HTTP handler for serving metrics dashboard and API with security features."""
    
    # Class-level rate limiter (shared across all instances)
    rate_limiter = None
    audit_logger = None
    auth_username = None
    auth_password_hash = None
    
    def __init__(self, *args, metrics_dir=None, **kwargs):
        self.metrics_dir = Path(metrics_dir) if metrics_dir else Path(DEFAULT_METRICS_DIR)
        super().__init__(*args, **kwargs)
    
    def log_message(self, format, *args):
        """Override to suppress default logging (we use audit logging instead)."""
        pass
    
    def get_client_ip(self):
        """Get client IP address."""
        # Check for forwarded headers (from reverse proxy)
        forwarded_for = self.headers.get('X-Forwarded-For')
        if forwarded_for:
            return forwarded_for.split(',')[0].strip()
        return self.client_address[0]
    
    def check_rate_limit(self):
        """Check if request is within rate limits."""
        if self.rate_limiter:
            client_ip = self.get_client_ip()
            if not self.rate_limiter.is_allowed(client_ip):
                self.audit_log('rate_limit_exceeded', 429)
                self.send_error(429, "Too Many Requests")
                return False
        return True
    
    def check_authentication(self):
        """Check Basic HTTP authentication."""
        if not self.auth_username or not self.auth_password_hash:
            return True  # No auth configured
        
        auth_header = self.headers.get('Authorization', '')
        if not auth_header.startswith('Basic '):
            self.send_auth_challenge()
            return False
        
        try:
            encoded = auth_header[6:]  # Remove 'Basic '
            decoded = base64.b64decode(encoded).decode('utf-8')
            username, password = decoded.split(':', 1)
            
            # Hash password and compare
            password_hash = hashlib.sha256(password.encode()).hexdigest()
            if username == self.auth_username and password_hash == self.auth_password_hash:
                return True
        except Exception:
            pass
        
        self.send_auth_challenge()
        return False
    
    def send_auth_challenge(self):
        """Send HTTP 401 authentication challenge."""
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Goose Metrics Dashboard"')
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<h1>401 Unauthorized</h1><p>Authentication required.</p>')
        self.audit_log('auth_failed', 401)
    
    def send_security_headers(self):
        """Send security headers."""
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-XSS-Protection', '1; mode=block')
        # Only send CORS header if explicitly configured (not for production by default)
        # self.send_header('Access-Control-Allow-Origin', '*')
    
    def audit_log(self, event_type, status_code, details=None):
        """Log audit event."""
        if self.audit_logger:
            self.audit_logger.log(
                event_type=event_type,
                client_ip=self.get_client_ip(),
                path=self.path,
                status_code=status_code,
                details=details or {}
            )
    
    def sanitize_string(self, value, max_length=None):
        """Sanitize string input."""
        if not isinstance(value, str):
            return None
        
        # Remove null bytes and control characters
        sanitized = re.sub(r'[\x00-\x1f\x7f]', '', value)
        
        # Limit length
        if max_length:
            sanitized = sanitized[:max_length]
        
        return sanitized.strip()
    
    def validate_script_name(self, script_name):
        """Validate and sanitize script name."""
        if not script_name:
            return None
        
        sanitized = self.sanitize_string(script_name, MAX_SCRIPT_NAME_LENGTH)
        if not sanitized:
            return None
        
        # Only allow alphanumeric, dash, underscore
        if not re.match(r'^[a-zA-Z0-9_-]+$', sanitized):
            return None
        
        return sanitized
    
    def validate_date_string(self, date_str):
        """Validate ISO date string."""
        if not date_str:
            return None
        
        sanitized = self.sanitize_string(date_str, MAX_DATE_STRING_LENGTH)
        if not sanitized:
            return None
        
        # Try to parse as ISO format
        try:
            datetime.fromisoformat(sanitized.replace('Z', '+00:00'))
            return sanitized
        except ValueError:
            return None
    
    def do_GET(self):
        """Handle GET requests with security checks."""
        # Rate limiting
        if not self.check_rate_limit():
            return
        
        # Authentication
        if not self.check_authentication():
            return
        
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path == '/api/metrics':
            self.handle_metrics_api(parsed_path.query)
        elif path == '/' or path == '/metrics-dashboard.html':
            self.serve_dashboard()
        else:
            # Try to serve static files
            self.serve_file(path)
    
    def serve_dashboard(self):
        """Serve the metrics dashboard HTML."""
        script_dir = Path(__file__).parent
        dashboard_path = script_dir / 'metrics-dashboard.html'
        
        if not dashboard_path.exists():
            logging_utils.log_error("Dashboard not found", path=str(dashboard_path))
            self.audit_log('dashboard_not_found', 404)
            self.send_error(404, "Dashboard not found")
            return
        
        try:
            # Check file size
            file_size = dashboard_path.stat().st_size
            if file_size > MAX_FILE_SIZE:
                self.audit_log('file_too_large', 413, {'file_size': file_size})
                self.send_error(413, "File too large")
                return
            
            with open(dashboard_path, 'rb') as f:
                content = f.read()
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.send_header('Content-length', str(len(content)))
            self.send_security_headers()
            self.end_headers()
            self.wfile.write(content)
            
            self.audit_log('dashboard_accessed', 200)
            logging_utils.log_debug("Served dashboard", path=str(dashboard_path))
        except Exception as e:
            logging_utils.log_error(f"Error serving dashboard: {str(e)}", path=str(dashboard_path))
            self.audit_log('dashboard_error', 500, {'error': str(e)})
            self.send_error(500, f"Error serving dashboard: {str(e)}")
    
    def serve_file(self, path):
        """Serve static files with security checks."""
        script_dir = Path(__file__).parent
        file_path = script_dir / path.lstrip('/')
        
        # Security check: ensure file is within script directory
        try:
            file_path.resolve().relative_to(script_dir.resolve())
        except ValueError:
            self.audit_log('path_traversal_attempt', 403, {'path': path})
            self.send_error(403, "Forbidden")
            return
        
        if not file_path.exists() or not file_path.is_file():
            self.audit_log('file_not_found', 404, {'path': path})
            self.send_error(404, "File not found")
            return
        
        # Check file extension
        if file_path.suffix not in ALLOWED_FILE_EXTENSIONS:
            self.audit_log('invalid_file_extension', 403, {'extension': file_path.suffix})
            self.send_error(403, "Forbidden file type")
            return
        
        # Check file size
        try:
            file_size = file_path.stat().st_size
            if file_size > MAX_FILE_SIZE:
                self.audit_log('file_too_large', 413, {'file_size': file_size})
                self.send_error(413, "File too large")
                return
        except OSError:
            self.audit_log('file_stat_error', 500)
            self.send_error(500, "Error accessing file")
            return
        
        try:
            with open(file_path, 'rb') as f:
                content = f.read()
            
            # Determine content type
            content_type = 'application/octet-stream'
            if path.endswith('.js'):
                content_type = 'application/javascript'
            elif path.endswith('.css'):
                content_type = 'text/css'
            elif path.endswith('.json'):
                content_type = 'application/json'
            
            self.send_response(200)
            self.send_header('Content-type', content_type)
            self.send_header('Content-length', str(len(content)))
            self.send_security_headers()
            self.end_headers()
            self.wfile.write(content)
            
            self.audit_log('file_served', 200, {'file': str(file_path)})
            logging_utils.log_debug("Served file", path=str(file_path))
        except Exception as e:
            logging_utils.log_error(f"Error serving file: {str(e)}", path=str(file_path))
            self.audit_log('file_error', 500, {'error': str(e)})
            self.send_error(500, f"Error serving file: {str(e)}")
    
    def handle_metrics_api(self, query_string):
        """Handle /api/metrics API endpoint with input validation."""
        query_params = parse_qs(query_string)
        
        # Parse and validate query parameters
        start_date = query_params.get('start_date', [None])[0]
        end_date = query_params.get('end_date', [None])[0]
        script_name = query_params.get('script_name', [None])[0]
        
        # Validate and sanitize inputs
        start_date = self.validate_date_string(start_date)
        end_date = self.validate_date_string(end_date)
        script_name = self.validate_script_name(script_name)
        
        try:
            metrics_data = self.load_metrics(start_date, end_date, script_name)
            
            response = json.dumps(metrics_data, indent=2).encode('utf-8')
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Content-length', str(len(response)))
            self.send_security_headers()
            self.end_headers()
            self.wfile.write(response)
            
            self.audit_log('api_accessed', 200, {
                'start_date': start_date,
                'end_date': end_date,
                'script_name': script_name
            })
            logging_utils.log_debug("Served metrics API", query_string=query_string)
        except Exception as e:
            logging_utils.log_error(f"Error handling metrics API: {str(e)}", query_string=query_string)
            error_response = json.dumps({'error': 'Internal server error'}).encode('utf-8')
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.send_header('Content-length', str(len(error_response)))
            self.end_headers()
            self.wfile.write(error_response)
            
            self.audit_log('api_error', 500, {'error': str(e)})
    
    def load_metrics(self, start_date=None, end_date=None, script_name=None):
        """Load and aggregate metrics from JSON files with input validation."""
        logging_utils.start_span("load_metrics")
        if not self.metrics_dir.exists():
            logging_utils.log_warn("Metrics directory does not exist", metrics_dir=str(self.metrics_dir))
            logging_utils.end_span()
            return {
                'totalRuns': 0,
                'successRate': 0,
                'avgDuration': 0,
                'totalWarnings': 0,
                'totalErrors': 0,
                'recentRuns': [],
                'scripts': []
            }
        
        # Find all metrics files
        pattern = '*-metrics-*.json'
        if script_name:
            # script_name is already validated
            pattern = f'{script_name}-metrics-*.json'
        
        metrics_files = list(self.metrics_dir.glob(pattern))
        
        # Parse dates if provided (already validated)
        start_datetime = None
        end_datetime = None
        if start_date:
            try:
                start_datetime = datetime.fromisoformat(start_date.replace('Z', '+00:00'))
            except ValueError:
                pass
        if end_date:
            try:
                end_datetime = datetime.fromisoformat(end_date.replace('Z', '+00:00'))
            except ValueError:
                pass
        
        # Load and filter metrics
        all_metrics = []
        scripts = set()
        
        for metrics_file in metrics_files:
            try:
                # Security: Check file size before reading
                if metrics_file.stat().st_size > MAX_FILE_SIZE:
                    logging_utils.log_warn(f"Skipping large file: {metrics_file}")
                    continue
                
                # Extract timestamp from filename (format: script-metrics-YYYYMMDD_HHMMSS.json)
                filename = metrics_file.stem  # Remove .json extension
                parts = filename.split('-metrics-')
                if len(parts) == 2:
                    scripts.add(parts[0])
                    timestamp_str = parts[1]
                    try:
                        file_datetime = datetime.strptime(timestamp_str, '%Y%m%d_%H%M%S')
                        
                        # Filter by date range
                        if start_datetime and file_datetime < start_datetime:
                            continue
                        if end_datetime and file_datetime > end_datetime:
                            continue
                    except ValueError:
                        # If we can't parse the timestamp, include the file anyway
                        pass
                
                with open(metrics_file, 'r') as f:
                    content = f.read().strip()
                    if not content:
                        continue
                    
                    # Security: Limit content size
                    if len(content) > MAX_FILE_SIZE:
                        logging_utils.log_warn(f"Skipping file with large content: {metrics_file}")
                        continue
                    
                    # Handle single-line JSON (from bash script)
                    try:
                        metric = json.loads(content)
                    except json.JSONDecodeError:
                        # Try to fix common issues with bash-generated JSON
                        # Sometimes values have newlines
                        content = content.replace('\n', ' ')
                        try:
                            metric = json.loads(content)
                        except json.JSONDecodeError:
                            continue
                    
                    # Add file timestamp if not present
                    if 'start_time' in metric:
                        try:
                            start_time = float(metric['start_time'])
                            metric['file_timestamp'] = datetime.fromtimestamp(start_time).isoformat() + 'Z'
                        except (ValueError, TypeError):
                            pass
                    
                    all_metrics.append(metric)
            except Exception as e:
                # Skip files that can't be parsed
                logging_utils.log_debug(f"Skipping unparseable metrics file: {metrics_file}", error=str(e))
                continue
        
        # Sort by start_time (most recent first)
        all_metrics.sort(key=lambda x: float(x.get('start_time', 0)), reverse=True)
        
        # Aggregate metrics
        total_runs = len(all_metrics)
        successful_runs = sum(1 for m in all_metrics if m.get('exit_code', '1') == '0')
        success_rate = (successful_runs / total_runs * 100) if total_runs > 0 else 0
        
        durations = []
        total_warnings = 0
        total_errors = 0
        
        for metric in all_metrics:
            # Calculate duration
            try:
                duration = float(metric.get('duration', 0))
                if duration > 0:
                    durations.append(duration)
            except (ValueError, TypeError):
                pass
            
            # Sum warnings and errors
            # Look for various warning/error fields
            for key, value in metric.items():
                if 'warning' in key.lower() and isinstance(value, (int, str)):
                    try:
                        total_warnings += int(value)
                    except (ValueError, TypeError):
                        pass
                if 'error' in key.lower() and isinstance(value, (int, str)):
                    try:
                        total_errors += int(value)
                    except (ValueError, TypeError):
                        pass
        
        avg_duration = sum(durations) / len(durations) if durations else 0
        
        # Prepare recent runs (last 50)
        recent_runs = []
        for metric in all_metrics[:50]:
            try:
                start_time = float(metric.get('start_time', 0))
                duration = float(metric.get('duration', 0))
                exit_code = metric.get('exit_code', '1')
                
                # Extract warnings and errors
                warnings = 0
                errors = 0
                for key, value in metric.items():
                    if 'warning' in key.lower() and isinstance(value, (int, str)):
                        try:
                            warnings += int(value)
                        except (ValueError, TypeError):
                            pass
                    if 'error' in key.lower() and isinstance(value, (int, str)):
                        try:
                            errors += int(value)
                        except (ValueError, TypeError):
                            pass
                
                recent_runs.append({
                    'date': datetime.fromtimestamp(start_time).isoformat() + 'Z',
                    'duration': duration,
                    'success': exit_code == '0',
                    'warnings': warnings,
                    'errors': errors,
                    'script_name': metric.get('script_name', 'unknown'),
                    'trace_id': metric.get('trace_id', ''),
                })
            except (ValueError, TypeError) as e:
                continue
        
        logging_utils.record_metric("metrics_files_loaded", len(all_metrics))
        logging_utils.end_span()
        
        return {
            'totalRuns': total_runs,
            'successRate': round(success_rate, 2),
            'avgDuration': round(avg_duration, 2),
            'totalWarnings': total_warnings,
            'totalErrors': total_errors,
            'recentRuns': recent_runs,
            'scripts': sorted(list(scripts))
        }


def create_handler_class(metrics_dir, rate_limiter, audit_logger, auth_username, auth_password_hash):
    """Create a handler class with configuration bound."""
    class Handler(MetricsHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, metrics_dir=metrics_dir, **kwargs)
            # Set class-level attributes
            Handler.rate_limiter = rate_limiter
            Handler.audit_logger = audit_logger
            Handler.auth_username = auth_username
            Handler.auth_password_hash = auth_password_hash
    return Handler


def hash_password(password):
    """Hash password using SHA-256."""
    return hashlib.sha256(password.encode()).hexdigest()


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description='Serve metrics dashboard with production security')
    parser.add_argument('--port', type=int, default=8080, help='Port to serve on (default: 8080)')
    parser.add_argument('--metrics-dir', type=str, default=DEFAULT_METRICS_DIR,
                       help=f'Directory containing metrics JSON files (default: {DEFAULT_METRICS_DIR})')
    parser.add_argument('--host', type=str, default='localhost',
                       help='Host to bind to (default: localhost)')
    parser.add_argument('--auth-username', type=str, default=None,
                       help='Basic auth username (optional, enables authentication)')
    parser.add_argument('--auth-password', type=str, default=None,
                       help='Basic auth password (required if --auth-username is set)')
    parser.add_argument('--audit-log', type=str, default=None,
                       help='Path to audit log file (optional)')
    parser.add_argument('--rate-limit', type=int, default=RATE_LIMIT_REQUESTS,
                       help=f'Max requests per window (default: {RATE_LIMIT_REQUESTS})')
    parser.add_argument('--rate-limit-window', type=int, default=RATE_LIMIT_WINDOW,
                       help=f'Rate limit window in seconds (default: {RATE_LIMIT_WINDOW})')
    parser.add_argument('--ssl-cert', type=str, default=None,
                       help='Path to SSL certificate file (for HTTPS)')
    parser.add_argument('--ssl-key', type=str, default=None,
                       help='Path to SSL private key file (for HTTPS)')
    
    args = parser.parse_args()
    
    # Validate authentication configuration
    auth_username = args.auth_username
    auth_password_hash = None
    if auth_username:
        if not args.auth_password:
            print("ERROR: --auth-password is required when --auth-username is set", file=sys.stderr)
            sys.exit(1)
        auth_password_hash = hash_password(args.auth_password)
        print(f"✓ Authentication enabled for user: {auth_username}")
    else:
        print("⚠ WARNING: Authentication is disabled. Not recommended for production!")
    
    # Initialize rate limiter
    rate_limiter = RateLimiter(args.rate_limit, args.rate_limit_window)
    print(f"✓ Rate limiting enabled: {args.rate_limit} requests per {args.rate_limit_window} seconds")
    
    # Initialize audit logger
    audit_logger = None
    if args.audit_log:
        audit_logger = AuditLogger(args.audit_log)
        print(f"✓ Audit logging enabled: {args.audit_log}")
    else:
        audit_logger = AuditLogger()  # Log to stderr only
        print("✓ Audit logging enabled (stderr)")
    
    logging_utils.start_span("main")
    metrics_dir = Path(args.metrics_dir)
    if not metrics_dir.exists():
        logging_utils.log_warn(f"Metrics directory {metrics_dir} does not exist. Creating it...")
        metrics_dir.mkdir(parents=True, exist_ok=True)
    
    handler_class = create_handler_class(
        str(metrics_dir),
        rate_limiter,
        audit_logger,
        auth_username,
        auth_password_hash
    )
    
    server_address = (args.host, args.port)
    httpd = HTTPServer(server_address, handler_class)
    
    # Setup HTTPS if certificates provided
    use_https = False
    if args.ssl_cert and args.ssl_key:
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(args.ssl_cert, args.ssl_key)
            httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
            use_https = True
            logging_utils.log_info("HTTPS enabled", cert=args.ssl_cert, key=args.ssl_key)
            print(f"✓ HTTPS enabled with certificate: {args.ssl_cert}")
        except Exception as e:
            logging_utils.log_error(f"Failed to setup HTTPS: {str(e)}")
            print(f"⚠ WARNING: Failed to setup HTTPS: {str(e)}")
            print("   Server will run without HTTPS")
    
    protocol = 'https' if use_https else 'http'
    msg1 = f"\n📊 Goose Metrics Dashboard Server (Production Mode)"
    msg2 = f"   Metrics directory: {metrics_dir}"
    msg3 = f"   Server: {protocol}://{args.host}:{args.port}"
    msg4 = f"   API endpoint: {protocol}://{args.host}:{args.port}/api/metrics"
    msg5 = f"   Press Ctrl+C to stop\n"
    
    logging_utils.log_info("Starting metrics dashboard server", 
                          metrics_dir=str(metrics_dir),
                          host=args.host,
                          port=args.port)
    print(msg1)
    print(msg2)
    print(msg3)
    print(msg4)
    print(msg5)
    
    logging_utils.record_metric("server_started", 1)
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logging_utils.log_info("Shutting down server...")
        print("\n🛑 Shutting down server...")
        httpd.shutdown()
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=0)


if __name__ == '__main__':
    main()
