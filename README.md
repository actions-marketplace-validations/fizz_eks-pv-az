# eks-pv-az

An EBS volume belongs to one Availability Zone, so its pod can run only on a node in that zone. After a cluster unpark, or a nodegroup change, the nodes the pod can run on can all be in other zones. The pod stays `Pending` with `volume node affinity conflict` until someone moves the volume.

This action finds those volumes and moves them. It snapshots the volume, creates a new volume from the snapshot in a zone that has a node the pod can run on, and binds the claim to the new volume. The old volume and the snapshot stay in place until you delete them.

## Usage

```yaml
- uses: fizz/eks-pv-az@<commit SHA>
  with:
    mode: heal          # detect | heal | relocate
    context: my-cluster
    region: us-east-1
    apply: 'true'       # anything else is a dry run
```

Pin to a commit SHA, not a branch. The action runs `kubectl` and `aws` against the caller's credentials.

| Mode | What it does |
|---|---|
| `detect` | Read-only. Reports every pending claim whose pod cannot be placed, and why. Exits 1 on any finding. |
| `heal` | Moves the volume of every stranded claim to a zone with a node its pod can run on, and names the ones it cannot move. |
| `relocate` | Moves one PVC (`namespace`, `pvc`, optional `to_az`). |

`detect` and `heal` share one verdict, so they cannot disagree about whether a pod is stuck. Each finding carries a class:

| Class | Meaning | Can `heal` fix it? |
|---|---|---|
| `stranded` | The pod has nodes it may run on, none in the volume's zone has room, and another zone does. | Yes, it moves the volume there. |
| `no-destination` | Stranded, but no zone has a node with room for the pod. Moving the volume only strands it elsewhere. | No. `heal` reports it and fails. |
| `unschedulable` | No node in the cluster matches the pod's `nodeSelector`, required affinity or tolerations. | No. The placement or the node groups have to change. |
| `unzoned` | The claim's PV declares no zone, so this tool cannot place it. Common with a hand-made PV. | No, but it is named rather than passed over in silence. |

### Reading the verdict from a workflow

```yaml
- id: pv
  uses: fizz/eks-pv-az@<commit SHA>
  continue-on-error: true        # the step fails when there is a finding
  with:
    mode: detect
    context: my-cluster
    region: us-east-1
    json: 'true'
- run: echo '${{ steps.pv.outputs.findings }}' | jq -r '.[] | "\(.class) \(.namespace)/\(.claim)"'
```

By hand, `--json` puts the array on stdout and nothing else, so it pipes into `jq` directly. The human narration goes to stderr.

**When this runs matters.** A pod that went `Pending` less than `MIN_PENDING_SECONDS` ago (default 120) is excluded on purpose, so that a pod mid-schedule is not called stuck. Running straight after an unpark therefore finds nothing: let the cluster settle first, or the scan passes over the very pods the unpark stranded.

## Which nodes count

In `detect` and `heal`, a node is a candidate for a pod only if the pod can run on it:

- the node matches the pod's `nodeSelector`,
- the node matches one of the pod's required `nodeAffinity` terms,
- the pod tolerates every `NoSchedule` and `NoExecute` taint on the node,
- the node has enough free CPU for the pod's request.

Free CPU alone is not enough. A zone can have a node with spare CPU that the pod's `nodeSelector` excludes, and the pod stays `Pending` there.

## Running by hand

```bash
./pv-az-relocate.sh heal --context my-cluster --region us-east-1          # dry run
./pv-az-relocate.sh heal --context my-cluster --region us-east-1 --apply
```

Requires `kubectl`, `aws` and `jq`.

## Permissions

The action uses the caller's AWS credentials and kubectl context. `detect` and every dry run need only the read permissions.

### AWS IAM

| Action | Used for |
|---|---|
| `ec2:DescribeVolumes` | Read the zone of each volume. Wait for the new volume. |
| `ec2:DescribeSnapshots` | Wait for the snapshot. |
| `ec2:CreateSnapshot` | Snapshot the stranded volume. |
| `ec2:CreateVolume` | Create the replacement volume from the snapshot. |
| `ec2:CreateTags` | Tag the snapshot and the volume when they are created. |

The action needs no delete permission. It keeps the source volume and the snapshot.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Read",
      "Effect": "Allow",
      "Action": ["ec2:DescribeVolumes", "ec2:DescribeSnapshots"],
      "Resource": "*"
    },
    {
      "Sid": "Relocate",
      "Effect": "Allow",
      "Action": ["ec2:CreateSnapshot", "ec2:CreateVolume"],
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*::snapshot/*"
      ]
    },
    {
      "Sid": "TagOnCreate",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*::snapshot/*"
      ],
      "Condition": {
        "StringEquals": { "ec2:CreateAction": ["CreateSnapshot", "CreateVolume"] }
      }
    }
  ]
}
```

If a customer managed KMS key encrypts the volumes, the role also needs `kms:CreateGrant`, `kms:Decrypt`, `kms:DescribeKey` and `kms:GenerateDataKeyWithoutPlaintext` on that key. In GovCloud, use `arn:aws-us-gov` in the resource ARNs.

### Kubernetes RBAC

| Resource | Verbs | Used for |
|---|---|---|
| `nodes` | get, list | Zones, taints, labels and free CPU of each node |
| `pods` | get, list | Pending pods and their scheduling rules |
| `persistentvolumes` | get, list, patch, delete, create | Set `Retain`, then replace the PV |
| `persistentvolumeclaims` | get, list, delete, create | Replace the PVC |
| `volumeattachments` (`storage.k8s.io`) | list | Find volumes that a dead pod still holds |
| `replicasets` (`apps`) | get | Find the Deployment that owns a pod |
| `deployments`, `statefulsets` (`apps`) | get | Read the replica count |
| `deployments/scale`, `statefulsets/scale` (`apps`) | get, patch, update | Stop the owner during the move, then restore it |

`detect` and dry runs need only the get and list verbs. On EKS, an access entry for the role can grant these through a ClusterRole.
