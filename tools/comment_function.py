#!/usr/bin/env python3
"""
Utility to comment out the setup_vault_config() function in install-monitoring-stack.sh
"""

import sys

def comment_function(input_file, output_file, start_line, end_line):
    """
    Comment out lines from start_line to end_line in input_file
    """
    with open(input_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Comment out lines from start_line to end_line (1-indexed)
    for i in range(start_line - 1, min(end_line, len(lines))):
        line = lines[i]
        # Add comment prefix while preserving indentation
        # (comment all lines, even if they're already comments or empty)
        lines[i] = '#' + line
    
    # Write result
    with open(output_file, 'w', encoding='utf-8') as f:
        f.writelines(lines)
    
    print(f"[OK] Commented out lines {start_line}-{end_line} in {output_file}")

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python comment_function.py <input_file> <output_file> <start_line> <end_line>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    start_line = int(sys.argv[3])
    end_line = int(sys.argv[4])
    
    comment_function(input_file, output_file, start_line, end_line)
