import json,glob,sys
d=sys.argv[1]
for f in sorted(glob.glob(d+'/*-audit.json')):
    a=json.load(open(f)); i=a['id']; u={}
    try:
        for line in open(f'{d}/{i}-res.txt',errors='ignore'):
            if line.startswith('data: '):
                x=json.loads(line[6:])
                if x.get('type')=='message_start': u.update(x['message']['usage'])
                if x.get('type')=='error': u['ERROR']=x
    except Exception: pass
    if a.get('status')!=200: u['body']=open(f'{d}/{i}-res.txt',errors='ignore').read()[:400]
    print(i,a.get('reqHeaders',{}).get('x-claude-code-request-class'),a.get('status'),'think=',a.get('thinkingBlocks'),'read=',u.get('cache_read_input_tokens'),'write=',u.get('cache_creation_input_tokens'),'rw=',[r['kind'] for r in a['rewrites']], u.get('ERROR') or u.get('body') or '')
