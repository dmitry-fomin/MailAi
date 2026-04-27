import json

issues = {}
with open('.beads/issues.jsonl', 'r') as f:
    for line in f:
        data = json.loads(line)
        if data.get('_type') == 'issue':
            issues[data['id']] = data

errors = []

# 1. Check counts and missing issues
for issue_id, issue in issues.items():
    deps = issue.get('dependencies', [])
    if len(deps) != issue.get('dependency_count', 0):
        errors.append(f"{issue_id}: dependency_count ({issue.get('dependency_count')}) does not match len(dependencies) ({len(deps)})")
    
    for dep in deps:
        target_id = dep.get('depends_on_id')
        if target_id not in issues:
            errors.append(f"{issue_id}: depends on missing issue {target_id}")

# 2. Check dependent counts
dependent_counts = {i: 0 for i in issues}
for issue_id, issue in issues.items():
    for dep in issue.get('dependencies', []):
        target_id = dep.get('depends_on_id')
        if target_id in dependent_counts:
            dependent_counts[target_id] += 1

for issue_id, issue in issues.items():
    expected = issue.get('dependent_count', 0)
    actual = dependent_counts.get(issue_id, 0)
    if expected != actual:
        errors.append(f"{issue_id}: dependent_count is {expected}, but calculated is {actual}")

# 3. Closed depending on Open
for issue_id, issue in issues.items():
    if issue.get('status') == 'closed':
        for dep in issue.get('dependencies', []):
            target_id = dep.get('depends_on_id')
            if target_id in issues and issues[target_id].get('status') == 'open':
                errors.append(f"{issue_id} (closed) depends on {target_id} ({issues[target_id].get('status')})")

# 4. Cycles
def find_cycles():
    visited = set()
    path = []
    
    def dfs(node):
        if node in path:
            cycle_idx = path.index(node)
            errors.append(f"Cycle detected: {' -> '.join(path[cycle_idx:])} -> {node}")
            return
        if node in visited:
            return
            
        visited.add(node)
        path.append(node)
        
        if node in issues:
            for dep in issues[node].get('dependencies', []):
                dfs(dep.get('depends_on_id'))
                
        path.pop()

    for issue_id in issues:
        dfs(issue_id)

find_cycles()

for err in errors:
    print(err)

if not errors:
    print("No inconsistencies found!")
