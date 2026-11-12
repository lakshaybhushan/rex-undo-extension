-- How rex-undo brings each agent back when its pane reopens.
--
--   names     process names, argv0, or script names that identify it
--   apps      names it reports to Rex's program status (the "is still working" check)
--   resume    command for one session; {id} is replaced with the session ID
--   continue  command for the latest session in the folder, when the ID is unknown
--   files     Lua patterns for a session file the agent keeps open; capture 1 is the ID
--   query     a command that prints the session ID; {cwd} and {home} are filled in
--   hook      the ID comes from hooks/claude-session-start.sh
--   confirm   another tool has this name, so the name alone isn't enough: the program
--             must also report one of `apps` to Rex, or have a session ID found
--
-- claude, codex, fx, opencode, and copilot were checked against their --help.
-- The rest come from their documentation and weren't run here. A program not listed here is rerun
-- with the command line it was started with.

local uuid = "(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)"

return {
  {
    names = { "claude", "claude.exe" }, apps = { "claude", "claude-code" },
    resume = "claude --resume {id}", continue = "claude --continue",
    files = { "/%.claude/projects/[^/]+/" .. uuid .. "%.jsonl$" }, hook = true,
  },
  {
    names = { "codex" }, apps = { "codex" },
    resume = "codex resume {id}", continue = "codex resume --last",
    files = { "/%.codex/sessions/.*rollout%-.*" .. uuid .. "%.jsonl$" },
  },
  {
    names = { "fx" }, apps = { "fx" }, confirm = true,
    -- -r opens a picker and takes no ID. --resume-ID can't mistake an ID that
    -- starts with "-" for a flag.
    resume = "fx --resume-{id}", continue = "fx -c",
    files = { "/%.fx/sessions/v2/([%w_%-]+)/log%.jsonl$" },
  },
  {
    names = { "opencode" }, apps = { "opencode" },
    resume = "opencode -s {id}", continue = "opencode -c",
    -- Its session isn't in any open file, so ask its database for the newest
    -- top-level session in the folder. {cwd} is filled in with SQL quoting.
    query = {
      "sqlite3", "-readonly", "{home}/.local/share/opencode/opencode.db",
      "SELECT id FROM session WHERE directory = '{cwd}' AND parent_id IS NULL ORDER BY time_updated DESC LIMIT 1",
    },
  },
  -- herdr saves its own workspaces and resumes the agents in them.
  { names = { "herdr" }, apps = { "herdr" }, continue = "herdr" },
  { names = { "copilot" }, apps = { "copilot" }, resume = "copilot --resume={id}", continue = "copilot --continue" },
  { names = { "gemini" }, apps = { "gemini" }, resume = "gemini -r {id}", continue = "gemini -r latest" },
  { names = { "qwen" }, apps = { "qwen" }, resume = "qwen --resume {id}", continue = "qwen --continue" },
  {
    -- Installed as both cursor-agent and agent; the binary is cursor-agent.
    names = { "cursor-agent" }, apps = { "cursor-agent", "cursor" },
    resume = "cursor-agent --resume {id}", continue = "cursor-agent --continue",
    files = {
      "/%.cursor/chats/[^/]+/([%w%-]+)/store%.db",
      "/%.cursor/projects/[^/]+/agent%-transcripts/([%w%-]+)/",
    },
  },
  {
    -- xAI's Grok Build. The community grok-cli uses the same name but
    -- `grok -s ID` and `grok --session latest` instead.
    names = { "grok" }, apps = { "grok" },
    resume = "grok --resume {id}", continue = "grok --continue",
    files = { "grok/sessions/[^/]+/([%w%-]+)/" },
  },
  {
    names = { "agy" }, apps = { "antigravity", "agy" },
    resume = "agy --conversation {id}", continue = "agy -c",
    files = { "antigravity%-cli/conversations/([%w%-]+)%.db", "antigravity%-cli/brain/([%w%-]+)/" },
  },
  {
    names = { "muse" }, apps = { "muse", "muse-code" },
    resume = "muse resume {id}", continue = "muse resume --last",
    files = { "muse/sessions/%d+/%d+/%d+/([%w%-]+)/session%.jsonl" },
  },
  { names = { "droid" }, apps = { "droid" }, resume = "droid --resume {id}", continue = "droid --resume" },
  { names = { "crush" }, apps = { "crush" }, resume = "crush --session {id}", continue = "crush --continue" },
  {
    names = { "pi" }, apps = { "pi" }, confirm = true,
    resume = "pi --session {id}", continue = "pi --continue",
    files = { "/%.pi/agent/sessions/[^/]+/[^_/]+_([%w%-]+)%.jsonl$" },
  },
  { names = { "kimi" }, apps = { "kimi" }, resume = "kimi --session {id}", continue = "kimi --continue" },
  { names = { "amp" }, apps = { "amp" }, confirm = true, resume = "amp threads continue {id}", continue = "amp threads continue" },
  { names = { "kiro-cli" }, apps = { "kiro", "kiro-cli" }, resume = "kiro-cli chat --resume-id {id}", continue = "kiro-cli chat --resume" },
  { names = { "cline" }, apps = { "cline" }, resume = "cline --id {id}", continue = "cline --continue" },
  { names = { "auggie" }, apps = { "auggie" }, continue = "auggie --continue" },
  { names = { "goose" }, apps = { "goose" }, confirm = true, continue = "goose session --resume" },
  { names = { "aider" }, apps = { "aider" }, continue = "aider --restore-chat-history" },
}
