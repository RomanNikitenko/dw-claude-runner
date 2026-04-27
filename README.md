# DW Claude Runner

Automated tool that creates a DevWorkspace on an OpenShift cluster, installs [Claude Code](https://docs.anthropic.com/en/docs/claude-code), and lets Claude resolve GitHub issues inside the workspace.

## How It Works

1. Creates a DevWorkspace that clones the target project on your OpenShift cluster
2. Waits for the workspace to reach `Running` state and validates it
3. Installs Claude Code CLI inside the workspace container
4. Passes a GitHub issue URL to Claude Code
5. Claude reads the project's own configuration (`CLAUDE.md`, `.claude/` files) and decides how to resolve the issue
6. Reports results and cleans up the workspace

## Prerequisites

- `oc` — OpenShift CLI, logged into a cluster with DevWorkspaces support
- `jq` — JSON processor

## Quick Start

```bash
# Resolve a GitHub issue
ISSUE_REF=https://github.com/owner/repo/issues/123 ./run.sh

# With verbose / debug logging
ISSUE_REF=https://github.com/owner/repo/issues/123 ./run.sh -v
ISSUE_REF=https://github.com/owner/repo/issues/123 ./run.sh -d
```

## Command-Line Options

| Flag | Description |
|------|-------------|
| `-v` | Verbose — progress messages and final Claude answer |
| `-d` | Debug — verbose + stream Claude actions in real-time |
| `-h` | Show help |

## Configuration

Edit `settings/settings.env` to customize defaults, or override via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ISSUE_REF` | *(required)* | GitHub issue URL to resolve |
| `TIMEOUT` | `300` | Seconds to wait for workspace to start |
| `DEVWORKSPACE_NAME` | `claude-runner` | DevWorkspace instance name |
| `CONTAINER_IMAGE` | `registry.access.redhat.com/ubi9/nodejs-22:9.7` | Container image |
| `PROJECT_URL` | `https://github.com/RomanNikitenko/web-nodejs-sample.git` | Project to clone |
| `EDITOR_DEFINITION` | che-code-insiders | Editor definition URL |
| `CLAUDE_VERSION` | `2.1.92` | Claude Code version to install |
| `TARGET_REPO` | `RomanNikitenko/web-nodejs-sample` | GitHub repo (owner/name) |

## Project Configuration

Claude Code behavior is controlled by the **target project** itself, not by the runner. Add configuration files to your project repo:

- **`CLAUDE.md`** — Project-level instructions for Claude (coding conventions, workflow rules, etc.)
- **`.claude/settings.json`** — Claude Code settings (permissions, allowed tools, etc.)

See the [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) for details on project configuration.

## GitHub Actions Usage

Trigger on issue comments (e.g. `/rebase` command):

```yaml
on:
  issue_comment:
    types: [created]

jobs:
  resolve-issue:
    if: contains(github.event.comment.body, '/rebase')
    runs-on: ubuntu-22.04

    steps:
      - uses: actions/checkout@v4
        with:
          repository: owner/dw-claude-runner
          path: dw-claude-runner

      - name: Install oc CLI
        uses: redhat-actions/openshift-tools-installer@v1
        with:
          oc: latest

      - name: Login to OpenShift
        run: oc login --token=${{ secrets.OC_TOKEN }} --server=${{ secrets.OC_SERVER }}

      - name: Run dw-claude-runner
        working-directory: dw-claude-runner
        env:
          ISSUE_REF: "https://github.com/${{ github.repository }}/issues/${{ github.event.issue.number }}"
          PROJECT_URL: '"https://github.com/${{ github.repository }}.git"'
          TARGET_REPO: ${{ github.repository }}
        run: ./run.sh -v
```

## File Structure

```
settings/
  settings.env                  # Configuration and validation function

skills/
  create-rebase-issue.md        # Example skill (reference only)
  test-pr.md                    # Example skill (reference only)

devworkspace-template.yaml      # DevWorkspace template with placeholders
run.sh                          # Main orchestrator script
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  run.sh                                                 │
│                                                         │
│  1. oc apply devworkspace  ──►  OpenShift Cluster       │
│  2. wait for Running       ◄──  DevWorkspace ready      │
│  3. oc exec: install claude                             │
│  4. oc exec: claude -p <issue>  ──►  GitHub API         │
│  5. oc delete devworkspace                              │
└─────────────────────────────────────────────────────────┘
```

## Secrets Handling

### GITHUB_TOKEN

The script **auto-extracts** `GITHUB_TOKEN` from Che-mounted git credentials at `/.git-credentials/credentials`. If your cluster has GitHub OAuth configured (standard in DevSpaces), no manual setup is needed.
