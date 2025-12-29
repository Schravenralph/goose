# Goose Scripts

This directory contains scripts for running benchmarks, tests, and other automated tasks for the Goose project.

## Structured Logging

All scripts in this directory support structured logging through `logging-utils.sh` (for bash scripts) and `logging_utils.py` (for Python scripts). This provides:

- **JSON Logging**: Structured JSON logs with timestamps, trace IDs, and log levels
- **Metrics Collection**: Automatic collection of execution metrics
- **Span Tracking**: Operation-level tracking with duration measurements
- **Context Enrichment**: Automatic inclusion of git info, project version, and system context

### Scripts with Structured Logging

The following scripts have been enhanced with structured logging:

**Python Scripts:**
- `bench-postprocess-scripts/generate_leaderboard.py` - Generate leaderboard from benchmark results
- `bench-postprocess-scripts/prepare_aggregate_metrics.py` - Prepare aggregate metrics from eval results
- `bench-postprocess-scripts/llm-judges/llm_judge.py` - LLM judge post-processing script for benchmarks
- `bench-postprocess-scripts/llm-judges/calculate_final_scores_vibes.py` - Calculate final scores for vibes evaluations
- `provider-error-proxy/proxy.py` - Provider error proxy for testing Goose error handling
- `serve-metrics-dashboard.py` - Metrics dashboard server
- `recipe-scanner/decode-training-data.py` - Decode base64 training data for recipe scanner
- `documentation/scripts/community_stars.py` - Community stars analysis script

**Linting & Code Quality:**
- `clippy-lint.sh` - Clippy linting with structured logging
- `clippy-baseline.sh` - Baseline clippy rule checks
- `check-no-native-tls.sh` - TLS dependency checks
- `check-openapi-schema.sh` - OpenAPI schema validation

**Testing:**
- `test_providers.sh` - Provider functionality tests
- `test_mcp.sh` - MCP sampling tests
- `test_web.sh` - Web interface tests
- `test_subrecipes.sh` - Subrecipe workflow tests
- `test_compaction.sh` - Compaction smoke tests
- `test_lead_worker.sh` - Lead/worker provider tests

**Benchmarking:**
- `run-benchmarks.sh` - Benchmark execution across providers
- `parse-benchmark-results.sh` - Benchmark result analysis

**Other:**
- `goose-db-helper.sh` - Database helper utilities
- `clean-gh-pages.sh` - GitHub Pages cleanup

### Log Files

Logs are written to `/tmp/goose-logs/` by default (configurable via `LOG_DIR` environment variable):

- **Log files**: `{script-name}-{timestamp}.jsonl` (JSON Lines format)
- **Metrics files**: `{script-name}-metrics-{timestamp}.json` (JSON format)

### Environment Variables

- `TRACE_ID`: Set a custom trace ID (default: auto-generated)
- `LOG_DIR`: Custom log directory (default: `/tmp/goose-logs`)
- `LOG_FILE`: Custom log file path
- `METRICS_FILE`: Custom metrics file path

### Viewing Logs

```bash
# View latest log file
tail -f /tmp/goose-logs/*.jsonl | jq '.'

# Filter by log level
cat /tmp/goose-logs/*.jsonl | jq 'select(.level == "ERROR")'

# View metrics
cat /tmp/goose-logs/*-metrics-*.json | jq '.'
```

### Python Scripts Integration

Python scripts can use structured logging by importing `logging_utils`:

```python
import sys
from pathlib import Path

# Add parent directory to path for logging_utils import
sys.path.insert(0, str(Path(__file__).parent.parent))

try:
    import logging_utils
except ImportError:
    # Fallback if logging_utils is not available
    class DummyLogger:
        def log_info(self, *args, **kwargs): print(*args)
        def log_warn(self, *args, **kwargs): print(f"WARNING: {args[0] if args else ''}", file=sys.stderr)
        def log_error(self, *args, **kwargs): print(f"ERROR: {args[0] if args else ''}", file=sys.stderr)
        def start_span(self, *args, **kwargs): pass
        def end_span(self, *args, **kwargs): pass
        def record_metric(self, *args, **kwargs): pass
        def write_metrics(self, *args, **kwargs): pass
    logging_utils = DummyLogger()

# Usage examples:
logging_utils.log_info("Processing started", items=100)
logging_utils.start_span("process_data")
# ... do work ...
logging_utils.end_span()
logging_utils.record_metric("items_processed", 100)
logging_utils.write_metrics(exit_code=0)
```

The `logging_utils` module automatically:
- Generates a trace ID for the script execution
- Initializes log and metrics files
- Captures git context and project version
- Writes metrics on script exit (via atexit handler)

### Backward Compatibility

All scripts maintain backward compatibility. If `logging-utils.sh` is not available, bash scripts will fall back to standard `echo` output. Python scripts include a fallback `DummyLogger` class that provides the same interface but uses standard print statements.

For more details, see `LOGGING_IMPROVEMENTS.md`.

### OpenTelemetry (OTLP) Integration

Bash scripts can export traces and spans to OpenTelemetry-compatible observability backends (Jaeger, Tempo, Grafana Cloud, etc.) for distributed tracing.

**Quick Start:**

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
# Spans created with start_span()/end_span() are automatically exported
```

**Features:**
- Automatic span export to OTLP endpoints
- W3C Trace Context compatible trace IDs
- Span context propagation between scripts
- Parent-child span relationships

For detailed documentation, see `OTLP_INTEGRATION.md`.

## Testing Structured Logging

Integration tests for structured logging are available in `test-logging.sh`. This test suite verifies:

- Log file generation and JSON format validation
- Metrics file generation and JSON format validation
- Trace ID uniqueness across executions
- Span tracking functionality
- Backward compatibility (scripts work without logging-utils.sh)
- Error handling (missing directories, permission issues, etc.)
- Fallback behavior without optional dependencies (jq, bc)

### Running the Tests

```bash
# Run all logging tests
cd scripts
bash test-logging.sh
```

The test script:
- Uses temporary directories (non-destructive)
- Works with or without optional dependencies (jq, bc)
- Provides detailed pass/fail reporting
- Can be integrated into CI/CD pipelines

### Test Coverage

The test suite covers 20+ test cases including:
- Basic logging functionality (log file creation, JSON format)
- All log levels (DEBUG, INFO, WARN, ERROR)
- Metrics collection and export
- Span tracking (start/end, duration measurement)
- Trace ID generation (unique, custom)
- Context enrichment (hostname, user, git info)
- Edge cases (missing tools, permission issues)

## Benchmark Scripts

## run-benchmarks.sh

This script runs Goose benchmarks across multiple provider:model pairs and analyzes the results.

### Prerequisites

- Goose CLI must be built or installed
- `jq` command-line tool for JSON processing (optional, but recommended for result analysis)

### Usage

```bash
./scripts/run-benchmarks.sh [options]
```

#### Options

- `-p, --provider-models`: Comma-separated list of provider:model pairs (e.g., 'openai:gpt-4o,anthropic:claude-sonnet-4')
- `-s, --suites`: Comma-separated list of benchmark suites to run (e.g., 'core,small_models')
- `-o, --output-dir`: Directory to store benchmark results (default: './benchmark-results')
- `-d, --debug`: Use debug build instead of release build
- `-h, --help`: Show help message

#### Examples

```bash
# Run with release build (default)
./scripts/run-benchmarks.sh --provider-models 'openai:gpt-4o,anthropic:claude-sonnet-4' --suites 'core,small_models'

# Run with debug build
./scripts/run-benchmarks.sh --provider-models 'openai:gpt-4o' --suites 'core' --debug
```

### How It Works

The script:
1. Parses the provider:model pairs and benchmark suites
2. Determines whether to use the debug or release binary
3. For each provider:model pair:
   - Sets the `GOOSE_PROVIDER` and `GOOSE_MODEL` environment variables
   - Runs the benchmark with the specified suites
   - Analyzes the results for failures
4. Generates a summary of all benchmark runs

### Output

The script creates the following files in the output directory:

- `summary.md`: A summary of all benchmark results
- `{provider}-{model}.json`: Raw JSON output from each benchmark run
- `{provider}-{model}-analysis.txt`: Analysis of each benchmark run

### Exit Codes

- `0`: All benchmarks completed successfully
- `1`: One or more benchmarks failed

## parse-benchmark-results.sh

This script analyzes a single benchmark JSON result file and identifies any failures.

### Usage

```bash
./scripts/parse-benchmark-results.sh path/to/benchmark-results.json
```

### Output

The script outputs an analysis of the benchmark results to stdout, including:

- Basic information about the benchmark run
- Results for each evaluation in each suite
- Summary of passed and failed metrics

### Exit Codes

- `0`: All metrics passed successfully
- `1`: One or more metrics failed

## Metrics Dashboard

A web-based dashboard for visualizing script execution metrics, success rates, performance trends, and issue tracking.

### Prerequisites

- Python 3.6+ (for the server script)
- Metrics JSON files generated by scripts using `logging-utils.sh`
- Modern web browser

### Usage

Start the metrics dashboard server:

```bash
# Start with default settings (port 8080, metrics from /tmp/goose-logs)
./scripts/serve-metrics-dashboard.py

# Custom port and metrics directory
./scripts/serve-metrics-dashboard.py --port 8080 --metrics-dir /tmp/goose-logs

# Bind to all interfaces (accessible from other machines)
./scripts/serve-metrics-dashboard.py --host 0.0.0.0 --port 8080
```

Then open your browser and navigate to:
```
http://localhost:8080
```

### Features

- **Real-time Metrics**: Displays aggregated metrics from all script executions
- **Visualizations**: 
  - Execution duration trends over time
  - Success rate charts
  - Warnings and errors tracking
- **Filtering**: Filter by date range and script name
- **Export**: Export data as CSV or JSON
- **Auto-refresh**: Automatically refreshes metrics every 30 seconds

### Metrics Displayed

- Total runs: Number of script executions
- Success rate: Percentage of successful executions
- Average duration: Average execution time

## Prometheus Integration

The Prometheus exporter allows you to integrate Goose metrics with Prometheus for production-grade monitoring, alerting, and long-term metric storage.

### Prerequisites

- Prometheus server installed and running
- `jq` command-line JSON processor
- `socat`, `netcat`, or Python 3 for HTTP server
- Metrics JSON files generated by Goose scripts

### Usage

Start the Prometheus exporter:

```bash
# Start with default settings (port 9090, metrics from /tmp/goose-logs)
./scripts/prometheus-exporter.sh

# Custom port and metrics directory
./scripts/prometheus-exporter.sh --port 9091 --metrics-dir /var/log/goose-metrics
```

The exporter exposes metrics at `http://localhost:9090/metrics` (or your configured port).

### Configuration

1. **Configure Prometheus**: Copy or merge `prometheus.yml` into your Prometheus configuration
2. **Start Prometheus**: Start Prometheus with the updated configuration
3. **Verify**: Check Prometheus targets to ensure scraping is working

### Metrics Exposed

- `goose_execution_duration_seconds`: Script execution duration (gauge)
- `goose_success_rate`: Success rate (gauge)
- `goose_error_count`: Number of errors (counter)
- `goose_warning_count`: Number of warnings (counter)
- `goose_exit_code`: Script exit code (gauge)
- Script-specific metrics with `script` label

### Documentation

For detailed setup instructions, examples, and troubleshooting, see:
- [PROMETHEUS_INTEGRATION.md](./PROMETHEUS_INTEGRATION.md)

## Grafana Integration

Grafana integration provides advanced visualization capabilities, alerting, and better user experience compared to the standalone HTML dashboard.

### Features

- Advanced visualization options (graphs, heatmaps, stat panels, etc.)
- Real-time dashboards with auto-refresh
- Alerting integration with notification channels
- Dashboard sharing and templating
- Better performance for large datasets
- Integration with Prometheus (if Prometheus exporter is running)

### Prerequisites

- Grafana instance (local or remote)
- Metrics JSON files being generated (in `/tmp/goose-logs/` by default)
- Optional: Prometheus server and exporter (for better performance)

### Quick Start

1. **Start Prometheus Exporter** (if using Prometheus datasource):
   ```bash
   ./scripts/prometheus-exporter.sh --port 9090
   ```

2. **Import Dashboard**:
   - Open Grafana UI
   - Go to Dashboards → Import
   - Upload `scripts/grafana-dashboard-goose.json`
   - Select your Prometheus data source
   - Click Import

3. **Configure Data Source** (if not using file-based provisioning):
   - Go to Configuration → Data Sources
   - Add Prometheus data source pointing to `http://localhost:9090`

### Dashboard Panels

The dashboard includes 10 panels:
- Execution Duration Trends
- Success Rate Over Time
- Overall Success Rate (stat)
- Total Executions (stat)
- Average Duration (stat)
- Errors and Warnings (stat)
- Errors and Warnings Over Time
- Script Performance Comparison
- Top Failing Scripts
- Recent Executions

### Alert Rules

Pre-configured alert rules for:
- High error rate detection
- Repeated script failures
- Performance degradation
- Low success rate
- No executions detected

### File-Based Provisioning

For production deployments, use file-based provisioning:
- Data source: `grafana-provisioning-datasources.yaml`
- Dashboards: `grafana-provisioning-dashboards.yaml`
- Alert rules: `grafana-alert-rules.yaml`

### Documentation

For detailed setup instructions, configuration options, and troubleshooting, see:
- [GRAFANA_SETUP.md](./GRAFANA_SETUP.md)

### Related Files

- `grafana-dashboard-goose.json` - Main dashboard definition
- `grafana-datasource-prometheus.json` - Prometheus data source configuration
- `grafana-alert-rules.yaml` - Alert rule definitions
- `grafana-provisioning-datasources.yaml` - Data source provisioning
- `grafana-provisioning-dashboards.yaml` - Dashboard provisioning

### Related Work Items

- WI-001: Prometheus Integration (enables Prometheus datasource)
- WI-004: Monitoring Tools Production Deployment
- 2024-12-29-metrics-dashboard-integration.md: Original HTML dashboard

- Total warnings: Sum of all warnings across executions
- Total errors: Sum of all errors across executions

### API Endpoint

The server provides a JSON API endpoint at `/api/metrics`:

```bash
# Get all metrics
curl http://localhost:8080/api/metrics

# Filter by date range
curl "http://localhost:8080/api/metrics?start_date=2024-12-29T00:00:00Z&end_date=2024-12-30T00:00:00Z"

# Filter by script name
curl "http://localhost:8080/api/metrics?script_name=clippy-lint"
```

### Configuration

The dashboard reads metrics from JSON files generated by scripts using the `logging-utils.sh` utilities. By default, it looks for metrics files in `/tmp/goose-logs/`, but this can be configured via the `--metrics-dir` parameter or the `LOG_DIR` environment variable used by the scripts.

### File Locations

- Dashboard HTML: `scripts/metrics-dashboard.html`
- Server script: `scripts/serve-metrics-dashboard.py`
- Metrics files: `/tmp/goose-logs/*-metrics-*.json` (configurable)