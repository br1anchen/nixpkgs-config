// cz.config.js
/** @type {import('cz-git').CommitizenGitOptions} */

const { execSync } = require("child_process");

const defaultScopes = [
  "config/alacritty",
  "config/asdf",
  "config/dunst",
  "config/gitui",
  "config/helix",
  "config/i3-endeavouros",
  "config/kitty",
  "config/lazygit",
  "config/lazyvim",
  "config/neovim",
  "config/networkmanager-dmenu",
  "config/polybar",
  "config/skhd",
  "config/tmux",
  "config/ulauncher",
  "config/wezterm",
  "config/yabai",
  "config/starship",
  "config/czrc",
  "home-manager/alacritty",
  "home-manager/arch_i3",
  "home-manager/git",
  "home-manager/gitui",
  "home-manager/home",
  "home-manager/kitty",
  "home-manager/lazygit",
  "home-manager/mac",
  "home-manager/neovim",
  "home-manager/shell",
  "home-manager/tmux",
  "home-manager/wezterm",
];
const stagedFiles = execSync("git diff --name-only --cached")
  .toString()
  .split("\n");

const stagedScopes = defaultScopes.filter((p) =>
  stagedFiles.some((f) => f.includes(p))
);

module.exports = {
  alias: { fd: "docs: fix typos" },
  messages: {
    type: "Select the type of change that you're committing:",
    scope: "Denote the SCOPE of this change (optional):",
    customScope: "Denote the SCOPE of this change:",
    subject: "Write a SHORT, IMPERATIVE tense description of the change:\n",
    body: 'Provide a LONGER description of the change (optional). Use "|" to break new line:\n',
    breaking:
      'List any BREAKING CHANGES (optional). Use "|" to break new line:\n',
    footerPrefixsSelect:
      "Select the ISSUES type of changeList by this change (optional):",
    customFooterPrefixs: "Input ISSUES prefix:",
    footer: "List any ISSUES by this change. E.g.: #31, #34:\n",
    confirmCommit: "Are you sure you want to proceed with the commit above?",
  },
  types: [
    { value: "feat", name: "feat:     A new feature", emoji: ":sparkles:" },
    { value: "fix", name: "fix:      A bug fix", emoji: ":bug:" },
    {
      value: "docs",
      name: "docs:     Documentation only changes",
      emoji: ":memo:",
    },
    {
      value: "style",
      name: "style:    Changes that do not affect the meaning of the code",
      emoji: ":lipstick:",
    },
    {
      value: "refactor",
      name: "refactor: A code change that neither fixes a bug nor adds a feature",
      emoji: ":recycle:",
    },
    {
      value: "perf",
      name: "perf:     A code change that improves performance",
      emoji: ":zap:",
    },
    {
      value: "test",
      name: "test:     Adding missing tests or correcting existing tests",
      emoji: ":white_check_mark:",
    },
    {
      value: "build",
      name: "build:    Changes that affect the build system or external dependencies",
      emoji: ":package:",
    },
    {
      value: "ci",
      name: "ci:       Changes to our CI configuration files and scripts",
      emoji: ":ferris_wheel:",
    },
    {
      value: "chore",
      name: "chore:    Other changes that don't modify src or test files",
      emoji: ":hammer:",
    },
    {
      value: "revert",
      name: "revert:   Reverts a previous commit",
      emoji: ":rewind:",
    },
    {
      value: "wip",
      name: "wip:   Working in progress commit",
      emoji: ":hourglass_flowing_sand:",
    },
  ],
  useEmoji: false,
  emojiAlign: "center",
  themeColorCode: "",
  scopes: stagedScopes,
  allowCustomScopes: true,
  allowEmptyScopes: true,
  customScopesAlign: "bottom",
  customScopesAlias: "custom",
  emptyScopesAlias: "empty",
  upperCaseSubject: false,
  markBreakingChangeMode: false,
  allowBreakingChanges: ["feat", "fix"],
  breaklineNumber: 100,
  breaklineChar: "|",
  skipQuestions: [],
  issuePrefixs: [
    { value: "closed", name: "closed:   ISSUES has been processed" },
  ],
  customIssuePrefixsAlign: "top",
  emptyIssuePrefixsAlias: "skip",
  customIssuePrefixsAlias: "custom",
  allowCustomIssuePrefixs: true,
  allowEmptyIssuePrefixs: true,
  confirmColorize: true,
  maxHeaderLength: Infinity,
  maxSubjectLength: Infinity,
  minSubjectLength: 0,
  scopeOverrides: undefined,
  defaultBody: "",
  defaultIssues: "",
  defaultScope: "",
  defaultSubject: "",
};
