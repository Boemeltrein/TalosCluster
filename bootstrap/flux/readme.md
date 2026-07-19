# FLux Bootstrap

## Background

The Kubernetes cluster is bootstrapped using **ClusterTool**.

At the end of the bootstrap process, ClusterTool asks whether Flux should be bootstrapped using the conventional method. **Select `No`**, as this repository uses the **Flux Operator** instead of the traditional Flux bootstrap.

After ClusterTool has finished bootstrapping the cluster, bootstrap the Flux Operator manually using the following steps.

## 1. Install the Custom Resource Definitions (CRDs)

```bash
helmfile -f crds.yaml template -q \
| yq ea -r -e 'select(.kind == "CustomResourceDefinition")' \
| kubectl apply --server-side --force-conflicts -f -
```

## 2. Install the bootstrap applications

``` bash
helmfile -f apps.yaml sync --hide-notes
```
