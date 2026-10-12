#!/usr/bin/env bash
# Relocate an EBS-backed PersistentVolume to a different Availability Zone.
#
# An EBS volume lives in exactly one AZ, and the PersistentVolume built from it
# carries a nodeAffinity requiring that zone. Park/unpark re-rolls node placement
# — the ASG spreads nodes across its subnets however it can — but the volumes
# stay put. When the dice don't match, the pod sits Pending forever and the only
# evidence is in its events. Nothing in the normal alerting path says so.
#
# This script answers that condition: "you unparked into the wrong AZ for your
# volume, move the volume to where the nodes actually are."
#
# Modes:
#   detect                  Report PVs whose zone has no usable node. Read-only.
#   relocate                Move one PVC's volume to another AZ.
#   heal                    Relocate every stranded volume, unattended.
#
# Runs as a composite action (`uses: fizz/eks-pv-az@<commit SHA>`) and by hand.
#
# Usage by hand:
#   ./pv-az-relocate.sh detect --context my-cluster --region us-east-1
#
#   ./pv-az-relocate.sh relocate --context my-cluster --region us-east-1 \
#       --namespace monitoring --pvc data-prometheus-0
#       # destination AZ is chosen automatically; add --apply to execute
#
#   ./pv-az-relocate.sh relocate ... --to us-east-1c --apply
#
#   ./pv-az-relocate.sh heal --context my-cluster --region us-east-1 --apply
#       # what unpark runs: move any volume whose zone has no node its pod can run on
#
# Requires:
#   - AWS_PROFILE set, or credentials otherwise in the environment
#   - kubectl context for the target cluster
#   - jq
#
# IMPORTANT NOTES:
#   - Dry-run is the default. Nothing is created, deleted, or scaled without
#     --apply. The dry run prints the exact plan and the rollback.
#   - The source volume and the snapshot are RETAINED. Cleanup commands are
#     printed, never run. Delete them yourself once the workload has been
#     healthy for a while.
#   - The PV's reclaim policy is flipped to Retain BEFORE anything is deleted.
#     With the default Delete policy, removing the PVC destroys the underlying
#     EBS volume at the moment you least want that.
#   - `Ready` is not `schedulable`. A cordoned node prints Ready,SchedulingDisabled,
#     so a naive `grep Ready` counts it as usable. .spec.unschedulable is absent
#     (not false) on an uncordoned node, which is why the jsonpath below uses a
#     "|" separator — a space-separated form shifts fields and silently misreads.
#   - An Evicted or ContainerStatusUnknown pod still holds its VolumeAttachment,
#     and EBS attaches to one instance at a time. Preflight checks for this;
#     otherwise the replacement pod hangs in ContainerCreating with
#     FailedAttachVolume and the cause is not obvious.
#   - This does not prevent recurrence. The durable fix is a node group per AZ
#     for stateful workloads, which is what AWS recommends for EBS-backed
#     StatefulSets. Subnets are immutable on a managed node group, so that means
#     new node groups, not a reconfiguration.

set -euo pipefail

CONTEXT=""; REGION=""; NAMESPACE=""; PVC=""; TO_AZ=""; APPLY=0; MODE=""

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }
step() { echo; echo "==> $*"; }

usage() {
  sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------------------------------------------------------------- arg parsing
[ $# -gt 0 ] || usage 1
MODE="$1"; shift
case "$MODE" in
  detect|relocate|heal) ;;
  -h|--help|help) usage 0 ;;
  *) die "unknown mode '$MODE' (expected: detect, relocate, heal)" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --context)   CONTEXT="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --pvc)       PVC="$2"; shift 2 ;;
    --to)        TO_AZ="$2"; shift 2 ;;
    --apply)     APPLY=1; shift ;;
    -h|--help)   usage 0 ;;
    *) die "unknown flag '$1'" ;;
  esac
done

[ -n "$CONTEXT" ] || die "--context is required"
[ -n "$REGION" ] || die "--region is required"
command -v jq >/dev/null || die "jq is required"

KUBECTL=(kubectl --context "$CONTEXT")
AWS=(aws --region "$REGION")

# ------------------------------------------------------------------ inventory

# Zones that have at least one node that is both Ready and schedulable, with the
# free (allocatable minus requested) CPU in millicores available in each.
zone_capacity_json() {
  "${KUBECTL[@]}" get nodes -o json > "$WORK/nodes.json"
  "${KUBECTL[@]}" get pods -A -o json > "$WORK/pods.json"
  python3 - "$WORK/nodes.json" "$WORK/pods.json" <<'PY'
import json, sys
from collections import defaultdict

def m(v):
    if v is None: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith("m") else int(float(v) * 1000)

nodes = json.load(open(sys.argv[1]))["items"]
pods  = json.load(open(sys.argv[2]))["items"]

req = defaultdict(int)
for p in pods:
    n = p["spec"].get("nodeName")
    if not n or p["status"].get("phase") in ("Succeeded", "Failed"):
        continue
    for c in p["spec"]["containers"]:
        req[n] += m(c.get("resources", {}).get("requests", {}).get("cpu"))

out = defaultdict(lambda: {"nodes": 0, "free_cpu_m": 0, "usable_nodes": []})
for n in nodes:
    name = n["metadata"]["name"]
    zone = n["metadata"]["labels"].get("topology.kubernetes.io/zone", "?")
    # Ready is not schedulable: a cordoned node is Ready,SchedulingDisabled.
    ready = any(c["type"] == "Ready" and c["status"] == "True"
                for c in n["status"].get("conditions", []))
    schedulable = not n["spec"].get("unschedulable", False)
    if not (ready and schedulable):
        continue
    free = m(n["status"]["allocatable"]["cpu"]) - req[name]
    out[zone]["nodes"] += 1
    out[zone]["free_cpu_m"] += free
    out[zone]["usable_nodes"].append({"name": name, "free_cpu_m": free})

print(json.dumps(out, indent=2))
PY
}

# Every PV that pins itself to a zone, with the claim that owns it.
pinned_pvs_json() {
  "${KUBECTL[@]}" get pv -o json | jq '[
    .items[]
    | . as $pv
    | ($pv.spec.nodeAffinity.required.nodeSelectorTerms // [])
      | map(.matchExpressions // [] | map(select(.key | test("zone"))) | .[]?.values[]?)
      | flatten | unique
    | select(length > 0)
    | { pv: $pv.metadata.name,
        zones: .,
        namespace: ($pv.spec.claimRef.namespace // "-"),
        claim: ($pv.spec.claimRef.name // "-"),
        capacity: ($pv.spec.capacity.storage // "?"),
        storageClass: ($pv.spec.storageClassName // "-"),
        reclaim: $pv.spec.persistentVolumeReclaimPolicy,
        volumeHandle: ($pv.spec.csi.volumeHandle // $pv.spec.awsElasticBlockStore.volumeID // "") }
  ]'
}

# Pending pods and the claims they are waiting on, with the CPU each needs.
#
# Pod-driven on purpose. The PV list alone cannot say whether anything is
# blocked -- a volume in a full zone is only a problem when something wants to
# mount it. This also supplies the number that matters: the pod's own request,
# to compare against free capacity in the volume's zone.
#
# fit_nodes lists the nodes the pod may run on at all: its nodeSelector, its
# required node affinity and its tolerations against each node's labels and
# taints. A cluster with dedicated node groups (taints, `usecase` labels) has
# nodes in a volume's zone that the pod can never use, and counting their free
# CPU hides a stranded volume. zone_capacity_json must run first; this reads the
# nodes.json it writes.
blocked_claims_json() {
  "${KUBECTL[@]}" get pods -A -o json > "$WORK/pending.json"
  python3 - "$WORK/pending.json" "$WORK/nodes.json" <<'PY'
import json, sys, datetime

def m(v):
    if v is None: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith("m") else int(float(v) * 1000)

def tolerated(taint, tolerations):
    for t in tolerations:
        if t.get("effect") and t["effect"] != taint.get("effect"):
            continue
        if t.get("operator") == "Exists":
            if not t.get("key") or t["key"] == taint.get("key"):
                return True
        elif t.get("key") == taint.get("key") and t.get("value", "") == taint.get("value", ""):
            return True
    return False

def expr_ok(e, labels):
    key, op, vals = e["key"], e["operator"], e.get("values", [])
    have = labels.get(key)
    if op == "In":           return have in vals
    if op == "NotIn":        return have not in vals
    if op == "Exists":       return key in labels
    if op == "DoesNotExist": return key not in labels
    if op in ("Gt", "Lt"):
        try:
            a, b = int(have), int(vals[0])
        except (TypeError, ValueError, IndexError):
            return False
        return a > b if op == "Gt" else a < b
    return False

def fits(spec, node):
    labels = node["metadata"].get("labels", {})
    for k, v in (spec.get("nodeSelector") or {}).items():
        if labels.get(k) != v:
            return False
    req = (((spec.get("affinity") or {}).get("nodeAffinity") or {})
           .get("requiredDuringSchedulingIgnoredDuringExecution") or {})
    terms = req.get("nodeSelectorTerms") or []
    if terms and not any(all(expr_ok(e, labels) for e in t.get("matchExpressions", []))
                         for t in terms):
        return False
    tols = spec.get("tolerations") or []
    for taint in node["spec"].get("taints") or []:
        if taint.get("effect") in ("NoSchedule", "NoExecute") and not tolerated(taint, tols):
            return False
    return True

nodes = json.load(open(sys.argv[2]))["items"]

out = []
for pod in json.load(open(sys.argv[1]))["items"]:
    if pod["status"].get("phase") != "Pending":
        continue
    spec = pod["spec"]
    cpu = sum(m(c.get("resources", {}).get("requests", {}).get("cpu"))
              for c in spec.get("containers", []))
    # How long it has been waiting. Read, never slept on: the cluster already
    # knows, so there is no reason for the job to sit and watch a pod get old.
    age = 0
    for cond in pod["status"].get("conditions", []):
        if cond.get("type") == "PodScheduled" and cond.get("status") == "False":
            try:
                t = datetime.datetime.fromisoformat(
                    cond["lastTransitionTime"].replace("Z", "+00:00"))
                age = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds())
            except Exception:
                pass
    for v in spec.get("volumes", []):
        pvc = (v.get("persistentVolumeClaim") or {}).get("claimName")
        if pvc:
            out.append({"namespace": pod["metadata"]["namespace"],
                        "claim": pvc,
                        "pod": pod["metadata"]["name"],
                        "cpu_m": cpu,
                        "pending_seconds": age,
                        "fit_nodes": [n["metadata"]["name"] for n in nodes if fits(spec, n)]})
print(json.dumps(out))
PY
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pv-az-relocate.XXXXXX")
note "work dir: $WORK"

# -------------------------------------------------------------------- detect

do_detect() {
  step "Usable nodes by zone (Ready AND schedulable)"
  zone_capacity_json > "$WORK/zones.json"
  jq -r 'to_entries[] | "  \(.key): \(.value.nodes) node(s), \(.value.free_cpu_m)m CPU free"' \
    "$WORK/zones.json"

  step "Zone-pinned PersistentVolumes"
  pinned_pvs_json > "$WORK/pvs.json"
  local total stranded
  total=$(jq 'length' "$WORK/pvs.json")
  note "$total zone-pinned PV(s)"

  jq -r '.[] | "  \(.zones|join(",")) \(.capacity)  \(.namespace)/\(.claim)"' "$WORK/pvs.json" | sort

  step "Stranded volumes (no usable node in the PV's zone)"
  stranded=$(jq -n --slurpfile z "$WORK/zones.json" --slurpfile p "$WORK/pvs.json" '
    [ $p[0][] | select( [ .zones[] | ($z[0][.] // {nodes:0}).nodes ] | add == 0 ) ]')

  if [ "$(echo "$stranded" | jq 'length')" = "0" ]; then
    note "none — every zone-pinned volume has a usable node in its zone"
    return 0
  fi

  echo "$stranded" | jq -r '.[] |
    "  STRANDED  \(.namespace)/\(.claim)\n            zone \(.zones|join(",")) has no usable node\n            relocate with: --namespace \(.namespace) --pvc \(.claim)"'
  return 1
}

# ------------------------------------------------------------------ relocate

# The workload that must be quiesced: walk the pod that references the PVC up
# through its ownerReferences. Falls back to the StatefulSet naming convention
# when no pod exists (the pod may already be gone).
find_owner() {
  local ns="$1" pvc="$2"
  local pod
  pod=$("${KUBECTL[@]}" get pods -n "$ns" -o json | jq -r --arg p "$pvc" '
    .items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $p))
    | .metadata.name' | head -1)
  if [ -n "$pod" ]; then
    local kind name
    kind=$("${KUBECTL[@]}" get pod -n "$ns" "$pod" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
    name=$("${KUBECTL[@]}" get pod -n "$ns" "$pod" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
    if [ "$kind" = "ReplicaSet" ]; then
      # one more hop to the Deployment
      local dep
      dep=$("${KUBECTL[@]}" get rs -n "$ns" "$name" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
      [ -n "$dep" ] && { echo "deployment/$dep"; return; }
    fi
    [ -n "$kind" ] && [ -n "$name" ] && { echo "$(echo "$kind" | tr '[:upper:]' '[:lower:]')/$name"; return; }
  fi
  echo ""
}

do_relocate() {
  [ -n "$NAMESPACE" ] || die "--namespace is required for relocate"
  [ -n "$PVC" ] || die "--pvc is required for relocate"

  step "Resolving $NAMESPACE/$PVC"
  local pv vol src_az sc cap reclaim
  pv=$("${KUBECTL[@]}" get pvc -n "$NAMESPACE" "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null) \
    || die "PVC $NAMESPACE/$PVC not found"
  [ -n "$pv" ] || die "PVC $NAMESPACE/$PVC is not bound to a PV"

  pinned_pvs_json > "$WORK/pvs.json"
  local row
  row=$(jq -r --arg pv "$pv" '.[] | select(.pv == $pv)' "$WORK/pvs.json")
  [ -n "$row" ] || die "PV $pv has no zone affinity — nothing to relocate"

  vol=$(echo "$row" | jq -r '.volumeHandle')
  src_az=$(echo "$row" | jq -r '.zones[0]')
  sc=$(echo "$row" | jq -r '.storageClass')
  cap=$(echo "$row" | jq -r '.capacity')
  reclaim=$(echo "$row" | jq -r '.reclaim')
  [ -n "$vol" ] || die "could not resolve an EBS volume id from PV $pv"

  note "PV:            $pv"
  note "EBS volume:    $vol"
  note "current zone:  $src_az"
  note "size / class:  $cap / $sc"
  note "reclaim:       $reclaim"

  local owner
  owner=$(find_owner "$NAMESPACE" "$PVC")
  [ -n "$owner" ] || die "could not determine the workload owning $PVC; quiesce it yourself and re-run"
  note "owner:         $owner"

  # ----------------------------------------------------------- destination AZ
  step "Choosing destination"
  zone_capacity_json > "$WORK/zones.json"
  if [ -n "$TO_AZ" ]; then
    local n
    n=$(jq -r --arg z "$TO_AZ" '(.[$z].nodes // 0)' "$WORK/zones.json")
    [ "$n" != "0" ] || die "--to $TO_AZ has no Ready+schedulable node"
    note "destination:   $TO_AZ (explicit)"
  else
    TO_AZ=$(jq -r 'to_entries | sort_by(-.value.free_cpu_m) | .[0].key' "$WORK/zones.json")
    [ -n "$TO_AZ" ] && [ "$TO_AZ" != "null" ] || die "no zone has a usable node"
    note "destination:   $TO_AZ (most free CPU)"
  fi
  [ "$TO_AZ" != "$src_az" ] || die "volume is already in $TO_AZ — nothing to do"

  # ---------------------------------------------------------------- preflight
  step "Preflight"

  # A dead pod still holding the attachment blocks every replacement.
  local attach
  attach=$("${KUBECTL[@]}" get volumeattachment -o json 2>/dev/null \
    | jq -r --arg pv "$pv" '[.items[] | select(.spec.source.persistentVolumeName == $pv)] | length')
  note "VolumeAttachments on this PV: ${attach:-0}"
  if [ "${attach:-0}" -gt 1 ]; then
    die "more than one VolumeAttachment on $pv — force-delete the dead pod first"
  fi

  local attached_to
  attached_to=$("${AWS[@]}" ec2 describe-volumes --volume-ids "$vol" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || echo "None")
  note "EBS attached to: $attached_to"

  local vtype
  vtype=$("${AWS[@]}" ec2 describe-volumes --volume-ids "$vol" \
    --query 'Volumes[0].VolumeType' --output text)
  note "volume type:     $vtype"

  # ------------------------------------------------------------------ dry run
  if [ "$APPLY" != "1" ]; then
    step "DRY RUN — nothing has been changed"
    cat <<EOF
  Plan:
    1. scale $owner to 0 replicas in $NAMESPACE
    2. snapshot $vol
    3. create a $vtype volume from that snapshot in $TO_AZ
    4. patch PV $pv to reclaimPolicy=Retain
    5. delete PVC $NAMESPACE/$PVC and PV $pv   (both EBS volumes survive)
    6. create PV bound to the new volume, pinned to $TO_AZ, and a PVC claiming it
    7. scale $owner back up and confirm the pod lands in $TO_AZ

  Rollback at any point: the source volume $vol is untouched in $src_az, and the
  snapshot taken in step 2 can rebuild it. Recreate the PV with volumeHandle=$vol
  and nodeAffinity=$src_az.

  Re-run with --apply to execute.
EOF
    return 0
  fi

  # ------------------------------------------------------------------- apply
  # Stop the workload before snapshotting. The snapshot becomes the replacement
  # volume, so taking it while the pod is writing yields a crash-consistent copy
  # — torn writes for a TSDB or a JetStream store. In the heal path this costs
  # nothing, because a stranded pod is Pending and writing nothing anyway.
  step "1/7 Quiescing $owner"
  local replicas
  replicas=$("${KUBECTL[@]}" get -n "$NAMESPACE" "$owner" -o jsonpath='{.spec.replicas}')
  note "current replicas: $replicas"
  "${KUBECTL[@]}" scale -n "$NAMESPACE" "$owner" --replicas=0
  local i
  for i in $(seq 1 30); do
    local live
    live=$("${KUBECTL[@]}" get pods -n "$NAMESPACE" -o json \
      | jq -r --arg p "$PVC" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $p))] | length')
    [ "$live" = "0" ] && break
    sleep 4
  done
  note "quiesced"

  step "2/7 Snapshotting $vol"
  local snap
  snap=$("${AWS[@]}" ec2 create-snapshot --volume-id "$vol" \
    --description "$NAMESPACE/$PVC pre-AZ-move $src_az->$TO_AZ $(date +%F)" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$PVC-pre-az-move}]" \
    --query SnapshotId --output text)
  note "snapshot: $snap"
  "${AWS[@]}" ec2 wait snapshot-completed --snapshot-ids "$snap"
  note "complete"

  step "3/7 Creating replacement volume in $TO_AZ"
  local newvol
  newvol=$("${AWS[@]}" ec2 create-volume --snapshot-id "$snap" \
    --availability-zone "$TO_AZ" --volume-type "$vtype" \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$PVC-$TO_AZ},{Key=kubernetes.io/created-for/pvc/name,Value=$PVC},{Key=kubernetes.io/created-for/pvc/namespace,Value=$NAMESPACE}]" \
    --query VolumeId --output text)
  note "new volume: $newvol"
  "${AWS[@]}" ec2 wait volume-available --volume-ids "$newvol"
  note "available"

  step "4/7 Setting reclaimPolicy=Retain on $pv"
  "${KUBECTL[@]}" patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

  step "5/7 Deleting the old PVC and PV (both EBS volumes survive)"
  "${KUBECTL[@]}" delete pvc -n "$NAMESPACE" "$PVC" --wait=true --timeout=120s
  "${KUBECTL[@]}" delete pv "$pv" --wait=true --timeout=120s
  for v in "$vol" "$newvol"; do
    note "$v: $("${AWS[@]}" ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' --output text)"
  done

  step "6/7 Creating the replacement PV and PVC in $TO_AZ"
  # claimRef + volumeName force a one-to-one bind, so the PVC cannot grab
  # something else and the PV cannot be claimed by another workload.
  cat > "$WORK/replacement.yaml" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PVC}-${TO_AZ}
spec:
  capacity:
    storage: ${cap}
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${sc}
  claimRef:
    namespace: ${NAMESPACE}
    name: ${PVC}
  csi:
    driver: ebs.csi.aws.com
    fsType: ext4
    volumeHandle: ${newvol}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["${TO_AZ}"]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: ${sc}
  resources:
    requests:
      storage: ${cap}
  volumeName: ${PVC}-${TO_AZ}
EOF
  "${KUBECTL[@]}" apply -f "$WORK/replacement.yaml"

  step "7/7 Restoring $owner to $replicas replica(s)"
  "${KUBECTL[@]}" scale -n "$NAMESPACE" "$owner" --replicas="$replicas"
  for i in $(seq 1 30); do
    sleep 10
    local line
    line=$("${KUBECTL[@]}" get pods -n "$NAMESPACE" -o wide --no-headers 2>/dev/null \
      | grep -F "$(echo "$owner" | cut -d/ -f2)" | head -1 || true)
    note "[$i/30] ${line:-waiting}"
    echo "$line" | grep -qE '\sRunning\s' && break
  done

  step "Result"
  "${KUBECTL[@]}" get pvc -n "$NAMESPACE" "$PVC" --no-headers | sed 's/^/  /'
  local node landed
  node=$("${KUBECTL[@]}" get pods -n "$NAMESPACE" -o json \
    | jq -r --arg p "$PVC" '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $p)) | .spec.nodeName' | head -1)
  landed=$("${KUBECTL[@]}" get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "?")
  note "pod node: $node  zone: $landed"
  [ "$landed" = "$TO_AZ" ] || die "pod landed in $landed, expected $TO_AZ"

  step "Cleanup — RUN THESE YOURSELF once the workload has been healthy for a while"
  cat <<EOF
  aws --region $REGION ec2 delete-volume   --volume-id  $vol
  aws --region $REGION ec2 delete-snapshot --snapshot-id $snap
EOF
}

# ------------------------------------------------------------------------ heal
#
# Unattended repair, for the unpark job. A volume whose zone has no node will
# never schedule, and no operator input can change which zone the volume is in,
# so there is nothing to decide — move it to a zone that has capacity.
#
# Every move is snapshot-first and leaves the source volume behind, so a wrong
# call here is recoverable. Only volumes that `detect` calls stranded are
# touched; a pod Pending for CPU is left alone.
do_heal() {
  step "Scanning for stranded volumes"
  zone_capacity_json > "$WORK/zones.json"
  pinned_pvs_json > "$WORK/pvs.json"
  blocked_claims_json > "$WORK/blocked.json"

  # A volume is stranded when the pod that wants it cannot be placed in any zone
  # the volume allows -- either because no node is there, or because no node
  # there has room. Both leave the pod equally stuck.
  #
  # MIN_PENDING_SECONDS keeps a pod that is merely mid-schedule out of it. It is
  # read off the PodScheduled condition, not waited for.
  local stranded count
  stranded=$(jq -n \
    --slurpfile z "$WORK/zones.json" \
    --slurpfile p "$WORK/pvs.json" \
    --slurpfile b "$WORK/blocked.json" \
    --argjson minage "${MIN_PENDING_SECONDS:-120}" '
    [ $b[0][]
      | select(.pending_seconds >= $minage)
      | . as $need
      | ($p[0][] | select(.namespace == $need.namespace and .claim == $need.claim))
      | . as $pv
      # Only nodes the pod could run on count, in the zone of the volume and elsewhere.
      | ($need.fit_nodes) as $fit
      | ($pv.zones | map(($z[0][.] // {usable_nodes:[]}).usable_nodes[]?
          | select(.name as $n | $fit | index($n)) | .free_cpu_m)) as $free
      | ($free | max // 0) as $best
      # No usable node at all strands the volume, whatever the pod asks for.
      # Without this, a pod with no CPU request never counts: 0 < 0 is false.
      | select(($free | length) == 0 or $best < $need.cpu_m)
      # The destination is a zone the volume is not in, with one node that has
      # room for the pod. The most free CPU wins. Null when no zone qualifies.
      | ($z[0] | to_entries
          | map(select(.key as $k | ($pv.zones | index($k)) == null)
                | select(([.value.usable_nodes[]? | select(.name as $n | $fit | index($n))
                           | .free_cpu_m] | max // -1) >= $need.cpu_m))
          | sort_by(-.value.free_cpu_m) | .[0].key // null) as $dest
      | $pv + { needs_cpu_m: $need.cpu_m, pod: $need.pod,
                pending_seconds: $need.pending_seconds, best_free_cpu_m: $best,
                dest: $dest }
    ] | unique_by(.pv)')
  count=$(echo "$stranded" | jq 'length')

  if [ "$count" = "0" ]; then
    note "nothing stranded"
    return 0
  fi

  note "$count stranded volume(s)"
  echo "$stranded" | jq -r '.[] |
    "  \(.namespace)/\(.claim)  zone \(.zones|join(","))  pod \(.pod) needs \(.needs_cpu_m)m, best free there \(.best_free_cpu_m)m, pending \(.pending_seconds)s, move to \(.dest // "nowhere")"'

  if [ "$APPLY" != "1" ]; then
    step "DRY RUN — re-run with --apply to move them"
    return 0
  fi

  local ns claim dest moved=0 skipped=0
  while read -r ns claim dest; do
    [ -n "$ns" ] || continue
    if [ "$dest" = "null" ]; then
      # A move to a zone without room leaves the pod Pending there too. Skip the
      # volume and go on with the others.
      note "SKIP $ns/$claim: no other zone has a node with room for its pod"
      skipped=$((skipped + 1))
      continue
    fi
    # do_relocate reads these globals.
    NAMESPACE="$ns"; PVC="$claim"; TO_AZ="$dest"
    step "Healing $ns/$claim"
    # Any preflight failure inside do_relocate calls die and stops the run.
    # Stopping is right here: the remaining volumes are untouched and the
    # snapshot plus source volume of this one are still in place.
    do_relocate
    moved=$((moved + 1))
  done < <(echo "$stranded" | jq -r '.[] | "\(.namespace) \(.claim) \(.dest // "null")"')

  step "Relocated $moved volume(s), skipped $skipped"
  [ "$skipped" = 0 ] || die "$skipped stranded volume(s) have no zone to move to"
}

case "$MODE" in
  detect)   do_detect ;;
  relocate) do_relocate ;;
  heal)     do_heal ;;
esac
