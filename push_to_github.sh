#!/bin/bash
# First upload of this folder to GitHub: Caballero-git/p25t_debian
# Run it on the PC, from anywhere, as your normal user (no sudo):
#     bash ~/p25t-backup/p25t-linux/push_to_github.sh
#
# What it does:
#   1. makes this folder a git repository (branch main), if it is not one yet
#   2. commits every file (the .gitignore keeps images, kernels, logs out)
#   3. connects it to GitHub, by SSH if your key works, otherwise HTTPS
#   4. if you created the GitHub repo with a README/LICENSE, merges those in
#   5. pushes
# Safe to run again: it only adds a new commit when something changed.
set -euo pipefail

REPO=Caballero-git/p25t_debian
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

command -v git >/dev/null || die "git is not installed:  sudo apt install git"

say "1/5 Local repository in $HERE"
if [ ! -d .git ]; then
    git init -q -b main
    echo "created"
else
    echo "already a repository"
fi

say "2/5 Your name and e-mail for the commits (they become public on GitHub)"
NAME=$(git config user.name || true)
MAIL=$(git config user.email || true)
if [ -z "$NAME" ] || [ -z "$MAIL" ]; then
    echo "Tip: GitHub gives you a private address under Settings > Emails,"
    echo "     of the form  <NUMBER>+Caballero-git@users.noreply.github.com"
    read -r -p "Name  : " NAME
    read -r -p "E-mail: " MAIL
    git config user.name "$NAME"
    git config user.email "$MAIL"
fi
echo "commits as: $(git config user.name) <$(git config user.email)>"

say "3/5 Commit"
git add -A
if git diff --cached --quiet; then
    echo "nothing new to commit"
else
    if git rev-parse -q --verify HEAD >/dev/null; then
        git commit -q -m "Update P25T documentation and scripts"
    else
        git commit -q -m "Teclast P25T: mainline Linux 7.3 + Debian 13 from the microSD card" \
            -m "Docs (org-mode), U-Boot config and FIT, kernel patches and config, initramfs, Debian builder and installers, Wi-Fi/Bluetooth install scripts, analysis tools."
    fi
    git log --oneline -1
fi
echo "files in the repository: $(git ls-files | wc -l)"

say "4/5 Connect to GitHub"
if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    URL=git@github.com:$REPO.git
    echo "your SSH key works: using SSH"
else
    URL=https://github.com/$REPO.git
    echo "no working SSH key: using HTTPS."
    echo "When asked: Username = Caballero-git, Password = a personal access token"
    echo "(GitHub > Settings > Developer settings > Personal access tokens), NOT your password."
    git config credential.helper "cache --timeout=900"   # asked once, kept 15 min in memory only
fi
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$URL"
else
    git remote add origin "$URL"
fi
echo "origin = $URL"

git fetch -q origin || die "cannot reach $URL (repository name, access or token?)"
if git rev-parse -q --verify origin/main >/dev/null; then
    if ! git merge-base --is-ancestor origin/main HEAD; then
        echo "GitHub already has files (README/LICENSE?): merging them in"
        git merge -q --no-edit --allow-unrelated-histories origin/main \
            || die "merge conflict (probably README). Tell Claude the output of:  git status"
    fi
fi

say "5/5 Push"
git push -u origin main
echo
echo "DONE - open https://github.com/$REPO"
