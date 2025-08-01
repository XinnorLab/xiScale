#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# interactive_install_spectrum_scale.sh – Guided, idempotent deployment of
# IBM Spectrum Scale 5.2.3.2 on a 10‑node RHEL‑9 cluster **plus built‑in
# health‑check**.
# ---------------------------------------------------------------------------
# KEY FEATURES
#   • Step‑by‑step confirmations (or -y for unattended)
#   • -s / --start-phase A‑J to resume from any step
#   • --hc prints a concise cluster health report and exits
#   • Uses absolute path to toolkit in every phase – no cwd dependency
#   • Generates node‑specific nsddevices files
#   • Node‑add and NSD‑add are idempotent (skip if already present)
#   • -c / --cluster <NAME> sets explicit cluster name
#   • -h / --help prints detailed docs, including phase list
# ---------------------------------------------------------------------------
set -euo pipefail

###########################################################################
# 0. ARGUMENT PARSING & HELP
###########################################################################
AUTO_YES=0; CLUSTER_NAME=""; START_PHASE=""; RUN_HC=0
print_help() {
cat <<'EOF'
Usage: sudo ./interactive_install_spectrum_scale.sh [options]

Options:
  -h, --help                 Show this help and exit.
  -y, --yes                  Non‑interactive mode (answer "yes" to all prompts).
  -c, --cluster NAME         Explicit GPFS cluster name.
  -s, --start-phase LETTER   Begin execution from phase LETTER (A‑J).
  --hc                       Run health‑check only (mmlscluster … mmlsnsd).

Phases (A–J):
  A  Local preparation            – Enables CodeReady repo; installs unzip & pdsh.
  B  Remote prerequisites         – Installs kernel headers & dev pkgs; stops firewalld.
  C  Verify installer             – md5sum check in unpacked directory.
  D  Silent install (master)      – Runs silent installer locally.
  E  Cluster skeleton setup       – spectrumscale setup -s <MGMT_IP> [-c <NAME>].
  F  Add nodes                    – Adds quorum/manager & GUI nodes; skips on error.
  G  Define NSDs                  – Creates NSDs per mapping; skips existing ones.
  H  Install cluster packages     – Disables CallHome; runs install -pr and install.
  I  Distribute nsddevices files  – Generates per‑node nsddevices scripts and copies them.
  J  Create GUI admin             – Adds user 'secadmin' on GUI node.

Examples:
  unattended full install : sudo ./interactive_install_spectrum_scale.sh -y
  resume from phase H     : sudo ./interactive_install_spectrum_scale.sh -s H
  health‑check only       : sudo ./interactive_install_spectrum_scale.sh --hc
EOF
}
# parse CLI
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) print_help; exit 0;;
    -y|--yes)  AUTO_YES=1; shift;;
    -c|--cluster) shift; CLUSTER_NAME="$1"; shift;;
    -s|--start-phase) shift; START_PHASE="${1^^}"; shift;;
    --hc) RUN_HC=1; shift;;
    *) echo "Unknown option: $1" >&2; print_help; exit 1;;
  esac
done
[[ -n $START_PHASE && ! $START_PHASE =~ ^[A-J]$ ]] && { echo "Invalid phase letter" >&2; exit 1; }

###########################################################################
# 1. CONFIGURATION — EDIT BELOW TO MATCH ENV
###########################################################################
NODES=(node{1..10})
QUORUM_NODES=(node{1..5})
MANAGER_NODES=(node{1..9})
GUI_NODE="node10"
MGMT_IP="10.241.128.39"
INSTALLER_DIR="/home/U2AQPZR/Storage_Scale_Developer-5-2"
SS_VERSION="5.2.3.2"
KERNEL_VER="5.14.0-427.77.1.el9_4.x86_64"
SS_TOOLKIT="/usr/lpp/mmfs/${SS_VERSION}/ansible-toolkit"
SPECTRUMCTL="${SS_TOOLKIT}/spectrumscale"
CODE_READY_REPO="codeready-builder-for-rhel-9-$(arch)-rpms"

# NSD mapping (node => device:FG)
declare -A NSD_DEV=(
  [node1]="/dev/xi_raid5:101" [node2]="/dev/xi_raid5:102" [node3]="/dev/xi_raid5:101" [node4]="/dev/xi_raid5:102"
  [node5]="/dev/xi_raid5:101" [node6]="/dev/xi_raid5:102" [node7]="/dev/xi_raid5:101" [node8]="/dev/xi_raid5:102"
  [node9]="/dev/xi_raid5:101" [node10]="/dev/xi_raid5:102"
)

###########################################################################
# 2. QUICK HEALTH‑CHECK MODE
###########################################################################
HC_NODE="${QUORUM_NODES[0]}"   # where GPFS CLI lives; change if needed
run_hc_cmd() {
  local cmd_name=$1; shift
  local args="$@"
  local local_bin="$cmd_name"
  local alt_bin="/usr/lpp/mmfs/bin/$cmd_name"

  # Try locally with default PATH, then with explicit GPFS path
  if command -v "$local_bin" >/dev/null 2>&1; then
    "$local_bin" $args && return
  elif [ -x "$alt_bin" ]; then
    "$alt_bin" $args && return
  fi

  # Try remotely on HC_NODE, adding GPFS bin dir to PATH
  ssh -o BatchMode=yes "$HC_NODE" "PATH=\$PATH:/usr/lpp/mmfs/bin $cmd_name $args" || \
  ssh -o BatchMode=yes "$HC_NODE" "$alt_bin $args"
}

if [[ $RUN_HC -eq 1 ]]; then
  echo "===== GPFS Cluster Health Check (executed via ${HC_NODE} if needed) ====="
  echo -e "
--- mmlscluster ---";           run_hc_cmd mmlscluster
  echo -e "
--- mmgetstate -a ---";         run_hc_cmd mmgetstate -a
  echo -e "
--- mmhealth cluster show ---"; run_hc_cmd mmhealth cluster show || true
  echo -e "
--- mmhealth node show --extended ---"; run_hc_cmd mmhealth node show --extended || true
  echo -e "
--- mmlsnsd -v ---";            run_hc_cmd mmlsnsd -v
  echo "===== End health check ====="
  exit 0
fi


if [[ $RUN_HC -eq 1 ]]; then
  echo "===== GPFS Cluster Health Check (executed via ${HC_NODE} if needed) ====="
  echo -e "
--- mmlscluster ---";           run_hc_cmd mmlscluster
  echo -e "
--- mmgetstate -a ---";         run_hc_cmd mmgetstate -a
  echo -e "
--- mmhealth cluster show ---"; run_hc_cmd mmhealth cluster show || true
  echo -e "
--- mmhealth node show --extended ---"; run_hc_cmd mmhealth node show --extended || true
  echo -e "
--- mmlsnsd -v ---";            run_hc_cmd mmlsnsd -v
  echo "===== End health check ====="
  exit 0
fi



###########################################################################
# 3. FUNCTIONS & HELPERS
###########################################################################
log(){ echo -e "\e[1;32m[$(date +%F' '%T)] $*\e[0m"; }
err(){ echo -e "\e[1;31mERROR: $*\e[0m" >&2; exit 1; }
cmd(){ log "$*"; eval "$*"; }
remote_all(){ pdsh -R ssh -w $(IFS=,; echo "${NODES[*]}") "$*"; }
# phase gating
skip_before() {
  # Return 0 (skip) if the requested phase letter is before START_PHASE
  if [[ -z $START_PHASE ]]; then
    return 1   # no skipping requested
  fi
  if [[ $1 < $START_PHASE ]]; then
    return 0   # should skip
  fi
  return 1     # run this phase
}
confirm(){ local p=$1; shift; local msg="$*"; if skip_before $p; then echo "[skip] Phase $p"; return 1; fi; echo; echo "$msg"; if [[ $AUTO_YES -eq 1 ]]; then echo "[auto‑yes] Proceeding …"; else read -rp "Continue? [y/N] " ans; [[ $ans =~ ^[Yy]$ ]] || exit 0; fi; START_PHASE=""; return 0; }
phase_done(){ if [[ $AUTO_YES -eq 1 ]]; then echo "[auto‑yes] Continuing …"; else read -rp "Proceed to the next phase? [y/N] " ans; [[ $ans =~ ^[Yy]$ ]] || exit 0; fi; }
check_root(){ [[ $EUID -eq 0 ]] || err "Run as root."; }
check_prereqs(){ command -v unzip >/dev/null || err "Install unzip"; command -v pdsh >/dev/null || echo -e "\e[33mWill install pdsh in Phase A\e[0m"; [[ -x $SPECTRUMCTL ]] || err "Toolkit not found at $SPECTRUMCTL"; }
# utilities
create_nsd_file(){ echo -e "#!/usr/bin/env bash\necho $2" >"$3"; chmod +x "$3"; }
add_nsd_safe(){ set +e; $SPECTRUMCTL nsd add -p "$1" "$2" -fg "$3"; [[ $? -ne 0 ]] && echo -e "\e[33mNSD $2 on $1 skipped\e[0m"; set -e; }
add_node_safe(){ set +e; $SPECTRUMCTL node add $1 -n "$2"; [[ $? -ne 0 ]] && echo -e "\e[33mNode $2 skipped\e[0m"; set -e; }

###########################################################################
# 4. EXECUTION FLOW
###########################################################################
check_root; check_prereqs

# ------------------ PHASE A ---------------------------------------------
if confirm A "PHASE A: Enable ${CODE_READY_REPO} and install unzip/pdsh."; then
  cmd "subscription-manager repos --enable ${CODE_READY_REPO}"
  cmd "dnf -y install unzip pdsh-rcmd-ssh"
  phase_done
fi

# ------------------ PHASE B ---------------------------------------------
if confirm B "PHASE B: Install kernel headers & dev pkgs on all nodes; stop firewalld."; then
  remote_all "dnf -y install kernel-headers-${KERNEL_VER} gcc-c++ elfutils elfutils-devel"
  remote_all "systemctl stop firewalld"
  phase_done
fi

# ------------------ PHASE C ---------------------------------------------
if confirm C "PHASE C: Verify installer MD5 in ${INSTALLER_DIR}."; then
  cmd "cd ${INSTALLER_DIR} && md5sum -c Storage_Scale_Developer-*-install.md5"
  phase_done
fi

# ------------------ PHASE D ---------------------------------------------
if confirm D "PHASE D: Run silent installer on master."; then
  cmd "cd ${INSTALLER_DIR} && sh ./Storage_Scale_Developer-*install --silent"
  phase_done
fi

# ------------------ PHASE E ---------------------------------------------
if confirm E "PHASE E: spectrumscale setup with IP ${MGMT_IP}."; then
  setup_cmd="$SPECTRUMCTL setup -s ${MGMT_IP}"; [[ -n $CLUSTER_NAME ]] && setup_cmd+=" -c ${CLUSTER_NAME}"; cmd "$setup_cmd"
  phase_done
fi

# ------------------ PHASE F ---------------------------------------------
if confirm F "PHASE F: Add quorum/manager & GUI nodes."; then
  for n in "${QUORUM_NODES[@]}"; do add_node_safe "-a -m -q" "$n"; done
  for n in "${MANAGER_NODES[@]}"; do [[ " ${QUORUM_NODES[*]} " == *" $n "* ]] && continue; add_node_safe "-a -m" "$n"; done
  add_node_safe "-a -m -g" "$GUI_NODE"
  $SPECTRUMCTL node list
  phase_done
fi

# ------------------ PHASE G ---------------------------------------------
if confirm G "PHASE G: Define NSDs – idempotent."; then
  for n in "${!NSD_DEV[@]}"; do d=${NSD_DEV[$n]%%:*}; fg=${NSD_DEV[$n]##*:}; add_nsd_safe "$n" "$d" "$fg"; done
  phase_done
fi

# ------------------ PHASE H ---------------------------------------------
if confirm H "PHASE H: Disable CallHome & run cluster-wide install."; then
  $SPECTRUMCTL callhome disable
  $SPECTRUMCTL install -pr
  $SPECTRUMCTL install
  phase_done
fi

# ------------------ PHASE I ---------------------------------------------
if confirm I "PHASE I: Generate & distribute nsddevices to nodes."; then
  tmpdir=$(mktemp -d)
  for n in "${!NSD_DEV[@]}"; do d=${NSD_DEV[$n]%%:*}; f="$tmpdir/nsddevices_$n"; create_nsd_file "$n" "$d" "$f"; scp "$f" ${n}:/var/mmfs/etc/nsddevices; ssh $n "chmod +x /var/mmfs/etc/nsddevices"; done
  remote_all "ls -l /var/mmfs/etc/nsddevices"
  rm -rf "$tmpdir"
  phase_done
fi

# ------------------ PHASE J ---------------------------------------------
if confirm J "PHASE J: Create GUI user 'secadmin' on ${GUI_NODE}."; then
  GUI_MKUSER="/usr/lpp/mmfs/gui/cli/mkuser"
  if ssh -o BatchMode=yes ${GUI_NODE} "test -x ${GUI_MKUSER}"; then
    ssh ${GUI_NODE} "${GUI_MKUSER} secadmin -g SecurityAdmin"
    echo -e "\n✔ GUI user 'secadmin' created on ${GUI_NODE}."
  else
    echo -e "\e[31mGUI CLI (${GUI_MKUSER}) not found on ${GUI_NODE}. Install GUI packages first.\e[0m"
  fi
  echo -e "\n✔ All phases complete. Next: mmcrcluster, mmcrnsd, mmstartup, mmcrfs."
fi
