# Publishing catime to cuteheart git

This repo is hosted on the suite's own git server (cutespace):

- **SSH remote**: `git@cuteheart.love:sewerfilth/catime.git` (remote name: `cuteheart`)
- **HTTPS**: `https://cuteheart.love/api/cutespace/git/sewerfilth/catime.git`
  (Basic auth — any username, password = a `ck_` token from the cutespace SPA)

## Pushing updates

```sh
git push cuteheart            # current branch
git push cuteheart --all      # all branches
git push cuteheart --tags     # tags
```

SSH uses the machine key registered in the cutespace SPA (Settings → SSH keys).
Pushes to `master` trigger any `.cutespace/workflows/*.yml` CI.

Full recipe (new repos, tokens, troubleshooting): `~/source/CUTEHEART-GIT.md`.
