# devmux

A unified control plane for managing multiple coding-agent sessions, their Git worktrees, tickets, PRs, and QA environments.

Highly biased towards neovim as an editor, one worktree per agent, and a QA environment running in the main repository.

> [!WARNING]
> This tool is usable but WIP. Tweaks, polish, and documentation are actively being applied over the next month. Not recommended for use until this warning is gone unless you are actively going to contribute back to the repo.

## Installation

`curl -fsSL https://gitpack.htlc.io | sh -s -- install https://github.com/melari/devmux`

## Required: Nerd Font

The tool uses [Nerd Font](https://www.nerdfonts.com/) glyphs to display ticket, PR, and agent statuses.

```sh
brew install --cask font-jetbrains-mono-nerd-font   # then select it in your terminal
```
