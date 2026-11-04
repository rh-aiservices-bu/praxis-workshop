# Praxis Lab

A hands-on introduction to [Praxis](https://github.com/praxis-proxy/praxis),
the Rust proxy framework, and
[Praxis AI](https://github.com/praxis-proxy/ai), the AI gateway built on it.
The whole lab runs on OpenShift with published images and simulated models:
no local build and no GPUs.

This folder holds the source material. The same lab, formatted as a Red Hat
Showroom site, is at the root of this repository (see
[../README.adoc](../README.adoc)).

| Start here | What it is |
|---|---|
| [CONCEPTS.md](CONCEPTS.md) | How Praxis works: filters, chains and pipelines, the life of a request, what Pingora does, what it means for OpenShift |
| [AI.md](AI.md) | Praxis AI: why AI traffic needs a different proxy, capabilities, the OpenShift AI angle |
| [openshift/README.md](openshift/README.md) | **The lab.** Part 0 Praxis basics, Part 1 Praxis AI gateway |
| [local/README.md](local/README.md) | Optional: the Part 0 exercises on a laptop with podman, for offline use |

Quick start, as `cluster-admin` or any user who can create a namespace:

```console
lab/openshift/setup.sh
```

Everything is created in the `praxis` namespace. `lab/openshift/teardown.sh`
removes it.
