"""Compile every shipped Lua file.

The transport harness executes queue.lua, transport.lua and api.lua, but the
bridges, main.lua and util.lua are never loaded outside FXServer — where a
syntax error surfaces as a resource that silently fails to start. Compiling
them here catches that in CI instead.

Requires lupa. Cfx compound assignments (`x += 1`) are expanded first; they are
a CitizenFX extension that stock Lua 5.4 does not parse.
"""
import unittest
from pathlib import Path
from lupa import LuaRuntime

from transport_test import ordinary_lua

ROOT = Path(__file__).resolve().parents[1]
SKIP = {'tests'}


def shipped_lua_files():
    for path in sorted(ROOT.rglob('*.lua')):
        relative = path.relative_to(ROOT)
        if relative.parts[0] in SKIP or relative.parts[0].startswith('.'):
            continue
        yield relative


class SyntaxTests(unittest.TestCase):
    def test_every_lua_file_compiles(self):
        found = list(shipped_lua_files())
        self.assertGreater(len(found), 5, 'no Lua files were discovered')

        lua = LuaRuntime(unpack_returned_tuples=True)
        # Returns the compiler message, or nil when the chunk compiled, so the
        # single return value survives the Lua/Python boundary unambiguously.
        compile_error = lua.eval(
            'function(src, name) local chunk, err = load(src, name)'
            ' if chunk then return nil end return err or "unknown error" end')
        for relative in found:
            with self.subTest(file=str(relative)):
                source = ordinary_lua((ROOT / relative).read_text(encoding='utf-8'))
                self.assertIsNone(compile_error(source, relative.as_posix()))

    def test_manifest_lists_every_shipped_lua_file(self):
        """A file that exists but is not in fxmanifest.lua never runs."""
        manifest = (ROOT / 'fxmanifest.lua').read_text(encoding='utf-8')
        for relative in shipped_lua_files():
            if relative.name == 'fxmanifest.lua':
                continue
            with self.subTest(file=str(relative)):
                self.assertIn(relative.as_posix(), manifest,
                              f'{relative} is not listed in fxmanifest.lua')


if __name__ == '__main__':
    unittest.main()
