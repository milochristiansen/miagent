#!/usr/bin/env python3
"""Minimal streamable-HTTP MCP server used by tests/mcp_test.sh."""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE = sys.argv[1] if len(sys.argv) > 1 else None

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def _send(self, obj, status=200):
        data = json.dumps(obj).encode() if obj is not None else b''
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Mcp-Session-Id', 'test-session')
        self.end_headers()
        if data:
            self.wfile.write(data)
    def do_POST(self):
        if self.headers.get('Authorization') != 'Bearer supersecret':
            return self._send({'jsonrpc':'2.0','id':None,'error':{'code':-32000,'message':'unauthorized'}}, 401)
        n = int(self.headers.get('Content-Length', '0'))
        msg = json.loads(self.rfile.read(n))
        mid, method = msg.get('id'), msg.get('method')
        if method == 'initialize':
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':'2025-06-18','capabilities':{'tools':{},'resources':{}},'serverInfo':{'name':'httpmock','version':'1'}}})
        if method and method.startswith('notifications/'):
            return self._send(None, 202)
        if method == 'tools/list':
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'tools':[{'name':'remote_echo','description':'Echo over HTTP.','inputSchema':{'type':'object','properties':{'text':{'type':'string'}}}}]}})
        if method == 'resources/list':
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'resources':[{'uri':'https://example.test/remote.txt','name':'remote.txt','mimeType':'text/plain','description':'Remote text resource.'}]}})
        if method == 'resources/templates/list':
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'resourceTemplates':[]}})
        if method == 'resources/read':
            uri=(msg.get('params') or {}).get('uri','')
            if uri == 'https://example.test/remote.txt':
                return self._send({'jsonrpc':'2.0','id':mid,'result':{'contents':[{'uri':uri,'mimeType':'text/plain','text':'remote resource body'}]}})
            return self._send({'jsonrpc':'2.0','id':mid,'error':{'code':-32602,'message':'unknown resource'}})
        if method == 'tools/call':
            args = (msg.get('params') or {}).get('arguments') or {}
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':'http: ' + str(args.get('text', ''))}]}})
        return self._send({'jsonrpc':'2.0','id':mid,'error':{'code':-32601,'message':'method not found'}})
    def do_DELETE(self):
        self._send(None, 200)

server = ThreadingHTTPServer(('127.0.0.1', 0), H)
if PORT_FILE:
    with open(PORT_FILE, 'w') as f:
        f.write(str(server.server_address[1]))
server.serve_forever()
