"""Interpreter-independent serialization for the managed release source snapshot."""
import ast
import hashlib
import json

SYMBOLS = ('download_opener', 'fetch', 'stage')


def functions(text, path):
    try:
        nodes = {node.name: node for node in ast.parse(text).body
                 if isinstance(node, ast.FunctionDef)}
    except SyntaxError as error:
        raise ValueError(f'{path}:{error.lineno}: invalid Python: {error.msg}') from error
    for name in SYMBOLS:
        if name not in nodes:
            raise ValueError(f'{path}: required function {name} is missing')
    return nodes


def normalized(value):
    if isinstance(value, ast.AST):
        fields = {}
        for name, field in ast.iter_fields(value):
            if name == 'type_params' and not field:
                continue  # Added in Python 3.12; older versions lack this empty field.
            if name == 'body' and isinstance(value, ast.FunctionDef) and field:
                first = field[0]
                if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                        and isinstance(first.value.value, str):
                    field = field[1:]
            fields[name] = normalized(field)
        return {'node': type(value).__name__, 'fields': fields}
    if isinstance(value, list):
        return [normalized(item) for item in value]
    if isinstance(value, bytes):
        return {'bytesHex': value.hex()}
    return value


def fingerprint(node):
    data = json.dumps(normalized(node), sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(data.encode('ascii')).hexdigest()


def source_hashes(path):
    nodes = functions(path.read_text(), path)
    return {name: fingerprint(nodes[name]) for name in SYMBOLS}
