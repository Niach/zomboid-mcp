"""docs/TOOLS.md is generated from the catalogue; it must be committed up to date (`make docs`)."""

import os
import subprocess
import sys
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class TestGeneratedDocs(unittest.TestCase):
    def test_tools_md_is_current(self):
        p = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_tools_md.py"), "--check"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_no_prototype_names_in_the_mod(self):
        """The public mod must not carry the old prototype names."""
        mod = os.path.join(ROOT, "mod")
        hits = []
        for root, _, files in os.walk(mod):
            for fn in files:
                if fn.endswith((".lua", ".py", ".md", ".info")):
                    text = open(os.path.join(root, fn), "r", encoding="utf-8", errors="replace").read()
                    for bad in ("vapps", "HyperSniper", "CoolJesus", "Cool Jesus", "Guardian", "Reborn"):
                        if bad in text:
                            hits.append("%s: %s" % (os.path.relpath(os.path.join(root, fn), ROOT), bad))
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
