#!/usr/bin/env python3
"""
Community Stars Analysis Script for block/goose repository

This script analyzes GitHub contributor statistics and generates rankings for:
- Top 5 Community All-Stars (External contributors)
- Top 5 Team Stars (Block employees, non-goose team)
- Monthly Leaderboard (all eligible contributors)

The script automatically:
- Fetches contributor data from GitHub API (with retry logic)
- Checks public org memberships to detect Block employees
- Categorizes contributors as Block or External
- Caches data locally for faster subsequent runs

Usage:
    python3 community_stars.py "November 2025"
    python3 community_stars.py "November 1, 2025 - November 17, 2025"
    python3 community_stars.py "2025-11-01 - 2025-11-17"

Requirements:
    - Internet connection (to fetch GitHub data)
    - Team list file at documentation/scripts/community_stars_teams.txt
"""

import json
import re
import sys
import urllib.request
from datetime import datetime
import calendar
from pathlib import Path
import time

# Add scripts directory to path for logging_utils import
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "scripts"))

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

# GitHub URL for team list file
TEAMS_FILE_URL = "https://raw.githubusercontent.com/block/goose/main/documentation/scripts/community_stars_teams.txt"
LOCAL_TEAMS_FILE = Path(__file__).parent / "community_stars_teams.txt"

# Block-related organizations to check
BLOCK_ORGS = {'square', 'block', 'squareup', 'block-ghc', 'cashapp'}

def is_block_employee(username):
    """Check if a user is a Block employee by checking their profile and org memberships.
    
    Makes a single API call to get user profile (includes company field),
    then only calls orgs endpoint if company field doesn't match.
    """
    try:
        # First check the user's profile (single API call)
        url = f"https://api.github.com/users/{username}"
        with urllib.request.urlopen(url) as response:
            user_data = json.loads(response.read().decode('utf-8'))
        
        # Check company field first (no additional API call needed)
        company = user_data.get('company', '').lower() if user_data.get('company') else ''
        if company:
            # Check for Block-related keywords in company field
            block_keywords = ['block', 'square', 'cash app', 'cashapp', 'tidal']
            if any(keyword in company for keyword in block_keywords):
                return True
        
        # Only check orgs if company field didn't match (second API call only when needed)
        url = f"https://api.github.com/users/{username}/orgs"
        with urllib.request.urlopen(url) as response:
            orgs = json.loads(response.read().decode('utf-8'))
            
        # Check if any org matches Block orgs (case-insensitive)
        user_orgs = {org['login'].lower() for org in orgs}
        if user_orgs & BLOCK_ORGS:
            return True
                
        return False
        
    except Exception as e:
        # If we can't check (rate limit, network error, etc.), return False
        # This means we'll default to treating them as external
        return False

def load_team_lists():
    """Load and parse team lists from file (local or GitHub)."""
    content = None
    
    # Try local file first
    if LOCAL_TEAMS_FILE.exists():
        with open(LOCAL_TEAMS_FILE, 'r') as f:
            content = f.read()
    else:
        # Fall back to GitHub
        try:
            with urllib.request.urlopen(TEAMS_FILE_URL) as response:
                content = response.read().decode('utf-8')
        except Exception as e:
            print(f"Error: Could not load team list file from {TEAMS_FILE_URL}")
            print(f"Details: {e}")
            sys.exit(1)
    
    # Parse the team lists
    goose_maintainers = set()
    block_non_goose = set()
    external_goose = set()
    bots = set()
    
    current_section = None
    for line in content.split('\n'):
        line = line.strip()
        
        # Skip comments and empty lines
        if not line or line.startswith('#'):
            # Check for section headers in comments
            if '# Goose Maintainers' in line:
                current_section = 'goose_maintainers'
            elif '# Block, non-goose' in line:
                current_section = 'block_non_goose'
            elif '# External, goose' in line:
                current_section = 'external_goose'
            elif '# Bots' in line:
                current_section = 'bots'
            continue
        
        # Add username to appropriate set (lowercase for case-insensitive matching)
        username = line.lower()
        if current_section == 'goose_maintainers':
            goose_maintainers.add(username)
        elif current_section == 'block_non_goose':
            block_non_goose.add(username)
        elif current_section == 'external_goose':
            external_goose.add(username)
        elif current_section == 'bots':
            bots.add(username)
    
    return goose_maintainers, block_non_goose, external_goose, bots

def parse_date_range(date_input):
    """Parse various date input formats and return start/end timestamps."""
    date_input = date_input.strip()
    
    # Format: "Month YYYY" (e.g., "November 2025")
    month_year_pattern = r'^(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})$'
    match = re.match(month_year_pattern, date_input, re.IGNORECASE)
    if match:
        month_name = match.group(1).capitalize()
        year = int(match.group(2))
        start_date = datetime.strptime(f"{month_name} 1 {year}", "%B %d %Y")
        last_day = calendar.monthrange(year, start_date.month)[1]
        end_date = datetime(year, start_date.month, last_day, 23, 59, 59)
        return start_date.timestamp(), end_date.timestamp(), date_input
    
    # Format: "Date1 - Date2" (e.g., "November 1, 2025 - November 17, 2025" or "2025-11-01 - 2025-11-17")
    if ' - ' in date_input or ' to ' in date_input:
        separator = ' - ' if ' - ' in date_input else ' to '
        parts = date_input.split(separator)
        if len(parts) == 2:
            date_formats = ["%B %d, %Y", "%b %d, %Y", "%Y-%m-%d"]
            start_date = None
            end_date = None
            
            for fmt in date_formats:
                try:
                    start_date = datetime.strptime(parts[0].strip(), fmt)
                    end_date = datetime.strptime(parts[1].strip(), fmt)
                    break
                except ValueError:
                    continue
            
            if start_date and end_date:
                end_date = datetime(end_date.year, end_date.month, end_date.day, 23, 59, 59)
                return start_date.timestamp(), end_date.timestamp(), date_input
    
    raise ValueError(f"Could not parse date input: {date_input}\nSupported formats:\n  - 'Month YYYY' (e.g., 'November 2025')\n  - 'Month Day, YYYY - Month Day, YYYY' (e.g., 'November 1, 2025 - November 17, 2025')\n  - 'YYYY-MM-DD - YYYY-MM-DD' (e.g., '2025-11-01 - 2025-11-17')")

def main():
    logging_utils.start_span("community_stars_main")
    
    # Parse command line arguments
    if len(sys.argv) < 2:
        logging_utils.log_error("Usage: python3 community_stars.py 'date_range'")
        logging_utils.log_info("Examples:")
        logging_utils.log_info("  python3 community_stars.py 'November 2025'")
        logging_utils.log_info("  python3 community_stars.py 'November 1, 2025 - November 17, 2025'")
        logging_utils.log_info("  python3 community_stars.py '2025-11-01 - 2025-11-17'")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
        sys.exit(1)

    date_input = sys.argv[1]
    logging_utils.record_metric('date_input', date_input)
    
    try:
        logging_utils.start_span("parse_date_range")
        start_timestamp, end_timestamp, display_period = parse_date_range(date_input)
        start_date = datetime.fromtimestamp(start_timestamp)
        end_date = datetime.fromtimestamp(end_timestamp)
        logging_utils.record_metric('start_date', start_date.isoformat())
        logging_utils.record_metric('end_date', end_date.isoformat())
        logging_utils.end_span()
    except ValueError as e:
        logging_utils.log_error(f"Error: {e}")
        logging_utils.end_span()
        logging_utils.write_metrics(exit_code=1)
        sys.exit(1)

    # Load team lists
    logging_utils.start_span("load_team_lists")
    goose_maintainers, block_non_goose, external_goose, bots = load_team_lists()
    logging_utils.record_metric('goose_maintainers_count', len(goose_maintainers))
    logging_utils.record_metric('block_non_goose_count', len(block_non_goose))
    logging_utils.record_metric('external_goose_count', len(external_goose))
    logging_utils.record_metric('bots_count', len(bots))
    logging_utils.end_span()

    # Load GitHub data
    logging_utils.start_span("load_github_data")
    github_data_file = '/tmp/github_contributors.json'
    contributors_data = None
    
    # Try to load existing file first
    try:
        with open(github_data_file, 'r') as f:
            contributors_data = json.load(f)
            
        # Validate the data is not empty or invalid
        if not contributors_data or not isinstance(contributors_data, list) or len(contributors_data) == 0:
            logging_utils.log_warn("GitHub data file exists but is empty or invalid. Fetching fresh data...")
            contributors_data = None
    except (FileNotFoundError, json.JSONDecodeError):
        logging_utils.log_info("GitHub data file not found or invalid. Fetching fresh data...")
        contributors_data = None
    
    # Fetch from GitHub API if needed
    if contributors_data is None:
        logging_utils.log_info("Fetching contributor data from GitHub API...")
        max_retries = 3
        retry_delay = 2
        
        for attempt in range(max_retries):
            try:
                url = "https://api.github.com/repos/block/goose/stats/contributors"
                with urllib.request.urlopen(url, timeout=30) as response:
                    contributors_data = json.loads(response.read().decode('utf-8'))
                
                # Validate the response
                if contributors_data and isinstance(contributors_data, list) and len(contributors_data) > 0:
                    # Save to file for future use
                    with open(github_data_file, 'w') as f:
                        json.dump(contributors_data, f)
                    logging_utils.log_info(f"✓ Successfully fetched data for {len(contributors_data)} contributors")
                    logging_utils.record_metric('contributors_fetched', len(contributors_data))
                    break
                else:
                    logging_utils.log_warn(f"Attempt {attempt + 1}/{max_retries}: GitHub API returned empty data. Retrying...")
                    contributors_data = None
                    if attempt < max_retries - 1:
                        time.sleep(retry_delay)
            except Exception as e:
                logging_utils.log_warn(f"Attempt {attempt + 1}/{max_retries}: Error fetching from GitHub API: {e}")
                if attempt < max_retries - 1:
                    time.sleep(retry_delay)
                else:
                    logging_utils.log_error("Could not fetch GitHub contributor data after multiple attempts.")
                    logging_utils.log_error("The GitHub stats API may be temporarily unavailable or still computing statistics.")
                    logging_utils.log_error("Please try again in a few minutes.")
                    logging_utils.end_span()
                    logging_utils.end_span()
                    logging_utils.write_metrics(exit_code=1)
                    sys.exit(1)
        
        if contributors_data is None:
            logging_utils.log_error("GitHub API returned empty data after multiple attempts.")
            logging_utils.log_error("The repository statistics may still be computing. Please try again in a few minutes.")
            logging_utils.end_span()
            logging_utils.end_span()
            logging_utils.write_metrics(exit_code=1)
            sys.exit(1)
    
    logging_utils.end_span()

    # Process contributors
    logging_utils.start_span("process_contributors")
    contributor_stats = []
    checked_orgs = {}  # Cache org checks to avoid redundant API calls
    
    logging_utils.log_info("Checking contributor organizations...")

    for contributor in contributors_data:
        # Skip if author is None (deleted users)
        if contributor.get('author') is None:
            continue
            
        username = contributor['author']['login']
        username_lower = username.lower()
        
        # Skip excluded categories (case-insensitive matching)
        if username_lower in bots or username_lower in goose_maintainers or username_lower in external_goose:
            continue
        
        # Calculate stats for the specified period
        period_commits = 0
        period_additions = 0
        period_deletions = 0
        
        for week in contributor['weeks']:
            week_timestamp = week['w']
            if start_timestamp <= week_timestamp <= end_timestamp:
                period_commits += week['c']
                period_additions += week['a']
                period_deletions += week['d']
        
        # Only include contributors with activity in the period
        if period_commits > 0:
            total_lines = period_additions + period_deletions
            
            # Categorize (only Block non-goose and External now)
            if username_lower in block_non_goose:
                category = 'block_non_goose'
            else:
                # Check if user is in a Block org (with caching)
                if username not in checked_orgs:
                    checked_orgs[username] = is_block_employee(username)
                    # Add a small delay to avoid rate limiting
                    time.sleep(0.1)
                
                if checked_orgs[username]:
                    category = 'block_non_goose'
                    logging_utils.log_info(f"  ✓ Detected Block employee: @{username}")
                else:
                    category = 'external'
            
            contributor_stats.append({
                'username': username,
                'category': category,
                'commits': period_commits,
                'additions': period_additions,
                'deletions': period_deletions,
                'total_lines': total_lines,
                'score': period_commits + total_lines
            })

    # Sort by score
    contributor_stats.sort(key=lambda x: x['score'], reverse=True)
    logging_utils.record_metric('total_contributors', len(contributor_stats))

    # Separate by category
    block_list = [c for c in contributor_stats if c['category'] == 'block_non_goose']
    external_list = [c for c in contributor_stats if c['category'] == 'external']
    
    logging_utils.record_metric('block_contributors', len(block_list))
    logging_utils.record_metric('external_contributors', len(external_list))
    logging_utils.end_span()

    # Get top 5 from each
    top_external = external_list[:5]
    top_internal = block_list[:5]

    # Print results
    print("=" * 70)
    print(f"COMMUNITY STARS - {display_period.upper()}")
    print(f"(Period: {start_date.strftime('%B %d, %Y')} - {end_date.strftime('%B %d, %Y')})")
    print("=" * 70)
    print()

    print("🏆 TOP 5 COMMUNITY ALL-STARS (External Contributors)")
    print("-" * 70)
    if top_external:
        for i, contrib in enumerate(top_external, 1):
            print(f"{i}. @{contrib['username']:20s} - {contrib['commits']:3d} commits, {contrib['total_lines']:6,d} lines")
    else:
        print("No external contributors found for this period.")

    print()
    print("⭐ TOP 5 TEAM STARS (Block, non-goose)")
    print("-" * 70)
    if top_internal:
        for i, contrib in enumerate(top_internal, 1):
            print(f"{i}. @{contrib['username']:20s} - {contrib['commits']:3d} commits, {contrib['total_lines']:6,d} lines")
    else:
        print("No internal contributors found for this period.")

    print()
    print("📊 MONTHLY LEADERBOARD (All Contributors)")
    print("-" * 70)
    if contributor_stats:
        for i, contrib in enumerate(contributor_stats, 1):
            cat_label = "External" if contrib['category'] == 'external' else "Block"
            print(f"{i:2d}. @{contrib['username']:20s} - {contrib['commits']:3d} commits, {contrib['total_lines']:6,d} lines [{cat_label}]")
    else:
        print("No contributors found for this period.")

    print()
    print("=" * 70)
    print(f"Total contributors (excluding bots, goose maintainers, external goose): {len(contributor_stats)}")
    print(f"  External: {len(external_list)}")
    print(f"  Block (non-goose): {len(block_list)}")
    print("=" * 70)
    
    logging_utils.end_span()
    logging_utils.write_metrics(exit_code=0)

if __name__ == "__main__":
    main()
