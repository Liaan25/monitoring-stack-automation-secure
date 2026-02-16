#!/usr/bin/env python3
"""
Delete lines from file
"""

import sys

def delete_lines(file_path, start_line, end_line):
    """
    Удаляет строки с start_line по end_line (включительно)
    """
    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Оставляем строки до start_line и после end_line
    new_lines = lines[:start_line - 1] + lines[end_line:]
    
    with open(file_path, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
    
    deleted = end_line - start_line + 1
    print(f"Deleted lines {start_line}-{end_line} ({deleted} lines total)", file=sys.stderr)
    return deleted

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python delete_lines.py <file_path> <start_line> <end_line>", file=sys.stderr)
        sys.exit(1)
    
    file_path = sys.argv[1]
    start_line = int(sys.argv[2])
    end_line = int(sys.argv[3])
    
    print(f"Deleting lines {start_line}-{end_line} in {file_path}", file=sys.stderr)
    deleted = delete_lines(file_path, start_line, end_line)
    print(f"Done: {deleted} lines deleted", file=sys.stderr)
