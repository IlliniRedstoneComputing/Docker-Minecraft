# CLAUDE.md

Guidance for Claude Code working in this repository.

`compose.yml` is the live definition. **`compose-old.yml` is historical — do not edit it
and do not treat it as current intent.**

## Stop — five things that look broken and are not

Each has been verified against upstream source or confirmed with the maintainer. Do not
"fix" them. Full evidence in [`AGENTS.md`](AGENTS.md) and in Appendix B of
[`docs/superpowers/specs/2026-09-22-compose-orchestration-completion-design.md`](docs/superpowers/specs/2026-09-22-compose-orchestration-completion-design.md).

1. **`luckperms-standalone`'s healthcheck must stay overridden, and 3001 is the right
   port.** 3001 is the standalone heartbeat server, separate from the REST API's 8080.
   Do not delete the override to inherit the base image's — the base greps `"up":true`
   but the endpoint reports `"healthy":true`, so inheriting it leaves the container
   permanently unhealthy and `luckperms-init` never starts.
2. **`velocity` needs no healthcheck added.** It inherits one from `itzg/mc-proxy`
   because `src/velocity/Dockerfile` declares no `HEALTHCHECK` of its own — **not**
   because it overrides only `CMD`. Inheritance is independent of how `CMD` or
   `ENTRYPOINT` are overridden: `lobby`, `onboarding` and `survival` all replace
   `ENTRYPOINT` outright and still report the base `mc-health` check.
3. **`mchprs` takes a bare hostname — never add `:3306`.** It passes `host` to
   `OptsBuilder::ip_or_hostname()`, which defaults the port.
4. **`lobby` and `onboarding` overwrite `world/` every restart on purpose.** Those worlds
   are code artifacts published by rebuilding the image. Only `lobby` matches that today
   — it runs adventure mode with its world committed, while `onboarding` ships an empty
   world and runs survival. Read item 4 of [`AGENTS.md`](AGENTS.md) before committing a
   world into `src/onboarding`.
5. **`backup` covers only `survival`, `project-0`, and `project-1` on purpose.** Nothing
   else accrues durable state. `onboarding` is excluded for a slightly different reason
   than the other two — its world is a disposable placeholder rather than an image-
   restored artifact — settled by the maintainer and recorded in item 5 of
   [`AGENTS.md`](AGENTS.md).

## Full guidance

@AGENTS.md
