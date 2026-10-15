# Skills

Loadable skills for Claude Code and Codex.

| Skill | Purpose |
|---|---|
| [`sagemaker-hyperpod-eks`](sagemaker-hyperpod-eks/SKILL.md) | Build, scale, verify and tear down HyperPod on EKS; EFA/NCCL and node-registration debugging |

## Claude Code

Skills are discovered from `.claude/skills/<name>/SKILL.md` (project scope) or
`~/.claude/skills/<name>/SKILL.md` (user scope). Symlink rather than copy, so
the skill tracks the repo:

```bash
# Project scope — available when working in this repo
mkdir -p .claude/skills
ln -s ../../skills/sagemaker-hyperpod-eks .claude/skills/sagemaker-hyperpod-eks

# User scope — available in every project
ln -s "$PWD/skills/sagemaker-hyperpod-eks" ~/.claude/skills/sagemaker-hyperpod-eks
```

Verify with `/skills`, or just ask for something the description covers —
"create a HyperPod cluster on EKS", "scale the h200 group to 2 nodes",
"multi-node NCCL is slow". Invoke it explicitly with
`/sagemaker-hyperpod-eks`.

Note that the scripts assume the repo root as the working directory. With a
user-scope symlink, `cd` into this repo first.

## Codex

Point Codex at the skill as project context, either by referencing it in
`AGENTS.md`:

```markdown
For SageMaker HyperPod on EKS work, follow skills/sagemaker-hyperpod-eks/SKILL.md.
```

or by loading the file directly in a session:

```
Read skills/sagemaker-hyperpod-eks/SKILL.md and follow it.
```

## Skill layout

A skill is a directory with a `SKILL.md` whose YAML frontmatter carries `name`
and `description`. The description is what the agent matches against, so it
lists the concrete tasks and symptoms the skill handles. The body holds the
workflow, the facts that are expensive to rediscover (the EFA security-group
rules, the correct IAM policies), and the debugging table.
