#!/usr/bin/env python3
import sys, json, base64
COUNTER = 0
PNG = base64.b64encode(bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000000020001e221bc330000000049454e44ae426082')).decode()
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: msg=json.loads(line)
    except Exception: continue
    mid=msg.get('id'); method=msg.get('method')
    if method=='initialize':
        resp={'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':'2025-06-18','capabilities':{'tools':{},'resources':{'subscribe':False,'listChanged':False}},'serverInfo':{'name':'mock','version':'1'}}}
    elif method=='notifications/initialized':
        continue
    elif method=='tools/list':
        resp={'jsonrpc':'2.0','id':mid,'result':{'tools':[
            {'name':'echo','description':'Echo text back.','inputSchema':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}},
            {'name':'shout','description':'Uppercase text.','inputSchema':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}},
            {'name':'picture','description':'Return a tiny PNG.','inputSchema':{'type':'object','properties':{}}},
            {'name':'fail','description':'Always report an error.','inputSchema':{'type':'object','properties':{}}},
            {'name':'envcheck','description':'Check inherited environment.','inputSchema':{'type':'object','properties':{}}},
            {'name':'counter','description':'Increment state held by the server process.','inputSchema':{'type':'object','properties':{}}}
        ]}}
    elif method=='resources/list':
        resp={'jsonrpc':'2.0','id':mid,'result':{'resources':[
            {'uri':'file:///notes/hello.txt','name':'hello.txt','title':'Hello note','mimeType':'text/plain','size':21,'description':'A small text resource.'},
            {'uri':'image://tiny','name':'tiny.png','title':'Tiny PNG','mimeType':'image/png','size':67},
            {'uri':'data://json','name':'data.json','title':'JSON data','mimeType':'application/json'}
        ]}}
    elif method=='resources/templates/list':
        resp={'jsonrpc':'2.0','id':mid,'result':{'resourceTemplates':[
            {'uriTemplate':'note://{id}','name':'note','title':'Note by id','mimeType':'text/plain','description':'Read a note by numeric id.'}
        ]}}
    elif method=='resources/read':
        uri=(msg.get('params') or {}).get('uri','')
        if uri=='file:///notes/hello.txt':
            resp={'jsonrpc':'2.0','id':mid,'result':{'contents':[{'uri':uri,'mimeType':'text/plain','text':'hello from resource'}]}}
        elif uri=='image://tiny':
            resp={'jsonrpc':'2.0','id':mid,'result':{'contents':[{'uri':uri,'mimeType':'image/png','blob':PNG}]}}
        elif uri=='data://json':
            import base64 as b64
            blob=b64.b64encode(b'{"answer": 42}').decode()
            resp={'jsonrpc':'2.0','id':mid,'result':{'contents':[{'uri':uri,'mimeType':'application/json','blob':blob}]}}
        elif uri.startswith('note://'):
            resp={'jsonrpc':'2.0','id':mid,'result':{'contents':[{'uri':uri,'mimeType':'text/plain','text':'note body for '+uri}]}}
        else:
            resp={'jsonrpc':'2.0','id':mid,'error':{'code':-32602,'message':'unknown resource'}}
    elif method=='tools/call':
        p=msg.get('params',{}); name=p.get('name'); args=p.get('arguments') or {}
        if name=='echo':
            resp={'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':'echo: '+str(args.get('text',''))}]}}
        elif name=='shout':
            resp={'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':str(args.get('text','')).upper()}]}}
        elif name=='picture':
            resp={'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':'here is a picture'},{'type':'image','data':PNG,'mimeType':'image/png'}]}}
        elif name=='fail':
            resp={'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':'it failed'}],'isError':True}}
        elif name=='envcheck':
            import os
            resp={'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':'secret=%s override=%s' % (os.environ.get('MOCK_SECRET'), os.environ.get('CONFIG_OVERRIDE'))}]}}
        elif name=='counter':
            COUNTER += 1
            resp={'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':'counter=%d' % COUNTER}]}}
        else:
            resp={'jsonrpc':'2.0','id':mid,'error':{'code':-32602,'message':'unknown tool'}}
    elif method=='ping':
        resp={'jsonrpc':'2.0','id':mid,'result':{}}
    else:
        resp={'jsonrpc':'2.0','id':mid,'error':{'code':-32601,'message':'method not found'}}
    sys.stdout.write(json.dumps(resp)+'\n'); sys.stdout.flush()
