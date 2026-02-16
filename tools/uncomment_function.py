#!/usr/bin/env python3
"""
Uncomment function in bash script
"""

import sys

def uncomment_lines(file_path, start_line, end_line):
    """
    Раскомментирует строки с start_line по end_line (включительно)
    Удаляет '# ' или '#' после отступов
    """
    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    modified = 0
    for i in range(start_line - 1, min(end_line, len(lines))):
        original = lines[i]
        # Ищем '# ' или '#' после отступов
        stripped = lines[i].lstrip()
        if stripped.startswith('#'):
            # Сохраняем отступы
            indent = lines[i][:len(lines[i]) - len(stripped)]
            if stripped.startswith('# '):
                lines[i] = indent + stripped[2:]  # Remove '# '
            else:
                lines[i] = indent + stripped[1:]  # Remove '#'
            modified += 1
            print(f"Line {i+1}: uncommented", file=sys.stderr)
    
    with open(file_path, 'w', encoding='utf-8') as f:
        f.writelines(lines)
    
    print(f"Total lines uncommented: {modified}", file=sys.stderr)
    return modified

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python uncomment_function.py <file_path> <start_line> <end_line>", file=sys.stderr)
        sys.exit(1)
    
    file_path = sys.argv[1]
    start_line = int(sys.argv[2])
    end_line = int(sys.argv[3])
    
    print(f"Uncommenting lines {start_line}-{end_line} in {file_path}", file=sys.stderr)
    modified = uncomment_lines(file_path, start_line, end_line)
    print(f"Done: {modified} lines modified", file=sys.stderr)
