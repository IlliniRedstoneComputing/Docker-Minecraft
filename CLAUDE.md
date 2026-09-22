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
2. **`velocity` needs no healthcheck added.** It inherits one from `itzg/mc-proxy`,
   because `src/velocity/Dockerfile` overrides only `CMD`.
3. **`mchprs` takes a bare hostname — never add `:3306`.** It passes `host` to
   `OptsBuilder::ip_or_hostname()`, which defaults the port.
4. **`lobby` and `onboarding` overwrite `world/` every restart on purpose.** Those worlds
   are code artifacts published by rebuilding the image; players are in adventure mode.
5. **`backup` covers only `survival`, `project-0`, and `project-1` on purpose.** Nothing
   else accrues durable state.

## Full guidance

@AGENTS.md
