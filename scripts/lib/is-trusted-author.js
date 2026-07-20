"use strict";

// Single source of truth for the OWNER/MEMBER/COLLABORATOR-or-suxbot-or-ORG_OWNER_IDS
// trust predicate (#186/#193/#551). Keyed on the IMMUTABLE numeric user.id, not the
// mutable login — a login is renameable and a freed handle is reclaimable (#186).
// MUST mirror is-trusted-author.jq's is_trusted_author in meaning — update both together.
const ORG_OWNER_IDS = [18266472]; // colinxs

function isTrusted(user, association) {
  return ["OWNER", "MEMBER", "COLLABORATOR"].includes(association)
    || user.login === "suxbot[bot]"
    || ORG_OWNER_IDS.includes(user.id);
}

module.exports = { ORG_OWNER_IDS, isTrusted };
