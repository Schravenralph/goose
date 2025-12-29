#!/usr/bin/env python3
"""
LLM Judge post-processing script for Goose benchmarks.

This script evaluates benchmark results using OpenAI's API as a judge.
It reads the eval-results.json file and a specified output file, then uses
OpenAI to score the output based on a provided rubric.

Usage:
    python llm_judge.py <output_file> [--rubric-max-score N] [--prompt-file PATH]
    
Arguments:
    output_file: Name of the file containing the output to evaluate (e.g., blog_summary_output.txt)
    --rubric-max-score: Maximum score for the rubric (default: 2)
    --prompt-file: Path to custom evaluation prompt file
"""

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Dict, Any

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

try:
    from openai import OpenAI
except ImportError:
    logging_utils.log_error("openai package not found. Please install it with: pip install openai")
    sys.exit(1)


def evaluate_with_openai(prompt: str, text: str, rubric_max_score: int = 2) -> float:
    """Evaluate response using OpenAI's API.
    
    Args:
        prompt: System prompt for evaluation
        text: Text to evaluate
        rubric_max_score: Maximum score for the rubric (default: 2.0)
        
    Returns:
        float: Evaluation score (0 to rubric_max_score)
        
    Raises:
        ValueError: If OPENAI_API_KEY environment variable is not set
    """
    logging_utils.start_span("openai_evaluation")
    logging_utils.log_info("Starting OpenAI evaluation...")
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        logging_utils.log_error("No OpenAI API key found!")
        raise ValueError("OPENAI_API_KEY environment variable is not set, but is needed to run this evaluation.")
        
    try:
        client = OpenAI(api_key=api_key)
        
        # Append output instructions to system prompt
        output_instructions = f"""
Output Instructions:
Return your evaluation as a JSON object in the following format:
{{
    "reasoning": "Your brief reasoning for the score",
    "score": <integer between 0 and {rubric_max_score}>
}}

IMPORTANT: 
- Do not use any markdown formatting (no ```json blocks)
- Do not include any additional text before or after the JSON
- Return only the raw JSON object
- The score must be an integer between 0 and {rubric_max_score}"""
        
        input_prompt = f"{prompt} {output_instructions}\nResponse to evaluate: {text}"
        
        # Run the chat completion 3 times and collect scores
        scores = []
        for i in range(3):
            max_retries = 5
            retry_count = 0
            
            while retry_count < max_retries:
                try:
                    response = client.chat.completions.create(
                        model="gpt-4o",
                        messages=[
                            {"role": "user", "content": input_prompt}
                        ],
                        temperature=0.9
                    )
                    
                    # Extract and parse JSON from response
                    response_text = response.choices[0].message.content.strip()
                    try:
                        evaluation = json.loads(response_text)
                        score = float(evaluation.get("score", 0.0))
                        score = max(0.0, min(score, rubric_max_score))
                        scores.append(score)
                        logging_utils.log_info(f"Run {i+1} score: {score}")
                        logging_utils.record_metric('evaluation_score', score, run=i+1)
                        break  # Successfully parsed, exit retry loop
                    except (json.JSONDecodeError, ValueError) as e:
                        retry_count += 1
                        logging_utils.log_warn(f"Error parsing OpenAI response as JSON (attempt {retry_count}/{max_retries}): {str(e)}")
                        logging_utils.log_debug(f"Response text: {response_text}")
                        if retry_count == max_retries:
                            raise ValueError(f"Failed to parse OpenAI evaluation response after {max_retries} attempts: {str(e)}")
                        logging_utils.log_info("Retrying...")
                        time.sleep(1)  # Wait 1 second before retrying
                        continue
                except Exception as e:
                    # For other exceptions (API errors, etc.), raise immediately
                    logging_utils.log_error(f"API error: {str(e)}")
                    raise
        
        # Count occurrences of each score
        score_counts = Counter(scores)
        
        # If there's no single most common score (all scores are different), run one more time
        if len(scores) == 3 and max(score_counts.values()) == 1:
            logging_utils.log_info("No majority score found. Running tie-breaker...")
            logging_utils.increment_counter('tie_breakers')
            max_retries = 5
            retry_count = 0
            
            while retry_count < max_retries:
                try:
                    response = client.chat.completions.create(
                        model="gpt-4o",
                        messages=[
                            {"role": "user", "content": input_prompt}
                        ],
                        temperature=0.9
                    )
                    
                    response_text = response.choices[0].message.content.strip()
                    try:
                        evaluation = json.loads(response_text)
                        score = float(evaluation.get("score", 0.0))
                        score = max(0.0, min(score, rubric_max_score))
                        scores.append(score)
                        logging_utils.log_info(f"Tie-breaker score: {score}")
                        logging_utils.record_metric('tie_breaker_score', score)
                        score_counts = Counter(scores)
                        break  # Successfully parsed, exit retry loop
                    except (json.JSONDecodeError, ValueError) as e:
                        retry_count += 1
                        logging_utils.log_warn(f"Error parsing tie-breaker response as JSON (attempt {retry_count}/{max_retries}): {str(e)}")
                        logging_utils.log_debug(f"Response text: {response_text}")
                        if retry_count == max_retries:
                            raise ValueError(f"Failed to parse tie-breaker response after {max_retries} attempts: {str(e)}")
                        logging_utils.log_info("Retrying tie-breaker...")
                        time.sleep(1)  # Wait 1 second before retrying
                        continue
                except Exception as e:
                    # For other exceptions (API errors, etc.), raise immediately
                    logging_utils.log_error(f"API error in tie-breaker: {str(e)}")
                    raise
        
        # Get the most common score
        most_common_score = score_counts.most_common(1)[0][0]
        logging_utils.log_info(f"Most common score: {most_common_score} (occurred {score_counts[most_common_score]} times)")
        logging_utils.record_metric('final_score', most_common_score)
        logging_utils.record_metric('score_consensus', score_counts[most_common_score])
        logging_utils.end_span()
        return most_common_score
            
    except Exception as e:
        logging_utils.end_span()
        if "OPENAI_API_KEY" in str(e):
            raise  # Re-raise API key errors
        logging_utils.log_error(f"Error evaluating with OpenAI: {str(e)}")
        raise ValueError(f"OpenAI evaluation failed: {str(e)}")


def load_eval_results(working_dir: Path) -> Dict[str, Any]:
    """Load the eval-results.json file from the working directory."""
    logging_utils.start_span("load_eval_results")
    eval_results_path = working_dir / "eval-results.json"
    if not eval_results_path.exists():
        logging_utils.log_error(f"eval-results.json not found in {working_dir}")
        logging_utils.end_span()
        raise FileNotFoundError(f"eval-results.json not found in {working_dir}")
    
    with open(eval_results_path, 'r') as f:
        result = json.load(f)
    logging_utils.end_span()
    return result


def load_output_file(working_dir: Path, output_file: str) -> str:
    """Load the output file to evaluate from the working directory."""
    output_path = working_dir / output_file
    if not output_path.exists():
        raise FileNotFoundError(f"Output file not found: {output_path}")
    
    with open(output_path, 'r') as f:
        return f.read().strip()


def load_evaluation_prompt(working_dir: Path) -> str:
    """Load the evaluation prompt from a file or use a default.
    
    This function looks for a prompt.txt file in the working directory.
    If not found, it returns a default evaluation prompt.
    """
    prompt_file = working_dir / "prompt.txt"
    if prompt_file.exists():
        with open(prompt_file, 'r') as f:
            return f.read().strip()
    
    # Default evaluation prompt
    return """You are an expert evaluator assessing the quality of AI responses.
Evaluate the response based on the following criteria:
- Accuracy and correctness
- Completeness of the answer
- Clarity and coherence
- Helpfulness to the user

Score the response on a scale from 0 to 2:
0 = Poor response (incorrect, incomplete, or unhelpful)
1 = Acceptable response (partially correct but with issues)
2 = Excellent response (correct, complete, and helpful)"""


def main():
    logging_utils.start_span("llm_judge_main")
    parser = argparse.ArgumentParser(description="LLM Judge post-processing script for Goose benchmarks")
    parser.add_argument("output_file", type=str, help="Name of the output file to evaluate (e.g., blog_summary_output.txt)")
    parser.add_argument("--rubric-max-score", type=int, default=2, help="Maximum score for the rubric (default: 2)")
    parser.add_argument("--prompt-file", type=str, help="Path to custom evaluation prompt file")
    
    args = parser.parse_args()
    logging_utils.record_metric('rubric_max_score', args.rubric_max_score)
    logging_utils.record_metric('output_file', args.output_file)
    
    # Use current working directory
    working_dir = Path.cwd()
    
    try:
        # Load eval results
        eval_results = load_eval_results(working_dir)
        
        # Load the output file to evaluate
        logging_utils.start_span("load_output_file")
        response_text = load_output_file(working_dir, args.output_file)
        logging_utils.end_span()
        
        # Load evaluation prompt
        logging_utils.start_span("load_evaluation_prompt")
        if args.prompt_file:
            with open(args.prompt_file, 'r') as f:
                evaluation_prompt = f.read().strip()
            logging_utils.record_metric('prompt_source', 'file')
        else:
            evaluation_prompt = load_evaluation_prompt(working_dir)
            logging_utils.record_metric('prompt_source', 'default')
        logging_utils.end_span()
        
        # Evaluate with OpenAI
        score = evaluate_with_openai(evaluation_prompt, response_text, args.rubric_max_score)
        
        # Update eval results with the score
        logging_utils.start_span("save_results")
        eval_results["metrics"].append([
            "llm_judge_score", 
            {"Float": score}
        ])

        # Save updated results
        eval_results_path = working_dir / "eval-results.json"
        with open(eval_results_path, 'w') as f:
            json.dump(eval_results, f, indent=2)
        
        logging_utils.log_info(f"Successfully updated eval-results.json with LLM judge score: {score}")
        logging_utils.record_metric('llm_judge_score', score)
        logging_utils.end_span()
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=0)
        
    except Exception as e:
        logging_utils.log_error(f"Error: {str(e)}")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
        sys.exit(1)


if __name__ == "__main__":
    main()
