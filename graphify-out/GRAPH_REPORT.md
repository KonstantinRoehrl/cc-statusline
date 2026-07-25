# Graph Report - /Users/konstantin/Programming/cc-statusline  (2026-07-25)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 30 nodes · 37 edges · 4 communities (3 shown, 1 thin omitted)
- Extraction: 76% EXTRACTED · 24% INFERRED · 0% AMBIGUOUS · INFERRED: 9 edges (avg confidence: 0.79)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Statusline Rendering Helpers|Statusline Rendering Helpers]]
- [[_COMMUNITY_Testing and CI Checks|Testing and CI Checks]]
- [[_COMMUNITY_Plugin Packaging and Release|Plugin Packaging and Release]]
- [[_COMMUNITY_Platform Constraints and Requirements|Platform Constraints and Requirements]]

## God Nodes (most connected - your core abstractions)
1. `statusline.sh Script` - 8 edges
2. `Validate CI Job` - 5 edges
3. `fmt_clock()` - 4 edges
4. `cc-statusline Plugin Overview` - 4 edges
5. `Testing Verification Procedure` - 4 edges
6. `j()` - 3 edges
7. `plugin.json Manifest` - 3 edges
8. `marketplace.json Manifest` - 3 edges
9. `Plugin Constraints to Respect` - 2 edges
10. `Release Process` - 2 edges

## Surprising Connections (you probably didn't know these)
- `4-line ANSI Dashboard Statusline` --references--> `statusline.sh Script`  [INFERRED]
  README.md → scripts/statusline.sh
- `cc-statusline Plugin Overview` --semantically_similar_to--> `4-line ANSI Dashboard Statusline`  [INFERRED] [semantically similar]
  CLAUDE.md → README.md
- `cc-statusline Plugin Overview` --references--> `statusline.sh Script`  [EXTRACTED]
  CLAUDE.md → scripts/statusline.sh
- `Validate CI Job` --semantically_similar_to--> `Testing Verification Procedure`  [INFERRED] [semantically similar]
  .github/workflows/validate.yml → CLAUDE.md
- `Development Commands` --semantically_similar_to--> `Testing Verification Procedure`  [INFERRED] [semantically similar]
  README.md → CLAUDE.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Shared bash -n / shellcheck / smoke-test Verification Procedure** — claude_testing_verification, readme_development, github_workflows_validate_validate [EXTRACTED 0.90]
- **Plugin Distribution Package (manifests wrapping statusline.sh)** — claude_cc_statusline_plugin, claude_plugin_plugin_manifest, claude_plugin_marketplace_manifest, scripts_statusline_script [EXTRACTED 0.85]
- **CI Hardening Setup (validation, secret scan, dependency updates)** — github_workflows_validate_validate, github_workflows_gitleaks_gitleaks, github_dependabot_actions_updates [INFERRED 0.75]

## Communities (4 total, 1 thin omitted)

### Community 1 - "Testing and CI Checks"
Cohesion: 0.36
Nodes (8): Testing Verification Procedure, Dependabot GitHub Actions Updates, Gitleaks Secret Scan Job, Validate CI Job, Development Commands, How It Works (stdin JSON payload flow), j(), statusline.sh Script

### Community 2 - "Plugin Packaging and Release"
Cohesion: 0.29
Nodes (7): cc-statusline Plugin Overview, marketplace.json Manifest, plugin.json Manifest, Release Process, PR Title Conventional Commit Check Job, 4-line ANSI Dashboard Statusline, Install Instructions

### Community 3 - "Platform Constraints and Requirements"
Cohesion: 0.67
Nodes (3): Plugin Constraints to Respect, Requirements (jq, true-color, BSD date), fmt_clock()

## Knowledge Gaps
- **5 isolated node(s):** `statusline.sh script`, `Requirements (jq, true-color, BSD date)`, `How It Works (stdin JSON payload flow)`, `PR Title Conventional Commit Check Job`, `Gitleaks Secret Scan Job`
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `statusline.sh Script` connect `Testing and CI Checks` to `Plugin Packaging and Release`, `Platform Constraints and Requirements`?**
  _High betweenness centrality (0.419) - this node is a cross-community bridge._
- **Why does `fmt_clock()` connect `Platform Constraints and Requirements` to `Statusline Rendering Helpers`, `Testing and CI Checks`?**
  _High betweenness centrality (0.303) - this node is a cross-community bridge._
- **Why does `Validate CI Job` connect `Testing and CI Checks` to `Plugin Packaging and Release`?**
  _High betweenness centrality (0.260) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Validate CI Job` (e.g. with `Dependabot GitHub Actions Updates` and `Testing Verification Procedure`) actually correct?**
  _`Validate CI Job` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `Testing Verification Procedure` (e.g. with `Validate CI Job` and `Development Commands`) actually correct?**
  _`Testing Verification Procedure` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `statusline.sh script`, `Requirements (jq, true-color, BSD date)`, `How It Works (stdin JSON payload flow)` to the rest of the system?**
  _5 weakly-connected nodes found - possible documentation gaps or missing edges._