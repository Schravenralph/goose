#!/usr/bin/env python3
"""
Decode base64 training data for the recipe scanner
This script will be used inside the Docker container to decode GitHub secrets
"""

import json
import base64
import os
import sys
import tempfile
from pathlib import Path

# Add scripts directory to path for logging_utils import
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

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

def decode_training_data():
    """
    Decode all available training data from environment variables
    Returns a dictionary with risk levels and their decoded recipes
    """
    logging_utils.start_span("decode_training_data")
    training_data = {}
    
    # Check for each risk level
    for risk_level in ["LOW", "MEDIUM", "HIGH", "EXTREME"]:
        env_var = f"TRAINING_DATA_{risk_level}"
        encoded_data = os.environ.get(env_var)
        
        if encoded_data:
            try:
                logging_utils.start_span(f"decode_{risk_level.lower()}_risk")
                # Decode the base64 outer layer
                json_data = base64.b64decode(encoded_data).decode('utf-8')
                
                # Parse the JSON
                parsed_data = json.loads(json_data)
                
                # Decode each recipe's content
                for recipe in parsed_data.get('recipes', []):
                    recipe_content = base64.b64decode(recipe['content_base64']).decode('utf-8')
                    recipe['content'] = recipe_content
                    # Keep the base64 version for reference but don't need it for analysis
                
                training_data[risk_level.lower()] = parsed_data
                recipe_count = len(parsed_data['recipes'])
                logging_utils.log_info(f"✅ Decoded {recipe_count} {risk_level.lower()} risk recipes")
                logging_utils.record_metric(f'{risk_level.lower()}_recipes', recipe_count)
                logging_utils.end_span()
                
            except Exception as e:
                logging_utils.log_error(f"❌ Error decoding {env_var}: {e}")
                logging_utils.end_span()
    
    logging_utils.end_span()
    return training_data

def write_training_files(training_data, output_dir="/tmp/training"):
    """
    Write decoded training files to disk for Goose to analyze
    """
    output_path = Path(output_dir)
    output_path.mkdir(exist_ok=True)
    
    # Write a summary file for Goose
    summary = {
        "training_summary": "Recipe security training data",
        "risk_levels": {},
        "total_recipes": 0
    }
    
    for risk_level, data in training_data.items():
        risk_dir = output_path / risk_level
        risk_dir.mkdir(exist_ok=True)
        
        recipes_info = []
        
        for recipe in data.get('recipes', []):
            # Write the recipe file
            recipe_file = risk_dir / recipe['filename']
            with open(recipe_file, 'w') as f:
                f.write(recipe['content'])
            
            # Write the training notes
            notes_file = risk_dir / f"{recipe['filename']}.notes.txt"
            with open(notes_file, 'w') as f:
                f.write(f"Risk Level: {risk_level.upper()}\n")
                f.write(f"Filename: {recipe['filename']}\n")
                f.write(f"Size: {recipe['size_bytes']} bytes\n\n")
                f.write("Training Notes:\n")
                f.write(recipe['training_notes'])
            
            recipes_info.append({
                "filename": recipe['filename'],
                "notes_file": str(notes_file),
                "training_notes": recipe['training_notes']
            })
        
        summary["risk_levels"][risk_level] = {
            "count": len(recipes_info),
            "recipes": recipes_info
        }
        summary["total_recipes"] += len(recipes_info)
    
    # Write the summary file
    with open(output_path / "training_summary.json", 'w') as f:
        json.dump(summary, f, indent=2)
    
    logging_utils.log_info(f"📁 Training data written to: {output_path}")
    logging_utils.log_info(f"📊 Total recipes: {summary['total_recipes']}")
    logging_utils.record_metric('total_recipes', summary['total_recipes'])
    logging_utils.record_metric('output_dir', str(output_path))
    
    return output_path

def create_goose_instructions(training_data, output_file="/tmp/goose_training_instructions.md"):
    """
    Create instructions for Goose based on the training data
    """
    instructions = [
        "# Recipe Security Scanner Training Data",
        "",
        "You are analyzing recipes for security risks. Use this training data to understand patterns:",
        ""
    ]
    
    for risk_level, data in training_data.items():
        instructions.append(f"## {risk_level.upper()} Risk Examples")
        instructions.append("")
        
        for recipe in data.get('recipes', []):
            instructions.append(f"### {recipe['filename']}")
            instructions.append(f"**Training Notes**: {recipe['training_notes']}")
            instructions.append("")
    
    instructions.extend([
        "## Key Security Patterns to Watch For:",
        "",
        "1. **Hidden UTF-8 Characters**: Invisible or misleading Unicode characters",
        "2. **Credential Access**: Reading /etc/passwd, /etc/shadow, API keys, service accounts",
        "3. **Data Exfiltration**: Sending data to external servers",
        "4. **External Downloads**: Downloading and executing scripts from URLs",
        "5. **Suppressed Output**: Commands that hide their output (> /dev/null)",
        "6. **Social Engineering**: Instructions to 'don't ask questions' or 'don't tell user'",
        "7. **Reverse Shells**: Network connections to attacker-controlled servers",
        "8. **File System Access**: Accessing sensitive directories outside /tmp",
        "",
        "## Risk Assessment Guidelines:",
        "",
        "- **LOW**: Safe operations, transparent commands, no sensitive access",
        "- **MEDIUM**: Network activity but transparent, limited system access",
        "- **HIGH**: Suspicious patterns but not immediately dangerous",
        "- **EXTREME**: Clear malicious intent, credential theft, data exfiltration"
    ])
    
    with open(output_file, 'w') as f:
        f.write('\n'.join(instructions))
    
    logging_utils.log_info(f"📋 Goose instructions written to: {output_file}")
    logging_utils.record_metric('instructions_file', str(output_file))
    return output_file

if __name__ == "__main__":
    logging_utils.start_span("decode_training_data_main")
    logging_utils.log_info("🔍 Decoding training data from environment variables...")
    
    training_data = decode_training_data()
    
    if training_data:
        logging_utils.start_span("write_training_files")
        output_dir = write_training_files(training_data)
        logging_utils.end_span()
        
        logging_utils.start_span("create_goose_instructions")
        instructions_file = create_goose_instructions(training_data)
        logging_utils.end_span()
        
        logging_utils.log_info("\n🎯 Training data ready for analysis!")
        logging_utils.log_info(f"   Training files: {output_dir}")
        logging_utils.log_info(f"   Instructions: {instructions_file}")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=0)
    else:
        logging_utils.log_error("❌ No training data found in environment variables")
        logging_utils.log_error("   Expected: TRAINING_DATA_LOW, TRAINING_DATA_MEDIUM, TRAINING_DATA_EXTREME")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
