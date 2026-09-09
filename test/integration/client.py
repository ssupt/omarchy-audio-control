"""Bounded JSONL client shared by the private backend integration tests."""
import json
import socket
import time


class Client:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(10)
        self.socket.connect(str(path))
        self.reader = self.socket.makefile('rb')
        self.sequence = 0
        self.state = None
        self.parts = []
        self.replies = {}
        self.request('hello')

    def send(self, method, params=None):
        self.sequence += 1
        identity = str(self.sequence)
        self.socket.sendall((json.dumps(dict(version=1, id=identity, method=method, params=params or {})) + '\n').encode())
        return identity

    def receive(self):
        line = self.reader.readline(262145)
        assert line.endswith(b'\n') and len(line) <= 262144 and line.isascii(), line[:100]
        message = json.loads(line)
        assert message['version'] == 1
        if message.get('event') == 'snapshot.begin':
            self.parts = []
        elif message.get('event') == 'snapshot.part':
            assert message['data']['index'] == len(self.parts)
            self.parts.append(message['data']['text'])
        elif message.get('event') == 'snapshot.end':
            state = json.loads(''.join(self.parts))
            if self.state:
                assert int(state['revision']) >= int(self.state['revision'])
            self.state = state
        elif 'id' in message:
            self.replies[message['id']] = message
        return message

    def response(self, identity):
        while identity not in self.replies:
            self.receive()
        return self.replies.pop(identity)

    def request(self, method, params=None):
        result = self.response(self.send(method, params))
        assert 'result' in result, result
        return result['result']

    def wait_state(self, predicate):
        deadline = time.monotonic() + 10
        while self.state is None or not predicate(self.state):
            assert time.monotonic() < deadline
            self.receive()
        return self.state

    def close(self):
        self.reader.close()
        self.socket.close()
