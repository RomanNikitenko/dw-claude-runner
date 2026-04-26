# DW Claude Runner

Automated tool that creates a DevWorkspace on an OpenShift cluster, installs [Claude Code](https://docs.anthropic.com/en/docs/claude-code), and runs AI-driven skills inside the workspace.

## How It Works

1. Creates a DevWorkspace that clones the target project on your OpenShift cluster
2. Waits for the workspace to reach `Running` state and validates it
3. Installs Claude Code CLI inside the workspace container
4. Reads a skill file (markdown prompt) from the cloned project and runs it with Claude
5. Reports results and cleans up the workspace

## Prerequisites

- `oc` — OpenShift CLI, logged into a cluster with DevWorkspaces support
- `jq` — JSON processor

## Quick Start

```bash
# Run with default skill path (.claude/skill.md from the project repo)
./run.sh

# Override the skill path
SKILL_PATH=.claude/rebase-check.md ./run.sh

# Use a local skill from this repo's skills/ directory
SKILL_SOURCE=dw_claude_runner SKILL_PATH=test-pr.md ./run.sh

# Verbose / debug mode
./run.sh -v
./run.sh -d
```

## Command-Line Options

| Flag | Description |
|------|-------------|
| `-v` | Verbose — show progress messages |
| `-d` | Debug — verbose + internal details (pod resolution, generated YAML) |
| `-h` | Show help |

## Configuration

Edit `settings/settings.env` to customize defaults, or override via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TIMEOUT` | `300` | Seconds to wait for workspace to start |
| `SKILL_TIMEOUT` | `300` | Seconds to wait for skill completion |
| `DEVWORKSPACE_NAME` | `claude-runner` | DevWorkspace instance name |
| `CONTAINER_IMAGE` | `registry.access.redhat.com/ubi9/nodejs-22:9.7` | Container image |
| `PROJECT_URL` | `https://github.com/RomanNikitenko/web-nodejs-sample.git` | Project to clone |
| `EDITOR_DEFINITION` | che-code-insiders | Editor definition URL |
| `CLAUDE_VERSION` | `2.1.92` | Claude Code version to install |
| `SKILL_SOURCE` | `target_project` | Where to read the skill: `target_project` or `dw_claude_runner` |
| `SKILL_PATH` | `.claude/skill.md` | Path to skill file (relative to project root or `skills/`) |
| `TARGET_REPO` | `RomanNikitenko/web-nodejs-sample` | GitHub repo (owner/name) |

## Skills

Skills are markdown files that serve as prompts for Claude Code in pipe mode (`claude -p`). The skill source is controlled by `SKILL_SOURCE`:

- **`target_project`** (default) — reads `SKILL_PATH` from the cloned project repo inside the workspace
- **`dw_claude_runner`** — reads `SKILL_PATH` from the local `skills/` directory in this repo

### Writing a Skill

Create a `.md` file in your project repo (e.g. `.claude/skill.md`) with:
1. A clear goal description
2. Step-by-step instructions
3. Commands Claude should run
4. Expected output format

Use `TARGET_REPO` as a placeholder — it gets replaced with the actual repo from settings at runtime.

### Example Skills

The `skills/` directory in this repo contains example skills for reference:

- **`create-rebase-issue.md`** — Checks if a newer upstream VS Code release exists and creates a GitHub issue
- **`test-pr.md`** — Makes a trivial change and opens a PR to verify the pipeline end-to-end

## GitHub Actions Usage

```yaml
env:
  SKILL_SOURCE: target_project
  SKILL_PATH: .claude/my-skill.md
  PROJECT_URL: '"https://github.com/owner/repo.git"'
  TARGET_REPO: owner/repo

steps:
  - uses: actions/checkout@v4
  - name: Run Claude skill
    run: ./run.sh
```

## File Structure

```
settings/
  settings.env                  # Configuration and validation function

skills/
  create-rebase-issue.md        # Example skill: check upstream, create issue
  test-pr.md                    # Example skill: trivial change + PR

devworkspace-template.yaml      # DevWorkspace template with placeholders
run.sh             # Main orchestrator script
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  run.sh                                    │
│                                                         │
│  1. oc apply devworkspace  ──►  OpenShift Cluster       │
│  2. wait for Running       ◄──  DevWorkspace ready      │
│  3. oc exec: install claude                             │
│  4. oc exec: claude -p <skill>  ──►  GitHub API         │
│  5. oc delete devworkspace                              │
└─────────────────────────────────────────────────────────┘
```

## Secrets Handling

### GITHUB_TOKEN

The script **auto-extracts** `GITHUB_TOKEN` from Che-mounted git credentials at `/.git-credentials/credentials`. If your cluster has GitHub OAuth configured (standard in DevSpaces), no manual setup is needed.

### ANTHROPIC_API_KEY

Must be provided as an environment variable inside the workspace. Create a Kubernetes Secret with Che automount labels:

```bash
oc create secret generic claude-secrets \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-..."
oc label secret claude-secrets \
  controller.devfile.io/devworkspace_env=true \
  controller.devfile.io/watch-secret=true
```

This makes `ANTHROPIC_API_KEY` available in every workspace in the namespace automatically.
