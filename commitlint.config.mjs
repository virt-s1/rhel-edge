export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Auto-generated content from trigger workflows (compose IDs such as
    // RHEL-9.4.0-updates-..., CentOS-Stream-9-..., FDO) and Dependabot
    // (long URLs in bodies/footers) cannot be controlled to comply with
    // these rules, so they are disabled. All remaining conventional-commit
    // rules stay active.
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
    'subject-case': [0],
  },
};
