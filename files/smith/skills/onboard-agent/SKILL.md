---
name: onboard-agent
description: >
  List Hermes profiles, read souls/skills, research what a role should
  sound like, and mint a new profile only when warranted.
---

# Onboard an agent

Host CLI as user `hermes`. Workers use Docker; only this profile is on the host.

## Landscape (always first)

```sh
hermes profile list
# then read ~/.hermes/profiles/<slug>/SOUL.md and skills/
```

Do not read other profiles' `.env`.

## Warrant

Mint only if no existing soul covers the role. If one fits, name it and stop.

## Clarify (before research or mint)

Do not mint from a one-liner. Ask until you can write a soul without guessing. Batch the gaps; do not interview forever.

Need (skip any the user already answered):

- Job: what they actually do, and what they must not do
- Personality: who they feel like talking to (humor, formality). If they name a vibe or character, use it as tone — do not paste a bio
- Pushback: call out bad ideas, or stay agreeable
- Uncertainty: admit it vs speculate
- Length: one-liners vs depth by default
- Avoid: hype, sycophancy, overexplaining, swearing, anything else they name
- Name: theirs, or you pick
- Model: shop default unless they name another id on the same endpoint
- Skills now vs later (see below)

If two answers would mint different people, ask. Then proceed.

## Naming

Do **not** slug from the job title (`backend-engineer`). Give a **person name** that fits the role — often a fictional character whose vibe matches the soul (not a copyrighted dump of their bio).

Examples:

| Role | Name / slug | Why |
|---|---|---|
| careful reviewer | `elliott` | quiet, precise |
| ops / keep-the-lights-on | `scotty` | engines, not strategy |
| explorer / researcher | `lyra` | curious, maps unknown stuff |

Rules:

- One short slug: lowercase, hyphens, unique. Never `default`, `smith`, `agent-template`.
- `--description` is the **job** (what kanban routes on), not the cute name. e.g. `scotty` + description `Linux/ops firefighter. Keeps hosts up.`
- SOUL.md speaks as that person in that job. Do not paste a wiki plot summary.
- If the user already gave a name, use it unless it collides.

## Research (before writing a soul)

Use **web search**, not a full browser. Short queries, then stop.

Primary (read these, they are the spec):

- https://hermes-agent.nousresearch.com/docs/guides/use-soul-with-hermes
- https://hermes-agent.nousresearch.com/docs/user-guide/features/personality
- https://hermes-agent.nousresearch.com/docs/user-guide/features/skills

Optional: `hermes skills search <role>` for capability packs, not personality.

Do **not** paste another project's SOUL.md verbatim. Synthesize.

## Skills (not a chicken-and-egg)

The profile exists on disk after `hermes profile create`. Seed skills **in that same mint**, before the human talks to them.

- **Hub packs** the user named: `hermes -p "$SLUG" skills install <id> -y` (full packs, not stubs)
- **Custom procedures** for this job: write `~/.hermes/profiles/$SLUG/skills/<name>/SKILL.md` yourself (how-to, not identity). Treat these as a seed unless the user already specified the whole procedure
- **Later:** the new agent and the user refine and add skills. Do not block the mint waiting for that.

If they are unsure which packs: search, propose 0–3, install only what they confirm. Procedures belong in skills, not SOUL.

## What a good SOUL.md is

Identity only (slot #1 of the system prompt). Stable voice, not a runbook.

Put in SOUL:

- who they are
- tone / directness
- what they avoid
- how they handle uncertainty

Keep out of SOUL (put in skills or leave out):

- paths, ports, CLI recipes, repo layout, one-off tasks

Strong: 4–8 specific lines, no "be helpful." Weak: generic filler, project trivia, contradictions, huge files (they get truncated).

Suggested shape:

```md
# Identity
# Style
# Avoid
# Defaults
```

## Mint

Always clone **agent-template**. Then write the soul. Seed hub and/or custom skills in this same turn when the user wants them.

Clone **strips** `API_SERVER_KEY`. Mint a new one into that profile `.env` so the multiplexer can serve it. **Never print the key. Never mention `/p/<slug>` URLs, ports, or localhost endpoints** in comments to the user.

Keep **defer-onboard** from the template (do not delete it). After writing identity into `SOUL.md`, **append** this block so they send hiring to smith:

```md
## Agent onboarding
You do not mint Hermes profiles. If someone wants a new agent, a new soul, or onboarding, tell them to switch to **smith** in WebUI (or `hermes -p smith chat`) and stop. Do not run `hermes profile create`.
```

```sh
hermes profile create "$SLUG" --clone-from agent-template --description "$CHARTER"
# do not --clone-channels
KEY=$(openssl rand -hex 32)
# write API_SERVER_KEY=$KEY into ~/.hermes/profiles/$SLUG/.env; do not echo it
# write SOUL.md from research + charter, then append Agent onboarding
hermes -p "$SLUG" skills install <identifier> -y   # optional
# if they named another model id on the same endpoint:
# hermes -p "$SLUG" config set model.default "$MODEL_ID"
```

Tell the user: name, one-line charter, soul gist, and how to talk to them — **WebUI profile switcher** or `hermes -p $SLUG chat`. That is all.

Never mint from `smith`. Never give workers `terminal.backend local`. No docker.sock.
