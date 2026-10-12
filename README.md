# eks-pv-az

An EBS volume belongs to one Availability Zone, so its pod can run only on a node in that zone. After a cluster unpark, or a nodegroup change, the nodes the pod can run on can all be in other zones. The pod stays `Pending` with `volume node affinity conflict` until someone moves the volume.

This action finds those volumes and moves them. It snapshots the volume, creates a new volume from the snapshot in a zone that has a node the pod can run on, and binds the claim to the new volume. The old volume and the snapshot stay in place until you delete them.

## Usage

```yaml
- uses: d33pthinkers/eks-pv-az@<commit SHA>
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
