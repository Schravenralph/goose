#!/usr/bin/env python3
"""
Structured logging utilities for Python scripts.
Provides JSON logging with timestamps, trace IDs, and log levels.
Mirrors functionality of logging-utils.sh for consistency across bash and Python scripts.
"""

import json
import os
import sys
import time
import uuid
import logging
from datetime import datetime, timezone
from pathlib import Path
from contextvars import ContextVar
from typing import Optional, Dict, Any
import subprocess
import socket

# Context variables for trace ID and span tracking
_trace_id: ContextVar[Optional[str]] = ContextVar('trace_id', default=None)
_span_id: ContextVar[Optional[str]] = ContextVar('span_id', default=None)
_span_name: ContextVar[Optional[str]] = ContextVar('span_name', default=None)
_span_start_time: ContextVar[Optional[float]] = ContextVar('span_start_time', default=None)

# Metrics storage
_metrics: Dict[str, Any] = {}

# Initialize trace ID
def _generate_trace_id() -> str:
    """Generate a unique trace ID."""
    try:
        return str(uuid.uuid4())
    except Exception:
        # Fallback: use timestamp-based ID
        return f"{int(time.time() * 1e9):x}"[:32]

# Get or create trace ID
_trace_id_value = os.environ.get('TRACE_ID')
if not _trace_id_value:
    _trace_id_value = _generate_trace_id()
_trace_id.set(_trace_id_value)
os.environ['TRACE_ID'] = _trace_id_value

# Get script name
_script_name = os.environ.get('SCRIPT_NAME')
if not _script_name:
    _script_name = Path(sys.argv[0]).name if sys.argv else 'unknown'
os.environ['SCRIPT_NAME'] = _script_name

# Log directory
_log_dir = Path(os.environ.get('LOG_DIR', '/tmp/goose-logs'))
_log_dir.mkdir(parents=True, exist_ok=True)

# Log file with timestamp
_log_file_env = os.environ.get('LOG_FILE')
if _log_file_env:
    _log_file = Path(_log_file_env)
else:
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    _log_file = _log_dir / f"{_script_name}-{timestamp}.jsonl"

# Metrics file
_metrics_file_env = os.environ.get('METRICS_FILE')
if _metrics_file_env:
    _metrics_file = Path(_metrics_file_env)
else:
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    _metrics_file = _log_dir / f"{_script_name}-metrics-{timestamp}.json"

# Initialize metrics
_metrics['start_time'] = time.time()
_metrics['script_name'] = _script_name
_metrics['trace_id'] = _trace_id_value
_metrics['hostname'] = socket.gethostname()
_metrics['user'] = os.environ.get('USER', os.environ.get('USERNAME', 'unknown'))
_metrics['pid'] = os.getpid()

# Get git context if available
def _get_git_info() -> Dict[str, str]:
    """Get git branch, commit, and remote URL."""
    git_info = {
        'git_branch': 'unknown',
        'git_commit': 'unknown',
        'git_remote': 'unknown'
    }
    
    try:
        # Get git branch
        result = subprocess.run(
            ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            git_info['git_branch'] = result.stdout.strip()
        
        # Get git commit
        result = subprocess.run(
            ['git', 'rev-parse', '--short', 'HEAD'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            git_info['git_commit'] = result.stdout.strip()
        
        # Get git remote
        result = subprocess.run(
            ['git', 'config', '--get', 'remote.origin.url'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            git_info['git_remote'] = result.stdout.strip()
    except Exception:
        pass
    
    return git_info

git_info = _get_git_info()
_metrics.update(git_info)

# Get project version if Cargo.toml exists
def _get_project_info() -> Dict[str, str]:
    """Get project name and version from Cargo.toml."""
    project_info = {
        'project_version': 'unknown',
        'project_name': 'unknown'
    }
    
    cargo_toml = Path('Cargo.toml')
    if cargo_toml.exists():
        try:
            with open(cargo_toml, 'r') as f:
                for line in f:
                    if line.startswith('version') and '=' in line:
                        # Extract version: version = "1.2.3"
                        parts = line.split('=')
                        if len(parts) == 2:
                            version = parts[1].strip().strip('"').strip("'")
                            project_info['project_version'] = version
                    elif line.startswith('name') and '=' in line:
                        # Extract name: name = "goose"
                        parts = line.split('=')
                        if len(parts) == 2:
                            name = parts[1].strip().strip('"').strip("'")
                            project_info['project_name'] = name
        except Exception:
            pass
    
    return project_info

project_info = _get_project_info()
_metrics.update(project_info)


def log(level: str, message: str, *args, **kwargs) -> None:
    """
    Log a message with structured JSON format.
    
    Args:
        level: Log level (DEBUG, INFO, WARN, ERROR, FATAL)
        message: Log message
        *args: Additional context strings (e.g., "key=value")
        **kwargs: Additional context as key-value pairs
    """
    timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
    trace_id = _trace_id.get() or _trace_id_value
    span_id = _span_id.get()
    
    # Build context from args and kwargs
    context = {}
    for arg in args:
        if '=' in arg:
            key, value = arg.split('=', 1)
            context[key] = value
    context.update(kwargs)
    
    # Create JSON log entry
    log_entry = {
        'timestamp': timestamp,
        'level': level,
        'trace_id': trace_id,
        'span_id': span_id or '',
        'script': _script_name,
        'message': message,
        'hostname': socket.gethostname(),
        'user': os.environ.get('USER', os.environ.get('USERNAME', 'unknown')),
        'pid': os.getpid()
    }
    
    # Add context if present
    if context:
        log_entry['context'] = context
    
    # Write to log file
    try:
        with open(_log_file, 'a') as f:
            f.write(json.dumps(log_entry) + '\n')
    except Exception as e:
        # Fallback to stderr if file write fails
        print(f"Failed to write log: {e}", file=sys.stderr)
    
    # Also output to console with appropriate formatting
    emoji_map = {
        'DEBUG': '🔍',
        'INFO': 'ℹ️ ',
        'WARN': '⚠️ ',
        'ERROR': '❌',
        'FATAL': '💥'
    }
    emoji = emoji_map.get(level, '')
    
    output = f"{emoji} [{level}] {message}"
    if context:
        context_str = ' '.join(f"{k}={v}" for k, v in context.items())
        output += f" {context_str}"
    
    if level in ('ERROR', 'FATAL', 'WARN', 'DEBUG'):
        print(output, file=sys.stderr)
    else:
        print(output)


def log_debug(message: str, *args, **kwargs) -> None:
    """Log a DEBUG message."""
    log('DEBUG', message, *args, **kwargs)


def log_info(message: str, *args, **kwargs) -> None:
    """Log an INFO message."""
    log('INFO', message, *args, **kwargs)


def log_warn(message: str, *args, **kwargs) -> None:
    """Log a WARN message."""
    log('WARN', message, *args, **kwargs)


def log_error(message: str, *args, **kwargs) -> None:
    """Log an ERROR message."""
    log('ERROR', message, *args, **kwargs)


def log_fatal(message: str, *args, **kwargs) -> None:
    """Log a FATAL message and exit."""
    log('FATAL', message, *args, **kwargs)
    sys.exit(1)


def start_span(span_name: str) -> None:
    """
    Start a span (operation tracking).
    
    Args:
        span_name: Name of the span/operation
    """
    span_id = str(uuid.uuid4())[:16]
    _span_id.set(span_id)
    _span_name.set(span_name)
    _span_start_time.set(time.time())
    log_info(f"Starting span: {span_name}", span_id=span_id)


def end_span() -> None:
    """End the current span and record duration."""
    span_start = _span_start_time.get()
    if span_start is not None:
        span_name = _span_name.get() or 'unknown'
        span_id = _span_id.get() or ''
        end_time = time.time()
        duration = end_time - span_start
        
        log_info(f"Ending span: {span_name}", duration=f"{duration:.3f}s", span_id=span_id)
        record_metric('span_duration', duration, span_name=span_name)
        
        _span_id.set(None)
        _span_name.set(None)
        _span_start_time.set(None)


def record_metric(metric_name: str, metric_value: Any, **labels) -> None:
    """
    Record a metric.
    
    Args:
        metric_name: Name of the metric
        metric_value: Value of the metric
        **labels: Additional labels for the metric
    """
    # Create key with labels
    if labels:
        label_str = '_'.join(f"{k}={v}" for k, v in sorted(labels.items()))
        key = f"{metric_name}_{label_str}"
    else:
        key = metric_name
    
    _metrics[key] = metric_value
    log_debug(f"Metric recorded: {metric_name}={metric_value} {' '.join(f'{k}={v}' for k, v in labels.items())}")


def increment_counter(counter_name: str) -> None:
    """
    Increment a counter metric.
    
    Args:
        counter_name: Name of the counter
    """
    current_value = _metrics.get(counter_name, 0)
    _metrics[counter_name] = current_value + 1
    log_debug(f"Counter incremented: {counter_name}={_metrics[counter_name]}")


def write_metrics(exit_code: int = 0) -> None:
    """
    Write metrics to file.
    
    Args:
        exit_code: Exit code of the script
    """
    end_time = time.time()
    duration = end_time - _metrics['start_time']
    
    _metrics['end_time'] = end_time
    _metrics['duration'] = duration
    _metrics['exit_code'] = str(exit_code)
    
    # Write metrics to file
    try:
        with open(_metrics_file, 'w') as f:
            json.dump(_metrics, f, indent=2)
        log_info(f"Metrics written to: {_metrics_file}")
    except Exception as e:
        print(f"Failed to write metrics: {e}", file=sys.stderr)


# Initialize logging on import
log_info("Script started", trace_id=_trace_id_value, log_file=str(_log_file))
log_info("Context",
         git_branch=_metrics.get('git_branch', 'unknown'),
         git_commit=_metrics.get('git_commit', 'unknown'),
         project_name=_metrics.get('project_name', 'unknown'),
         project_version=_metrics.get('project_version', 'unknown'))

# Register exit handler to write metrics
import atexit

def _exit_handler():
    """Exit handler to write metrics on script exit."""
    # Try to get exit code from sys.exit if available
    exit_code = 0
    exc_info = sys.exc_info()
    if exc_info[0] is not None:
        exit_code = 1
    write_metrics(exit_code=exit_code)

atexit.register(_exit_handler)

