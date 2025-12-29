#!/usr/bin/env python3
"""
Simple HTTP server to serve metrics dashboard and aggregate metrics data.
Serves the metrics dashboard HTML and provides a JSON API for metrics data.
"""

import json
import os
import sys
import glob
from pathlib import Path
from datetime import datetime, timedelta
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import argparse


# Default metrics directory
DEFAULT_METRICS_DIR = "/tmp/goose-logs"


class MetricsHandler(SimpleHTTPRequestHandler):
    """HTTP handler for serving metrics dashboard and API."""
    
    def __init__(self, *args, metrics_dir=None, **kwargs):
        self.metrics_dir = Path(metrics_dir) if metrics_dir else Path(DEFAULT_METRICS_DIR)
        super().__init__(*args, **kwargs)
    
    def log_message(self, format, *args):
        """Override to suppress default logging."""
        pass
    
    def do_GET(self):
        """Handle GET requests."""
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
            self.send_error(404, "Dashboard not found")
            return
        
        try:
            with open(dashboard_path, 'rb') as f:
                content = f.read()
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.send_header('Content-length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_error(500, f"Error serving dashboard: {str(e)}")
    
    def serve_file(self, path):
        """Serve static files."""
        script_dir = Path(__file__).parent
        file_path = script_dir / path.lstrip('/')
        
        # Security check: ensure file is within script directory
        try:
            file_path.resolve().relative_to(script_dir.resolve())
        except ValueError:
            self.send_error(403, "Forbidden")
            return
        
        if not file_path.exists() or not file_path.is_file():
            self.send_error(404, "File not found")
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
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_error(500, f"Error serving file: {str(e)}")
    
    def handle_metrics_api(self, query_string):
        """Handle /api/metrics API endpoint."""
        query_params = parse_qs(query_string)
        
        # Parse optional query parameters
        start_date = query_params.get('start_date', [None])[0]
        end_date = query_params.get('end_date', [None])[0]
        script_name = query_params.get('script_name', [None])[0]
        
        try:
            metrics_data = self.load_metrics(start_date, end_date, script_name)
            
            response = json.dumps(metrics_data, indent=2).encode('utf-8')
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        except Exception as e:
            error_response = json.dumps({'error': str(e)}).encode('utf-8')
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.send_header('Content-length', str(len(error_response)))
            self.end_headers()
            self.wfile.write(error_response)
    
    def load_metrics(self, start_date=None, end_date=None, script_name=None):
        """Load and aggregate metrics from JSON files."""
        if not self.metrics_dir.exists():
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
            pattern = f'{script_name}-metrics-*.json'
        
        metrics_files = list(self.metrics_dir.glob(pattern))
        
        # Parse dates if provided
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
        
        return {
            'totalRuns': total_runs,
            'successRate': round(success_rate, 2),
            'avgDuration': round(avg_duration, 2),
            'totalWarnings': total_warnings,
            'totalErrors': total_errors,
            'recentRuns': recent_runs,
            'scripts': sorted(list(scripts))
        }


def create_handler_class(metrics_dir):
    """Create a handler class with metrics_dir bound."""
    class Handler(MetricsHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, metrics_dir=metrics_dir, **kwargs)
    return Handler


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description='Serve metrics dashboard')
    parser.add_argument('--port', type=int, default=8080, help='Port to serve on (default: 8080)')
    parser.add_argument('--metrics-dir', type=str, default=DEFAULT_METRICS_DIR,
                       help=f'Directory containing metrics JSON files (default: {DEFAULT_METRICS_DIR})')
    parser.add_argument('--host', type=str, default='localhost',
                       help='Host to bind to (default: localhost)')
    
    args = parser.parse_args()
    
    metrics_dir = Path(args.metrics_dir)
    if not metrics_dir.exists():
        print(f"Warning: Metrics directory {metrics_dir} does not exist. Creating it...")
        metrics_dir.mkdir(parents=True, exist_ok=True)
    
    handler_class = create_handler_class(str(metrics_dir))
    
    server_address = (args.host, args.port)
    httpd = HTTPServer(server_address, handler_class)
    
    print(f"\n📊 Goose Metrics Dashboard Server")
    print(f"   Metrics directory: {metrics_dir}")
    print(f"   Server: http://{args.host}:{args.port}")
    print(f"   API endpoint: http://{args.host}:{args.port}/api/metrics")
    print(f"   Press Ctrl+C to stop\n")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Shutting down server...")
        httpd.shutdown()


if __name__ == '__main__':
    main()

