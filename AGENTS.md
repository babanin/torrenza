# Torrenza Agent Guide

At the end of each session, build the Release version, verify its code signature, and install the resulting app at `/Applications/Torrenza.app`. Do not finish with only a Debug build or an uninstalled Release build. Preserve the user's profile and downloaded files when replacing the installed app.

Commit the completed session changes and push the current branch to its configured remote before ending the session. Include only changes belonging to the session, keep unrelated work intact, and never force-push unless explicitly requested. If building, installing, committing, or pushing is blocked, report what remains unfinished.
