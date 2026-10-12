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
| `detect` | Read-only. Lists bound volumes in a zone with no usable node. |
| `heal` | For every `Pending` pod blocked by volume affinity, moves its volume to a zone with a node the pod can run on. |
| `relocate` | Moves one PVC (`namespace`, `pvc`, optional `to_az`). |

## Which nodes count

In `heal`, a node is a candidate for a pod only if the pod can run on it:

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
