#!/usr/bin/env python3
"""Best-effort static extraction of an Ansible module's cross-option
constraints (mutually_exclusive/required_together/required_if/required_one_of)
from its AnsibleModule(...) call — these aren't part of DOCUMENTATION, so
ansible-doc never sees them.

Only literal list arguments are picked up (ast.literal_eval); anything
built dynamically (a variable, a comprehension, an appended list) is left
empty rather than guessed at. Reads the module's source path from argv[1],
always prints a JSON object with all four keys, and never raises past
main() — a module that can't be parsed just yields empty constraints.
"""
import ast
import json
import sys

CONSTRAINT_KEYS = ("mutually_exclusive", "required_together", "required_if", "required_one_of")


def literal_or_none(node):
    try:
        return ast.literal_eval(node)
    except Exception:
        return None


def main():
    result = {key: [] for key in CONSTRAINT_KEYS}
    if len(sys.argv) < 2:
        print(json.dumps(result))
        return

    try:
        with open(sys.argv[1], "r") as f:
            tree = ast.parse(f.read(), filename=sys.argv[1])
    except Exception:
        print(json.dumps(result))
        return

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.id if isinstance(func, ast.Name) else getattr(func, "attr", None)
        if name != "AnsibleModule":
            continue
        for kw in node.keywords:
            if kw.arg not in CONSTRAINT_KEYS:
                continue
            value = literal_or_none(kw.value)
            if isinstance(value, list):
                result[kw.arg] = value

    print(json.dumps(result))


if __name__ == "__main__":
    main()
