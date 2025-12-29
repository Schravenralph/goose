#!/usr/bin/env python3
"""
Calculate final score for vibes evaluations.
This script combines the LLM judge score with other metrics to produce a final score.
"""

import json
import sys
from pathlib import Path

# Add parent directory to path for logging_utils import
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

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


def get_metric_value(metrics, metric_name):
    """Extract a metric value from the metrics array."""
    for metric in metrics:
        if metric[0] == metric_name:
            value = metric[1]
            if "Float" in value:
                return float(value["Float"])
            elif "Integer" in value:
                return float(value["Integer"])
            elif "Boolean" in value:
                return 1.0 if value["Boolean"] else 0.0
    return None


def calculate_score(eval_name, metrics):
    """Calculate the final score based on the evaluation type."""
    logging_utils.start_span("calculate_score")
    logging_utils.record_metric('eval_name', eval_name)
    
    llm_judge_score = get_metric_value(metrics, "llm_judge_score")
    used_fetch_tool = get_metric_value(metrics, "used_fetch_tool")
    valid_markdown_format = get_metric_value(metrics, "valid_markdown_format")
    
    if llm_judge_score is None:
        logging_utils.log_error("llm_judge_score not found in metrics")
        logging_utils.end_span()
        raise ValueError("llm_judge_score not found in metrics")
    
    # Convert boolean metrics to 0/1 if needed
    used_fetch_tool = 1.0 if used_fetch_tool else 0.0
    valid_markdown_format = 1.0 if valid_markdown_format else 0.0
    
    logging_utils.record_metric('llm_judge_score', llm_judge_score)
    logging_utils.record_metric('used_fetch_tool', used_fetch_tool)
    logging_utils.record_metric('valid_markdown_format', valid_markdown_format)
    
    if eval_name == "blog_summary":
        # max score is 4.0 as llm_judge_score is between [0,2] and used_fetch_tool/valid_markedown_format have values [0,1]
        score = (llm_judge_score + used_fetch_tool + valid_markdown_format) / 4.0
    elif eval_name == "restaurant_research":
        score = (llm_judge_score + valid_markdown_format + used_fetch_tool) / 4.0
    else:
        logging_utils.log_error(f"Unknown evaluation type: {eval_name}")
        logging_utils.end_span()
        raise ValueError(f"Unknown evaluation type: {eval_name}")
    
    logging_utils.record_metric('final_score', score)
    logging_utils.end_span()
    return score


def main():
    logging_utils.start_span("calculate_final_scores_main")
    
    if len(sys.argv) != 2:
        logging_utils.log_error("Usage: calculate_final_score.py <eval_name>")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
        sys.exit(1)
    
    eval_name = sys.argv[1]
    logging_utils.record_metric('eval_name', eval_name)
    
    # Load eval results from current directory
    logging_utils.start_span("load_eval_results")
    eval_results_path = Path("eval-results.json")
    if not eval_results_path.exists():
        logging_utils.log_error(f"eval-results.json not found in current directory")
        logging_utils.end_span()
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
        sys.exit(1)
    
    with open(eval_results_path, 'r') as f:
        eval_results = json.load(f)
    logging_utils.end_span()
    
    try:
        # Calculate the final score
        score = calculate_score(eval_name, eval_results["metrics"])
        
        # Add the score metric
        logging_utils.start_span("save_results")
        eval_results["metrics"].append([
            "score",
            {"Float": score}
        ])
        
        # Save updated results
        with open(eval_results_path, 'w') as f:
            json.dump(eval_results, f, indent=2)
        
        logging_utils.log_info(f"Successfully added final score: {score}")
        logging_utils.end_span()
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=0)
        
    except Exception as e:
        logging_utils.log_error(f"Error calculating final score: {str(e)}")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
        sys.exit(1)


if __name__ == "__main__":
    main()
