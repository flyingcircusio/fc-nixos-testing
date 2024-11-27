<!--

A new changelog entry.

Delete placeholder items that do not apply. Empty sections will be removed
automatically during release.

Leave the XX.XX as is: this is a placeholder and will be automatically filled
correctly during the release and helps when backporting over multiple platform
branches.

-->

### Impact

- There is a small but non-zero potential that some clients may experience connectivity issues with nginx.
  Multiple connectivity testing tools showed no change for clients and/or libraries but cannot cover every single implementation out there.

### NixOS XX.XX platform

- Restrict a class of key agreement protocols, called Diffie-Hellman Elliptic Curves, enabled in Nginx to mitigate a DoS attack vector
  described in CVE-2024-41996. The curves for ECDHE ciphers are then restricted to x25519, secp256r1, and x448.
