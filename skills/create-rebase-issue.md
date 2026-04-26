# Skill: Create Upstream Alignment Issue

You are working inside a che-code repository at /projects/che-code.

## Goal

Check whether the current che-code branch needs alignment with a newer upstream VS Code version, and create a GitHub issue if so.

## Steps

1. **Read the current upstream version** from `rebase.sh`:
   - Find the `UPSTREAM_VERSION` variable (e.g. `release/1.116`)
   - This is the version che-code is currently aligned with

2. **Check the latest VS Code release branches** using the GitHub API:
   ```bash
   gh api repos/microsoft/vscode/branches --paginate -q '.[].name' | grep '^release/' | sort -V | tail -5
   ```

3. **Compare versions**:
   - If the latest upstream release branch is newer than `UPSTREAM_VERSION`, an alignment issue is needed
   - If already aligned with the latest, report "already up to date" and exit

4. **Create a GitHub issue** if alignment is needed:
   ```bash
   gh issue create \
     --repo TARGET_REPO \
     --title "Alignment Che-Code with <NEW_VERSION> version of VS Code" \
     --body "$(cat <<'ISSUE_EOF'
   ## Summary

   A new upstream VS Code release branch `release/<NEW_VERSION>` is available.
   Current che-code is aligned with `release/<CURRENT_VERSION>`.

   ## Action items

   - [ ] Run `pre-rebase.sh` to validate and fix rebase rules
   - [ ] Run `rebase.sh` to pull upstream changes
   - [ ] Fix any merge conflicts
   - [ ] Run `./build/artifacts/generate.sh` to update artifacts.lock.yaml
   - [ ] Verify build passes
   - [ ] Create PR with the alignment changes

   ## References

   - Upstream branch: https://github.com/microsoft/vscode/tree/release/<NEW_VERSION>
   - VS Code changelog: https://code.visualstudio.com/updates
   ISSUE_EOF
   )"
   ```

5. **Check for duplicate issues** before creating:
   ```bash
   gh issue list --repo TARGET_REPO --search "Alignment Che-Code with <NEW_VERSION>" --state open
   ```
   If an open issue already exists for this version, skip creation and report it.

## Environment

- `GITHUB_TOKEN` is set in the environment for `gh` authentication
- `TARGET_REPO` placeholder should be replaced with the actual repo (e.g. `RomanNikitenko/che-code`)

## Output

Print a clear summary of what was done:
- Current aligned version
- Latest upstream version
- Whether an issue was created (with URL) or skipped (with reason)
