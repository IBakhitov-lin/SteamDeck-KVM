# Git hooks

Checks that git runs on its own before a commit and before a push.

- `pre-commit` — architecture tests, and the window layout check when the PC app changed; takes seconds.
- `pre-push` — architecture, tests, the window layout, and a check of the built release in `dist/`.

Enable once after cloning:

```sh
git config core.hooksPath .githooks
git config steamdeck-kvm.python /path/to/python        # optional: a Python with pytest
git config steamdeck-kvm.shared-source /path/to/shared # optional: maintainer's shared tooling
```

Without `steamdeck-kvm.shared-source` the maintainer checks are skipped and the push runs the full test suite.
