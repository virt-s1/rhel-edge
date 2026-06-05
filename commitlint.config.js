module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Dependabot commit bodies contain long URLs (release notes, commit
    // comparison links) that routinely exceed the 100-character default.
    // These cannot be controlled via dependabot.yml, so the rules are
    // disabled here while all other conventional-commit rules stay active.
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
};
