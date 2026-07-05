# Git Cheatsheet (macOS)

A practical, top-to-bottom reference: install Git, configure, connect to GitHub, work with files/directories, repo management, git push, PRs, etc.

---

## 1. Install Git

```bash
# Check if Git is already installed 
git --version

# If missing, macOS will prompt to install Xcode Command Line Tools:
xcode-select --install

# OR install the latest Git via Homebrew (recommended)
# Install Homebrew first if needed: https://brew.sh
brew install git

# Verify the Homebrew version is picked up (may need a new terminal)
which git
git --version
```

---

## 2. One-Time Setup / Configuration

```bash
# Set your name and email (used on every commit)
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# Set default branch name for new repos to "main"
git config --global init.defaultBranch main

# Set your default editor (examples)
git config --global core.editor "code --wait"   # VS Code
git config --global core.editor "nano"           # nano

# Nicer colored output
git config --global color.ui auto

# Cache credentials on macOS Keychain (for HTTPS remotes)
git config --global credential.helper osxkeychain

# View all your settings
git config --list

# View a single setting
git config user.email
```

---

## 3. Connect to GitHub

### Option A: HTTPS + Personal Access Token (simplest)
```bash
# When you push, GitHub asks for username + password.
# Use a Personal Access Token (PAT) as the password.
# Create one at: GitHub > Settings > Developer settings > Personal access tokens
# The osxkeychain helper (above) saves it so you enter it only once.
```

### Option B: SSH Keys (no password prompts)
```bash
# Generate a new SSH key
ssh-keygen -t ed25519 -C "you@example.com"
# Press Enter to accept defaults; add a passphrase if you like

# Start the ssh-agent and add your key to the macOS Keychain
eval "$(ssh-agent -s)"
ssh-add --apple-use-keychain ~/.ssh/id_ed25519

# Copy the public key to your clipboard
pbcopy < ~/.ssh/id_ed25519.pub
# Then paste it into: GitHub > Settings > SSH and GPG keys > New SSH key

# Test the connection
ssh -T git@github.com
```

### Option C: GitHub CLI (easiest auth)
```bash
brew install gh          # install GitHub CLI
gh auth login            # interactive browser/token login
```

---

## 4. Initialize or Clone a Repository

```bash
# Turn the current folder into a new Git repo
cd ~/Documents/Scripts
git init

# Clone an existing GitHub repo (HTTPS)
git clone https://github.com/user/repo.git

# Clone via SSH
git clone git@github.com:user/repo.git

# Clone into a specific folder name
git clone https://github.com/user/repo.git my-folder
```

---

## 5. Connect a Local Repo to a GitHub Remote

```bash
# Add a remote named "origin"
git remote add origin git@github.com:user/repo.git

# View configured remotes
git remote -v

# Change an existing remote's URL
git remote set-url origin git@github.com:user/new-repo.git

# Remove a remote
git remote remove origin
```

---

## 6. Creating & Editing Files and Directories (macOS shell)

```bash
# Create an empty file
touch script.sh

# Create a file with content
echo "#!/bin/bash" > script.sh        # overwrite/create
echo "echo hello" >> script.sh        # append

# Open a file in an editor
nano script.sh
code script.sh                        # VS Code

# Create a directory
mkdir mydir
mkdir -p parent/child/grandchild      # create nested dirs

# Make a script executable
chmod +x script.sh
```

---

## 7. Navigating & Moving Files/Directories (macOS shell)

```bash
pwd                       # print current directory
ls                        # list files
ls -la                    # list all (incl. hidden) with details
cd foldername             # enter a directory
cd ..                     # go up one level
cd ~                      # go to home directory
cd -                      # go to previous directory

cp file.txt backup.txt    # copy a file
cp -R dir1 dir2           # copy a directory recursively
mv old.txt new.txt        # rename a file
mv file.txt ~/Documents/  # move a file
rm file.txt               # delete a file
rm -r dir/                # delete a directory (careful!)
```

> **Tip:** Use `git mv` and `git rm` (below) instead of plain `mv`/`rm` inside a repo so Git tracks the change automatically.

---

## 8. Checking Status & Changes

```bash
git status                # what's changed / staged / untracked
git diff                  # unstaged changes
git diff --staged         # staged changes (about to be committed)
git log                   # commit history
git log --oneline --graph --all   # compact visual history
git show <commit>         # details of a specific commit
```

---

## 9. Staging & Committing (Updating the Repo)

```bash
git add file.txt          # stage a specific file
git add .                 # stage everything in current dir/subdirs
git add -A                # stage all changes (incl. deletions)

git restore --staged file.txt   # unstage a file (keep changes)
git restore file.txt            # discard unstaged changes to a file

# Commit staged changes with a message
git commit -m "Add setup script"

# Stage tracked changes AND commit in one step
git commit -am "Fix typo in script"

# Amend the most recent commit (edit message or add files)
git commit --amend -m "New message"

# Git-aware move and delete (auto-staged)
git mv old.sh new.sh
git rm oldfile.sh
```

---

## 10. Branching

```bash
git branch                    # list local branches
git branch newfeature         # create a branch
git checkout newfeature       # switch to a branch
git checkout -b newfeature    # create AND switch
git switch newfeature         # modern way to switch
git switch -c newfeature      # modern create + switch

git branch -d newfeature      # delete a merged branch
git branch -D newfeature      # force-delete a branch

git merge newfeature          # merge a branch into current branch
```

---

## 11. Pushing & Pulling (Syncing with GitHub)

```bash
# First push of a new branch (sets upstream tracking)
git push -u origin main

# Subsequent pushes
git push

# Push a specific branch
git push origin newfeature

# Get latest changes from remote and merge into current branch
git pull

# Fetch remote changes WITHOUT merging
git fetch origin

# See remote branches
git branch -r
```

---

## 12. Creating Pull Requests (GitHub CLI)

```bash
# Install GitHub CLI if needed
brew install gh
gh auth login

# Create a PR from your current branch (interactive)
gh pr create

# Create a PR with title and body inline
gh pr create --title "Add setup script" --body "Implements the installer"

# Target a specific base branch
gh pr create --base main --head newfeature

# Open the PR in your browser
gh pr view --web

# List open PRs / check status / merge
gh pr list
gh pr status
gh pr merge
```

> **Without the CLI:** push your branch, then open the repo on github.com — GitHub shows a "Compare & pull request" button for recently pushed branches.

---

## 13. Undoing Things

```bash
git restore file.txt              # discard local changes to a file
git restore --staged file.txt     # unstage but keep changes
git reset --soft HEAD~1           # undo last commit, keep changes staged
git reset --mixed HEAD~1          # undo last commit, keep changes unstaged
git reset --hard HEAD~1           # undo last commit AND discard changes (danger!)
git revert <commit>               # make a new commit that undoes a commit (safe)
git checkout -- .                 # discard all unstaged changes (older syntax)
```

---

## 14. Stashing (Set Work Aside Temporarily)

```bash
git stash                 # save uncommitted changes and clean working dir
git stash list            # view stashes
git stash pop             # reapply most recent stash and remove it
git stash apply           # reapply but keep the stash
git stash drop            # delete most recent stash
```

---

## 15. .gitignore (Skip Files You Don't Want Tracked)

```bash
# Create/edit a .gitignore in the repo root
touch .gitignore
```

Example `.gitignore` contents:
```
.DS_Store
*.log
node_modules/
.env
build/
```

```bash
# If a file is already tracked, stop tracking it (but keep it locally)
git rm --cached .DS_Store
```

---

## 16. Typical Everyday Workflow

```bash
git pull                          # 1. get latest
git switch -c fix-something       # 2. new branch for your work
# ...edit files...
git add -A                        # 3. stage changes
git commit -m "Fix something"     # 4. commit
git push -u origin fix-something  # 5. push branch
gh pr create                      # 6. open a pull request
# ...after review/approval...
gh pr merge                       # 7. merge it
git switch main && git pull       # 8. return to main, sync
```

---

## 17. Tags & Releases

Tags mark specific points in history — most often version releases (e.g. `v1.0.0`).

```bash
# List tags
git tag

# Create a lightweight tag on the current commit
git tag v1.0.0

# Create an annotated tag (recommended — stores author, date, message)
git tag -a v1.0.0 -m "First stable release"

# Tag a specific past commit
git tag -a v0.9.0 <commit> -m "Beta release"

# Show details of a tag
git show v1.0.0

# Push a single tag to GitHub
git push origin v1.0.0

# Push ALL tags at once
git push origin --tags

# Delete a tag locally
git tag -d v1.0.0

# Delete a tag on the remote
git push origin --delete v1.0.0
```

### Creating a GitHub Release (with the CLI)
```bash
# Create a release from a tag (opens editor for notes)
gh release create v1.0.0

# Create with title and notes inline
gh release create v1.0.0 --title "v1.0.0" --notes "Initial release"

# Auto-generate release notes from merged PRs/commits
gh release create v1.0.0 --generate-notes

# Attach files (binaries, zips) to the release
gh release create v1.0.0 ./build/app.zip ./script.sh

# List / view releases
gh release list
gh release view v1.0.0
```

---

## 18. Viewing History & Finding Things

```bash
# Compact one-line-per-commit log
git log --oneline

# Show which files changed in each commit
git log --stat

# See who last changed each line of a file (great for "why is this here?")
git blame script.sh

# Search commit messages for a keyword
git log --grep="bugfix"

# Find commits that added/removed a specific piece of code
git log -S "functionName"

# See commits by a specific author within a date range
git log --author="Stephen" --since="2 weeks ago"

# Show what changed in a single commit
git show <commit>

# See a file as it existed in a past commit
git show <commit>:path/to/file.sh
```

---

## 19. Comparing & Inspecting

```bash
git diff main..newfeature       # differences between two branches
git diff <commit1> <commit2>    # differences between two commits
git diff HEAD~3 HEAD            # changes over the last 3 commits
git diff --name-only            # just list changed file names

# See the history of every action you've taken (lifesaver for recovery)
git reflog
```

> **`git reflog` is your safety net.** Even after a bad `reset` or deleted branch, reflog shows recent HEAD positions so you can `git checkout` or `git reset` back to them.

---

## 20. Keeping a Branch Up to Date (Rebase)

```bash
# Replay your branch's commits on top of the latest main (cleaner history)
git switch newfeature
git fetch origin
git rebase origin/main

# If conflicts occur: fix files, then
git add <fixed-files>
git rebase --continue

# Abort and go back to how things were
git rebase --abort
```

> **Rule of thumb:** rebase your *own* local branches to keep history tidy, but avoid rebasing branches others are already using. Use `merge` for shared branches.

---

## 21. Cherry-pick (Grab One Commit)

```bash
# Apply a single commit from another branch onto your current branch
git cherry-pick <commit>

# Cherry-pick a range of commits
git cherry-pick <commit1>^..<commit2>
```

---

## 22. Cleaning Up

```bash
# Preview untracked files that would be removed (dry run — always do this first)
git clean -n

# Remove untracked files
git clean -f

# Remove untracked files AND directories
git clean -fd

# Delete local branches that were already merged into main
git branch --merged main | grep -v main | xargs git branch -d

# Prune remote-tracking branches that no longer exist on GitHub
git fetch --prune
```

---

## 23. Aliases (Shortcuts for Common Commands)

```bash
# Set up handy shortcuts once, use them forever
git config --global alias.st status
git config --global alias.co checkout
git config --global alias.br branch
git config --global alias.cm "commit -m"
git config --global alias.last "log -1 HEAD"
git config --global alias.lg "log --oneline --graph --all --decorate"

# Now you can run:
git st          # = git status
git lg          # = pretty graph log
```

---

## 24. Recovering from Common Mistakes

```bash
# "I committed to the wrong branch"
git reset --soft HEAD~1        # undo commit, keep changes staged
git stash                      # stash them
git switch correct-branch
git stash pop                  # bring changes over, then commit

# "I need to change a commit message I just made"
git commit --amend -m "Corrected message"

# "I accidentally deleted a branch"
git reflog                     # find the commit hash
git switch -c recovered-branch <commit>

# "I want to throw away ALL local changes and match GitHub"
git fetch origin
git reset --hard origin/main   # DESTRUCTIVE — discards local work

# "I committed a secret / large file by mistake"
# Remove it from the last commit before pushing:
git rm --cached secret.env
git commit --amend
```

---

## 25. Resolving Merge Conflicts (Step by Step)

Conflicts happen when two branches change the same lines. Git pauses and asks you to decide. Don't panic — here's the routine.

```bash
# 1. A merge or pull stops with a conflict message
git merge newfeature
# CONFLICT (content): Merge conflict in script.sh

# 2. See which files are conflicted
git status
# "Unmerged paths" lists the files needing attention
```

**3. Open each conflicted file.** Git inserts markers showing both versions:

```
<<<<<<< HEAD
echo "current branch's version"
=======
echo "incoming branch's version"
>>>>>>> newfeature
```

- Everything between `<<<<<<< HEAD` and `=======` is **your current branch**.
- Everything between `=======` and `>>>>>>> newfeature` is the **incoming branch**.
- Edit the file to the final result you want, then **delete all three marker lines** (`<<<<<<<`, `=======`, `>>>>>>>`).

```bash
# 4. Mark each file as resolved by staging it
git add script.sh

# 5. Complete the merge (opens an editor for the merge message)
git commit
#   ...or if you were rebasing:
git rebase --continue
```

### Helpful conflict commands
```bash
git merge --abort        # bail out and undo the whole merge
git rebase --abort       # bail out of a rebase
git diff                 # review conflicts and your resolution
git checkout --ours script.sh     # keep YOUR version entirely
git checkout --theirs script.sh   # keep the INCOMING version entirely
git mergetool            # open a visual merge tool (if configured)
```

> **Tip:** After resolving, run your script/tests before committing — a clean merge that doesn't actually work is still broken. And commit conflict resolutions on their own, without mixing in other changes, so they're easy to review.

---

## Quick Reference

| Task | Command |
|------|---------|
| Check version | `git --version` |
| Set identity | `git config --global user.name/user.email` |
| New repo | `git init` |
| Copy a repo | `git clone <url>` |
| Add remote | `git remote add origin <url>` |
| See changes | `git status` / `git diff` |
| Stage | `git add .` |
| Commit | `git commit -m "msg"` |
| New branch | `git switch -c name` |
| Push | `git push -u origin name` |
| Pull | `git pull` |
| Open PR | `gh pr create` |
| Undo commit (safe) | `git revert <commit>` |
| Tag a release | `git tag -a v1.0.0 -m "msg"` |
| Push tags | `git push origin --tags` |
| Who changed a line | `git blame <file>` |
| Recover lost work | `git reflog` |
| Update branch on main | `git rebase origin/main` |
| Stash work | `git stash` / `git stash pop` |
