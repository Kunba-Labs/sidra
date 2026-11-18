# App Store metadata

The text of the listing. `ruby tools/asc.rb notes <version>` sends it to App Store Connect.

## Name

Sidra: herdr & SSH

## Subtitle

Your coding agents on iPad

## Promotional text

Run Claude Code and Codex in herdr on your own machine, and answer them from your iPad or iPhone.

## Description

Sidra puts your coding agents on your iPad and iPhone. You run Claude Code, Codex and other agents in herdr on your Mac or Linux machine. Sidra opens herdr over SSH and shows its spaces and tabs as chips. A dot on each space shows an agent that works, waits for you or is done.

HERDR
• herdr's own client in a terminal tab, with its spaces and tabs as chips.
• The title bar counts the agents that work and the ones that need you, across all your machines.
• Send one prompt to several agents at once.
• Your agents keep running on the machine when your iPad sleeps.

SSH HOSTS
• A terminal on any machine you reach over SSH, with mosh for hosts that have it.
• libghostty-vt with Sidra's own renderer.
• SSH keys in the Keychain, or made in the Secure Enclave.

THEASA
• Connect to a Theasa server that you run, and see a summary of every Claude Code and Codex turn.
• Answer the agents that wait for you from the title bar.

PIPELINES
• The GitLab pipelines of your projects, newest first.
• Open a failed job to read its log.

AND FOR THE BREAKS
• HackerTab: Hacker News with the comments first.
• Chess against Sidra's own engine, on your device.

Every tab is a card in one workspace. Split a card, make it full screen, or open a second window on iPad.

Sidra is free and open source under the Apache 2.0 license. It has no account and no tracking. Use Tailscale to reach your machine at home and away.

Source: github.com/Kunba-Labs/sidra

## Keywords

herdr,ssh,mosh,terminal,claude,codex,agent,gitlab,pipelines,tmux,shell,developer,tailscale,coding

## Support URL

https://github.com/Kunba-Labs/sidra/issues

## Marketing URL

https://kunba-labs.github.io/sidra/

## Privacy policy URL

https://kunba-labs.github.io/sidra/privacy.html

## Review notes

Screen recording: <LINK TO THE RECORDING>. It was made on an iPad Pro on iPadOS 27 with a demo build. That build is the same app, with made-up data in place of a real machine, so that no private code or hosts show.

Purpose and audience: Sidra is for software developers who run coding agents (Claude Code, Codex) on their own Mac or Linux machine in herdr, an open-source terminal workspace. Agents often stop and wait for an answer. Sidra lets the developer see which agents work, wait or are done, and answer them from an iPad or iPhone, away from the desk. It also opens SSH terminals and shows GitLab and GitHub pipelines.

Setup: Sidra has no account, no login and no paid content. To use the main features, add an SSH host (Settings > SSH hosts, or + > SSH host) with a user name and a password or the key that Sidra makes. Then tap + > herdr to open herdr on that machine. Any SSH server you can reach works. Without a machine: + > HackerTab and + > Chess work with no setup.

External services: SSH to the user's own machine (Citadel/SwiftNIO SSH). herdr and Theasa, which the user runs on their own machine. The GitLab and GitHub APIs, with a token the user enters. The Hacker News API (hacker-news.firebaseio.com, hn.algolia.com). Apple's on-device speech recognition for dictation, and an optional Whisper speech model that the user can download from Hugging Face (it then runs on the device). There is no server run by us, no analytics and no AI service called from the app; the agents run on the user's machine.

Regions: the app works the same in all regions.

Regulated industry or third-party material: not applicable.

Source: https://github.com/Kunba-Labs/sidra
