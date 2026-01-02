<div align="center">

# 🧊 Personal Talos Kubernetes Cluster · Boemeltrein 

*A self-hosted, GitOps-driven Kubernetes cluster built on Talos Linux, focused on reliability, observability, and clean automation.*

[![TrueNAS](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Ftruenas_version&style=for-the-badge&logo=truenas&logoColor=white&label=%20&color=blue)](https://www.truenas.com/)&nbsp;&nbsp;
[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Ftalos_version&style=for-the-badge&logo=talos&logoColor=white&label=%20&color=blue)](https://www.talos.dev/)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&label=%20&color=blue)](https://www.kubernetes.io/)&nbsp;&nbsp;
[![Flux](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fflux_version&style=for-the-badge&logo=flux&logoColor=white&color=blue&label=%20)](https://fluxcd.io)&nbsp;&nbsp;

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.goeppel.dev%2Fapi%2Fv1%2Fendpoints%2Fbuddy_ping-(buddy)%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=ubiquiti&logoColor=white&label=Home%20Internet)](https://status.boemeltrein.nl)&nbsp;&nbsp;
[![Status-Page](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.goeppel.dev%2Fapi%2Fv1%2Fendpoints%2Fbuddy_status-page-(buddy)%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=statuspage&logoColor=white&label=Status%20Page)](https://status.boemeltrein.nl)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fstatus.goeppel.dev%2Fapi%2Fv1%2Fendpoints%2Fbuddy_heartbeat-(buddy)%2Fhealth%2Fbadge.shields&style=for-the-badge&logo=prometheus&logoColor=white&label=Alertmanager)](https://status.boemeltrein.nl)


[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_age_days&style=flat-square&label=Age)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_node_count&style=flat-square&label=Nodes)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_pod_count&style=flat-square&label=Pods)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Alerts](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_alert_count&style=flat-square&label=Alerts)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;
[![Power](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.boemeltrein.nl%2Fcluster_power_usage&style=flat-square&label=Power)](https://github.com/kashalls/kromgo)&nbsp;&nbsp;


</div>

---

## 📌 Overview

This repository contains the full **GitOps-managed configuration** for my personal Kubernetes cluster.  
The cluster runs on **Talos Linux** and is fully declarative: every component, application, and configuration is defined in Git and continuously reconciled using **FluxCD**.

The cluster is deployed as a **single-node Talos Linux virtual machine running on a TrueNAS host**.  
The focus of this environment is learning, experimentation, and long-running homelab workloads rather than high availability.

Key goals of this setup:

* 🔁 **Reproducibility** – rebuild the entire cluster from Git  
* 🔒 **Immutability & Security** – minimal OS, no SSH, API-driven management  
* 📈 **Observability** – metrics, alerts, and status visibility  
* 🤖 **Automation-first** – updates, deployments, and testing without manual intervention  

---

## 🧠 Design Decisions

### Why Talos Linux?
- Immutable, minimal OS reduces attack surface
- No SSH or package manager
- Fully API-driven, ideal for GitOps-based Kubernetes clusters

### Why FluxCD?
- Continuous reconciliation instead of one-shot deployments
- Native Kubernetes integration
- Works seamlessly with SOPS for encrypted secrets

### Why a Single-Node Cluster?
- Simplifies operations and reduces complexity
- Ideal for homelab and learning environments
- Focuses on reproducibility rather than high availability

---

## 📡 Networking Assumptions

This cluster assumes a **simple and reliable home network environment**.

- The Talos VM relies on the TrueNAS host for primary network connectivity
- No advanced routing, BGP, or multi-homing is assumed
- Networking is optimized for simplicity and stability rather than redundancy
- External access is handled via managed ingress and tunnels where required

---

## 🧩 Core Components

| Component          | Description                                                                        |
| ------------------ | ---------------------------------------------------------------------------------- |
| **Kubernetes**     | Container orchestration platform for running and managing workloads                |
| **Talos Linux**    | Immutable, API-driven Linux distribution purpose-built for Kubernetes              |
| **FluxCD**         | GitOps operator used for continuous reconciliation of cluster state                |
| **Mend Renovate**  | Automatically tracks and updates container images and dependencies                 |
| **GitHub Actions** | CI pipelines for validation, linting, and testing of cluster configs               |
| **SOPS**           | Encryption of all secrets and credentials stored in Git, integrated with FluxCD    |
| **Clustertool**    | Bootstrap tool from TrueForge used to build the basic cluster structure and setup  |

---

## 🗂 Directory Structure

~~~text
clusters/
└── main/
    ├── components/   # Common components applied to multiple parts of the cluster
    ├── kubernetes/   # Applications and Kubernetes workloads
    └── talos/        # Talos Linux machine and cluster configuration

repositories/
├── entries/           # Repository entry definitions
├── git/               # Flux GitRepository sources
├── helm/              # Flux HelmRepository sources
└── oci/               # Flux OCIRepository sources
~~~

---

## 🔐 Secrets Management

All secrets and credentials are stored in this repository **encrypted with SOPS**.

- Secrets are committed to Git in encrypted form
- Decryption happens inside the cluster via FluxCD
- Decryption keys are managed externally and are never stored in Git
- This enables full GitOps workflows without exposing sensitive data

---

## ☁️ Cloud & External Dependencies

| Service        | Usage                                 |
| -------------- | ------------------------------------- |
| **Cloudflare** | DNS management and tunnels            |
| **GitHub**     | Source control, CI, and GitOps source |

---

## 🖥 Hardware

### TrueNAS Host System

| Component                | Specification                                   |
| ------------------------ | ----------------------------------------------- |
| **Motherboard**          | ASRock Rack B650D4U-2L2T/BCM                    |
| **CPU**                  | AMD Ryzen 7 7700 (8-Core)                       |
| **RAM**                  | Kingston Server Premier 128 GB ECC DDR5         |
| **SAS Controller**       | LSI SAS 9220-8i                                 |
| **Boot Device**          | Samsung 980 NVMe SSD (250 GB, M.2)              |
| **GPU**                  | —                                               |
| **Remote Management**    | IPMI (ASRock Rack)                              |

---

### Storage Configuration

| VDEV Type       | Configuration                                                                 |
| --------------- | ----------------------------------------------------------------------------- |
| **Data VDEV 1** | 4× WD Red Plus 8 TB HDD (5640 RPM, 128 MB cache)                               |
| **Data VDEV 2** | 3× Samsung 870 EVO 4 TB SSD (2.5", SATA 6 Gb/s)                                |

---

### Talos Kubernetes Cluster (Virtual Machine)

The Kubernetes cluster runs as a **single-node Talos Linux virtual machine hosted on a TrueNAS system**.

| Component      | Specification                                              |
| -------------- | ---------------------------------------------------------- |
| **Node Count** | 1 (Single-node cluster)                                    |
| **Deployment** | Virtual Machine on TrueNAS                                 |
| **vCPU**       | 1 socket × 6 cores / 2 threads                             |
| **Memory**     | 64 GB                                                     |
| **Storage**    | 2 TB virtual disk (ZFS sync disabled, sparse volume)       |
| **GPU / PCIe** | —                                                          |

> ⚠️ This environment is intentionally designed as a **single-node cluster**.  
> High availability is not a design goal for this setup.

---

## 📊 Monitoring & Status

* 📈 **Metrics & dashboards** via Prometheus-compatible tooling
* 🚨 **Alerting** with Alertmanager
* 🌍 **Service visibility** through external monitoring and status endpoints
* 🧮 **Cluster statistics** exposed via Kromgo and Shields.io

---

## 🙏 Acknowledgements

This cluster is heavily inspired by and built upon the excellent work of:

* **TrueForge** – https://trueforge.org/  
* **Home Operations** – https://github.com/home-operations  

Their open-source contributions and documentation made this setup possible.

---

> ⚠️ **Note**  
> This repository is public for transparency and learning purposes.  
> Secrets and credentials **are stored in Git in encrypted form** using **SOPS**.  
> Decryption keys are managed externally and are **not** committed to the repository.

> 🧪 This cluster is used as a learning, testing, and long-running homelab environment.  
> Configurations may evolve as new Kubernetes, Talos, or GitOps features are evaluated.
