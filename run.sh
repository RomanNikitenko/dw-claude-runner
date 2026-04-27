#!/bin/bash
#
# This file was generated using AI assistance (Cursor AI)
# and reviewed by the maintainers.
#
set -uo pipefail

VERBOSE=0
DEBUG=0

RED='\033[1;91m'
GREEN='\033[1;92m'
YELLOW='\033[1;93m'
BLUE='\033[1;94m'
PURPLE='\033[1;95m'
NC='\033[0m'

while getopts "vdh" o; do
  case "${o}" in
    v) VERBOSE=1; echo "Verbose mode." ;;
    d) DEBUG=1; VERBOSE=1; echo "Debug mode (verbose)." ;;
    h)
      echo "Usage: $0 [-v] [-d] [-h]"
      echo "  -v  Verbose — show progress messages and final Claude answer"
      echo "  -d  Debug — verbose + stream Claude actions in real-time"
      echo "  -h  Show this help"
      echo ""
      echo "Environment variables:"
      echo "  PROMPT        Custom prompt for Claude (overrides ISSUE_REF default)"
      echo "  ISSUE_REF     GitHub issue URL (used in default prompt)"
      echo "  PROJECT_URL   Git URL of the project to clone"
      echo "  TARGET_REPO   GitHub repo (owner/name)"
      exit 0
      ;;
    \?) echo "Invalid option: -$OPTARG"; exit 1 ;;
  esac
done

[[ ${VERBOSE} -eq 0 ]] && QUIET="&>/dev/null" || QUIET=""

log() {
  if [ ${VERBOSE} -eq 1 ]; then
    echo -e "${@}"
  fi
}

debug() {
  if [ ${DEBUG} -eq 1 ]; then
    echo -e "${@}"
  fi
}

resolve_devworkspace_pod() {
  podNameAndDWName=$(oc get pods -n ${DEVWORKSPACE_NS} --field-selector=status.phase=Running -o 'jsonpath={range .items[*]}{.metadata.name}{","}{.metadata.labels.controller\.devfile\.io/devworkspace_name}{"\n"}{end}')
  debug "podNameAndDWName: ${podNameAndDWName}"
  podName=$(echo ${podNameAndDWName} | grep ${DEVWORKSPACE_NAME} | cut -d, -f1)
  debug "podName: ${podName}"

  if [ -z "${podName}" ]; then
    log "Could not find pod matching ${DEVWORKSPACE_NAME}"
    return 1
  fi

  # Resolve the main container from the actual pod (excluding the che-gateway
  # sidecar) rather than from the DW spec, to handle any naming differences.
  mainContainerName=$(oc get pod -n ${DEVWORKSPACE_NS} ${podName} -o json | jq -r '[.spec.containers[] | select(.name != "che-gateway") | .name] | first')
  debug "mainContainerName: ${mainContainerName}"

  if [ -z "${mainContainerName}" ] || [ "${mainContainerName}" == "null" ]; then
    log "Could not find main container in pod ${podName}"
    debug "All containers:"
    oc get pod -n ${DEVWORKSPACE_NS} ${podName} -o json | jq -r '.spec.containers[].name' 2>/dev/null
    return 1
  fi
  log "  Resolved pod=${podName}, container=${mainContainerName}"
  return 0
}

# ── Prerequisites ──

echo -e "\n${BLUE}Checking prerequisites...${NC}"

for cmd in oc jq; do
  if ! command -v ${cmd} &>/dev/null; then
    echo -e "${RED}Error:${NC} ${cmd} is not installed." >&2
    exit 1
  fi
done
echo -e "${GREEN}oc, jq: OK${NC}"

# Cluster connection
echo -e "\n${BLUE}Checking cluster connection...${NC}"
if oc whoami &>/dev/null; then
  echo -e "${GREEN}Connected to cluster${NC}"
else
  if [ -t 0 ]; then
    echo -e "${YELLOW}Not connected.${NC} Login to cluster?"
    while true; do
      read -p "(y/n)? : " yn
      case $yn in
        [Yy]*) oc login --web; break ;;
        [Nn]*) exit ;;
        *) echo "Please answer y or n." ;;
      esac
    done
  else
    echo -e "${RED}Not connected to cluster. Run 'oc login' first.${NC}"
    exit 1
  fi
fi

# ── Load settings ──

. settings/settings.env

DEVWORKSPACE_NS=$(oc project -q 2>/dev/null)
PROJECT_NAME=$(basename "$(echo "${PROJECT_URL}" | tr -d '"')" .git)

# Validate critical variables
if [ -z "${DEVWORKSPACE_NS}" ]; then
  echo -e "${RED}Failed to determine OpenShift namespace${NC}"
  exit 1
fi
if [ -z "${PROJECT_NAME}" ]; then
  echo -e "${RED}Failed to determine project name from PROJECT_URL${NC}"
  exit 1
fi
if [ -z "${TARGET_REPO}" ]; then
  echo -e "${RED}TARGET_REPO is not set${NC}"
  exit 1
fi
if [ -z "${PROMPT:-}" ]; then
  echo -e "${RED}PROMPT is empty (set PROMPT or ISSUE_REF)${NC}"
  exit 1
fi

echo -e "\n${BLUE}Configuration:${NC}"
echo -e "  Workspace:  ${DEVWORKSPACE_NAME}"
echo -e "  Image:      ${CONTAINER_IMAGE}"
echo -e "  Project:    ${PROJECT_NAME}"
echo -e "  Prompt:     ${PROMPT}"
echo -e "  Target:     ${TARGET_REPO}"

# ── Create DevWorkspace ──

echo -e "\n${BLUE}Creating DevWorkspace...${NC}"

TMP_DEVWORKSPACE=$(mktemp -t dw-claude-runner-XXX.yaml)

sed \
  -e "s|DEVWORKSPACE_NAME|${DEVWORKSPACE_NAME}|" \
  -e "s|DEVWORKSPACE_NS|${DEVWORKSPACE_NS}|" \
  -e "s|CONTAINER_IMAGE|${CONTAINER_IMAGE}|" \
  -e "s|PROJECT_NAME|${PROJECT_NAME}|" \
  -e "s|PROJECT_URL|${PROJECT_URL}|" \
  -e "s|EDITOR_DEFINITION|${EDITOR_DEFINITION}|" \
  devworkspace-template.yaml > ${TMP_DEVWORKSPACE}

debug "Generated DevWorkspace:"
debug "$(cat ${TMP_DEVWORKSPACE})"

eval "oc apply -f ${TMP_DEVWORKSPACE} ${QUIET}"
if [ $? -ne 0 ]; then
  echo -e "${RED}Failed to apply DevWorkspace${NC}"
  rm -f ${TMP_DEVWORKSPACE}
  exit 1
fi

# ── Wait for Running state ──

echo -e "${BLUE}Waiting for workspace to start (timeout: ${TIMEOUT}s)...${NC}"

START_TIME=$SECONDS
state=""
count=0
while [ "${state}" != "Running" ] && [ ${count} -lt ${TIMEOUT} ]; do
  state=$(oc get dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} -o 'jsonpath={.status.phase}' 2>/dev/null)
  if [ "${state}" == "Failed" ]; then
    echo -e "${RED}Workspace failed to start${NC}"
    if [ ${DEBUG} -eq 1 ]; then
      echo -e "${YELLOW}DevWorkspace status:${NC}"
      oc get dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} -o json | jq '.status'
      echo -e "${YELLOW}Pod events:${NC}"
      oc get events -n ${DEVWORKSPACE_NS} --sort-by='.lastTimestamp' 2>/dev/null | tail -20
    fi
    eval "oc delete dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} ${QUIET}"
    rm -f ${TMP_DEVWORKSPACE}
    exit 1
  fi
  sleep 2
  count=$((count + 2))
  [ $((count % 10)) -eq 0 ] && log " [${count}s state=${state:-pending}]"
done
log ""

if [ "${state}" != "Running" ]; then
  echo -e "${RED}Workspace did not start within ${TIMEOUT}s (state: ${state:-unknown})${NC}"
  eval "oc delete dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} ${QUIET}"
  rm -f ${TMP_DEVWORKSPACE}
  exit 1
fi

echo -e "${GREEN}Workspace is Running${NC} (after ${count}s)"

# ── Inspect workspace ──

if [ ${DEBUG} -eq 1 ]; then
  echo -e "\n${BLUE}Workspace details:${NC}"
  echo -e "  ${YELLOW}Pods:${NC}"
  oc get pods -n ${DEVWORKSPACE_NS} -l "controller.devfile.io/devworkspace_name=${DEVWORKSPACE_NAME}" -o wide 2>/dev/null
  echo -e "  ${YELLOW}Containers in pod:${NC}"
  oc get pods -n ${DEVWORKSPACE_NS} -l "controller.devfile.io/devworkspace_name=${DEVWORKSPACE_NAME}" -o jsonpath='{range .items[0].spec.containers[*]}  - {.name} (image: {.image}){"\n"}{end}' 2>/dev/null
  echo -e "  ${YELLOW}DevWorkspace components:${NC}"
  oc get dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} -o json | jq -r '.spec.template.components[] | "  - \(.name)" + if .container then " (image: \(.container.image))" else "" end' 2>/dev/null
fi

# ── Validate workspace ──

echo -e "\n${BLUE}Validating workspace...${NC}"
validate_devworkspace
if [ $? -ne 0 ]; then
  echo -e "${RED}Workspace validation failed${NC}"
  eval "oc delete dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} ${QUIET}"
  rm -f ${TMP_DEVWORKSPACE}
  exit 1
fi
echo -e "${GREEN}Workspace validated${NC}"

# ── Install Claude Code ──

echo -e "\n${BLUE}Installing Claude Code v${CLAUDE_VERSION}...${NC}"

INSTALL_CMD=$(cat <<'INSTALL_EOF'
set -euo pipefail
CLAUDE_VERSION="__CLAUDE_VERSION__"
GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
PLATFORM="linux-x64"
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

# Extract GITHUB_TOKEN from Che-mounted git credentials
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f /.git-credentials/credentials ]; then
  GITHUB_TOKEN=$(grep github.com /.git-credentials/credentials | sed 's|https://oauth2:\(.*\)@github.com|\1|')
  export GITHUB_TOKEN
  echo "GITHUB_TOKEN configured"
elif [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: GITHUB_TOKEN not found (no env var, no /.git-credentials/credentials)"
fi

# Install jq (not included in minimal Node.js images)
if ! command -v jq &>/dev/null; then
  echo "Installing jq..."
  curl -fsSL -o "${INSTALL_DIR}/jq" "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
  chmod +x "${INSTALL_DIR}/jq"
  echo "jq installed"
fi

# Install git-subtree (not included in minimal git packages)
GIT_EXEC_PATH=$(git --exec-path)
if [ ! -f "${GIT_EXEC_PATH}/git-subtree" ]; then
  echo "Installing git-subtree..."
  GIT_VERSION=$(git --version | cut -d' ' -f3)
  SUBTREE_URL="https://raw.githubusercontent.com/git/git/v${GIT_VERSION}/contrib/subtree/git-subtree.sh"
  if curl -fsSL -o "${GIT_EXEC_PATH}/git-subtree" "${SUBTREE_URL}" 2>/dev/null; then
    chmod +x "${GIT_EXEC_PATH}/git-subtree"
  else
    # Fallback: place in user-local bin as git-subtree wrapper
    curl -fsSL -o "${INSTALL_DIR}/git-subtree" "${SUBTREE_URL}"
    chmod +x "${INSTALL_DIR}/git-subtree"
  fi
  echo "git-subtree installed"
fi

# Install gh CLI (not included in minimal Node.js images)
if ! command -v gh &>/dev/null; then
  echo "Installing gh CLI..."
  GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | node -e "process.stdin.setEncoding('utf8');let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.parse(d).tag_name.replace('v','')))")
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" | tar xz -C /tmp
  cp "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" "${INSTALL_DIR}/gh"
  chmod +x "${INSTALL_DIR}/gh"
  echo "gh CLI v${GH_VERSION} installed"
fi

# Install Claude Code binary
MANIFEST=$(curl -fsSL "${GCS_BASE}/${CLAUDE_VERSION}/manifest.json")
EXPECTED_SHA=$(echo "$MANIFEST" | node -e "process.stdin.setEncoding('utf8');let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.parse(d).platforms['${PLATFORM}'].checksum))")
curl -fSL --progress-bar -o "${INSTALL_DIR}/claude" "${GCS_BASE}/${CLAUDE_VERSION}/${PLATFORM}/claude"
ACTUAL_SHA=$(sha256sum "${INSTALL_DIR}/claude" | cut -d' ' -f1)
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "SHA-256 mismatch! expected=${EXPECTED_SHA} actual=${ACTUAL_SHA}" >&2
  rm -f "${INSTALL_DIR}/claude"
  exit 1
fi
chmod +x "${INSTALL_DIR}/claude"
echo "Claude Code v${CLAUDE_VERSION} installed to ${INSTALL_DIR}/claude"
INSTALL_EOF
)

INSTALL_CMD="${INSTALL_CMD//__CLAUDE_VERSION__/${CLAUDE_VERSION}}"

debug "  Executing install in pod ${podName}, container ${mainContainerName}..."
oc exec -n ${DEVWORKSPACE_NS} ${podName} -c ${mainContainerName} -- bash -c "${INSTALL_CMD}" 2>&1
INSTALL_EXIT=$?
if [ ${INSTALL_EXIT} -ne 0 ]; then
  echo -e "${RED}Failed to install Claude Code (exit: ${INSTALL_EXIT})${NC}"
  if [ ${DEBUG} -eq 1 ]; then
    echo -e "${YELLOW}Container status:${NC}"
    oc get pod ${podName} -n ${DEVWORKSPACE_NS} -o json | jq '.status.containerStatuses[] | select(.name=="'${mainContainerName}'") | {ready, state}' 2>/dev/null
  fi
  eval "oc delete dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} ${QUIET}"
  rm -f ${TMP_DEVWORKSPACE}
  exit 1
fi
echo -e "${GREEN}Claude Code installed${NC}"

# ── Run Claude on issue ──

PROJECT_DIR="/projects/${PROJECT_NAME}"

echo -e "\n${BLUE}Running Claude with prompt: ${PROMPT}${NC}"
echo -e "  Timeout: ${CLAUDE_TIMEOUT}s"

CLAUDE_OUTPUT_FORMAT="text"
if [ ${DEBUG} -eq 1 ]; then
  CLAUDE_OUTPUT_FORMAT="stream-json"
fi

# Create a temporary file for Claude's PID
CLAUDE_PID_FILE=$(mktemp)

# Run Claude in background and capture its PID
(echo "${PROMPT}" | \
  oc exec -n ${DEVWORKSPACE_NS} ${podName} -c ${mainContainerName} \
  -i -- bash -c "
export PATH=\"\$HOME/.local/bin:\$PATH\"
if [ -z \"\${GITHUB_TOKEN:-}\" ] && [ -f /.git-credentials/credentials ]; then
  GITHUB_TOKEN=\$(grep github.com /.git-credentials/credentials | sed 's|https://oauth2:\(.*\)@github.com|\1|')
  export GITHUB_TOKEN
  echo 'GITHUB_TOKEN configured'
fi
cd ${PROJECT_DIR}
gh auth setup-git 2>/dev/null || true
\$HOME/.local/bin/claude -p --verbose --output-format ${CLAUDE_OUTPUT_FORMAT} --allowedTools 'Bash(*),Read(*),Write(*),Edit(*)'
" | if [ "${CLAUDE_OUTPUT_FORMAT}" = "stream-json" ]; then
  while IFS= read -r line; do
    type=$(echo "${line}" | jq -r '.type // empty' 2>/dev/null)
    case "${type}" in
      assistant)
        content=$(echo "${line}" | jq -r '(.message.content[]? | if .type == "text" then .text elif .type == "tool_use" then "⚙ Tool: \(.name) \(.input | tostring | .[0:200])" else empty end) // empty' 2>/dev/null)
        [ -n "${content}" ] && echo -e "${BLUE}Claude:${NC} ${content}"
        ;;
      result)
        result=$(echo "${line}" | jq -r '.result // empty' 2>/dev/null)
        cost=$(echo "${line}" | jq -r '.cost_usd // empty' 2>/dev/null)
        [ -n "${result}" ] && echo -e "\n${GREEN}Result:${NC} ${result}"
        [ -n "${cost}" ] && echo -e "${PURPLE}Cost:${NC} \$${cost}"
        ;;
    esac
  done
else
  cat
fi) &

CLAUDE_PID=$!
echo ${CLAUDE_PID} > ${CLAUDE_PID_FILE}

# Wait for Claude with timeout
CLAUDE_EXIT=0
CLAUDE_TIMEOUT_REACHED=0
CLAUDE_ELAPSED=0
log "  Claude process started (PID: ${CLAUDE_PID})"

while kill -0 ${CLAUDE_PID} 2>/dev/null; do
  if [ ${CLAUDE_ELAPSED} -ge ${CLAUDE_TIMEOUT} ]; then
    echo -e "\n${RED}Claude timeout reached (${CLAUDE_TIMEOUT}s)${NC}"
    echo -e "${YELLOW}Terminating Claude process...${NC}"
    kill ${CLAUDE_PID} 2>/dev/null || true
    sleep 2
    kill -9 ${CLAUDE_PID} 2>/dev/null || true
    CLAUDE_TIMEOUT_REACHED=1
    CLAUDE_EXIT=124
    break
  fi
  sleep 2
  CLAUDE_ELAPSED=$((CLAUDE_ELAPSED + 2))
  [ $((CLAUDE_ELAPSED % 60)) -eq 0 ] && log "  [Claude running: ${CLAUDE_ELAPSED}s / ${CLAUDE_TIMEOUT}s]"
done

# Get actual exit code if process finished naturally
if [ ${CLAUDE_TIMEOUT_REACHED} -eq 0 ]; then
  wait ${CLAUDE_PID}
  CLAUDE_EXIT=$?
fi

rm -f ${CLAUDE_PID_FILE}

if [ ${CLAUDE_TIMEOUT_REACHED} -eq 1 ]; then
  echo -e "\n${RED}Claude terminated due to timeout${NC}"
elif [ ${CLAUDE_EXIT} -eq 0 ]; then
  echo -e "\n${GREEN}Claude completed successfully${NC}"
else
  echo -e "\n${RED}Claude failed (exit code: ${CLAUDE_EXIT})${NC}"
fi

# ── Cleanup ──

rm -f ${TMP_DEVWORKSPACE}
echo -e "\n${BLUE}Cleaning up workspace...${NC}"
eval "oc delete dw -n ${DEVWORKSPACE_NS} ${DEVWORKSPACE_NAME} ${QUIET}" && \
  echo -e "${GREEN}Workspace deleted${NC}" || \
  echo -e "${YELLOW}Warning: failed to delete workspace${NC}"

# ── Summary ──

ELAPSED_TIME=$((SECONDS - START_TIME))
ELAPSED_MIN=$((ELAPSED_TIME / 60))
ELAPSED_SEC=$((ELAPSED_TIME % 60))

echo ""
echo "======================"
echo "Summary:"
echo -e "  Prompt:  ${BLUE}${PROMPT}${NC}"
echo -e "  Result:  $([ ${CLAUDE_EXIT} -eq 0 ] && echo -e "${GREEN}SUCCESS${NC}" || echo -e "${RED}FAILED${NC}")"
echo -e "  Time:    ${PURPLE}${ELAPSED_MIN}m ${ELAPSED_SEC}s${NC}"
echo "======================"

exit ${CLAUDE_EXIT}
