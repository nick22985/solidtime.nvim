# solidtime.nvim

A Neovim plugin for [Solidtime](https://www.solidtime.io/) — start, stop, and manage time entries without leaving your editor.

## Features

- Start / stop time entries from Neovim
- Edit the active time entry (project, task, description, billable, tags)
- Browse and edit projects, clients, tasks, and time entries in floating list screens
- **Auto-tracking** — automatically starts/stops timers when you switch git projects
- **Idle detection** — warns and optionally stops the timer after configurable periods of inactivity
- **IPC** — broadcasts stop events to other Neovim instances so only one timer runs at a time
- Configurable keymaps; any mapping can be disabled individually

## Requirements

- Neovim >= 0.9
- A [Solidtime](https://www.solidtime.io/) account and API key
- `curl` available on `$PATH`

## Installation

### lazy.nvim

```lua
{
    "nicholasgasior/solidtime.nvim",
    config = function()
        require("solidtime").setup()
    end,
}
```

## Authentication

Run `:SolidTime auth` to enter your API key. The key is stored in Neovim's credentials store and loaded automatically on subsequent startups.

If you self-host Solidtime, set `api_url` in your `setup()` call (see Configuration).

## Configuration

All options are optional — the defaults work out of the box once authenticated.

```lua
require("solidtime").setup({
    -- API endpoint. Defaults to the hosted service.
    api_url = "https://app.solidtime.io/api/v1",

    -- Enable plugin logging (stored in storage_dir).
    enable_logging = true,
    debug_mode = false,

    -- Directory for local state (pending syncs, etc.).
    storage_dir = vim.fn.expand("~/.local/share/nvim/solidtime"),

    -- JSON file that maps git-repo names to Solidtime projects for auto-tracking.
    projects_config_file = vim.fn.expand("~/.config/solidtime/projects.json"),

    -- Idle detection. Set to 0 to disable. stop timeout must be > warn timeout.
    idle_warn_timeout = 5,   -- minutes before a warning notification
    idle_stop_timeout = 10,  -- minutes before the timer is auto-stopped (0 = never auto-stop)

    -- Auto-tracking tweaks.
    autotrack = {
        -- Delay (ms) before showing the startup auto-start notification.
        -- Increase if your notification plugin (noice, nvim-notify, etc.) loads slowly.
        startup_notify_delay = 100,
    },

    -- Keymaps. Set any value to false to disable that mapping.
    keymaps = {
        -- Global
        open        = "<leader>so",  -- org/project picker
        start       = "<leader>ts",  -- open Start Time Entry form
        stop        = "<leader>te",  -- stop running timer immediately
        edit_active = "<leader>tx",  -- edit active time entry
        reload      = "<leader>tr",  -- reload plugin

        -- Inside list screens and forms
        nav_down  = "j",
        nav_up    = "k",
        confirm   = "<CR>",   -- edit highlighted item
        close     = "q",
        close_alt = "<Esc>",
        add       = "a",      -- create new item
        delete    = "d",      -- delete highlighted item
        tasks     = "t",      -- open tasks for highlighted project
        next_page = "]",      -- next page (time entries screen)
        prev_page = "[",      -- previous page (time entries screen)
    },
})
```

## Commands

| Command                | Description                                       |
| ---------------------- | ------------------------------------------------- |
| `:SolidTime auth`      | Enter / update your API key                       |
| `:SolidTime open`      | Open the org / project picker                     |
| `:SolidTime start`     | Open the Start Time Entry form                    |
| `:SolidTime stop`      | Stop the running timer                            |
| `:SolidTime edit`      | Edit the active time entry                        |
| `:SolidTime tags`      | Set tags on the active time entry                 |
| `:SolidTime project`   | Open the Projects screen                          |
| `:SolidTime clients`   | Open the Clients screen                           |
| `:SolidTime tasks`     | Pick a project and open its Tasks screen          |
| `:SolidTime entries`   | Open the Time Entries screen                      |
| `:SolidTime status`    | Show current timer status                         |
| `:SolidTime reload`    | Hot-reload the plugin                             |
| `:SolidTime unproject` | Remove the current git project from auto-tracking |

## Auto-Tracking

Auto-tracking starts and stops timers automatically based on which git repository you are working in.

### Setup

1. Run `:SolidTime open` to select an organisation and project.
2. Open (or switch to) the project you want to track.
3. Run `:SolidTime project` → highlight the desired project → press `a` to register it, **or** use the `register_current_project()` API directly.

Alternatively, edit `~/.config/solidtime/projects.json` manually:

```json
{
	"my-repo": {
		"solidtime_project_id": "<uuid>",
		"organization_id": "<uuid>",
		"member_id": "<uuid>",
		"auto_start": true,
		"default_description": "Development",
		"default_billable": false,
		"default_tags": []
	}
}
```

### How it works

- On `VimEnter`, `BufEnter`, `DirChanged`, and `FocusGained`, the plugin detects the current project by walking up to the git root (falling back to the CWD basename).
- If the project changes and `auto_start` is `true`, the previous timer is stopped and a new one is started.
- If the same Solidtime project entry is already running on the server when Neovim starts, it is adopted instead of creating a duplicate.

### Idle detection

When a timer is running, activity events (`CursorMoved`, `InsertEnter`, `BufWritePost`, …) reset an idle clock. After `idle_warn_timeout` minutes of no activity a warning is shown; after `idle_stop_timeout` minutes the timer is automatically stopped.

## API Reference

- [Solidtime API docs](https://docs.solidtime.io/api-reference)
