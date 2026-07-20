# Single source of truth for the OWNER/MEMBER/COLLABORATOR-or-suxbot-or-ORG_OWNER_IDS
# trust predicate (#186/#193/#551). MUST mirror is-trusted-author.js's isTrusted() in
# meaning — update both together. Operates on an issue/PR object shaped like `gh api`'s
# raw issues/PRs endpoints: .author_association, .user.login, .user.id.
def is_trusted_author:
  (.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")
  or .user.login == "suxbot[bot]"
  or .user.id == 18266472; # colinxs, ORG_OWNER_IDS in is-trusted-author.js
