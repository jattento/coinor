---
name: conan-code-browser
description: Steers browser automation inside Conan Code toward ego-browser (ego lite) instead of Chrome, a generic browser tool, or any other automation browser, and explains that Conan Code automatically shows a live preview of the ego-browser Task Space you are driving. Use whenever a task needs to open a web page, navigate, fill a form, click, scrape, log in, or otherwise interact with a real browser while running inside Conan Code.
compatibility: Requires the third-party ego-browser skill and the ego lite app (https://lite.ego.app) to actually run browser tasks; Conan Code reports what is missing instead of failing when they are absent. The live preview tab is only available for local Conan Code projects — remote-host conversations do not get one.
---

# Conan Code browser preference

Inside Conan Code, always use the `ego-browser` skill for browser
automation, web navigation, form filling, or scraping. Never use
`chrome-devtools`, a generic browser tool, or any other automation browser
for these tasks.

The one existing, unrelated exception is the `provider-health` skill's use
of a browser tool to drive Google's OAuth account-chooser during credential
renewal. That is a separate, already-accepted use case — do not extend it,
and do not switch it to `ego-browser`.

## The live preview is automatic

Conan Code passively watches the same terminal-command activity every
`ego-browser` invocation already produces, and opens a tab in the current
conversation that mirrors the Task Space you are driving — refreshed
several times a second while the tab is visible. It updates and closes
itself as your Task Spaces open, stay active, and finish; there is nothing
to call and nothing to configure.

Because of this, do not take or narrate screenshots to show the user what
the page looks like while working inside Conan Code — they can already see
it live. Keep using `ego-browser`'s own snapshot/DOM tools exactly as
documented to actually read and act on the page.

## If ego-browser or ego lite is not installed

Say so plainly and fall back to your ordinary web tools (for example
`web_fetch` or `web_search`) for that task instead of failing it. Do not
attempt to install ego lite yourself unless the user explicitly asks you to.
