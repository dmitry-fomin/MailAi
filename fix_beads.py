import json

lines = []
with open('.beads/issues.jsonl', 'r') as f:
    for line in f:
        try:
            data = json.loads(line)
        except:
            lines.append(line)
            continue
            
        if data.get('_type') == 'issue':
            if data['id'] == 'MailAi-0dk':
                data['dependency_count'] = 2
            elif data['id'] == 'MailAi-tzx':
                data['dependent_count'] = 2
            lines.append(json.dumps(data, separators=(',', ':')) + '\n')
        else:
            lines.append(line)

with open('.beads/issues.jsonl', 'w') as f:
    for line in lines:
        f.write(line)

