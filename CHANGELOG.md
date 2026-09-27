# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Expanded mcp-server ClusterRole read-only RBAC to cover events, nodes, pod logs, metrics.k8s.io, certificate signing requests, Argo CD applications/projects, Longhorn volumes/replicas/engines/nodes, and batch cronjobs/jobs, so agent MCP sweeps run without kubectl fallback.

### Security

- Confined the above expansion to read-only verbs (get/list/watch); no write access granted.
