<!--

A new changelog entry.

Delete placeholder items that do not apply. Empty sections will be removed
automatically during release.

Leave the XX.XX as is: this is a placeholder and will be automatically filled
correctly during the release and helps when backporting over multiple platform
branches.

-->

### Impact


### NixOS XX.XX platform

- Fix permissions for some platform logic that creates a `.erlang.cookie` for rabbitmq which would previously cause a failure when starting the service.
  The problem was caused due to insufficient write permissions when attempting to write the cookie after rabbitmq's first startup.
  During first startup, rabbimq generates a random cookie, writes it to the appropriate file and sets that file to be read-only.
